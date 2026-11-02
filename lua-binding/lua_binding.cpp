// 职责：严格转换 Lua 参数、构造返回值和管理回调内的 userdata 引用。
// OOM 交由运行时及宿主处理；普通输入错误按 Binding 诊断合同返回。
#include "lua_binding.h"
#include "lua_table.h"
#include <cstring>

namespace flywow_lua_binding
{
namespace detail
{
// 原生回调已退出并销毁局部对象后，才清空参数栈并尝试构造 Lua 错误结果。
int callbackFailure(lua_State *state, const char *message)
{
    // 实际 Native 函数及异常对象均已析构，才允许使用 Lua 的最终错误出口。
    lua_settop(state, 0);

    // 此处没有需要析构的 C++ 局部对象；Lua 分配失败直接走 Lua 错误出口。
    // [] -> [nil, error_table]；诊断字段复制进 Lua，不借用 Native 对象。
    lua_pushnil(state);
    lua_createtable(state, 0, 2);
    lua_pushliteral(state, "INTERNAL_ERROR");
    lua_setfield(state, -2, "code");
    lua_pushstring(state, message);
    lua_setfield(state, -2, "message");
    return 2;
}

// 严格读取 boolean 参数；保留 false 作为有效值，只有类型不符才写入失败原因。
bool ValueCodec<bool>::read(lua_State *state, int index, bool &output, const char **reason)
{
    // type 只检查原槽；toboolean 本来接受任意类型，这里先限定为真正的 bool。
    // 不改变栈，false 是有效结果，不能用输出值本身判断读取是否成功。
    if (lua_type(state, index) != LUA_TBOOLEAN)
    {
        *reason = "value must be a boolean";
        return false;
    }

    // 输入已确认是 boolean；保留 false 作为正常读取结果。
    output = lua_toboolean(state, index) != 0;
    return true;
}

// 将 bool 写入 Lua 栈；false 仍是成功结果，reason 仅为匹配统一 ValueCodec 签名。
bool ValueCodec<bool>::push(lua_State *state, bool value, const char **)
{
    // [S] -> [S, boolean]；false 也占一个值槽，不表示写入失败。
    lua_pushboolean(state, value);
    return true;
}

// 从已验证的字符串槽复制完整字节到 output；reason 接收类型诊断，C++ 复制异常交外层回调捕获。
bool ValueCodec<std::string>::read(lua_State *state, int index, std::string &output,
                                   const char **reason)
{
    // 不允许数字到字符串的隐式转换。尤其 lua_next 的数字 key 不能被原位 tostring，
    // 否则下轮迭代拿到不同类型的 key，Lua 会认为它不是上一次返回的 key。
    if (lua_type(state, index) != LUA_TSTRING)
    {
        *reason = "value must be a string";
        return false;
    }

    // 类型校验通过后，读取 Lua 持有的完整字节串并复制到独立 C++ string。
    std::size_t length = 0; // Lua 字符串长度，保留内嵌零字节。
    // 已确认是字符串，tolstring 不转换原槽；bytes 借用 Lua 内存，仅用于立即复制。
    // 按 length 复制（包括内嵌零字节），不依赖 C 字符串结束符；栈高度不变。
    const char *bytes  = lua_tolstring(state, index, &length);
    std::string value(bytes, length); // 独立副本构造成功后才移入 output。
    output = std::move(value);
    return true;
}

// 将调用方的完整字节串复制给 Lua；调用方继续拥有 C++ 缓冲区，Lua 字符串独立持有复制结果。
bool ValueCodec<std::string>::push(lua_State *state, const std::string &value, const char **)
{
    // pushlstring 复制全部 bytes，Lua 持有自己的字符串，不借用 C++ buffer。
    lua_pushlstring(state, value.data(), value.size());
    return true;
}

// 只接受 lightuserdata 并返回其借用地址；不创建 Lua-owned userdata，类型错误写入 reason。
bool ValueCodec<void *>::read(lua_State *state, int index, void *&output, const char **reason)
{
    // lightuserdata 是外部借用地址，不归 Lua 释放；读取不压栈、不注册 GC。
    // full userdata 通过具名 metatable 判断类型；其内存直接存放对象。
    if (lua_type(state, index) != LUA_TLIGHTUSERDATA)
    {
        *reason = "value must be a borrowed lightuserdata pointer";
        return false;
    }

    // 类型通过后取得调用方借入的地址，不建立 userdata 所有权。
    output = lua_touserdata(state, index);
    return true;
}

} // namespace detail

// 初始化单次回调的 Binding；借用 Lua State，错误记录和 userdata 强引用由本对象持有到回调结束。
LuaBinding::LuaBinding(lua_State *state) : state_(state)
{
}

// 回调结束时释放 readUserdata/checkUserdata 建立的强引用；对象内存和析构仍归 Lua GC。
LuaBinding::~LuaBinding()
{
    for (const auto &entry : userdata_refs_)
        luaL_unref(state_, LUA_REGISTRYINDEX, entry.reference);
}

// 检查 index 是否指向当前 Lua 参数栈中的真实值；无效时记录 INVALID_ARGUMENT。
bool LuaBinding::validIndex(int index)
{
    const int top = lua_gettop(state_); // 当前回调原始参数栈的末端，用于排除栈外索引。

    if (index == 0 || index > top || index < -top)
    {
        setError("INVALID_ARGUMENT", "argument index outside current stack");
        return false;
    }
    return true;
}

// 检查闭包是否实际拥有指定业务 upvalue；伪索引或超出 Lua 上限时记录 INVALID_ARGUMENT。
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

// 判断参数是否省略或为 nil；保留 false、0 和空字符串作为显式值。
bool LuaBinding::isNoneOrNil(int index) const noexcept
{
    const int top = lua_gettop(state_);
    return index > top || (index != 0 && index >= -top && lua_isnil(state_, index));
}

// 保存本次 Binding 的错误码和诊断文本，供后续 pushError 生成 Lua 返回值。
void LuaBinding::setError(const std::string &code, const std::string &message)
{
    error_code_    = code;
    error_message_ = message;
}

// 返回最近一次记录的错误码；返回引用仅在该 Binding 生命周期内有效。
const std::string &LuaBinding::errorCode() const
{
    return error_code_;
}

// Lua 错误对象在失败时仍位于栈顶；先复制诊断，再弹出。
// 失败对象不是字符串时不触发隐式转换，避免报告错误时再进入 Lua 分配。
bool LuaBinding::completeCall(bool succeeded, const char *failure)
{
    if (!succeeded)
    {
        setError("INTERNAL_ERROR", lua_type(state_, -1) == LUA_TSTRING ? lua_tostring(state_, -1)
                                                                       : "Lua operation failed");
        lua_pop(state_, 1);
        return false;
    }

    // Lua 调用成功后仍可能有业务值转换失败；把该静态原因记录为参数错误。
    if (failure)
    {
        setError("INVALID_ARGUMENT", failure);
        return false;
    }
    return true;
}

// 直接构造 nil/error；Lua 复制诊断文本，返回值不借用 Binding 的字符串。
int LuaBinding::pushError()
{
    lua_pushnil(state_);
    lua_createtable(state_, 0, 2);
    if (error_code_.empty())
    {
        lua_pushliteral(state_, "INTERNAL_ERROR");
        lua_setfield(state_, -2, "code");
        lua_pushliteral(state_, "no recorded Binding error");
    }
    else
    {
        lua_pushlstring(state_, error_code_.data(), error_code_.size());
        lua_setfield(state_, -2, "code");
        lua_pushlstring(state_, error_message_.data(), error_message_.size());
    }
    lua_setfield(state_, -2, "message");
    return 2;
}

int LuaBinding::pushError(const std::string &code, const std::string &message)
{
    // 先复制以支持调用者传入 errorCode() 本身。
    const std::string code_copy(code); // 先复制错误码，避免 setError 写入时失效。
    const std::string message_copy(message); // 同理保护引用当前 message 成员的调用。

    // 先写入独立副本，再复用统一的错误结果构造流程。
    setError(code_copy, message_copy);
    return pushError();
}

// 把输入 table 保存到 registry，供 LuaTable 句柄在当前 Binding 回调期间继续访问；StackRestore 恢复临时栈值。
bool LuaBinding::readTableAt(int index, LuaTable &output)
{
    if (!lua_istable(state_, index))
    {
        setError("INVALID_ARGUMENT", "value must be a table");
        return false;
    }

    detail::StackRestore stack(state_);
    // 先复制原表；luaL_ref 消耗副本，原输入仍保留在原槽。
    lua_pushvalue(state_, index);
    const int reference = luaL_ref(state_, LUA_REGISTRYINDEX);

    output = LuaTable(this, reference);
    return true;
}

bool LuaBinding::readTable(int index, LuaTable &output)
{
    return validIndex(index) && readTableAt(index, output);
}

// 创建空 table 并保存到 registry，成功后由 output 接管引用。
bool LuaBinding::newTable(LuaTable &output)
{
    detail::StackRestore stack(state_);
    lua_newtable(state_);
    output = LuaTable(this, luaL_ref(state_, LUA_REGISTRYINDEX));
    return true;
}

// 使用 Lua truthiness 读取已验证栈槽；Lua 的任意值都可读，不产生类型失败。
bool LuaBinding::readTruthAt(int index, bool &output)
{
    output = lua_toboolean(state_, index) != 0;
    return true;
}

// 将本 Binding 创建的 LuaTable 句柄所引用的原表压栈；拒绝无效或属于其他 Binding 的句柄。
bool LuaBinding::pushRaw(lua_State *state, const LuaTable &value, const char **reason)
{
    if (!value.valid() || value.binding_ != this)
    {
        *reason = "table must belong to this Binding callback";
        return false;
    }

    // 句柄归属验证通过后，从 registry 压入原 table。
    lua_rawgeti(state, LUA_REGISTRYINDEX, value.reference_);
    return true;
}
// 将非空零结尾 C 字符串复制到 Lua；nullptr 由独立重载转换为 nil。
bool LuaBinding::pushRaw(lua_State *state, const char *value, const char **reason)
{
    if (!value)
    {
        *reason = "string pointer must not be null; use nullptr for Lua nil";
        return false;
    }

    // 非空 C 字符串按首个零字节截断，并由 Lua 复制内容。
    lua_pushlstring(state, value, std::strlen(value));
    return true;
}
// 将显式 nullptr 转换为 Lua nil，与无效的空 C 字符串指针区分。
bool LuaBinding::pushRaw(lua_State *state, std::nullptr_t, const char **)
{
    lua_pushnil(state);
    return true;
}
// 按本回调的强引用表查找 Native 对象并压入原 userdata；未保活的裸指针不能返回给 Lua。
bool LuaBinding::pushObject(lua_State *state, const void *object, const char **reason)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            lua_rawgeti(state, LUA_REGISTRYINDEX, entry.reference);
            return true;
        }
    }

    *reason = "pointer is not a userdata held by this callback";
    return false;
}

