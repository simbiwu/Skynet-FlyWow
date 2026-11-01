// 职责：Lua 参数转换、完整操作的保护调用、错误结果和 userdata 引用。
// 保护回调中只放 Lua C API；C++ 字符串复制、构造和容器操作均在 pcall 外。
#include "lua_binding.h"
#include "lua_table.h"
#include <cstring>

namespace flywow_lua_binding
{
namespace detail
{
void ensureStack(lua_State *state, int extra)
{
    if (!lua_checkstack(state, extra))
        throw std::bad_alloc();
}

bool protectedCall(lua_State *state, lua_CFunction function, void *arguments, int inputs,
                   int outputs)
{
    ensureStack(state, LUA_MINSTACK + 2);
    const int first = lua_gettop(state) - inputs + 1;
    // [S, inputs...] -> [S, function, arguments, inputs...]。
    lua_pushcfunction(state, function);
    lua_insert(state, first);
    lua_pushlightuserdata(state, arguments);
    lua_insert(state, first + 1);
    return lua_pcall(state, inputs + 1, outputs, 0) == LUA_OK;
}

struct ErrorArguments
{
    const char *code;         ///< 借用调用方错误码字节，保护调用结束前有效。
    std::size_t code_size;    ///< 错误码字节数，支持内嵌零字节。
    const char *message;      ///< 借用调用方诊断字节，保护调用结束前有效。
    std::size_t message_size; ///< 诊断字节数，支持内嵌零字节。
};

// 只接收借用字节；Lua 分配错误由外层 pcall 接住，不跨越任何 C++ 资源。
static int errorResult(lua_State *state) noexcept
{
    auto *args = static_cast<ErrorArguments *>(lua_touserdata(state, 1));
    lua_pushnil(state);
    lua_createtable(state, 0, 2);
    lua_pushlstring(state, args->code, args->code_size);
    lua_setfield(state, -2, "code");
    lua_pushlstring(state, args->message, args->message_size);
    lua_setfield(state, -2, "message");
    return 2;
}

int callbackFailure(lua_State *state, const char *message)
{
    // 实际 Native 函数及异常对象均已析构，才允许使用 Lua 的最终错误出口。
    lua_settop(state, 0);
    ErrorArguments args{"INTERNAL_ERROR", 14, message, std::strlen(message)};
    try
    {
        if (protectedCall(state, &errorResult, &args, 0, 2))
            return 2;
    }
    catch (...)
    {
        // 退出 catch 再跳转到 Lua，避免跳过异常对象析构。
    }
    lua_pushliteral(state, "Native operation failed while reporting an error");
    return lua_error(state);
}

bool ValueCodec<bool>::read(lua_State *state, int index, bool &output, const char **reason)
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
    std::size_t length = 0; // Lua 字符串长度，保留内嵌零字节。
    // 已确认是字符串，tolstring 不转换原槽；bytes 借用 Lua 内存，仅用于立即复制。
    // 按 length 复制（包括内嵌零字节），不依赖 C 字符串结束符；栈高度不变。
    const char *bytes  = lua_tolstring(state, index, &length);
    std::string value(bytes, length); // 独立副本构造成功后才移入 output。
    output = std::move(value);
    return true;
}

// 将调用方的完整字节串复制给 Lua；调用方保留 C++ 缓冲区，Lua 分配错误先受保护再展开。
bool ValueCodec<std::string>::push(lua_State *state, const std::string &value, const char **)
{
    // pushlstring 复制全部 bytes，Lua 持有自己的字符串，不借用 C++ buffer。
    lua_pushlstring(state, value.data(), value.size());
    return true;
}

// 只从 lightuserdata 槽取得外部借用地址；output 不拥有资源，reason 在类型不符时接收诊断。
bool ValueCodec<void *>::read(lua_State *state, int index, void *&output, const char **reason)
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
    for (const auto &entry : userdata_refs_)
        luaL_unref(state_, LUA_REGISTRYINDEX, entry.reference);
}

bool LuaBinding::validIndex(int index)
{
    const int top = lua_gettop(state_);
    if (index == 0 || index > top || index < -top)
    {
        setError("INVALID_ARGUMENT", "argument index outside current stack");
        return false;
    }
    return true;
}

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

bool LuaBinding::isNoneOrNil(int index) const noexcept
{
    const int top = lua_gettop(state_);
    return index > top || (index != 0 && index >= -top && lua_isnil(state_, index));
}

void LuaBinding::setError(const std::string &code, const std::string &message)
{
    error_code_    = code;
    error_message_ = message;
}
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
    if (failure)
    {
        setError("INVALID_ARGUMENT", failure);
        return false;
    }
    return true;
}

