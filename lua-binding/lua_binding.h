// 职责：隐藏参数转换、table 临时栈和托管 userdata 生命周期。
// 普通 Native 函数直接书写；仅注册处的 nativeCallback 捕获越过函数的 C++ 异常。
// 不拥有 Lua State；所有句柄只在当前同步回调内有效，不允许 yield。
#pragma once
extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <string>
#include <tuple>
#include <type_traits>
#include <utility>
#include <vector>

namespace flywow_lua_binding
{
class LuaBinding;
class LuaTable;
class LuaValue;
using Callback = lua_CFunction;

namespace detail
{
// FWGC 标记仅属于托管析构闭包的私有 upvalue 2，用于阻止 LuaTable 改写该元表的 __gc。
// upvalue 1 仍为元表身份；这两项均不占用任何业务方法的 upvalue。
inline constexpr lua_Integer kManagedGcTag = 0x46574743;
inline constexpr int         kMaxUpvalues  = 255; // Lua 5.4 的业务 upvalue 数量上限。
union UserdataAlignment
{
    LUAI_MAXALIGN;
};

// 为外层 C++ 操作预留栈；无法预留时由注册入口捕获 bad_alloc。
void ensureStack(lua_State *state, int extra);
// 输入为栈顶 inputs 项；回调参数 1 为明确的数据记录，输入从 2 开始。
// 成功留下 outputs 项，Lua 执行失败留下错误对象。建立调用前的栈预留仍可能抛 bad_alloc。
// 回调只执行 Lua C API，不持有 C++ 资源。
bool protectedCall(lua_State *state, lua_CFunction function, void *arguments, int inputs,
                   int outputs);
int callbackFailure(lua_State *state, const char *message);

// 普通接口退出时恢复临时栈；最终返回值由 returnValues 显式留给 Lua。
class StackRestore
{
  public:
    explicit StackRestore(lua_State *state) : state_(state), top_(lua_gettop(state))
    {
    }
    ~StackRestore()
    {
        lua_settop(state_, top_);
    }
    StackRestore(const StackRestore &)            = delete;
    StackRestore &operator=(const StackRestore &) = delete;