// LuaTable 可以写普通字段，但不能覆盖由 LuaBinding 管理的 userdata 析构函数。
// 本检查比较目标字段中闭包保存的元表身份；仅当目标确实是受管析构闭包时才拒绝写入。
bool LuaBinding::canWriteField(lua_State *state, int table_index, int key_index) noexcept
{
    // 后续读取旧字段会压栈，因此先把目标 table 和 key 的负索引固定为绝对索引。
    table_index = lua_absindex(state, table_index);
    key_index   = lua_absindex(state, key_index);
    if (lua_type(state, key_index) != LUA_TSTRING)
        return true;
    std::size_t length = 0; // key 的完整字节数；不依赖以零结尾的 C 字符串。
    const char *key    = lua_tolstring(state, key_index, &length); // 借用 Lua 字符串，只在本次比较中使用。
    if (length != 4 || std::memcmp(key, "__gc", 4) != 0)
        return true;

    // 只有 key 恰好是 __gc，才需要确认旧值是不是本 Binding 安装的析构闭包。
    lua_pushliteral(state, "__gc");
    lua_rawget(state, table_index);
    bool managed = false; // 最终目标字段是否为当前元表的托管 GC 闭包。
    if (lua_iscfunction(state, -1))
    {
        bool tagged = false; // 第二个 upvalue 是否带 LuaBinding 的私有标记。
        if (lua_getupvalue(state, -1, 2))
        {
            tagged = lua_isinteger(state, -1) && lua_tointeger(state, -1) == detail::kManagedGcTag;
            lua_pop(state, 1);
        }
        if (tagged && lua_getupvalue(state, -1, 1))
        {
            managed = lua_rawequal(state, -1, table_index) != 0;
            lua_pop(state, 1);
        }
    }
    // 弹出旧字段值；只有确认它是受管析构闭包时才拒绝这次写入。
    lua_pop(state, 1);
    return !managed;
}

