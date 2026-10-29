// 职责：集中实现 Lua 入口、错误、registry 引用、userdata 类型及 GC。
// 封装内可能分配的 Lua 操作使用 pcall；业务自行调用 C API 时仍负责其栈与 longjmp 边界。
#include "lua_binding.h"
#include "lua_table.h"

#include <string_view>

extern "C"
{
#include <lauxlib.h>
}

namespace flywow_lua_binding
{
namespace detail
{
// Lua C API 的直接压栈先保证容量；checkstack 内部保护分配，失败用 C++ 展开清理调用方资源。
void ensureStack(lua_State *state, int extra)
{
    if (!lua_checkstack(state, extra))
    {
        throw std::bad_alloc();
    }
}

// 字节串由外层 C++ 对象持有，内层仅复制到 Lua：[S] -> [S,string]；OOM 不跳过外层析构。
void pushString(lua_State *state, const char *bytes, std::size_t length)
{
    runProtected(
        state,
        [bytes, length](lua_State *inner) noexcept
        {
            lua_pushlstring(inner, bytes, length);
            return 1;
        },
        0, 1);
}

// 新表由返回栈槽保活；两个尺寸只是容量提示：[S] -> [S,table]。
void createTable(lua_State *state, int array_slots, int fields)
{
    runProtected(
        state,
        [array_slots, fields](lua_State *inner) noexcept
        {
            lua_createtable(inner, array_slots, fields);
            return 1;
        },
        0, 1);
}

// 分配尚未构造的 T 存储和一个生命周期槽：[S] -> [S,userdata]，尚未设置元表及 GC。
void *createUserdata(lua_State *state, std::size_t bytes)
{
    void *storage = nullptr; // Lua 分配区借用地址；成功后由 newUserdata 执行 placement-new。
    runProtected(
        state,
        [bytes, &storage](lua_State *inner) noexcept
        {
            storage = lua_newuserdatauv(inner, bytes, 1);
            return 1;
        },
        0, 1);
    return storage;
}

// 消耗一个栈值并移交 registry：[S,value] -> [S]；返回编号由句柄或 Binding 持有并 unref。
int referenceValue(lua_State *state)
{
    int reference = LUA_NOREF; // 只有 Lua 保存引用成功才更新，错误不会伪造可释放的编号。
    runProtected(
        state,
        [&reference](lua_State *inner) noexcept
        {
            reference = luaL_ref(inner, LUA_REGISTRYINDEX);
            return 0;
        },
        1, 0);
    return reference;
}

// 具名 registry 查询可能为 name 创建 Lua 字符串，故也在 pcall 内；返回 table 或 nil。
void pushNamedMetatable(lua_State *state, const std::string &name)
{
    runProtected(
        state,
        [&name](lua_State *inner) noexcept
        {
            luaL_getmetatable(inner, name.c_str());
            return 1;
        },
        0, 1);
}

// 创建或取回元表：[S] -> [S,meta]；created 区分新注册与重名，重名表保持原样。
bool newMetatable(lua_State *state, const std::string &name)
{
    bool created = false; // 由内层 Lua 操作更新，供注册入口拒绝重复类型名。
    runProtected(
        state,
        [&name, &created](lua_State *inner) noexcept
        {
            created = luaL_newmetatable(inner, name.c_str()) != 0;
            return 1;
        },
        0, 1);
    return created;
}

// 只消耗业务 upvalues 并返回 closure；保护器的指针参数不进入创建出来的业务闭包。
void pushClosure(lua_State *state, lua_CFunction callback, int upvalues)
{
    runProtected(
        state,
        [callback, upvalues](lua_State *inner) noexcept
        {
            lua_pushcclosure(inner, callback, upvalues);
            return 1;
        },
        upvalues, 1);
}

// [S,table,key,value] -> [S,table]；rawset 不触发元方法，但扩容分配仍必须保护。
void rawSet(lua_State *state)
{
    runProtected(
        state,
        [](lua_State *inner) noexcept
        {
            lua_rawset(inner, 2);
            return 1; // 参数 2 的目标表是剩余栈顶值；参数 1 是保护器内部地址。
        },
        3, 1);
}

// 复制目标表给内层操作；原 table 保留，栈顶 value 被消耗：[S,table,value] -> [S,table]。
void setField(lua_State *state, int table_index, const char *key)
{
    ensureStack(state, 2);
    table_index = lua_absindex(state, table_index); // 后续复制值会移动负索引，先固定目标。
    lua_pushvalue(state, table_index);
    lua_insert(state, -2);
    runProtected(
        state,
        [key](lua_State *inner) noexcept
        {
            lua_setfield(inner, 2, key);
            return 0;
        },
        2, 0);
}

// [S,object,meta] -> [S,object]；消耗元表副本，保留同一个 Lua 对象。
void setMetatable(lua_State *state)
{
    runProtected(
        state,
        [](lua_State *inner) noexcept
        {
            lua_setmetatable(inner, 2);
            return 1;
        },
        2, 1);
}

// 保护 lua_next 的错误出口；原 key 只在调用结束后移除，错误时交外层 StackRestore 恢复。
bool nextEntry(lua_State *state, int table_index)
{
    ensureStack(state, 4);
    table_index       = lua_absindex(state, table_index); // 源表索引不能随临时参数变化。
    const int old_key = lua_gettop(state);                // 原迭代 key，内层只消费副本。
    lua_pushvalue(state, table_index);
    lua_pushvalue(state, old_key);
    runProtected(
        state, [](lua_State *inner) noexcept { return lua_next(inner, 2) != 0 ? 2 : 0; }, 2,
        LUA_MULTRET);
    const bool found = lua_gettop(state) > old_key;
    lua_remove(state, old_key);
    return found; // 有条目 [S,table,key,value]；结束 [S,table]。
}

// testudata 临时压入两张元表再弹出，净变化为零；借用地址写回外层，保护 name 的字符串分配。
void *testUserdata(lua_State *state, int index, const std::string &name)
{
    ensureStack(state, 1);
    void *object = nullptr; // 仅当精确元表匹配时写回 Lua-owned 地址。
    lua_pushvalue(state, index);
    runProtected(
        state,
        [&name, &object](lua_State *inner) noexcept
        {
            object = luaL_testudata(inner, 2, name.c_str());
            return 0;
        },
        1, 0);
    return object;
}

// 一次保护调用构造统一错误返回：[S] -> [S, nil, {code=..., message=...}]。
// 字符串按显式长度复制，保留内嵌零字节；内层只包含 Lua C API 调用。
void pushErrorResult(lua_State *state, std::string_view code, std::string_view message)
{
    runProtected(
        state,
        [&code, &message](lua_State *inner) noexcept
        {
            lua_pushnil(inner);
            lua_createtable(inner, 0, 2);
            lua_pushlstring(inner, code.data(), code.size());
            lua_setfield(inner, -2, "code");
            lua_pushlstring(inner, message.data(), message.size());
            lua_setfield(inner, -2, "message");
            return 2;
        },
        0, 2);
}

// 仅由已清理所有业务 C++ 资源的入口调用；持续 OOM 无法构造错误表时使用 Lua 自身错误出口。
int callbackFailure(lua_State *state, bool module, const char *code, const char *message)
{
    // 此时业务 C++ 资源已经析构；丢弃参数及部分结果，为最终错误保留最低栈空间。
    lua_settop(state, 0);
    if (!module)
    {
        try
        {
            pushErrorResult(state, code, message);
            return 2;
        }
        catch (...)
        {
            // 离开 catch 后才跳转到 Lua，避免跳过异常对象析构。
        }
    }
    lua_pushstring(state, message);
    return lua_error(state);
}

// 将已有槽严格读成 bool；state/index 来自当前读取入口，output 仅成功时更新，reason 接收类型诊断。
bool ValueCodec<bool>::read(lua_State *state, int index, bool &output, std::string *reason)
{
    // type 只检查原槽；toboolean 本来接受任意类型，这里先限定为真正的 bool。
    // 不改变栈，false 是有效结果，不能用输出值本身判断读取是否成功。
    if (lua_type(state, index) != LUA_TBOOLEAN)
    {
        *reason = "value must be a boolean";
        return false;
    }
    output = lua_toboolean(state, index) != 0;
    return true;
}

// 将 bool 压入当前 State；false 是有效值，未使用的诊断参数仅为匹配统一 codec 签名。
bool ValueCodec<bool>::push(lua_State *state, bool value, std::string *)
{
    // [S] -> [S, boolean]；false 也占一个值槽，不表示写入失败。
    ensureStack(state, 1);
    lua_pushboolean(state, value);
    return true;
}

// 从已验证的字符串槽复制完整字节到 output；reason 接收类型诊断，C++ 复制异常交外层回调捕获。
bool ValueCodec<std::string>::read(lua_State *state, int index, std::string &output,
                                   std::string *reason)
{
    // 不允许数字到字符串的隐式转换。尤其 lua_next 的数字 key 不能被原位 tostring，
    // 否则下轮迭代拿到不同类型的 key，Lua 会认为它不是上一次返回的 key。
    if (lua_type(state, index) != LUA_TSTRING)
    {
        *reason = "value must be a string";
        return false;
    }
    std::size_t length = 0; // Lua 字符串长度，保留内嵌零字节。
    // 已确认是字符串，tolstring 不转换原槽；bytes 借用 Lua 内存，仅用于立即复制。
    // 按 length 复制（包括内嵌零字节），不依赖 C 字符串结束符；栈高度不变。
    const char *bytes  = lua_tolstring(state, index, &length);
    std::string value(bytes, length); // 独立副本构造成功后才移入 output。
    output = std::move(value);
    return true;
}

// 将调用方的完整字节串复制给 Lua；调用方保留 C++ 缓冲区，Lua 分配错误先受保护再展开。
bool ValueCodec<std::string>::push(lua_State *state, const std::string &value, std::string *)
{
    // pushlstring 复制全部 bytes，Lua 持有自己的字符串，不借用 C++ buffer。
    pushString(state, value.data(), value.size());
    return true;
}

// 只从 lightuserdata 槽取得外部借用地址；output 不拥有资源，reason 在类型不符时接收诊断。
bool ValueCodec<void *>::read(lua_State *state, int index, void *&output, std::string *reason)
{
    // lightuserdata 是外部借用地址，不归 Lua 释放；读取不压栈、不注册 GC。
    // full userdata 通过具名 metatable 判断类型；其内存直接存放对象。
    if (lua_type(state, index) != LUA_TLIGHTUSERDATA)
    {
        *reason = "value must be a borrowed lightuserdata pointer";
        return false;
    }
    output = lua_touserdata(state, index);
    return true;
}
} // namespace detail

LuaBinding::LuaBinding(lua_State *state) : state_(state)
{
    detail::ensureStack(state_, LUA_MINSTACK);
}

LuaBinding::~LuaBinding()
{
    // luaL_unref 只释放本回调的 registry 引用，既不弹栈，也不直接调用析构。
    // 返回结果、table 字段或 closure 若仍引用对象，Lua GC 就不会回收它。
    for (const auto &entry : userdata_refs_)
    {
        luaL_unref(state_, LUA_REGISTRYINDEX, entry.reference);
    }
}

// 位置参数读取前确认 index 是当前栈的真实槽；不接收 registry/upvalue 伪索引，失败记录参数错误。
bool LuaBinding::validIndex(int index)
{
    // gettop 是栈项数量；正索引从底部 1 开始，负索引从顶部 -1 开始，0 无效。
    // 此处仅接受真实栈槽；upvalue 伪索引由 validUpvalue 校验。
    const int top = lua_gettop(state_); // 当前栈项数量，也是栈顶正索引；空栈为 0。
    if (index == 0 || index > top || index < -top)
    {
        setError("INVALID_ARGUMENT", "argument index outside current stack");
        return false;
    }
    return true;
}

// 只接受当前 C 闭包真实存在的 upvalue；先检查编号，避免 0 映射成 registry 伪索引。
bool LuaBinding::validUpvalue(int index)
{
    if (index < 1 || index > detail::kMaxUpvalues ||
        lua_type(state_, lua_upvalueindex(index)) == LUA_TNONE)
    {
        setError("INVALID_ARGUMENT", "upvalue index outside current closure");
        return false;
    }
    return true;
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
    const std::string code =
        error_code_.empty() ? "INTERNAL_ERROR" : error_code_; // 本次交付的错误码快照。
    const std::string message = error_code_.empty()
                                    ? "no recorded Binding error"
                                    : error_message_; // 与码配对，避免重载更新时改变输入。
    return pushError(code, message);
}

int LuaBinding::pushError(const std::string &code, const std::string &message)
{
    setError(code, message);

    // 一次保护调用连续构造 nil/error table，避免五次 Lua 边界往返；return 2 交付栈顶 nil/table。
    detail::pushErrorResult(state_, error_code_, error_message_);
    return 2;
}

// 字段、参数及 upvalue 入口共用：为 index 对应的 table 建立新引用，output 成功后替换原句柄。
bool LuaBinding::readTableAt(int index, LuaTable &output)
{
    if (!lua_istable(state_, index))
    {
        setError("INVALID_ARGUMENT", "value must be a table");
        return false;
    }
    // 保存指定位置的 table，使 LuaTable 在临时栈变化后仍能找到同一对象。
    // pushvalue 复制 index 处的值到栈顶：[table] -> [table, table]；原值仍保留。
    // 复制的是同一 table 的引用，不会复制内容。
    // luaL_ref 把栈顶值存入 registry，返回引用编号，并弹掉刚复制的栈项。
    // 因而 [S] -> [S, table-copy] -> [S]，两句完成后栈高度恢复原样。
    // output 句柄持有编号，存活期间防止 table 被 GC；析构时 luaL_unref 释放此引用。
    // unref 不弹栈、不直接销毁 table；其它栈项/字段/句柄仍引用它时，它继续存活。
    detail::ensureStack(state_, 1);
    lua_pushvalue(state_, index);
    const int reference =
        // luaL_ref：将栈顶值保存到 registry 并弹出，返回引用编号；编号由对应句柄/回调持有并最终 unref，持有期间防止对象被 GC。
        detail::referenceValue(state_); // output 句柄拥有的 registry 引用编号。
    output = LuaTable(this, reference);
    return true;
}

bool LuaBinding::readTable(int index, LuaTable &output)
{
    return validIndex(index) && readTableAt(index, output);
}

bool LuaBinding::readTable(LuaTable &output)
{
    return readTable(-1, output);
}

LuaTable LuaBinding::newTable()
{
    int reference = LUA_NOREF;
    // 同一保护边界内连续创建并登记 table：[S] -> [S, table] -> [S]。
    // 失败时 pcall 恢复栈且不会构造句柄；成功后句柄持有 registry 引用。
    detail::runProtected(
        state_,
        [&reference](lua_State *inner) noexcept
        {
            lua_createtable(inner, 0, 0);
            reference = luaL_ref(inner, LUA_REGISTRYINDEX);
            return 0;
        },
        0, 0);
    return LuaTable(this, reference);
}

bool LuaBinding::readUpvalueTable(int index, LuaTable &output)
{
    if (!validUpvalue(index))
    {
        return false;
    }
    const int actual =
        lua_upvalueindex(index); // 将业务编号映射到当前回调闭包槽，readTableAt 不压业务参数。
    return readTableAt(actual, output);
}

bool LuaBinding::readTruthAt(int index, bool &output)
{
    // 显式读取 Lua 真值：只有 nil/false 为假，0/空串为真；不转换或弹出原槽。
    output = lua_toboolean(state_, index) != 0;
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
    value.push();
    return true;
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
    detail::pushString(state_, value, std::char_traits<char>::length(value));
    return true;
}

bool LuaBinding::pushValue(std::nullptr_t)
{
    detail::ensureStack(state_, 1);
    lua_pushnil(state_);
    return true;
}

bool LuaBinding::pushValue(void *value)
{
    // [S] -> [S, lightuserdata]；只保存地址，Lua 不析构或释放它指向的资源。
    // 外部 owner 要保证所有使用它的 Lua 字段/闭包存活期间，此地址一直有效。
    detail::ensureStack(state_, 1);
    lua_pushlightuserdata(state_, value);
    return true;
}

// 模块初始化时用 name 注册元表，collector 是对应 T 的析构函数；成功给 output 独立引用，重名不改旧表。
bool LuaBinding::registerUserdataType(const std::string &name, lua_CFunction collector,
                                      LuaTable &output)
{
    if (name.empty())
    {
        setError("INVALID_ARGUMENT", "metatable needs a name");
        return false;
    }

    // luaL_newmetatable 从 registry 查找或创建具名 table 并压栈：[S] -> [S, metatable]；
    // 同名已存在时也会压入原 table，保护器覆盖成功/失败两条出口的栈恢复。
    detail::StackRestore stack(state_);
    if (!detail::newMetatable(state_, name))
    {
        setError("INVALID_ARGUMENT", "userdata metatable name is already registered");
        return false;
    }
    // push 后为 [S, metatable, collector]；setfield 消耗 collector，元表保留在栈顶。
    // readTableAt 复制元表到 registry；保护器随后移除临时元表，output 持有独立引用。
    // __gc 私有 upvalue 1 捕获注册元表，供回收时验证精确身份；业务闭包编号不受影响。
    lua_pushvalue(state_, -1);
    detail::pushClosure(state_, collector, 1);
    detail::setField(state_, -2, "__gc");

    return readTableAt(-1, output);
}

// 为 index 中的 userdata 建立本 Binding 的短期强引用，object 用于后续写表/返回定位原 Lua 对象。
bool LuaBinding::holdUserdata(int index, void *object)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            return true;
        }
    }
    // 复制 userdata 并保存到 registry，确保本回调结束前对象不会被 Lua GC 回收：
    // [S] -> [S, userdata-copy] -> [S]。reference 归本回调所有，析构时 unref。
    // pushvalue 在外层读取原 index；保护调用只消费副本，原槽及其正/负索引不变。
    detail::ensureStack(state_, 1);
    lua_pushvalue(state_, index);
    const int reference = detail::referenceValue(state_);
    try
    {
        userdata_refs_.push_back({object, reference});
    }
    catch (...)
    {
        luaL_unref(state_, LUA_REGISTRYINDEX, reference);
        setError("INTERNAL_ERROR", "cannot retain userdata for this callback");
        return false;
    }
    return true;
}