  private:
    lua_State *state_;
    int        top_;
};

template <typename T> struct ValueCodec
{
    /// 将已有 Lua 数值槽严格转换成 T；失败不改变 output，也不压栈。
    /// @param state 当前操作借用的 Lua State。
    /// @param index 调用方已验证的参数、字段或 upvalue 槽。
    /// @param output 转换成功后接收 C++ 数值。
    /// @param reason 非空诊断输出，类型或范围错误时供 Binding 记录。
    /// @return 严格类型及目标范围正确为 true，否则为 false。
    static bool read(lua_State *state, int index, T &output, const char **reason)
    {
        if constexpr (std::is_integral_v<T> && !std::is_same_v<T, bool>)
        {
            // lua_isinteger 只检查原槽是否为 Lua 整数，不接受 1.0/数字字符串，不改变栈。
            if (!lua_isinteger(state, index))
            {
                *reason = "value must be an integer";
                return false;
            }
            // 前一检查已确认整数；lua_tointeger 只读取该槽，不转换、不弹栈。
            const lua_Integer value =
                lua_tointeger(state, index); // 原槽中的整数，先按目标 T 的范围判断。
            if (std::is_signed_v<T>)
            {
                if (value < static_cast<std::intmax_t>(std::numeric_limits<T>::min()) ||
                    value > static_cast<std::intmax_t>(std::numeric_limits<T>::max()))
                {
                    *reason = "integer outside destination range";
                    return false;
                }
            }
            else if (value < 0 || static_cast<std::uintmax_t>(value) >
                                      static_cast<std::uintmax_t>(std::numeric_limits<T>::max()))
            {
                *reason = "integer outside destination range";
                return false;
            }
            output = static_cast<T>(value);
            return true;
        }
        else if constexpr (std::is_floating_point_v<T>)
        {
            // lua_type 只读取类型标签，不转换原槽、不改变栈。
            if (lua_type(state, index) != LUA_TNUMBER)
            {
                *reason = "value must be a number";
                return false;
            }
            // 已确认是 number；lua_tonumber 读取数值，不压栈、不移除原值。
            const lua_Number value =
                lua_tonumber(state, index); // 原槽中的数值，转换前检查有限性和目标范围。
            if (!std::isfinite(value) ||
                std::fabs(static_cast<long double>(value)) > std::numeric_limits<T>::max())
            {
                *reason = "number must be finite and within destination range";
                return false;
            }
            output = static_cast<T>(value);
            return true;
        }
        else
        {
            static_assert(std::is_integral_v<T> || std::is_floating_point_v<T>,
                          "ValueCodec<T>::read requires a supported numeric T or a specialization");
        }
    }

    /// 校验 C++ 数值后压入一个 Lua 值，拒绝越界和非有限浮点值。
    /// @param state 当前操作借用的 Lua State。
    /// @param value 要传给 Lua 的 C++ 数值。
    /// @param reason 非空诊断输出，失败时供 Binding 记录。
    /// @return 成功压入一项为 true；转换失败为 false，净栈变化为零。
    static bool push(lua_State *state, T value, const char **reason)
    {
        if constexpr (std::is_integral_v<T> && !std::is_same_v<T, bool>)
        {
            if constexpr (std::is_signed_v<T>)
            {
                if (static_cast<std::intmax_t>(value) < std::numeric_limits<lua_Integer>::min() ||
                    static_cast<std::intmax_t>(value) > std::numeric_limits<lua_Integer>::max())
                {
                    *reason = "integer outside Lua integer range";
                    return false;
                }
            }
            else if (static_cast<std::uintmax_t>(value) >
                     static_cast<std::uintmax_t>(std::numeric_limits<lua_Integer>::max()))
            {
                *reason = "integer outside Lua integer range";
                return false;
            }
            // 范围检查已完成；成功压入整数：[S] -> [S, integer]。
            lua_pushinteger(state, static_cast<lua_Integer>(value));
            return true;
        }
        else if constexpr (std::is_floating_point_v<T>)
        {
            if (!std::isfinite(value) ||
                std::fabs(static_cast<long double>(value)) > std::numeric_limits<lua_Number>::max())
            {
                *reason = "number must be finite and within Lua number range";
                return false;
            }
            // 有限值及范围检查已完成；成功压入 number：[S] -> [S, number]。
            lua_pushnumber(state, static_cast<lua_Number>(value));
            return true;
        }
        else
        {
            static_assert(std::is_integral_v<T> || std::is_floating_point_v<T>,
                          "ValueCodec<T>::push requires a supported numeric T or a specialization");
        }
    }
};

template <> struct ValueCodec<bool>
{
    static bool read(lua_State *state, int index, bool &output, const char **reason);
    static bool push(lua_State *state, bool value, const char **reason);
};
template <> struct ValueCodec<std::string>
{
    static bool read(lua_State *state, int index, std::string &output, const char **reason);
    static bool push(lua_State *state, const std::string &value, const char **reason);
};
template <> struct ValueCodec<void *>
{
    static bool read(lua_State *state, int index, void *&output, const char **reason);
};

} // namespace detail

class LuaBinding
{
  public:
    explicit LuaBinding(lua_State *state);
    ~LuaBinding();
    LuaBinding(const LuaBinding &)            = delete;
    LuaBinding &operator=(const LuaBinding &) = delete;

    // 注册为 Lua C 函数的唯一异常入口；不占用 upvalue，不改变业务参数或正常多返回值。
    // 实际函数返回/展开后才构造错误；持续 OOM 最终交给 Lua 错误出口。
    /// @tparam Function 注册的实际 Native 函数；正常签名为 int(lua_State*)。
    /// @param state Lua 提供的原参数栈，业务 upvalue 没有内部偏移。
    /// @return 原函数的 Lua 结果数量；意外异常返回 nil/INTERNAL_ERROR，持续 OOM 抛 Lua 错误。
    template <Callback Function> static int nativeCallback(lua_State *state)
    {
        const char *failure = "Unexpected Native exception";
        try
        {
            return Function(state);
        }
        catch (const std::bad_alloc &)
        {
            failure = "Native allocation failed";
        }
        catch (...)
        {
            // 离开 catch 后再进入 Lua，保证异常对象也已析构。
        }
        return detail::callbackFailure(state, failure);
    }

    // 模块入口直接注册托管类型及方法；不创建 Binding/table 句柄。
    // name 必须唯一；methods 不允许覆盖托管 __gc。失败按 Lua 模块加载错误传播。
    /// @tparam T 由 Lua 存储并析构的类型，要求 noexcept 析构。
    /// @param state 正在加载模块的 Lua State；此调用不创建 C++ 资源。
    /// @param name 本 State 中唯一的精确类型名。
    /// @param methods 静态方法表，以空项结束，不允许声明 __gc。
    /// @return 无结果；初始化失败按 Lua 错误传播。
    template <typename T>
    static void registerUserdata(lua_State *state, const char *name, const luaL_Reg *methods)
    {
        static_assert(alignof(T) <= alignof(detail::UserdataAlignment));
        static_assert(std::is_nothrow_destructible_v<T>);
        registerType(state, name, &collectUserdata<T>, methods);
    }

