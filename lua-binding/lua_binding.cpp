// 职责：Lua 参数转换、完整操作的保护调用、错误结果和 userdata 引用。
// 保护回调中只放 Lua C API；C++ 字符串复制、构造和容器操作均在 pcall 外。
#include "lua_binding.h"
#include "lua_table.h"
#include <cstring>

namespace flywow_lua_binding
{
namespace detail
{
// Lua 栈空间不足时抛 bad_alloc；外层注册回调统一处理该 C++ 失败。
void ensureStack(lua_State *state, int extra)
{
    if (!lua_checkstack(state, extra))
        throw std::bad_alloc();
}

bool protectedCall(lua_State *state, lua_CFunction function, void *arguments, int inputs,
                   int outputs)
{
    // 预留包装函数、arguments 和 Lua C API 调用自身需要的槽位。
    ensureStack(state, LUA_MINSTACK + 2);

    // 将回调与轻量参数记录插到原输入段之前，供回调以参数 1/2 读取。
    const int first = lua_gettop(state) - inputs + 1; // 原输入段在插入包装参数前的起点。
    // [S, inputs...] -> [S, function, arguments, inputs...]。
    lua_pushcfunction(state, function);
    lua_insert(state, first);
    lua_pushlightuserdata(state, arguments);
    lua_insert(state, first + 1);

    // pcall 消耗包装函数和输入；成功留下 outputs 项，失败留下 Lua 错误对象。
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
    // 参数 1 借用外层 ErrorArguments；只在保护调用期间读取其诊断字节。
    auto *args = static_cast<ErrorArguments *>(lua_touserdata(state, 1));

    // [arguments] -> [arguments, nil, error_table]；错误字段复制进 Lua 后不再依赖借用缓冲区。
    lua_pushnil(state);
    lua_createtable(state, 0, 2);
    lua_pushlstring(state, args->code, args->code_size);
    lua_setfield(state, -2, "code");
    lua_pushlstring(state, args->message, args->message_size);
    lua_setfield(state, -2, "message");

    // 参数 1 不是返回值；只交回 nil 和错误表。
    return 2;
}

// 原生回调已退出并销毁局部对象后，才清空参数栈并尝试构造 Lua 错误结果。
int callbackFailure(lua_State *state, const char *message)
{
    // 实际 Native 函数及异常对象均已析构，才允许使用 Lua 的最终错误出口。
    lua_settop(state, 0);

    // 只借用静态诊断文本；保护调用负责处理 Lua 创建错误表时产生的 Lua 错误。
    ErrorArguments args{"INTERNAL_ERROR", 14, message, std::strlen(message)}; // 静态错误码和借用诊断的字节长度。
    try
    {
        if (protectedCall(state, &errorResult, &args, 0, 2))
            return 2;
    }
    catch (...)
    {
        // 退出 catch 再跳转到 Lua，避免跳过异常对象析构。
    }

    // 结构化错误也无法创建时只能把固定错误交回 Lua。
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

    // 输入已确认是 boolean；保留 false 作为正常读取结果。
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

    // 类型校验通过后，读取 Lua 持有的完整字节串并复制到独立 C++ string。
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

    // 类型通过后取得调用方借入的地址，不建立 userdata 所有权。
    output = lua_touserdata(state, index);
    return true;
}

} // namespace detail

LuaBinding::LuaBinding(lua_State *state) : state_(state)
{
    detail::ensureStack(state_, LUA_MINSTACK);
}

// 回调结束时释放 readUserdata/checkUserdata 建立的强引用；对象内存和析构仍归 Lua GC。
LuaBinding::~LuaBinding()
{
    for (const auto &entry : userdata_refs_)
        luaL_unref(state_, LUA_REGISTRYINDEX, entry.reference);
}

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

    // Lua 调用成功后仍可能有业务值转换失败；把该静态原因记录为参数错误。
    if (failure)
    {
        setError("INVALID_ARGUMENT", failure);
        return false;
    }
    return true;
}

// 保护调用构造 nil/error；Lua 返回错误时恢复原栈并抛 bad_alloc。
int LuaBinding::pushError()
{
    const int   base = lua_gettop(state_); // Lua 无法构造错误表时恢复的原栈顶。
    // code/message 借用 Binding 成员或静态字面量，errorResult 在受保护调用中复制它们。
    const char *code = error_code_.empty() ? "INTERNAL_ERROR" : error_code_.data(); // 最近错误码或默认码。
    const char *message =
        error_code_.empty() ? "no recorded Binding error" : error_message_.data(); // 配对诊断或默认文本。
    detail::ErrorArguments args{code, error_code_.empty() ? 14 : error_code_.size(), message,
                                error_code_.empty() ? 25 : error_message_.size()};

    // 在受保护调用内把借用的诊断字节复制进 Lua 的 nil/error 返回值。
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
    const std::string code_copy(code); // 先复制错误码，避免 setError 写入时失效。
    const std::string message_copy(message); // 同理保护引用当前 message 成员的调用。

    // 先写入独立副本，再复用统一的错误结果构造流程。
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
    auto *args = static_cast<ReferenceArguments *>(lua_touserdata(state, 1)); // 外层接收引用编号的记录。
    lua_pushvalue(state, 2);
    args->reference = luaL_ref(state, LUA_REGISTRYINDEX);
    return 0;
}
} // namespace