// 注册类型元表、受保护的析构闭包和 methods 索引；拒绝重复名称及 methods 自带的 __gc。
void LuaBinding::registerType(lua_State *state, const char *name, lua_CFunction collector,
                              const luaL_Reg *methods)
{
    // 类型名须非空，析构入口由 Binding 独占，且同一 State 不能重复注册。
    if (!name || !*name)
        luaL_error(state, "metatable needs a name");
    for (auto *method = methods; method && method->name; ++method)
        if (std::strcmp(method->name, "__gc") == 0)
            luaL_error(state, "__gc is managed by userdata registration");

    // 新建本 State 的元表；重复名称按 Lua 模块加载错误退出。
    if (!luaL_newmetatable(state, name))
        luaL_error(state, "userdata metatable name is already registered");

    // __gc 闭包捕获元表身份和私有标记；methods 表只作为 __index，不覆盖元表本身。
    lua_pushvalue(state, -1);
    lua_pushinteger(state, detail::kManagedGcTag);
    lua_pushcclosure(state, collector, 2);
    lua_setfield(state, -2, "__gc");
    lua_newtable(state);
    if (methods)
        luaL_setfuncs(state, methods, 0);
    lua_setfield(state, -2, "__index");

    // luaL_newmetatable 留下的元表在此弹出，注册过程不改变入口栈高度。
    lua_pop(state, 1);
}