    // 严格读取位置参数；类型/范围错误返回 false，保持 output 原值并记录诊断。
    /// @param index 从 1 开始的参数编号或当前真实负索引，不能传伪索引。
    /// @param output 成功时接收严格转换后的值；失败保持原值。
    /// @return 类型和范围正确为 true；失败记录 INVALID_ARGUMENT。
    template <typename T> bool readValue(int index, T &output)
    {
        return validIndex(index) && readAt(index, output);
    }
    // nil/省略保留调用方的默认值；显式 false 仍按 T 校验。
    /// @param index 可省略的位置参数编号。
    /// @param output 调用方先设置默认值；nil/省略保留默认值。
    /// @return 读取或应用默认值成功为 true；显式值校验失败为 false。
    template <typename T> bool readOptionalValue(int index, T &output)
    {
        if (index > lua_gettop(state_))
            return true;
        return validIndex(index) && (lua_isnil(state_, index) || readAt(index, output));
    }
    /// @param index 被检查的位置参数；仅超出实参数量的正编号视为省略。
    /// @return 参数省略或 nil 为 true，不改变栈或诊断。
    bool isNoneOrNil(int index) const noexcept;
    /// @param index 原始参数或真实栈位置；读取保持原参数栈。
    /// @param output 成功时获得同一表的独立引用，必须早于 Binding 析构。
    /// @return 成功 true；类型或 Lua 操作失败 false，输出保持不变。
    bool readTable(int index, LuaTable &output);
    /// 从调用瞬间的栈顶读取表，输出合同与带 index 的重载相同。
    bool readTable(LuaTable &output);
    // 创建表并建立独立引用；已进入保护调用的 Lua 失败返回 false，不覆盖 output。
    // 建立保护边界、C++ 字符串复制和保存诊断仍可能抛异常，由注册入口处理。
    /// @param output 成功才接管新表引用；不允许超过本 Binding 生命周期。
    /// @return 创建成功 true；失败 false 并记录诊断。
    bool newTable(LuaTable &output);

    /// @param index 从 1 开始的真实业务 upvalue 编号。
    /// @param output 成功时接收值，失败保持原值。
    /// @return 编号和类型有效为 true；失败 false 并记录诊断。
    template <typename T> bool readUpvalue(int index, T &output)
    {
        return validUpvalue(index) && readAt(lua_upvalueindex(index), output);
    }
    /// 读取业务 upvalue 中的表；成功建立独立引用，失败保持输出。
    bool readUpvalueTable(int index, LuaTable &output);
    // 只替换已有业务槽；不增加任何隐藏 upvalue。
    /// @param index 已存在的业务 upvalue，编号从 1 开始。
    /// @param value 要保存的值；table/userdata 保持原对象身份。
    /// @return 更新成功 true；编号、类型或 Lua 操作失败 false。
    template <typename T> bool writeUpvalue(int index, const T &value)
    {
        if (!validUpvalue(index))
            return false;
        detail::StackRestore stack(state_);
        if (!pushOne(value))
            return false;
        lua_replace(state_, lua_upvalueindex(index));
        return true;
    }

    // 一次受保护调用压入全部结果；失败改为 nil/error。调用后立即 return。
    /// @param values 顺序交给 Lua 的零个或多个结果。
    /// @return 成功为结果数；转换失败为 nil/error 的两个结果。
    template <typename... Values> int returnValues(const Values &...values)
    {
        if constexpr (sizeof...(Values) == 0)
        {
            return 0;
        }
        const int                 base = lua_gettop(state_);
        ValueArguments<Values...> arguments{this, std::tie(values...), nullptr};
        const bool                ok =
            detail::protectedCall(state_, &pushResults<Values...>, &arguments, 0, LUA_MULTRET);
        if (!completeCall(ok, arguments.failure))
        {
            lua_settop(state_, base);
            return pushError();
        }
        return sizeof...(Values);
    }
    // 返回 nil,{code,message}；构造错误结果也失败时抛 bad_alloc，让注册入口完成资源展开。
    /// 最近失败未记录时使用 INTERNAL_ERROR；结果分配也失败会展开到注册入口。
    int pushError();
    int pushError(const std::string &code, const std::string &message);
    /// 只更新本回调诊断，不压栈；业务 parser 失败时供上层 pushError 使用。
    void setError(const std::string &code, const std::string &message);
    const std::string &errorCode() const;
    const std::string &errorMessage() const;