int LuaBinding::pushError()
{
    const int   base    = lua_gettop(state_);
    const char *code    = error_code_.empty() ? "INTERNAL_ERROR" : error_code_.data();
    const char *message = error_code_.empty() ? "no recorded Binding error" : error_message_.data();
    detail::ErrorArguments args{code, error_code_.empty() ? 14 : error_code_.size(), message,
                                error_code_.empty() ? 25 : error_message_.size()};
    if (!detail::protectedCall(state_, &detail::errorResult, &args, 0, 2))
    {
        lua_settop(state_, base);
        throw std::bad_alloc();
    }
    return 2;
}

int LuaBinding::pushError(const std::string &code, const std::string &message)
{
    // 先复制以支持调用者传入 errorCode() 本身。
    const std::string code_copy(code);
    const std::string message_copy(message);
    setError(code_copy, message_copy);
    return pushError();
}

namespace
{
struct ReferenceArguments
{
    int reference = LUA_NOREF; ///< 成功时建立的 registry 引用；外层接管或释放。
};

// 原值由外层复制到参数 2；ref 成功是最后一步，失败不会泄漏已发布的编号。
int referenceTable(lua_State *state) noexcept
{
    auto *args = static_cast<ReferenceArguments *>(lua_touserdata(state, 1));
    lua_pushvalue(state, 2);
    args->reference = luaL_ref(state, LUA_REGISTRYINDEX);
    return 0;
}
} // namespace

bool LuaBinding::readTableAt(int index, LuaTable &output)
{
    if (!lua_istable(state_, index))
    {
        setError("INVALID_ARGUMENT", "value must be a table");
        return false;
    }
    detail::StackRestore stack(state_);
    detail::ensureStack(state_, 1);
    lua_pushvalue(state_, index);
    ReferenceArguments args;
    if (!completeCall(detail::protectedCall(state_, &referenceTable, &args, 1, 0)))
        return false;
    output = LuaTable(this, args.reference);
    return true;
}
bool LuaBinding::readTable(int index, LuaTable &output)
{
    return validIndex(index) && readTableAt(index, output);
}

bool LuaBinding::newTable(LuaTable &output)
{
    detail::StackRestore stack(state_);
    ReferenceArguments   args;
    const bool           ok = detail::protectedCall(
        state_,
        [](lua_State *inner) noexcept -> int
        {
            auto *data = static_cast<ReferenceArguments *>(lua_touserdata(inner, 1));
            lua_newtable(inner);
            data->reference = luaL_ref(inner, LUA_REGISTRYINDEX);
            return 0;
        },
        &args, 0, 0);
    if (!completeCall(ok))
        return false;
    output = LuaTable(this, args.reference);
    return true;
}

bool LuaBinding::readTruthAt(int index, bool &output)
{
    output = lua_toboolean(state_, index) != 0;
    return true;
}

bool LuaBinding::pushRaw(lua_State *state, const LuaTable &value, const char **reason)
{
    if (!value.valid() || value.binding_ != this)
    {
        *reason = "table must belong to this Binding callback";
        return false;
    }
    lua_rawgeti(state, LUA_REGISTRYINDEX, value.reference_);
    return true;
}
bool LuaBinding::pushRaw(lua_State *state, const char *value, const char **reason)
{
    if (!value)
    {
        *reason = "string pointer must not be null; use nullptr for Lua nil";
        return false;
    }
    lua_pushlstring(state, value, std::strlen(value));
    return true;
}
bool LuaBinding::pushRaw(lua_State *state, std::nullptr_t, const char **)
{
    lua_pushnil(state);
    return true;
}
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

