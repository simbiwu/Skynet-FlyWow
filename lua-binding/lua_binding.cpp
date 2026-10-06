// 职责：集中实现 Lua 入口、错误、registry 引用、userdata 类型及 GC。
// 所有临时栈操作在此封装内部；业务 Binding 不使用 Lua C API。
#include "lua_binding.h"
#include "lua_table.h"

extern "C"
{
#include <lauxlib.h>
}

#include <exception>

namespace flywow_lua_binding
{
namespace
{
constexpr const char *kTypeField = "__flywow_userdata_type";
constexpr const char *kSizeField = "__flywow_userdata_size";

struct CallbackDescriptor
{
    const void *tag;
    Callback    callback; // 保存真正函数指针，不能把函数指针强转为 void*。
};

void rawField(lua_State *state, int index, const char *name)
{
    // 先固定源表；压入 key 后，传入的 -1 已经指向 key 而不是源表。
    // [S] -> [S, key] -> [S, field]；rawget 消耗 key，不触发 __index。
    // lua_absindex：将负的相对栈索引固定为绝对索引，避免后续压栈改变目标；不改变栈，upvalue 伪索引保持原值。
    const int absolute_index = lua_absindex(state, index);
    // lua_pushstring：复制以零字节结束的 C 字符串并压栈：[S] -> [S, string]；不会借用原地址，内嵌零字节需改用 pushlstring。
    lua_pushstring(state, name);
    // lua_rawget：消耗栈顶 key 并压入原始字段值：[S, key] -> [S, value]；不触发 __index，目标 table 不弹出。
    lua_rawget(state, absolute_index);
}

bool typeMatches(lua_State *state, int index, const void *type, std::size_t size)
{
    // 先固定 index，避免压入字段后负索引改指字段值；rawField 不触发元方法。
    // [S] -> [S, type] -> [S, type, size]，任一返回路径由保护器恢复 [S]。
    detail::StackRestore stack(state);
    // lua_absindex：将负的相对栈索引固定为绝对索引，避免后续压栈改变目标；不改变栈，upvalue 伪索引保持原值。
    const int            absolute_index = lua_absindex(state, index);
    // lua_istable：检查指定槽是否为 table，不转换值、不改变栈；非零表示符合，失败由封装返回普通错误。
    if (!lua_istable(state, absolute_index))
    {
        return false;
    }
    rawField(state, absolute_index, kTypeField);
    const bool matches =
        // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
        // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
        lua_type(state, -1) == LUA_TLIGHTUSERDATA && lua_touserdata(state, -1) == type;
    rawField(state, absolute_index, kSizeField);
    // lua_isinteger：检查该槽是否为 Lua 整数，不接受浮点或数字字符串；不转换原值、不改变栈，返回非零表示符合。
    return matches && lua_isinteger(state, -1) &&
           // lua_tointeger：读取已验证槽内的整数，不增减栈项；目标 C++ 类型的范围仍需单独校验，不能直接截断。
           lua_tointeger(state, -1) == static_cast<lua_Integer>(size);
}
} // namespace

namespace detail
{
bool ValueCodec<bool>::read(lua_State *state, int index, bool *output, std::string *reason)
{
    // type 只检查原槽；toboolean 本来接受任意类型，这里先限定为真正的 bool。
    // 不改变栈，false 是有效结果，不能用输出值本身判断读取是否成功。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state, index) != LUA_TBOOLEAN)
    {
        *reason = "value must be a boolean";
        return false;
    }
    // lua_toboolean：按 Lua 真值规则读取该槽：只有 nil/false 为假，0 和空串为真；不转换原值、不改变栈。
    *output = lua_toboolean(state, index) != 0;
    return true;
}

bool ValueCodec<bool>::push(lua_State *state, bool value, std::string *)
{
    // [S] -> [S, boolean]；false 也占一个值槽，不表示写入失败。
    // lua_pushboolean：压入布尔值：[S] -> [S, boolean]；false 同样是有效值并占一个栈槽。
    lua_pushboolean(state, value);
    return true;
}

bool ValueCodec<std::string>::read(lua_State *state, int index, std::string *output,
                                   std::string *reason)
{
    // 不允许数字到字符串的隐式转换。尤其 lua_next 的数字 key 不能被原位 tostring，
    // 否则下轮迭代拿到不同类型的 key，Lua 会认为它不是上一次返回的 key。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state, index) != LUA_TSTRING)
    {
        *reason = "value must be a string";
        return false;
    }
    std::size_t length = 0; // Lua 字符串长度，保留内嵌零字节。
    // 已确认是字符串，tolstring 不转换原槽；bytes 借用 Lua 内存，仅用于立即复制。
    // 按 length 复制（包括内嵌零字节），不依赖 C 字符串结束符；栈高度不变。
    // lua_tolstring：取得字符串地址及字节长度；地址由 Lua 持有。这里已检查字符串类型，不触发数字转字符串，不改变栈。
    const char *bytes  = lua_tolstring(state, index, &length);
    std::string value(bytes, length);
    *output = std::move(value);
    return true;
}

bool ValueCodec<std::string>::push(lua_State *state, const std::string &value, std::string *)
{
    // pushlstring 复制全部 bytes，Lua 持有自己的字符串，不借用 C++ buffer。
    // lua_pushlstring：按显式长度复制字节为 Lua 字符串并压栈：[S] -> [S, string]；保留内嵌零字节，不借用 C++ 缓冲区。
    lua_pushlstring(state, value.data(), value.size());
    return true;
}

bool ValueCodec<void *>::read(lua_State *state, int index, void **output, std::string *reason)
{
    // lightuserdata 是外部借用地址，不归 Lua 释放；读取不压栈、不注册 GC。
    // full userdata 必须走另一条类型/大小/metatable/存活状态校验路径。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state, index) != LUA_TLIGHTUSERDATA)
    {
        *reason = "value must be a borrowed lightuserdata pointer";
        return false;
    }
    // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
    *output = lua_touserdata(state, index);
    return true;
}
} // namespace detail

// lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
LuaBinding::LuaBinding(lua_State *state) : state_(state), entry_top_(lua_gettop(state))
{
}

LuaBinding::~LuaBinding()
{
    // luaL_unref 只释放本回调的 registry 引用，既不弹栈，也不直接调用析构。
    // 返回结果、table 字段或 closure 若仍引用对象，Lua GC 就不会回收它。
    for (const auto &entry : userdata_refs_)
    {
        // luaL_unref：释放此 owner 持有的 registry 引用编号，不弹栈、不直接销毁对象；其它 Lua 引用仍可保持对象存活。
        luaL_unref(state_, LUA_REGISTRYINDEX, entry.reference);
    }
}

bool LuaBinding::reserveStack(int slots)
{
    // 保证还有 slots 个可压入的槽，但不实际压值、不改变高度。
    // 大量 upvalue/返回值按实际数量扩容；失败记录错误，不跳过 C++ 栈析构。
    // lua_checkstack：保证还可压入指定数量的槽，不实际压入值、不改变高度；返回 0 表示扩容失败。
    if (!lua_checkstack(state_, slots))
    {
        setError("INTERNAL_ERROR", "cannot reserve Lua stack slots");
        return false;
    }
    return true;
}

int LuaBinding::initialize(lua_State *state, Callback callback)
{
    // ABI 检查可以由 Lua 以 longjmp 报错，所以放在创建 LuaBinding/C++ 业务对象之前。
    // 业务参数检查全部使用非抛错读取，以 bool/普通错误结果返回。
    // luaL_checkversion：校验宿主 Lua ABI，失败可能 longjmp；仅在构造 Binding/C++ 业务对象之前执行，不用于业务参数报错。
    luaL_checkversion(state);
    return invoke(state, callback);
}

int LuaBinding::invoke(lua_State *state, Callback callback)
{
    LuaBinding lua_binding(state);
    try
    {
        // 每条基础操作最多使用 8 个临时槽；大量返回值/closure 会单独按数量扩容。
        if (!lua_binding.reserveStack(8))
        {
            return lua_binding.pushError();
        }
        return lua_binding.runCallback(callback);
    }
    catch (const std::exception &exception)
    {
        // 业务局部对象已正常展开析构；只在 C ABI 边界转换，exception 不穿越 Lua。
        return lua_binding.pushError("INTERNAL_ERROR", exception.what());
    }
    catch (...)
    {
        return lua_binding.pushError("INTERNAL_ERROR", "unknown C++ exception");
    }
}

// 单独执行回调并核验结果；invoke 专注 C++ 异常边界和当前回调的资源 owner。
int LuaBinding::runCallback(Callback callback)
{
    if (callback == nullptr)
    {
        return pushError("INTERNAL_ERROR", "missing Native callback");
    }
    const int count = callback(*this);
    // 参数在基线以下，结果在基线以上；数量与实际栈都匹配，才交给 Lua。
    // 防止没有准备结果却手写 return 1；不根据 0/false 等业务值判断成功。
    // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
    if (!results_ready_ || count != result_count_ || lua_gettop(state_) != entry_top_ + count)
    {
        return pushError("INTERNAL_ERROR", "callback did not prepare valid results");
    }
    return count;
}

int LuaBinding::dispatch(lua_State *state)
{
    // 第 1 个内部 upvalue 是完整 userdata 描述，其后才是用户的 upvalue 1..N。
    // 类型/长度/tag 一起核验；业务只读得到映射后的编号。
    // lua_upvalueindex：生成当前 C 闭包的 upvalue 伪索引，不访问或改变栈；本封装槽 1 为内部描述，业务编号需偏移 1。
    const int descriptor_index = lua_upvalueindex(1);
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state, descriptor_index) != LUA_TUSERDATA ||
        // lua_rawlen：读取原始长度，不调用 __len、不改变栈；table 为数组边界，full userdata 为分配字节数，不能混淆。
        lua_rawlen(state, descriptor_index) != sizeof(CallbackDescriptor))
    {
        return invoke(state, nullptr);
    }
    const auto *descriptor =
        // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
        static_cast<const CallbackDescriptor *>(lua_touserdata(state, descriptor_index));
    if (descriptor->tag != detail::typeTag<CallbackDescriptor>())
    {
        return invoke(state, nullptr);
    }
    return invoke(state, descriptor->callback);
}