// referenceTable 需要临时压入 table；StackRestore 在句柄接管引用前恢复调用方参数栈。
bool LuaBinding::readTableAt(int index, LuaTable &output)
{
    if (!lua_istable(state_, index))
    {
        setError("INVALID_ARGUMENT", "value must be a table");
        return false;
    }

    // 保护原参数栈，把 table 复制到保护回调；referenceTable 只在回调成功时写入引用编号。
    detail::StackRestore stack(state_);
    detail::ensureStack(state_, 1);
    lua_pushvalue(state_, index);
    ReferenceArguments args; // 回调创建的 registry 引用编号，由 output 句柄接管。

    if (!completeCall(detail::protectedCall(state_, &referenceTable, &args, 1, 0)))
        return false;

    // 只在引用确实建立后替换 output，避免失败时丢失调用方原句柄。
    output = LuaTable(this, args.reference);
    return true;
}
bool LuaBinding::readTable(int index, LuaTable &output)
{
    return validIndex(index) && readTableAt(index, output);
}

// Lua 建表与 luaL_ref 放在同一保护调用中；外层只在成功后接管引用。
bool LuaBinding::newTable(LuaTable &output)
{
    detail::StackRestore stack(state_);
    ReferenceArguments   args; // 新表 registry 引用编号，成功后交给 output。

    // 回调只使用 Lua C API；luaL_ref 消耗新表并把引用编号写入外层参数记录。
    const bool ok = detail::protectedCall(
        state_,
        [](lua_State *inner) noexcept -> int
        {
            auto *data = static_cast<ReferenceArguments *>(lua_touserdata(inner, 1));
            lua_newtable(inner); // 新建表随后由 luaL_ref 移入 registry。
            data->reference = luaL_ref(inner, LUA_REGISTRYINDEX);
            return 0;
        },
        &args, 0, 0);
    if (!completeCall(ok))
        return false;

    // 保护调用成功后才接管新引用，不覆盖失败路径中的 output。
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

    // 句柄归属验证通过后，从 registry 压入原 table。
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

    // 非空 C 字符串按首个零字节截断，并由 Lua 复制内容。
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
    // 先固定负索引，后续压栈不会改变目标 table 与 key 的位置。
    table_index = lua_absindex(state, table_index);
    key_index   = lua_absindex(state, key_index);
    if (lua_type(state, key_index) != LUA_TSTRING)
        return true;

    // 仅字符串 key 可能命中固定的析构字段名。
    std::size_t length = 0; // key 的完整字节数；不依赖以零结尾的 C 字符串。
    const char *key    = lua_tolstring(state, key_index, &length); // 借用 Lua 字符串，只在本次比较中使用。
    if (length != 4 || std::memcmp(key, "__gc", 4) != 0)
        return true;

    // 只有精确写入 __gc 时才检查当前值是否为本 Binding 安装的析构闭包。
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
    // 移除读取到的旧 __gc；managed 为 true 时拒绝覆盖或删除。
    lua_pop(state, 1);
    return !managed;
}

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
    UserdataArguments args{name.c_str(), bytes}; // 借用 name 与请求长度，供保护回调分配 userdata。
    const bool        ok = detail::protectedCall(
        state_,
        [](lua_State *inner) noexcept -> int
        {
            auto *data = static_cast<UserdataArguments *>(lua_touserdata(inner, 1));
            // 先取得目标类型的已注册元表；没有注册时不分配无法安全析构的存储。
            luaL_getmetatable(inner, data->name);
            if (!lua_istable(inner, -1))
            {
                data->failure = "userdata type must be registered before construction";
                return 0;
            }

            // 分配 Lua-owned 存储并初始化 alive=false；外层 placement-new 成功后才启用 GC.
            data->object = lua_newuserdatauv(inner, data->size, 1);
            lua_pushboolean(inner, 0);
            lua_setiuservalue(inner, -2, 1);
            lua_pushvalue(inner, -2);
            lua_setmetatable(inner, -2);

            // registry 引用暂时保活未构造 userdata，外层成功或失败后负责接管/释放。
            data->reference = luaL_ref(inner, LUA_REGISTRYINDEX);
            return 0;
        },
        &args, 0, 0);

    if (!completeCall(ok, args.failure))
        return false;

    // Lua 存储和 registry 引用均已建立后才发布输出，失败路径保持调用方原值。
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

    // 新对象需要本回调自己的记录；vector 分配失败时必须撤销刚建立的 registry 引用。
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

void *LuaBinding::inspectUserdata(lua_State *state, int index, const char *name, int &reference,
                                  const char **failure)
{
    // 固定输入索引，后续读取 uservalue 与创建引用都复用同一 full userdata。
    index = lua_absindex(state, index);
    if (lua_type(state, index) != LUA_TUSERDATA)
    {
        *failure = "value must be full userdata with the registered metatable";
        return nullptr;
    }

    // luaL_testudata 同时确认具名元表身份并取得 userdata 内的 T 存储地址。
    void *object = luaL_testudata(state, index, name); // 通过精确元表检查后取得 Lua-owned 对象存储。
    if (!object)
    {
        *failure = "value must be userdata with the registered metatable";
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

void *LuaBinding::checkUserdata(int index, const std::string &name)
{
    detail::StackRestore stack(state_);
    if (lua_type(state_, index) != LUA_TUSERDATA)
    {
        setError("INVALID_ARGUMENT", "value must be full userdata with the registered metatable");
        return nullptr;
    }

    // protectedCall 内部的 Lua API 可能报错；复制参数后让 inspectUserdata 在隔离栈检查。
    detail::ensureStack(state_, 1);
    lua_pushvalue(state_, index);
    UserdataArguments args{name.c_str(), 0}; // 借用类型名；protectedCall 返回前调用方字符串保持有效。
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

    // registry 强引用现由 Binding 持有；返回的裸地址只借用到本回调结束。
    return args.object;
}
} // namespace flywow_lua_binding