// 分配 Lua-owned 存储、设置未构造标记并挂接元表；临时引用交给 newUserdata 接管。
bool LuaBinding::allocateUserdata(const std::string &name, std::size_t bytes, void *&storage,
                                  int &reference)
{
    detail::StackRestore stack(state_);
    luaL_getmetatable(state_, name.c_str());
    if (!lua_istable(state_, -1))
    {
        setError("INVALID_ARGUMENT", "userdata type must be registered before construction");
        return false;
    }

    // [元表, userdata]；构造成功前 alive=false，GC 不会析构尚未构造的 T。
    void *object = lua_newuserdatauv(state_, bytes, 1);
    lua_pushboolean(state_, 0);
    lua_setiuservalue(state_, -2, 1);
    lua_pushvalue(state_, -2);
    lua_setmetatable(state_, -2);

    // luaL_ref 消耗 userdata，由外层负责构造以及接管或释放引用。
    const int created_reference = luaL_ref(state_, LUA_REGISTRYINDEX);
    storage   = object;
    reference = created_reference;
    return true;
}

// 让当前 Binding 在 Native 回调期间保活 userdata；重复对象复用已有引用，新对象建立本回调的独立引用记录。
void LuaBinding::retainUserdata(void *object, int reference)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            luaL_unref(state_, LUA_REGISTRYINDEX, reference);
            return;
        }
    }

    userdata_refs_.push_back({object, reference});
}

// 验证精确元表和 alive 标记；成功返回借用对象地址并创建 registry 强引用。
void *LuaBinding::inspectUserdata(lua_State *state, int index, const char *name, int &reference,
                                  const char **failure)
{
    // 固定输入索引，后续读取 uservalue 与创建引用都复用同一 full userdata。
    index = lua_absindex(state, index);
    // luaL_testudata 同时确认具名元表身份并取得 userdata 内的 T 存储地址。
    void *object = luaL_testudata(state, index, name); // 通过精确元表检查后取得 Lua-owned 对象存储。
    if (!object)
    {
        // 仅在元表检查失败后区分原有诊断，不在成功路径重复检查类型。
        *failure = lua_type(state, index) != LUA_TUSERDATA
                       ? "value must be full userdata with the registered metatable"
                       : "value must be userdata with the registered metatable";
        return nullptr;
    }

    // 第一个 uservalue 是构造完成后才置真的 alive 标记；读取结果随后弹出。
    const int  type  = lua_getiuservalue(state, index, 1);
    const bool alive = type == LUA_TBOOLEAN && lua_toboolean(state, -1);
    lua_pop(state, 1);
    if (!alive)
    {
        *failure = "userdata has already been finalized";
        return nullptr;
    }

    // 对象仍存活时建立临时强引用；外层 Binding 接管并在回调结束时释放.
    lua_pushvalue(state, index);
    reference = luaL_ref(state, LUA_REGISTRYINDEX);
    return object;
}

// 读取 userdata 并建立回调内强引用；类型或存活检查失败时保持调用方输出不变。
void *LuaBinding::checkUserdata(int index, const std::string &name)
{
    detail::StackRestore stack(state_);
    int reference = LUA_NOREF; // 成功后交给 Binding 的保活记录。
    const char *failure = nullptr; // inspectUserdata 返回的静态类型或存活诊断。
    void *object = inspectUserdata(state_, index, name.c_str(), reference, &failure);
    if (!object)
    {
        setError("INVALID_ARGUMENT", failure);
        return nullptr;
    }
    retainUserdata(object, reference);
    return object;
}
} // namespace flywow_lua_binding