// LuaTable 通过这条内部函数构造描述；类型与 dispatch 必须在同一实现单元内一致。
void LuaTable::pushCallback(Callback callback)
{
    // lua_newuserdatauv：分配 Lua 管理的 full userdata 并压栈：[S] -> [S, userdata]；最后参数 0 表示无 uservalue，C++ 构造/析构需另行管理。
    void *storage = lua_newuserdatauv(binding_->state_, sizeof(CallbackDescriptor), 0);
    new (storage) CallbackDescriptor{detail::typeTag<CallbackDescriptor>(), callback};
    // 描述只含 tag 和函数指针，无 C++ 资源需析构；Lua 负责释放原始内存。
}

bool LuaBinding::validIndex(int index)
{
    // gettop 是栈项数量；正索引从底部 1 开始，负索引从顶部 -1 开始，0 无效。
    // 此处仅接受真实栈槽；upvalue 伪索引由专用入口校验。
    // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
    const int top = lua_gettop(state_); // 当前栈项数量，也是栈顶正索引；空栈为 0。
    if (index == 0 || index > top || index < -top)
    {
        setError("INVALID_ARGUMENT", "argument index outside current stack");
        return false;
    }
    return true;
}

int LuaBinding::upvalueIndex(int index)
{
    if (index < 1 || index > 254)
    {
        setError("INVALID_ARGUMENT", "upvalue index outside business range");
        return 0;
    }
    // 伪索引不随临时压栈变化；+1 跳过内部 callback descriptor。
    // lua_upvalueindex：生成当前 C 闭包的 upvalue 伪索引，不访问或改变栈；本封装槽 1 为内部描述，业务编号需偏移 1。
    const int actual = lua_upvalueindex(index + 1); // 业务编号映射为伪索引，跳过内部槽 1。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state_, actual) == LUA_TNONE)
    {
        setError("INVALID_ARGUMENT", "upvalue index is not present in this closure");
        return 0;
    }
    return actual;
}