// 检查实际 table 与其析构闭包身份，别名句柄也遵守同一保护规则。
// 只读取 Lua 值并恢复临时栈；调用方已在 pcall 中，不创建 C++ 资源。
bool LuaBinding::canWriteField(lua_State *state, int table_index, int key_index) noexcept
{
    table_index = lua_absindex(state, table_index);
    key_index   = lua_absindex(state, key_index);
    if (lua_type(state, key_index) != LUA_TSTRING)
        return true;
    std::size_t length = 0;
    const char *key    = lua_tolstring(state, key_index, &length);
    if (length != 4 || std::memcmp(key, "__gc", 4) != 0)
        return true;

    lua_pushliteral(state, "__gc");
    lua_rawget(state, table_index);
    bool managed = false;
    if (lua_iscfunction(state, -1))
    {
        bool tagged = false;
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
    lua_pop(state, 1);
    return !managed;
}

// 直接模块注册中只有 Lua 值和静态函数表，不创建需要 C++ 析构的对象。
void LuaBinding::registerType(lua_State *state, const char *name, lua_CFunction collector,
                              const luaL_Reg *methods)
{
    if (!name || !*name)
        luaL_error(state, "metatable needs a name");
    for (auto *method = methods; method && method->name; ++method)
        if (std::strcmp(method->name, "__gc") == 0)
            luaL_error(state, "__gc is managed by userdata registration");
    if (!luaL_newmetatable(state, name))
        luaL_error(state, "userdata metatable name is already registered");
    lua_pushvalue(state, -1);
    lua_pushinteger(state, detail::kManagedGcTag);
    lua_pushcclosure(state, collector, 2);
    lua_setfield(state, -2, "__gc");
    lua_newtable(state);
    if (methods)
        luaL_setfuncs(state, methods, 0);
    lua_setfield(state, -2, "__index");
    lua_pop(state, 1);
}

namespace
{
struct UserdataArguments
{
    const char *name;                  ///< 借用本次字段/类型名称，不在保护回调中构造字符串。
    std::size_t size;                  ///< 本次 Lua-owned userdata 存储字节数。
    void       *object    = nullptr;   ///< 原生操作返回的借用地址；外层决定构造或保活。
    int         reference = LUA_NOREF; ///< 成功时建立的 registry 引用；外层接管或释放。
    const char *failure   = nullptr;   ///< 失败时由原生操作写入的常量原因；外层随后记录诊断。
};
} // namespace

bool LuaBinding::allocateUserdata(const std::string &name, std::size_t bytes, void *&storage,
                                  int &reference)
{
    UserdataArguments args{name.c_str(), bytes};
    const bool        ok = detail::protectedCall(
        state_,
        [](lua_State *inner) noexcept -> int
        {
            auto *data = static_cast<UserdataArguments *>(lua_touserdata(inner, 1));
            luaL_getmetatable(inner, data->name);
            if (!lua_istable(inner, -1))
            {
                data->failure = "userdata type must be registered before construction";
                return 0;
            }
            data->object = lua_newuserdatauv(inner, data->size, 1);
            lua_pushboolean(inner, 0);
            lua_setiuservalue(inner, -2, 1);
            lua_pushvalue(inner, -2);
            lua_setmetatable(inner, -2);
            data->reference = luaL_ref(inner, LUA_REGISTRYINDEX);
            return 0;
        },
        &args, 0, 0);
    if (!completeCall(ok, args.failure))
        return false;
    storage   = args.object;
    reference = args.reference;
    return true;
}

bool LuaBinding::retainUserdata(void *object, int reference)
{
    for (const auto &entry : userdata_refs_)
    {
        if (entry.object == object)
        {
            luaL_unref(state_, LUA_REGISTRYINDEX, reference);
            return true;
        }
    }
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

// Lua 分配失败仅跨越 protectedCall 的 C 栈；此函数没有需析构的 C++ 局部对象。
void *LuaBinding::inspectUserdata(lua_State *state, int index, const char *name, int &reference,
                                  const char **failure)
{
    index = lua_absindex(state, index);
    if (lua_type(state, index) != LUA_TUSERDATA)
    {
        *failure = "value must be full userdata with the registered metatable";
        return nullptr;
    }
    void *object = luaL_testudata(state, index, name);
    if (!object)
    {
        *failure = "value must be userdata with the registered metatable";
        return nullptr;
    }
    const int  type  = lua_getiuservalue(state, index, 1);
    const bool alive = type == LUA_TBOOLEAN && lua_toboolean(state, -1);
    lua_pop(state, 1);
    if (!alive)
    {
        *failure = "userdata has already been finalized";
        return nullptr;
    }
    lua_pushvalue(state, index);
    reference = luaL_ref(state, LUA_REGISTRYINDEX);
    return object;
}

void *LuaBinding::checkUserdata(int index, const std::string &name)
{
    detail::StackRestore stack(state_);
    if (lua_type(state_, index) != LUA_TUSERDATA)
    {
        setError("INVALID_ARGUMENT", "value must be full userdata with the registered metatable");
        return nullptr;
    }
    detail::ensureStack(state_, 1);
    lua_pushvalue(state_, index);
    UserdataArguments args{name.c_str(), 0};
    const bool        ok = detail::protectedCall(
        state_,
        [](lua_State *inner) noexcept -> int
        {
            auto *data = static_cast<UserdataArguments *>(lua_touserdata(inner, 1));
            data->object = inspectUserdata(inner, 2, data->name, data->reference, &data->failure);
            return 0;
        },
        &args, 1, 0);
    if (!completeCall(ok, args.failure) || !retainUserdata(args.object, args.reference))
        return nullptr;
    return args.object;
}
} // namespace flywow_lua_binding
