// 职责：集中实现 Lua 入口、错误、registry 引用、userdata 类型及 GC。
// 所有临时栈操作在此封装内部；业务 Binding 不使用 Lua C API。
#include "lua_binding.h"
#include "lua_table.h"

extern "C"
{
#include <lauxlib.h>
}


namespace flywow_lua_binding
{
namespace detail
{
bool ValueCodec<bool>::read(lua_State *state, int index, bool &output, std::string *reason)
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
    output = lua_toboolean(state, index) != 0;
    return true;
}

bool ValueCodec<bool>::push(lua_State *state, bool value, std::string *)
{
    // [S] -> [S, boolean]；false 也占一个值槽，不表示写入失败。
    // lua_pushboolean：压入布尔值：[S] -> [S, boolean]；false 同样是有效值并占一个栈槽。
    lua_pushboolean(state, value);
    return true;
}

bool ValueCodec<std::string>::read(lua_State *state, int index, std::string &output,
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
    output = std::move(value);
    return true;
}

bool ValueCodec<std::string>::push(lua_State *state, const std::string &value, std::string *)
{
    // pushlstring 复制全部 bytes，Lua 持有自己的字符串，不借用 C++ buffer。
    // lua_pushlstring：按显式长度复制字节为 Lua 字符串并压栈：[S] -> [S, string]；保留内嵌零字节，不借用 C++ 缓冲区。
    lua_pushlstring(state, value.data(), value.size());
    return true;
}

bool ValueCodec<void *>::read(lua_State *state, int index, void *&output, std::string *reason)
{
    // lightuserdata 是外部借用地址，不归 Lua 释放；读取不压栈、不注册 GC。
    // full userdata 通过具名 metatable 判断类型；其内存直接存放对象。
    // lua_type：读取指定槽的类型标记，不转换值、不改变栈；无效槽返回 LUA_TNONE，而不是 LUA_TNIL。
    if (lua_type(state, index) != LUA_TLIGHTUSERDATA)
    {
        *reason = "value must be a borrowed lightuserdata pointer";
        return false;
    }
    // lua_touserdata：取得该槽携带的地址，不改变栈；lightuserdata 是外部地址，full userdata 是 Lua 分配区，不能混用 ownership。
    output = lua_touserdata(state, index);
    return true;
}
} // namespace detail

LuaBinding::LuaBinding(lua_State *state) : state_(state)
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
    // 直接在当前栈顶追加 nil 和错误表；return 2 时 Lua 取这两个栈顶值作为结果。
    // 任何更低的临时值都由 Lua 在回调返回时丢弃，无需回退到回调入口栈高。
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
    return 2;
}

bool LuaBinding::readTableAt(int index, LuaTable &output)
{
    // lua_istable：检查指定槽是否为 table，不转换值、不改变栈；非零表示符合，失败由封装返回普通错误。
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
    // lua_pushvalue：复制指定槽内的值到栈顶：[S] -> [S, copy]；原槽保留，table/userdata 只复制引用，不复制内容。
    lua_pushvalue(state_, index);
    const int reference =
        // luaL_ref：将栈顶值保存到 registry 并弹出，返回引用编号；编号由对应句柄/回调持有并最终 unref，持有期间防止对象被 GC。
        luaL_ref(state_, LUA_REGISTRYINDEX); // output 句柄拥有的 registry 引用编号。
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
    // [S] -> [S, new-table] -> [S]：newtable 压入新表，ref 消耗它并保存到 registry。
    // 返回句柄拥有这份引用；调用方不用维护栈顶，稍后析构只 unref。
    // lua_newtable：创建空 table 并压栈：[S] -> [S, table]；随后由 registry 引用持有，临时栈项不是唯一 owner。
    lua_newtable(state_);
    // luaL_ref：将栈顶值保存到 registry 并弹出，返回引用编号；编号由对应句柄/回调持有并最终 unref，持有期间防止对象被 GC。
    return LuaTable(this, luaL_ref(state_, LUA_REGISTRYINDEX));
}

bool LuaBinding::readUpvalueTable(int index, LuaTable &output)
{
    const int actual = lua_upvalueindex(index);
    return actual != 0 && readTableAt(actual, output);
}

bool LuaBinding::readTruthAt(int index, bool &output)
{
        // 显式读取 Lua 真值：只有 nil/false 为假，0/空串为真；不转换或弹出原槽。
    // lua_toboolean：按 Lua 真值规则读取该槽：只有 nil/false 为假，0 和空串为真；不转换原值、不改变栈。
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

bool LuaBinding::registerUserdataType(const std::string &name, lua_CFunction collector,
                                      LuaTable &output)
{
    if (name.empty())
    {
        setError("INVALID_ARGUMENT", "metatable needs a name");
        return false;
    }

    detail::StackRestore stack(state_);
    if (luaL_newmetatable(state_, name.c_str()) == 0)
    {
        setError("INVALID_ARGUMENT", "userdata metatable name is already registered");
        return false;
    }
    lua_pushcfunction(state_, collector);
    lua_setfield(state_, -2, "__gc");
    return readTableAt(-1, output);
}

bool LuaBinding::holdUserdata(int index, void *object)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            return true;
        }
    }
    // 复制 userdata 并保存到 registry，确保本回调结束前对象不会被 Lua GC 回收。
    lua_pushvalue(state_, index);
    const int reference = luaL_ref(state_, LUA_REGISTRYINDEX);
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

void *LuaBinding::checkUserdata(int index, const std::string &name)
{
    void *object = luaL_testudata(state_, index, name.c_str());
    if (object == nullptr)
    {
        setError("INVALID_ARGUMENT", "value must be userdata with the registered metatable");
        return nullptr;
    }
    if (!holdUserdata(index, object))
    {
        return nullptr;
    }
    return object;
}

bool LuaBinding::pushObject(const void *object)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            lua_rawgeti(state_, LUA_REGISTRYINDEX, entry.reference);
            return true;
        }
    }
    setError("INVALID_ARGUMENT", "pointer is not a userdata held by this callback");
    return false;
}
} // namespace flywow_lua_binding