void LuaBinding::setError(const std::string &code, const std::string &message)
{
    error_code_    = code;
    error_message_ = message;
    ++error_revision_;
}

const std::string &LuaBinding::errorCode() const
{
    return error_code_;
}
const std::string &LuaBinding::errorMessage() const
{
    return error_message_;
}

int LuaBinding::pushError()
{
    // 复制后再调用重载，避免 setError 自己覆盖所借用的字符串。
    const std::string code    = error_code_.empty() ? "INTERNAL_ERROR" : error_code_;
    const std::string message = error_code_.empty() ? "no recorded Binding error" : error_message_;
    return pushError(code, message);
}

int LuaBinding::pushError(const std::string &code, const std::string &message)
{
    setError(code, message);
    // lua_settop：将栈恢复到指定高度：多出的槽被移除，增加高度则补 nil；此处按保存的基线清理临时值，不释放 registry 引用。
    lua_settop(state_, entry_top_);

    // [参数] -> [参数, nil, error]；setfield 消耗字段值，保留结果 error table。
    // 最终结果故意留在栈上；没有 StackRestore，不能在返回前把 nil/error 弹掉。
    // lua_pushnil：压入 nil：[S] -> [S, nil]；作为错误首返回值或 table 遍历起始 key，具体用途由当前操作决定。
    lua_pushnil(state_);
    // lua_createtable：创建新 table 并压栈：[S] -> [S, table]；参数仅为数组/字段容量提示，不自动填入条目。
    lua_createtable(state_, 0, 2);
    // lua_pushlstring：按显式长度复制字节为 Lua 字符串并压栈：[S] -> [S, string]；保留内嵌零字节，不借用 C++ 缓冲区。
    lua_pushlstring(state_, error_code_.data(), error_code_.size());
    // lua_setfield：把栈顶值写入指定 table 的具名字段并弹出该值；目标 table 保留。此处目标为封装创建的无写入元方法表。
    lua_setfield(state_, -2, "code");
    // lua_pushlstring：按显式长度复制字节为 Lua 字符串并压栈：[S] -> [S, string]；保留内嵌零字节，不借用 C++ 缓冲区。
    lua_pushlstring(state_, error_message_.data(), error_message_.size());
    // lua_setfield：把栈顶值写入指定 table 的具名字段并弹出该值；目标 table 保留。此处目标为封装创建的无写入元方法表。
    lua_setfield(state_, -2, "message");
    result_count_  = 2;
    results_ready_ = true;
    return result_count_;
}