    // 回调内的显式类型注册，供动态注册场景使用；失败保持 output 不变。
    /// @param name 当前 State 唯一的精确类型名。
    /// @param output 成功接收元表引用；失败保持原句柄。
    /// @return 注册成功 true；空名、重名或 Lua 操作失败 false。
    template <typename T> bool registerUserdata(const std::string &name, LuaTable &output)
    {
        static_assert(alignof(T) <= alignof(detail::UserdataAlignment));
        static_assert(std::is_nothrow_destructible_v<T>);
        return registerUserdataType(name, &collectUserdata<T>, output);
    }

    // Lua 分配和类型挂接一次完成；C++ 构造在 pcall 外执行，构造后才启用 __gc。
    /// @param name 此 State 已注册且精确对应 T 的类型名。
    /// @param output 成功接收借用指针，不能 delete 或跨回调保存。
    /// @param args 直接转发给 T 构造函数的参数。
    /// @return 分配、构造和保活成功 true；普通失败 false。
    template <typename T, typename... Args>
    bool newUserdata(const std::string &name, T *&output, Args &&...args)
    {
        static_assert(alignof(T) <= alignof(detail::UserdataAlignment));
        static_assert(std::is_nothrow_destructible_v<T>);
        detail::StackRestore stack(state_);
        void                *storage   = nullptr;
        int                  reference = LUA_NOREF;
        if (!allocateUserdata(name, sizeof(T), storage, reference))
            return false;
        T *object = nullptr;
        try
        {
            object = new (storage) T(std::forward<Args>(args)...);
        }
        catch (...)
        {
            luaL_unref(state_, LUA_REGISTRYINDEX, reference);
            setError("INTERNAL_ERROR", "userdata construction failed");
            return false;
        }

        // 这些写入不分配；从启用标记开始，即使保活记录失败也由 GC 析构对象。
        lua_rawgeti(state_, LUA_REGISTRYINDEX, reference);
        lua_pushboolean(state_, 1);
        lua_setiuservalue(state_, -2, 1);
        if (!retainUserdata(object, reference))
            return false;
        output = object;
        return true;
    }
    /// @param index 含 userdata 的位置参数。
    /// @param name 已注册的精确类型名。
    /// @param output 成功接收本回调借用的 T*；失败保持原值。
    /// @return 类型匹配且存活为 true；失败 false 并记录诊断。
    template <typename T> bool readUserdata(int index, const std::string &name, T *&output)
    {
        return validIndex(index) && readUserdataAt(index, name, output);
    }
    /// 读取业务 upvalue 的托管 userdata；指针与 readUserdata 一样只在本回调借用。
    template <typename T> bool readUpvalueUserdata(int index, const std::string &name, T *&output)
    {
        return validUpvalue(index) && readUserdataAt(lua_upvalueindex(index), name, output);
    }

  private:
    friend class LuaTable;
    friend class LuaValue;
    struct UserdataReference
    {
        void *object;    ///< 本回调借用的 C++ 地址；用于找回原 userdata。
        int   reference; ///< Lua registry 强引用；Binding 析构时释放。
    };

    template <typename T> static int collectUserdata(lua_State *state) noexcept
    {
        /*
            __gc 的参数栈为 [S, userdata]。Lua 5.4 的 getiuservalue 总会压入一项；
            uservalue 序号无效时压入 nil 并返回 LUA_TNONE。本类型创建时固定分配了第 1 项：
            [S, userdata] -> [S, userdata, alive_state]。
        */
        // __gc 也可能由挂了此元表的普通 table 触发；先确认 full userdata、存储尺寸和元表身份。
        // [userdata] -> [userdata, actual_meta] -> [userdata]，闭包 upvalue 1 保留注册元表。
        if (lua_type(state, 1) != LUA_TUSERDATA || lua_rawlen(state, 1) != sizeof(T) ||
            lua_getmetatable(state, 1) == 0)
        {
            return 0;
        }
        const bool correct_type = lua_rawequal(state, -1, lua_upvalueindex(1)) != 0;
        lua_pop(state, 1);
        if (!correct_type)
        {
            return 0;
        }

        const int state_type = lua_getiuservalue(state, 1, 1);
        if (state_type != LUA_TBOOLEAN || lua_toboolean(state, -1) == 0)
        {
            // 状态缺失、类型不符或已清理：弹掉刚读出的 uservalue，恢复 [S, userdata]；
            // 返回 0 表示不产生 Lua 返回值，也不重复析构对象。
            lua_pop(state, 1);
            return 0;
        }

        // 先弹出 alive_state，再压入 false 并写回：[S, userdata, true]
        // -> [S, userdata] -> [S, userdata, false] -> [S, userdata]。
        // 先翻转状态，后续重复进入 __gc 会走上面的无操作分支。
        lua_pop(state, 1);
        lua_pushboolean(state, 0);
        lua_setiuservalue(state, 1, 1);

        // lua_touserdata 读取参数 1 的 full userdata 存储地址，不改变栈。
        // Lua 负责释放这块内存；这里仅结束 placement-new 的 T 生命周期，不能用 delete。
        static_cast<T *>(lua_touserdata(state, 1))->~T();
        return 0;
    }

