// 职责：table 的引用生命周期、raw 操作、遍历与数组检查。
// 每次操作恢复入口栈；临时引用不跨所属 Binding 回调。
#include "lua_table.h"
extern "C"
{
#include <lauxlib.h>
}
#include <algorithm>

namespace flywow_lua_binding
{
LuaTable::LuaTable(LuaBinding *binding, int reference) : binding_(binding), reference_(reference)
{
}
LuaTable::~LuaTable()
{
    reset();
}

LuaTable::LuaTable(LuaTable &&other) noexcept
    : binding_(other.binding_), reference_(other.reference_)
{
    other.binding_   = nullptr;
    other.reference_ = LUA_NOREF;
}

LuaTable &LuaTable::operator=(LuaTable &&other) noexcept
{
    if (this != &other)
    {
        reset();
        binding_         = other.binding_;
        reference_       = other.reference_;
        other.binding_   = nullptr;
        other.reference_ = LUA_NOREF;
    }
    return *this;
}

void LuaTable::reset() noexcept
{
    if (valid())
    {
        // 释放 registry 引用不弹栈。Lua 若还保存返回结果/字段引用，该表仍存活。
        // luaL_unref：释放此 owner 持有的 registry 引用编号，不弹栈、不直接销毁对象；其它 Lua 引用仍可保持对象存活。
        luaL_unref(binding_->state_, LUA_REGISTRYINDEX, reference_);
    }
    binding_   = nullptr;
    reference_ = LUA_NOREF;
}

bool LuaTable::valid() const
{
    return binding_ != nullptr && reference_ >= 0;
}

bool LuaTable::requireValid() const
{
    if (valid())
    {
        return true;
    }
    if (binding_ != nullptr)
    {
        binding_->setError("INVALID_ARGUMENT", "table handle is invalid");
    }
    return false;
}

bool LuaTable::push() const
{
    // reference_ 是 registry 引用编号，不是业务数组 key。
    // rawgeti 压入同一 table：[S] -> [S, table]，不触发 __index。
    // 句柄继续持有 registry 引用；外层保护器只弹掉这份临时栈引用。
    // lua_rawgeti：按整数 key 从指定 table/registry 取值并压栈：[S] -> [S, value]；不触发 __index，源表和原引用保留。
    lua_rawgeti(binding_->state_, LUA_REGISTRYINDEX, reference_);
    return true;
}

bool LuaTable::pushField(const std::string &key) const
{
    // [S, table, key] -> [S, table, value]，rawget 消耗 key；源表不弹出。
    // pushlstring 保留 key 的完整字节，不将内嵌零字节误当字符串结束。
    if (!push())
    {
        return false;
    }
    // lua_pushlstring：按显式长度复制字节为 Lua 字符串并压栈：[S] -> [S, string]；保留内嵌零字节，不借用 C++ 缓冲区。
    lua_pushlstring(binding_->state_, key.data(), key.size());
    // lua_rawget：消耗栈顶 key 并压入原始字段值：[S, key] -> [S, value]；不触发 __index，目标 table 不弹出。
    lua_rawget(binding_->state_, -2);
    return true;
}

bool LuaTable::pushWriteKey(const std::string &key) const
{
    if (!push())
    {
        return false;
    }
    if (key == "__gc")
    {
        binding_->setError("INVALID_ARGUMENT", "__gc is managed by userdata registration");
        return false;
    }
    // lua_pushlstring：按显式长度复制字节为 Lua 字符串并压栈：[S] -> [S, string]；保留内嵌零字节，不借用 C++ 缓冲区。
    lua_pushlstring(binding_->state_, key.data(), key.size());
    return true;
}

bool LuaTable::forEach(const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const
{
    if (!requireValid())
    {
        return false;
    }
    if (!visitor)
    {
        binding_->setError("INVALID_ARGUMENT", "table visitor must not be empty");
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    if (!push())
    {
        return false;
    }
    // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
    const int table_index = lua_gettop(binding_->state_); // 固定源表，嵌套操作不改变它。
    return visitEntries(table_index, visitor);
}

// 源表已在 table_index；外层 forEach 持有 StackRestore，负责成功/失败/异常的栈恢复。
// key/value 生命周期和 lua_next 的下一轮条件放在同一处，避免恢复栈时误删迭代 key。
bool LuaTable::visitEntries(
    int table_index, const std::function<bool(const LuaValue &, const LuaValue &)> &visitor) const
{
    /*
        `lua_next` 要求调用时栈顶有一个 key。第一次遍历还没有上一轮的 key，所以先压入 `nil`：
        [S, table]
        压入 nil：[S, table, nil]
        然后：
        lua_next(state, table_index);
        Lua 会把这个 `nil` 当作“从头开始”，并在有条目时把它替换为第一对 key/value：
        [S, table, nil] → [S, table, key, value]
    */
    lua_pushnil(binding_->state_);
    // lua_next 消耗旧 key，成功时压入新 key/value；结束时不压值。
    // [S, table, nil/key] -> [S, table, key, value]，第一轮 nil 表示开始。
    // lua_next：消耗上一轮 key；成功压入下一对 key/value，结束不压值。每轮只弹 value，保留未经转换的 key；初始 key 为 nil。
    while (lua_next(binding_->state_, table_index) != 0)
    {
        // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
        const int           iteration_top = lua_gettop(binding_->state_);
        const std::uint64_t revision      = binding_->error_revision_;
        const LuaValue      key(binding_, iteration_top - 1);
        const LuaValue      value(binding_, iteration_top);
        if (!visitor(key, value))
        {
            if (revision == binding_->error_revision_)
            {
                binding_->setError("INTERNAL_ERROR",
                                   "table visitor failed without recording error");
            }
            return false;
        }
        // 回调临时值清理后，保留原 key，只弹 value，供下次 lua_next 使用。
        // 不对数值 key 原位 tostring；异常/失败则由整个操作的保护器恢复 [S]。
        // lua_settop：将栈恢复到指定高度：多出的槽被移除，增加高度则补 nil；此处按保存的基线清理临时值，不释放 registry 引用。
        lua_settop(binding_->state_, iteration_top);
        // lua_pop：移除指定数量的栈顶临时值；不会直接销毁仍被 registry/字段/闭包引用的对象，遍历时必须保留下一轮所需 key。
        lua_pop(binding_->state_, 1);
    }
    return true;
}

bool LuaTable::arrayLength(std::size_t &output) const
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    if (!push())
    {
        return false;
    }
    // 不改变 [S, table]，不调用 __len；返回数组边界，不证明数组无空洞。
    // 稀疏表可能有多个合法边界；出口由保护器移除临时 table，恢复 [S]。
    // lua_rawlen：读取原始长度，不调用 __len、不改变栈；table 为数组边界，full userdata 为分配字节数，不能混淆。
    output = lua_rawlen(binding_->state_, -1);
    return true;
}

bool LuaTable::denseArrayLength(std::size_t &output) const
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    if (!push())
    {
        return false;
    }
    // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
    const int   table_index = lua_gettop(binding_->state_);
    lua_Integer max_index   = 0; // 正整数数组 key 的最大值；命名字段和非正 key 不计入。
    std::size_t entries     = 0; // 每个 table key 唯一，entries==max_index 才说明没有空洞。
    // nil 启动遍历：[S, table] -> [S, table, nil]；nil 不是实际字段 key。
    // next 消耗旧 key，成功压入新 key/value；结束弹掉最后 key，留下 [S, table]。
    // 每轮只弹 value，保留未经转换的原 key；成功/失败出口由保护器恢复 [S]。
    // lua_pushnil：压入 nil：[S] -> [S, nil]；作为错误首返回值或 table 遍历起始 key，具体用途由当前操作决定。
    lua_pushnil(binding_->state_);
    // lua_next：消耗上一轮 key；成功压入下一对 key/value，结束不压值。每轮只弹 value，保留未经转换的 key；初始 key 为 nil。
    while (lua_next(binding_->state_, table_index) != 0)
    {
        // lua_isinteger：检查该槽是否为 Lua 整数，不接受浮点或数字字符串；不转换原值、不改变栈，返回非零表示符合。
        if (lua_isinteger(binding_->state_, -2))
        {
            // lua_tointeger：读取已验证槽内的整数，不增减栈项；目标 C++ 类型的范围仍需单独校验，不能直接截断。
            const lua_Integer key = lua_tointeger(binding_->state_, -2);
            if (key > 0)
            {
                max_index = std::max(max_index, key);
                ++entries;
            }
        }
        // lua_pop：移除指定数量的栈顶临时值；不会直接销毁仍被 registry/字段/闭包引用的对象，遍历时必须保留下一轮所需 key。
        lua_pop(binding_->state_, 1); // 保留 key、移除 value，继续同一次迭代。
    }
    if (static_cast<std::uintmax_t>(max_index) != entries)
    {
        binding_->setError("INVALID_ARGUMENT",
                           "positive integer keys must form a dense 1-based array");
        return false;
    }
    output = entries; // 空表 max_index/entries 均为 0，是否允许空由业务决定。
    return true;
}

bool LuaTable::setMetatable(const LuaTable &meta)
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    if (!push())
    {
        return false;
    }
    if (!binding_->pushValue(meta))
    {
        return false;
    }
    // [S, table, meta] -> [S, table]：setmetatable 消耗 meta，不销毁 meta 引用。
    // lua_setmetatable：把栈顶 table/nil 设置为指定对象的 metatable，然后弹出栈顶值；对象本身保留，不销毁 metatable。
    lua_setmetatable(binding_->state_, -2);
    return true;
}