bool LuaBinding::readTableAt(int index, LuaTable *output)
{
    // lua_istable：检查指定槽是否为 table，不转换值、不改变栈；非零表示符合，失败由封装返回普通错误。
    if (output == nullptr || !lua_istable(state_, index))
    {
        setError("INVALID_ARGUMENT", "value must be a table and output must not be null");
        return false;
    }
    if (!reserveStack(1))
    {
        return false;
    }
    // 保存指定位置的 table，使 LuaTable 在临时栈变化后仍能找到同一对象。
    // pushvalue 复制 index 处的值到栈顶：[table] -> [table, table]；原值仍保留。
    // 复制的是同一 table 的引用，不会复制内容。
    // luaL_ref 把栈顶值存入 registry，返回引用编号，并弹掉刚复制的栈项。
    // 因而 [S] -> [S, table-copy] -> [S]，两句完成后栈高度恢复原样。
    // output 句柄持有编号，存活期间防止 table 被 GC；析构时 luaL_unref 释放此引用。
    // unref 不弹栈、不直接销毁 table；其它栈项/字段/句柄仍引用它时，它继续存活。
    // lua_pushvalue：复制指定槽内的值到栈顶：[S] -> [S, copy]；原槽保留，table/userdata 只复制引用，不复制内容。
    lua_pushvalue(state_, index);
    const int reference =
        // luaL_ref：将栈顶值保存到 registry 并弹出，返回引用编号；编号由对应句柄/回调持有并最终 unref，持有期间防止对象被 GC。
        luaL_ref(state_, LUA_REGISTRYINDEX); // output 句柄拥有的 registry 引用编号。
    *output = LuaTable(this, reference);
    return true;
}