    // 数据记录只有借用值和失败原因；执行代码是静态 Lua C 回调，不传递 operation 对象。
    template <typename... Values> struct ValueArguments
    {
        LuaBinding *binding; ///< 借用所属回调，负责严格转换与结果诊断。
        std::tuple<const Values &...>
                    values;  ///< 借用待写入的实参，顺序就是 Lua 返回值或 upvalue 顺序。
        const char *failure; ///< 失败时由原生操作写入的常量原因；外层随后记录诊断。
    };
    template <typename... Values> static int pushResults(lua_State *state) noexcept
    {
        auto *arguments = static_cast<ValueArguments<Values...> *>(lua_touserdata(state, 1));
        luaL_checkstack(state, sizeof...(Values) + 4, "Native results exceed stack capacity");
        const bool ok = std::apply(
            [&](const auto &...values)
            { return (arguments->binding->pushRaw(state, values, &arguments->failure) && ...); },
            arguments->values);
        return ok ? sizeof...(Values) : 0;
    }
    template <typename T> bool pushOne(const T &value)
    {
        ValueArguments<T> arguments{this, std::tie(value), nullptr};
        const bool        ok = detail::protectedCall(state_, &pushResults<T>, &arguments, 0, 1);
        return completeCall(ok, arguments.failure);
    }

    // 仅供受保护的 C 回调使用；不分配 C++ 对象，失败只记录常量原因。
    template <typename T> bool pushRaw(lua_State *state, const T &value, const char **reason)
    {
        return detail::ValueCodec<T>::push(state, value, reason);
    }
    template <typename T> bool pushRaw(lua_State *state, T *value, const char **reason)
    {
        return pushObject(state, value, reason);
    }
    template <std::size_t N>
    bool pushRaw(lua_State *state, const char (&value)[N], const char **reason)
    {
        return pushRaw(state, static_cast<const char *>(value), reason);
    }
    bool pushRaw(lua_State *state, const LuaTable &value, const char **reason);
    bool pushRaw(lua_State *state, const char *value, const char **reason);
    bool pushRaw(lua_State *state, std::nullptr_t, const char **reason);
    bool pushRaw(lua_State *state, void *value, const char **reason);
    bool pushObject(lua_State *state, const void *object, const char **reason);

    template <typename T> bool readAt(int index, T &output)
    {
        const char *reason = nullptr;
        if (!detail::ValueCodec<T>::read(state_, index, output, &reason))
        {
            setError("INVALID_ARGUMENT", reason);
            return false;
        }
        return true;
    }
    template <typename T> bool readUserdataAt(int index, const std::string &name, T *&output)
    {
        void *object = checkUserdata(index, name);
        if (!object)
            return false;
        output = static_cast<T *>(object);
        return true;
    }
    bool completeCall(bool succeeded, const char *failure = nullptr);
    bool validIndex(int index);
    bool validUpvalue(int index);
    bool readTableAt(int index, LuaTable &output);
    bool readTruthAt(int index, bool &output);
    bool retainUserdata(void *object, int reference);
    bool registerUserdataType(const std::string &name, lua_CFunction collector, LuaTable &output);
    bool allocateUserdata(const std::string &name, std::size_t bytes, void *&storage,
                          int &reference);
    void *checkUserdata(int index, const std::string &name);
    static void *inspectUserdata(lua_State *state, int index, const char *name, int &reference,
                                 const char **failure);
    // 仅在受保护写操作中调用；普通表允许 __gc，识别到托管析构闭包则拒绝改写。
    static bool canWriteField(lua_State *state, int table_index, int key_index) noexcept;
    static void registerType(lua_State *state, const char *name, lua_CFunction collector,
                             const luaL_Reg *methods);

    lua_State                     *state_;              // 借用当前 VM，不负责关闭。
    std::string                    error_code_;         // 最近错误码；成功不清除，pushError 读取。
    std::string                    error_message_;      // 与错误码配对的诊断。
    std::uint64_t                  error_revision_ = 0; // 遍历时区分 visitor 新记录的错误。
    std::vector<UserdataReference> userdata_refs_;      // 回调内保活对象及其 registry 引用。
};
} // namespace flywow_lua_binding