// 按 name 核对 index 的元表及存活标记，再交本 Binding 保活；返回地址只供当前调用借用，失败返回空指针。
void *LuaBinding::checkUserdata(int index, const std::string &name)
{
    // 精确比较元表，内部临时压入两张元表再弹出；净栈变化为零，地址仍由 Lua 持有。
    if (lua_type(state_, index) != LUA_TUSERDATA)
    {
        setError("INVALID_ARGUMENT", "value must be full userdata with the registered metatable");
        return nullptr;
    }
    void *object = detail::testUserdata(state_, index, name);
    if (object == nullptr)
    {
        setError("INVALID_ARGUMENT", "value must be userdata with the registered metatable");
        return nullptr;
    }
    // getiuservalue 压入生命周期槽：[S] -> [S, alive_state]；无效序号也压入 nil。
    // 读取后 pop 恢复 [S]，不改变原参数或 userdata。
    const int state_type =
        lua_getiuservalue(state_, index, 1); // 生命周期槽类型，必须严格为 boolean。
    const bool alive = state_type == LUA_TBOOLEAN &&
                       lua_toboolean(state_, -1) != 0; // 构造完成且未 finalize 才能借用 T。
    lua_pop(state_, 1);
    if (!alive)
    {
        setError("INVALID_ARGUMENT", "userdata has already been finalized");
        return nullptr;
    }
    if (!holdUserdata(index, object))
    {
        return nullptr;
    }
    return object;
}

// 把当前 Binding 已保活的 object 地址还原为原 userdata；拒绝任意指针，成功只压入一项。
bool LuaBinding::pushObject(const void *object)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            // registry 引用由本回调继续持有；rawgeti 另压相同 userdata 供 Lua 返回/写表：
            // [S] -> [S, userdata]。之后 unref 不会移除这个栈值或 Lua 字段引用。
            detail::ensureStack(state_, 1);
            lua_rawgeti(state_, LUA_REGISTRYINDEX, entry.reference);
            return true;
        }
    }
    setError("INVALID_ARGUMENT", "pointer is not a userdata held by this callback");
    return false;
}
} // namespace flywow_lua_binding