bool LuaBinding::readTable(int index, LuaTable *output)
{
    return validIndex(index) && readTableAt(index, output);
}

bool LuaBinding::readTable(LuaTable *output)
{
    return readTable(-1, output);
}

LuaTable LuaBinding::newTable()
{
    if (!reserveStack(1))
    {
        return LuaTable(this, LUA_NOREF);
    }
    // [S] -> [S, new-table] -> [S]：newtable 压入新表，ref 消耗它并保存到 registry。
    // 返回句柄拥有这份引用；调用方不用维护栈顶，稍后析构只 unref。
    // lua_newtable：创建空 table 并压栈：[S] -> [S, table]；随后由 registry 引用持有，临时栈项不是唯一 owner。
    lua_newtable(state_);
    // luaL_ref：将栈顶值保存到 registry 并弹出，返回引用编号；编号由对应句柄/回调持有并最终 unref，持有期间防止对象被 GC。
    return LuaTable(this, luaL_ref(state_, LUA_REGISTRYINDEX));
}

bool LuaBinding::readUpvalueTable(int index, LuaTable *output)
{
    const int actual = upvalueIndex(index);
    return actual != 0 && readTableAt(actual, output);
}

bool LuaBinding::readTruthAt(int index, bool *output)
{
    if (output == nullptr)
    {
        setError("INVALID_ARGUMENT", "truth output must not be null");
        return false;
    }
    // 显式读取 Lua 真值：只有 nil/false 为假，0/空串为真；不转换或弹出原槽。
    // lua_toboolean：按 Lua 真值规则读取该槽：只有 nil/false 为假，0 和空串为真；不转换原值、不改变栈。
    *output = lua_toboolean(state_, index) != 0;
    return true;
}

bool LuaBinding::pushValue(const LuaTable &value)
{
    if (!value.valid() || value.binding_ != this)
    {
        setError("INVALID_ARGUMENT", "table must belong to this Binding callback");
        return false;
    }
    // registry -> 栈：另压一个同表引用；句柄稍后 unref 不会移除这个返回/写表引用。
    return value.push();
}

bool LuaBinding::pushValue(const char *value)
{
    if (value == nullptr)
    {
        setError("INVALID_ARGUMENT", "string pointer must not be null; use nullptr for Lua nil");
        return false;
    }
    // [S] -> [S, string]；Lua 复制字符串，以首个零字节结束，不借用 C++ 地址。
    // 要保留内嵌零字节时使用 std::string 的 pushlstring 分支。
    // lua_pushstring：复制以零字节结束的 C 字符串并压栈：[S] -> [S, string]；不会借用原地址，内嵌零字节需改用 pushlstring。
    lua_pushstring(state_, value);
    return true;
}

bool LuaBinding::pushValue(std::nullptr_t)
{
    // lua_pushnil：压入 nil：[S] -> [S, nil]；作为错误首返回值或 table 遍历起始 key，具体用途由当前操作决定。
    lua_pushnil(state_);
    return true;
}
bool LuaBinding::pushValue(void *value)
{
    // [S] -> [S, lightuserdata]；只保存地址，Lua 不析构或释放它指向的资源。
    // 外部 owner 要保证所有使用它的 Lua 字段/闭包存活期间，此地址一直有效。
    // lua_pushlightuserdata：压入外部借用地址：[S] -> [S, lightuserdata]；Lua 不释放其指向资源，外部 owner 必须保证生命周期。
    lua_pushlightuserdata(state_, value);
    return true;
}

