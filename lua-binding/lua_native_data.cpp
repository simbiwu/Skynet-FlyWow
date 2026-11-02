// 数据树及 Lua 代理转换。沿用 Binding 当前直接 Lua API 路径，OOM 交由宿主处理。
// 普通参数错误先以 C++ 异常展开临时树，再由元方法出口转换成 Lua error。
#include "lua_native_data.h"
#include <limits>
#include <set>
#include <stdexcept>

namespace flywow_lua_binding
{
LuaNativeData::LuaNativeData() : proxy_state_(std::make_shared<LuaNativeDataProxyState>())
{
    proxy_state_->node = this;
}
LuaNativeData::~LuaNativeData() noexcept
{
    proxy_state_->node = nullptr;
}
const LuaNativeDataValue *LuaNativeData::get(const LuaNativeDataKey &key) const
{
    auto it = fields_.find(key); // 当前键对应的字段；地址由容器持有。
    return it == fields_.end() ? nullptr : &it->second;
}
void LuaNativeData::set(const LuaNativeDataKey &key, LuaNativeDataValue value)
{
    // 这是 C++ 公开写入入口；内部始终只挂接已完整构造的非空子树。
    if (auto child = std::get_if<std::unique_ptr<LuaNativeData>>(&value); child && !*child)
    {
        throw std::invalid_argument("NativeData child must not be null");
    }
    fields_.insert_or_assign(key, std::move(value));
}
void LuaNativeData::erase(const LuaNativeDataKey &key)
{
    fields_.erase(key);
}
std::unique_ptr<LuaNativeData> LuaNativeData::clone() const
{
    auto copy = std::make_unique<LuaNativeData>(); // 新树在返回前仅归本作用域所有。
    for (const auto &[key, value] : fields_)
    {
        std::visit(
            [&](const auto &field)
            {
                using T = std::decay_t<decltype(field)>;
                if constexpr (std::is_same_v<T, std::unique_ptr<LuaNativeData>>)
                {
                    copy->set(key, field->clone());
                }
                else
                {
                    copy->set(key, field);
                }
            },
            value);
    }
    return copy;
}
std::size_t LuaNativeData::size() const noexcept
{
    return fields_.size();
}
std::size_t LuaNativeData::arrayLength() const
{
    std::size_t length = 0; // 已找到的连续正整数键数量；空容器为零。
    for (std::int64_t key = 1; fields_.find(key) != fields_.end(); ++key)
    {
        ++length;
        if (key == std::numeric_limits<std::int64_t>::max())
        {
            break;
        }
    }
    return length;
}
const LuaNativeData::FieldMap &LuaNativeData::fields() const noexcept
{
    return fields_;
}
const std::shared_ptr<LuaNativeDataProxyState> &LuaNativeData::proxyState() const noexcept
{
    return proxy_state_;
}

namespace
{
constexpr const char *kTypeName = "flywow_lua_binding.LuaNativeData";
constexpr const char *kExpired  = "LuaNativeData node has expired";

// 元方法不能返回 nil,error：赋值语法会忽略它。普通错误展开所有 Native 资源后才进入 Lua。
// state 是 Lua 传入的参数栈；成功保持目标元方法结果数，普通错误在展开后抛 Lua error。
template <lua_CFunction Function> int metamethod(lua_State *state)
{
    const char *failure = nullptr; // 错误文本都是静态存储，不依赖已展开的异常对象。
    try
    {
        return Function(state);
    }
    catch (const char *message)
    {
        failure = message;
    }
    catch (...)
    {
        failure = "NativeData operation failed";
    }
    return luaL_error(state, "%s", failure);
}

// 验证精确元表、存储大小和构造标记；不检查节点，交给真实访问入口检查一次。
// state/index 指定当前 Lua 参数；返回 userdata 中借用的代理，不拥有其内存。
LuaNativeDataUserdata *readProxy(lua_State *state, int index)
{
    auto *proxy = static_cast<LuaNativeDataUserdata *>(luaL_testudata(state, index, kTypeName));
    if (!proxy || lua_rawlen(state, index) != sizeof(LuaNativeDataUserdata))
    {
        throw "NativeData userdata required";
    }
    // [S] -> [S, alive] -> [S]，读取 uservalue 后必须弹出，即使其不存在。
    const int  marker_type = lua_getiuservalue(state, index, 1); // 构造标记必须为 boolean。
    const bool alive       = marker_type == LUA_TBOOLEAN &&
                       lua_toboolean(state, -1) != 0; // placement-new 是否完成且尚未析构。
    lua_pop(state, 1);
    if (!alive)
    {
        throw kExpired;
    }
    return proxy;
}

// 每个 Lua 访问入口调用一次；返回值只借用到本同步访问完成。
// state/index 指向访问对象；返回同步访问借用节点，类型或失效错误向元方法出口传播。
LuaNativeData *readNode(lua_State *state, int index)
{
    auto *proxy = readProxy(state, index);  // Lua 参数对应的代理存储。
    auto *node  = proxy->proxy_state->node; // 唯一节点存活检查，不在 get/set 内重复。
    if (!node)
    {
        throw kExpired;
    }
    return node;
}

// 只读取真实整数或字符串槽，避免把 lua_next 保留的数字键转换成字符串。
// state/index 指定下标槽；返回独立的键内容，非法键抛静态错误并由元方法转换。
LuaNativeDataKey readKey(lua_State *state, int index)
{
    if (lua_isinteger(state, index))
    {
        return static_cast<std::int64_t>(lua_tointeger(state, index));
    }
    if (lua_type(state, index) == LUA_TSTRING)
    {
        std::size_t length = 0;                                    // 包含内嵌零字节的完整键长度。
        const char *bytes  = lua_tolstring(state, index, &length); // 当前栈保活的 Lua 字符串。
        return std::string(bytes, length);
    }
    throw "NativeData key must be a string or integer";
}

// 根、子代理共用这一个构造路径；子代理的 root 参数为空。
// state 接收一个新 userdata；root 是可为空的根 owner，identity 是分配前复制的节点通知。
void pushProxy(lua_State *state, const std::shared_ptr<LuaNativeData> &root,
               std::shared_ptr<LuaNativeDataProxyState> identity)
{
    // identity 按值接收，Lua 分配触发根 GC 后也能安全构造一个已失效代理。
    // 元表由根 Codec 建立；子代理来源已经过精确元表验证，无需重复登记。
    // [S] -> [S, userdata]；先禁用析构，挂接元表后再 placement-new。
    void *storage = lua_newuserdatauv(state, sizeof(LuaNativeDataUserdata), 1);
    lua_pushboolean(state, 0);
    lua_setiuservalue(state, -2, 1);
    luaL_getmetatable(state, kTypeName);
    lua_setmetatable(state, -2);
    new (storage) LuaNativeDataUserdata{root, identity};
    // shared_ptr 复制不抛异常；构造完成后启用一次性析构，存储由 Lua 回收。
    lua_pushboolean(state, 1);
    lua_setiuservalue(state, -2, 1);
}

// 分配 Lua 值只可能按宿主 OOM 规则退出；不调用用户元方法或业务回调。
// state 接收一个 Lua 结果；value 借用节点字段，Lua 分配完成后不再读取原字段。
void pushValue(lua_State *state, const LuaNativeDataValue &value)
{
    std::visit(
        [&](const auto &field)
        {
            using T = std::decay_t<decltype(field)>;
            if constexpr (std::is_same_v<T, bool>)
            {
                lua_pushboolean(state, field);
            }
            else if constexpr (std::is_same_v<T, std::int64_t>)
            {
                lua_pushinteger(state, field);
            }
            else if constexpr (std::is_same_v<T, double>)
            {
                lua_pushnumber(state, field);
            }
            else if constexpr (std::is_same_v<T, std::string>)
            {
                // 宿主 lua_pushlstring 先复制内容并压栈，再检查 GC；正常路径无需 C++ 副本。
                // OOM 的紧急 GC 与恢复沿用宿主规则，不在此增加保活或恢复流程。
                lua_pushlstring(state, field.data(), field.size());
            }
            else
            {
                pushProxy(state, {}, field->proxyState());
            }
        },
        value);
}

// 递归链只属于本次赋值；所有子树完整构造后才移动挂接，不保存 Lua 引用。
// state/index 是来源字段；ancestors 是当前 table 递归链，返回尚未挂接的独立值。
LuaNativeDataValue readValue(lua_State *state, int index, std::set<const void *> &ancestors)
{
    index = lua_absindex(state, index); // 递归压栈后仍指向当前来源值。
    switch (lua_type(state, index))
    {
    case LUA_TBOOLEAN:
        return lua_toboolean(state, index) != 0;
    case LUA_TNUMBER:
        if (lua_isinteger(state, index))
        {
            return static_cast<std::int64_t>(lua_tointeger(state, index));
        }
        return static_cast<double>(lua_tonumber(state, index));
    case LUA_TSTRING:
    {
        std::size_t length = 0;                                    // 当前字段值的完整字节数。
        const char *bytes  = lua_tolstring(state, index, &length); // 借用到字符串副本创建完成。
        return std::string(bytes, length);
    }
    case LUA_TUSERDATA:
        return readNode(state, index)->clone();
    case LUA_TTABLE:
    {
        // C++ 递归不会建立新的 Lua 调用帧。每层预留 key/value 两槽，
        // 并留两槽供嵌套 userdata 的精确元表检查；下一层 table 自行继续预留。
        // lua_checkstack 返回失败时先通过 C++ 展开临时树，再由元方法出口抛错。
        if (!lua_checkstack(state, 4))
        {
            throw "NativeData table copy exceeds Lua stack capacity";
        }
        const void *identity = lua_topointer(state, index); // 本次来源 table 的身份，只用于环检测。
        if (!ancestors.insert(identity).second)
        {
            throw "NativeData cannot copy a cyclic table";
        }
        auto child = std::make_unique<LuaNativeData>(); // 尚未挂接，普通错误由 unique_ptr 释放。
        lua_pushnil(state);
        // [S, key] -> [S, key, value]；递归返回后只弹 value，保留 key 给下一次 lua_next。
        while (lua_next(state, index))
        {
            auto key   = readKey(state, -2);              // 当前来源字段的键，按原始字段读取。
            auto value = readValue(state, -1, ancestors); // 完整的新字段值，子树只转换一次。
            child->set(key, std::move(value));
            lua_pop(state, 1);
        }
        ancestors.erase(identity); // 退出当前递归链；兄弟位置重复出现同一表仍可独立复制。
        return child;
    }
    default:
        throw "unsupported NativeData value";
    }
}

// Lua 字段读取：缺失是 nil；子节点仅返回不拥有子树的代理。
// state 参数 1/2 是代理和键；压入一个字段结果，不存在时压 nil。
int __index(lua_State *state)
{
    auto       *node  = readNode(state, 1); // 此次访问的 Native 节点。
    auto        key   = readKey(state, 2);  // Lua 下标，不做数字字符串转换。
    const auto *value = node->get(key);     // 借用节点字段，压栈期间没有业务回调修改它。
    if (!value)
    {
        lua_pushnil(state);
    }
    else
    {
        pushValue(state, *value);
    }
    return 1;
}

// Lua 字段写入：转换和 clone 完成之前不触碰旧字段。
// state 参数 1/2/3 是代理、键和新值；返回零项，普通转换失败由外层抛错。
int __newindex(lua_State *state)
{
    auto *node = readNode(state, 1); // 目标节点，访问入口只检查一次存活。
    auto  key  = readKey(state, 2);  // 被删除或替换的字段键。
    if (lua_isnil(state, 3))
    {
        node->erase(key);
        return 0;
    }

    std::set<const void *> ancestors;            // 本次导入的当前递归路径；操作结束即释放。
    auto value = readValue(state, 3, ancestors); // 尚未挂接的完整值，失败时旧值保持。
    node->set(key, std::move(value));
    return 0;
}

// state 参数 1 是代理；返回连续正整数键的长度，失效代理由外层抛错。
int __len(lua_State *state)
{
    lua_pushinteger(state, readNode(state, 1)->arrayLength());
    return 1;
}

// pairs 的下一项按 map 顺序定位；不保留迭代器，因此没有跨调用的迭代状态。
// state 参数 1/2 是容器代理和上次键；返回下一 key/value 或零项表示结束。
int next_native(lua_State *state)
{
    auto       *node   = readNode(state, 1); // pairs 返回的迭代容器，必须仍存活。
    const auto &fields = node->fields();     // 本次访问借用的原始字段，不创建快照。
    auto        it     = fields.begin();     // nil 控制键表示从第一项开始。
    if (!lua_isnil(state, 2))
    {
        it = fields.upper_bound(readKey(state, 2));
    }
    if (it == fields.end())
    {
        return 0;
    }

    // pushValue 可能触发根 GC，先复制键，并先压 value；之后不再访问字段迭代器。
    auto key_copy = it->first; // 本次输出键的独立内容副本。
    pushValue(state, it->second);
    std::visit(
        [&](const auto &key)
        {
            using T = std::decay_t<decltype(key)>;
            if constexpr (std::is_same_v<T, std::int64_t>)
            {
                lua_pushinteger(state, key);
            }
            else
            {
                lua_pushlstring(state, key.data(), key.size());
            }
        },
        key_copy);
    lua_insert(state, -2); // [S, value, key] -> [S, key, value]。
    return 2;
}

// state 参数 1 是容器代理；返回 next_native、同一代理和 nil，不保存迭代快照。
int __pairs(lua_State *state)
{
    readNode(state, 1);
    lua_pushcfunction(state, metamethod<next_native>);
    lua_pushvalue(state, 1);
    lua_pushnil(state);
    return 3;
}

// state 参数 1/2 是待比较代理；返回节点身份是否相同，不访问 Native 节点内容。
int __eq(lua_State *state)
{
    auto *left  = readProxy(state, 1); // 左侧代理，只比较身份，节点可以已经失效。
    auto *right = readProxy(state, 2); // 右侧代理，不访问 Native 节点。
    lua_pushboolean(state, left->proxy_state.get() == right->proxy_state.get());
    return 1;
}

// GC 可以由 Lua 重复触发或手工调用；只析构已构造且尚未回收的同类型存储。
// state 参数 1 是待析构 userdata；无返回值，标记保证显式调用和 GC 不重复析构。
int __gc(lua_State *state) noexcept
{
    auto *proxy = static_cast<LuaNativeDataUserdata *>(luaL_testudata(state, 1, kTypeName));
    if (!proxy || lua_rawlen(state, 1) != sizeof(LuaNativeDataUserdata))
    {
        return 0;
    }
    const int  marker_type = lua_getiuservalue(state, 1, 1); // 拒绝非 boolean 的伪造构造标记。
    const bool alive       = marker_type == LUA_TBOOLEAN &&
                       lua_toboolean(state, -1) != 0; // Lua 存储中的一次性构造标记。
    lua_pop(state, 1);
    if (alive)
    {
        lua_pushboolean(state, 0);
        lua_setiuservalue(state, 1, 1);
        proxy->~LuaNativeDataUserdata();
    }
    return 0;
}

// 同一 State 的多 .so 复用 registry 具名元表；首次创建才填充固定元方法。
// state 是当前 Lua State；注册完成后栈高度不变，多次调用不替换原元表。
void ensureMetatable(lua_State *state)
{
    if (luaL_newmetatable(state, kTypeName))
    {
        static const luaL_Reg methods[] = {
            {"__index", metamethod<__index>},
            {"__newindex", metamethod<__newindex>},
            {"__len", metamethod<__len>},
            {"__pairs", metamethod<__pairs>},
            {"__eq", metamethod<__eq>},
            {"__gc", __gc},
            {nullptr, nullptr},
        };
        luaL_setfuncs(state, methods, 0);
    }
    lua_pop(state, 1); // [S, metatable] -> [S]，不影响待返回的 userdata。
}
} // namespace

bool detail::ValueCodec<std::shared_ptr<LuaNativeData>>::push(
    lua_State *state, const std::shared_ptr<LuaNativeData> &root, const char **reason)
{
    if (!root)
    {
        *reason = "NativeData root must not be null";
        return false;
    }
    ensureMetatable(state); // 仅根输出负责幂等注册；子代理直接复用该 State 的元表。
    pushProxy(state, root, root->proxyState());
    return true;
}

bool LuaBinding::readNativeData(int index, LuaNativeData *&output)
{
    LuaNativeDataUserdata *proxy = nullptr; // 由现有 Binding 保活到本同步回调结束的代理。
    if (!readUserdata(index, kTypeName, proxy))
    {
        return false;
    }
    auto *node = proxy->proxy_state->node; // 唯一 Native 节点有效性检查；子代理不额外保活根。
    if (!node)
    {
        setError("INVALID_ARGUMENT", kExpired);
        return false;
    }
    output = node;
    return true;
}
} // namespace flywow_lua_binding