bool LuaTable::readMetatable(LuaTable &output) const
{
    if (!requireValid())
    {
        return false;
    }
    detail::StackRestore stack(binding_->state_);
    if (!push())
    {
        return false;
    }
    // 有 metatable：[S, table] -> [S, table, meta]；没有则不压值，返回 0。
    // readTableAt 为 meta 建立独立 registry 引用；临时 table/meta 出栈不使句柄失效。
    // lua_getmetatable：对象有 metatable 时压入它并返回 1；没有则不压值并返回 0。后续栈恢复必须覆盖成功与失败路径。
    if (lua_getmetatable(binding_->state_, -1) == 0)
    {
        binding_->setError("INVALID_ARGUMENT", "table has no metatable");
        return false;
    }
    return binding_->readTableAt(-1, output);
}

LuaType LuaValue::type() const
{
    // 查看本轮固定槽，不压栈或转换原 key，保证后续 lua_next 可以继续。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    switch (lua_type(binding_->state_, index_))
    {
    case LUA_TBOOLEAN:
        return LuaType::kBoolean;
    case LUA_TNUMBER:
        return LuaType::kNumber;
    case LUA_TSTRING:
        return LuaType::kString;
    case LUA_TTABLE:
        return LuaType::kTable;
    case LUA_TFUNCTION:
        return LuaType::kFunction;
    case LUA_TUSERDATA:
        return LuaType::kUserdata;
    case LUA_TLIGHTUSERDATA:
        return LuaType::kLightUserdata;
    case LUA_TTHREAD:
        return LuaType::kThread;
    default:
        return LuaType::kNil;
    }
}
bool LuaValue::isNil() const
{
    // lua_isnil：检查该槽是否恰为 nil，不改变栈；缺失字段由 rawget 产生 nil，无效槽则不是 nil。
    return lua_isnil(binding_->state_, index_);
}
bool LuaValue::readTable(LuaTable &output) const
{
    return binding_->readTableAt(index_, output);
}
bool LuaValue::readTruth(bool &output) const
{
    return binding_->readTruthAt(index_, output);
}
} // namespace flywow_lua_binding