bool LuaBinding::registerMetatable(const std::string &name, LuaTable *output, bool *created)
{
    if (output == nullptr || created == nullptr || name.empty() ||
        name.find('\0') != std::string::npos)
    {
        setError("INVALID_ARGUMENT", "metatable needs nonempty name and outputs");
        return false;
    }
    detail::StackRestore stack(state_);
    if (!reserveStack(4))
    {
        return false;
    }
    // [S] -> [S, meta]：newmetatable 首次创建与命中已有表都会压入 meta。
    // registry 持有具名表；readTableAt 再给调用方独立句柄引用，保护器清理临时栈项。
    // luaL_newmetatable：按名称查询或创建 registry 中的 metatable 并压栈；新建返回 1，已有返回 0，两条路径都留下 table。
    const bool first = luaL_newmetatable(state_, name.c_str()) != 0;
    LuaTable   meta;
    if (!readTableAt(-1, &meta))
    {
        return false;
    }
    *output  = std::move(meta);
    *created = first;
    return true;
}

bool LuaBinding::registerType(const std::string &name, const void *type, std::size_t size,
                              LuaTable *output, bool *created)
{
    if (output == nullptr || created == nullptr)
    {
        setError("INVALID_ARGUMENT", "userdata registration outputs must not be null");
        return false;
    }
    LuaTable meta;
    bool     first = false;
    if (!registerMetatable(name, &meta, &first))
    {
        return false;
    }
    detail::StackRestore stack(state_);
    if (!meta.push())
    {
        return false;
    }
    if (!first)
    {
        if (!typeMatches(state_, -1, type, size))
        {
            setError("INVALID_ARGUMENT", "metatable name already belongs to another type");
            return false;
        }
    }
    else
    {
        // 标记只存地址及大小，无额外 owner；统一 __gc 注册后禁止普通 write/setFunction 覆盖。
        // lua_pushlightuserdata：压入外部借用地址：[S] -> [S, lightuserdata]；Lua 不释放其指向资源，外部 owner 必须保证生命周期。
        lua_pushlightuserdata(state_, const_cast<void *>(type));
        // lua_setfield：把栈顶值写入指定 table 的具名字段并弹出该值；目标 table 保留。此处目标为封装创建的无写入元方法表。
        lua_setfield(state_, -2, kTypeField);
        // lua_pushinteger：将一个 Lua 整数压到栈顶：[S] -> [S, integer]；前面的范围检查保证转换不会截断。
        lua_pushinteger(state_, static_cast<lua_Integer>(size));
        // lua_setfield：把栈顶值写入指定 table 的具名字段并弹出该值；目标 table 保留。此处目标为封装创建的无写入元方法表。
        lua_setfield(state_, -2, kSizeField);
        // lua_pushcfunction：压入无业务 upvalue 的 C 函数：[S] -> [S, function]；此处作为统一 __gc，C++ 资源由该回调析构。
        lua_pushcfunction(state_, &LuaBinding::collectUserdata);
        // lua_setfield：把栈顶值写入指定 table 的具名字段并弹出该值；目标 table 保留。此处目标为封装创建的无写入元方法表。
        lua_setfield(state_, -2, "__gc");
    }
    *output  = std::move(meta);
    *created = first;
    return true;
}

bool LuaBinding::holdUserdata(int index, detail::UserdataHeader *header)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == header->storage)
        {
            return true;
        }
    }
    // 先压复制引用，ref 消耗它：[S] -> [S, userdata] -> [S]。
    // lua_pushvalue：复制指定槽内的值到栈顶：[S] -> [S, copy]；原槽保留，table/userdata 只复制引用，不复制内容。
    lua_pushvalue(state_, index);
    // luaL_ref：将栈顶值保存到 registry 并弹出，返回引用编号；编号由对应句柄/回调持有并最终 unref，持有期间防止对象被 GC。
    const int reference = luaL_ref(state_, LUA_REGISTRYINDEX); // 本回调持有的 userdata 引用编号。
    try
    {
        userdata_refs_.push_back({header->storage, header->type, reference});
    }
    catch (...)
    {
        // vector 分配失败仍释放刚取得的 ref；已经挂 __gc 的对象交给 Lua 正常回收。
        // luaL_unref：释放此 owner 持有的 registry 引用编号，不弹栈、不直接销毁对象；其它 Lua 引用仍可保持对象存活。
        luaL_unref(state_, LUA_REGISTRYINDEX, reference);
        throw;
    }
    return true;
}

bool LuaBinding::allocateUserdata(const std::string &name, const void *type, std::size_t size,
                                  void (*destroy)(void *), detail::UserdataHeader **output)
{
    detail::StackRestore stack(state_);
    if (!reserveStack(5))
    {
        return false;
    }
    // 按 name 从 registry 取具名表：[S] -> [S, meta]；未注册则压 nil。
    // 先验证类型，失败由保护器弹掉 meta/nil，不构造业务对象。
    // luaL_getmetatable：按名称从 registry 取 metatable 并压栈；未注册时压 nil，调用方需校验，不能直接用于构造对象。
    luaL_getmetatable(state_, name.c_str());
    if (!typeMatches(state_, -1, type, size))
    {
        setError("INVALID_ARGUMENT", "userdata type must be registered before construction");
        return false;
    }

    // [S, meta] -> [S, meta, userdata] -> [S, meta, userdata, meta-copy]。
    // Lua 分配头部和对齐存储；先建立未构造状态，挂 __gc 后才允许业务 placement-new。
    // lua_newuserdatauv：分配 Lua 管理的 full userdata 并压栈：[S] -> [S, userdata]；最后参数 0 表示无 uservalue，C++ 构造/析构需另行管理。
    void *storage   = lua_newuserdatauv(state_, detail::userdataBytes(size), 0);
    auto *header    = new (storage) detail::UserdataHeader;
    header->type    = type;
    header->size    = size;
    header->destroy = destroy;
    // lua_pushvalue：复制指定槽内的值到栈顶：[S] -> [S, copy]；原槽保留，table/userdata 只复制引用，不复制内容。
    lua_pushvalue(state_, -2);
    // setmetatable 消耗 meta-copy，恢复 [S, meta, userdata]；userdata 立刻受 GC 管理。
    // lua_setmetatable：把栈顶 table/nil 设置为指定对象的 metatable，然后弹出栈顶值；对象本身保留，不销毁 metatable。
    lua_setmetatable(state_, -2);
    holdUserdata(-1, header);
    *output = header;
    return true;
}

void *LuaBinding::checkUserdata(int index, const std::string &name, const void *type,
                                std::size_t size)
{
    detail::StackRestore stack(state_);
    if (!reserveStack(4))
    {
        return nullptr;
    }
    // 固定 -1 等相对索引，避免后续压入 metatable 改变目标；不增加栈项。
    // type/rawlen/touserdata 只读取槽；full userdata 的 rawlen 是分配字节数。
    // lua_absindex：将负的相对栈索引固定为绝对索引，避免后续压栈改变目标；不改变栈，upvalue 伪索引保持原值。
    const int absolute_index = lua_absindex(state_, index);
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state_, absolute_index) != LUA_TUSERDATA ||
        // lua_rawlen：读取原始长度，不调用 __len、不改变栈；table 为数组边界，full userdata 为分配字节数，不能混淆。
        lua_rawlen(state_, absolute_index) != detail::userdataBytes(size))
    {
        setError("INVALID_ARGUMENT", "value must be a registered full userdata");
        return nullptr;
    }
    // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
    auto *header = static_cast<detail::UserdataHeader *>(lua_touserdata(state_, absolute_index));
    // getmetatable 把对象的表压入；再取具名表，rawequal 比较表身份而非 __eq。
    // [S] -> [S, actual-meta, named-meta]，保护器恢复 [S]。
    // lua_getmetatable：对象有 metatable 时压入它并返回 1；没有则不压值并返回 0。后续栈恢复必须覆盖成功与失败路径。
    if (lua_getmetatable(state_, absolute_index) == 0)
    {
        setError("INVALID_ARGUMENT", "userdata has no metatable");
        return nullptr;
    }
    // luaL_getmetatable：按名称从 registry 取 metatable 并压栈；未注册时压 nil，调用方需校验，不能直接用于构造对象。
    luaL_getmetatable(state_, name.c_str());
    // lua_rawequal：比较两个槽的原始相等性，不调用 __eq、不改变栈；这里用于核验 metatable 是同一张表。
    if (!lua_rawequal(state_, -1, -2) || !typeMatches(state_, -1, type, size) ||
        header->type != type || header->size != size || !header->alive)
    {
        setError("INVALID_ARGUMENT", "userdata type mismatch or object already finalized");
        return nullptr;
    }
    holdUserdata(absolute_index, header);
    return header->storage;
}

bool LuaBinding::pushObject(const void *object, const void *type)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object && entry.type == type)
        {
            // 按编号取原 userdata：[S] -> [S, userdata]，不复制 C++ 对象。
            // 成功留给返回值/写表/闭包；若已析构则弹掉它，失败保持 [S]。
            // lua_rawgeti：按整数 key 从指定 table/registry 取值并压栈：[S] -> [S, value]；不触发 __index，源表和原引用保留。
            lua_rawgeti(state_, LUA_REGISTRYINDEX, entry.reference);
            const auto *header =
                // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
                static_cast<const detail::UserdataHeader *>(lua_touserdata(state_, -1));
            if (header->alive)
            {
                return true;
            }
            // lua_pop：移除指定数量的栈顶临时值；不会直接销毁仍被 registry/字段/闭包引用的对象，遍历时必须保留下一轮所需 key。
            lua_pop(state_, 1);
            break;
        }
    }
    setError("INVALID_ARGUMENT", "pointer is not a live userdata held by this callback");
    return false;
}

int LuaBinding::collectUserdata(lua_State *state) noexcept
{
    // 统一 GC 不构造 Binding，不分配，不调用业务错误 API；析构必须 noexcept。
    // 即使 Lua 主动重复调用 __gc，也先清 alive 再析构，确保 C++ 对象只析构一次。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state, 1) != LUA_TUSERDATA ||
        // lua_rawlen：读取原始长度，不调用 __len、不改变栈；table 为数组边界，full userdata 为分配字节数，不能混淆。
        lua_rawlen(state, 1) < sizeof(detail::UserdataHeader))
    {
        return 0;
    }
    // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
    auto                *header = static_cast<detail::UserdataHeader *>(lua_touserdata(state, 1));
    detail::StackRestore stack(state);
    // lua_getmetatable：对象有 metatable 时压入它并返回 1；没有则不压值并返回 0。后续栈恢复必须覆盖成功与失败路径。
    if (lua_getmetatable(state, 1) == 0 || !typeMatches(state, -1, header->type, header->size) ||
        // lua_rawlen：读取原始长度，不调用 __len、不改变栈；table 为数组边界，full userdata 为分配字节数，不能混淆。
        lua_rawlen(state, 1) != detail::userdataBytes(header->size))
    {
        return 0;
    }
    if (header->alive)
    {
        header->alive = false;
        header->destroy(header->storage);
    }
    // 这里只析构 C++ 资源，userdata 原始内存稍后由 Lua 释放；GC 没有业务返回值。
    return 0;
}
} // namespace flywow_lua_binding
