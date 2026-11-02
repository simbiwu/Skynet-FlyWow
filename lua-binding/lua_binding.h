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
/// @param state 当前操作借用的 Lua State。
/// @param extra 在现有栈顶之外需要预留的槽数。
/// @return 无；容量不足时抛出 std::bad_alloc。
void ensureStack(lua_State *state, int extra);
// 输入为栈顶 inputs 项；回调参数 1 为明确的数据记录，输入从 2 开始。
// 成功留下 outputs 项，Lua 执行失败留下错误对象。建立调用前的栈预留仍可能抛 bad_alloc。
// 回调只执行 Lua C API，不持有 C++ 资源。
/// @param state 当前操作借用的 Lua State。
/// @param function 只调用 Lua C API 的保护回调。
/// @param arguments 回调参数 1 读取的借用记录指针。
/// @param inputs 原栈顶属于本次调用的输入值数量。
/// @param outputs 成功时要求留下的结果数；LUA_MULTRET 保留全部结果。
/// @return Lua 回调成功为 true；Lua 错误为 false，错误对象留在栈顶。
bool protectedCall(lua_State *state, lua_CFunction function, void *arguments, int inputs,
                   int outputs);
/// 将原生回调逸出的 C++ 异常转换为 Lua 可见的 INTERNAL_ERROR。
/// @param state 已由原生回调处理过的 Lua 参数栈；失败路径会清空原参数和临时值。
/// @param message 静态诊断文本；不依赖已析构的异常对象。
/// @return 成功构造错误结果时返回 2；Lua 也无法构造错误结果时调用 lua_error。
int callbackFailure(lua_State *state, const char *message);

// 普通接口退出时恢复临时栈；最终返回值由 returnValues 显式留给 Lua。
class StackRestore
{
  public:
    /// 记下本作用域开始时的栈顶，供析构时恢复。
    /// @param state 当前 Native 回调借用的 Lua State。
    explicit StackRestore(lua_State *state) : state_(state), top_(lua_gettop(state))
    {
    }
    /// 恢复到构造时记录的栈顶；正常用法只丢弃本作用域新增的临时值。
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

            // 数值已通过目标类型范围检查，转换后写入调用方输出。
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
    /// 只接受 Lua boolean；false 是有效输入，失败不改写 output 或栈。
    /// @param state 当前 Binding 借用的 Lua State。
    /// @param index 待读取的真实栈位置。
    /// @param output 成功接收 true 或 false。
    /// @param reason 非空诊断输出；类型错误时供 Binding 记录。
    /// @return 输入类型正确为 true，否则为 false。
    static bool read(lua_State *state, int index, bool &output, const char **reason);
    /// 将 C++ bool 压入一个 Lua boolean。
    /// @param state 当前 Binding 借用的 Lua State。
    /// @param value 要返回给 Lua 的布尔值。
    /// @param reason 保留统一 codec 签名；此转换不会失败。
    /// @return 总是 true，栈顶新增一个 boolean。
    static bool push(lua_State *state, bool value, const char **reason);
};
template <> struct ValueCodec<std::string>
{
    /// 复制 Lua 字符串的全部字节到 C++ string，保留内嵌零字节。
    /// @param state 当前 Binding 借用的 Lua State。
    /// @param index 必须是 Lua string 的真实栈位置；不做数字到字符串转换。
    /// @param output 成功接收独立副本；类型失败保持原值。
    /// @param reason 非空诊断输出；类型错误时供 Binding 记录。
    /// @return 输入类型正确并完成复制为 true；类型错误为 false。
    static bool read(lua_State *state, int index, std::string &output, const char **reason);
    /// 将 C++ string 的全部字节复制到 Lua，并由 Lua 持有返回字符串。
    /// @param state 当前 Binding 借用的 Lua State。
    /// @param value 要复制给 Lua 的完整字节串。
    /// @param reason 保留统一 codec 签名；此转换不报告类型错误。
    /// @return 成功压入一个 Lua 字符串为 true。
    static bool push(lua_State *state, const std::string &value, const char **reason);
};
template <> struct ValueCodec<void *>
{
    /// 只读取 lightuserdata 中的借用地址，不创建 Lua-owned userdata。
    /// @param state 当前 Binding 借用的 Lua State。
    /// @param index 必须是 lightuserdata 的真实栈位置。
    /// @param output 成功接收借用地址；失败保持原值。
    /// @param reason 非空诊断输出；类型错误时供 Binding 记录。
    /// @return 输入类型正确为 true，否则为 false。
    static bool read(lua_State *state, int index, void *&output, const char **reason);
};

} // namespace detail

class LuaBinding
{
  public:
    /// 为一次同步 Native 回调创建 Binding，借用 Lua State 并管理本次诊断与强引用。
    /// @param state 当前回调收到的 Lua State；Binding 借用它，不负责关闭。
    explicit LuaBinding(lua_State *state);
    /// 释放本次回调为 userdata 建立的 registry 强引用；必须早于所属 Lua State 关闭。
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

        // 编译期约束通过后，在当前 Lua State 注册该类型的析构器和方法。
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

        // 实参存在时仍验证槽位，再允许 nil 沿用调用方默认值。
        return validIndex(index) && (lua_isnil(state_, index) || readAt(index, output));
    }
    /// 判断指定参数是否省略或为 nil；显式 false、0 和空串都返回 false。
    /// @param index 被检查的位置参数；仅超出实参数量的正编号视为省略。
    /// @return 参数省略或 nil 为 true，不改变栈或诊断。
    bool isNoneOrNil(int index) const noexcept;
    /// 将参数中的 Lua table 固定为当前回调内可读写的独立句柄。
    /// @param index 原始参数或真实栈位置；读取保持原参数栈。
    /// @param output 成功时获得同一表的独立引用，必须早于 Binding 析构。
    /// @return 成功 true；类型或 Lua 操作失败 false，输出保持不变。
    bool readTable(int index, LuaTable &output);
    // 创建表并建立独立引用；已进入保护调用的 Lua 失败返回 false，不覆盖 output。
    // 建立保护边界、C++ 字符串复制和保存诊断仍可能抛异常，由注册入口处理。
    /// @param output 成功才接管新表引用；不允许超过本 Binding 生命周期。
    /// @return 创建成功 true；失败 false 并记录诊断。
    bool newTable(LuaTable &output);

    /// 严格读取闭包中的业务 upvalue；读取类型与范围规则和 readValue 相同。
    /// @param index 从 1 开始的真实业务 upvalue 编号。
    /// @param output 成功时接收值，失败保持原值。
    /// @return 编号和类型有效为 true；失败 false 并记录诊断。
    template <typename T> bool readUpvalue(int index, T &output)
    {
        return validUpvalue(index) && readAt(lua_upvalueindex(index), output);
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

        // 非空结果通过保护回调转换；base 用于丢弃转换失败时已压入的部分值。
        const int                 base = lua_gettop(state_); // 转换失败时恢复到调用前的栈顶。
        ValueArguments<Values...> arguments{this, std::tie(values...), nullptr}; // 借用结果和诊断槽。
        const bool                ok =
            detail::protectedCall(state_, &pushResults<Values...>, &arguments, 0, LUA_MULTRET);

        // 失败时丢弃可能已压入的部分结果，再统一返回 nil/error。
        if (!completeCall(ok, arguments.failure))
        {
            lua_settop(state_, base);
            return pushError();
        }

        // pcall 已把全部结果留在栈顶；返回其数量交由 Lua C API 读取。
        return sizeof...(Values);
    }
    // 返回 nil,{code,message}；构造错误结果也失败时抛 bad_alloc，让注册入口完成资源展开。
    /// 将最近记录的诊断压成 Lua 的 nil、错误表两个返回值。
    /// @return 成功构造时为 2；结果分配失败时抛出 bad_alloc。
    int pushError();
    /// 先复制并记录本次错误，再返回 nil、错误表；支持 message/code 引用当前诊断成员。
    /// @param code 稳定错误码，交给 Lua 调用方作程序化判断。
    /// @param message 面向日志或调试的诊断文本，不作为机器协议。
    /// @return 成功构造时为 2；字符串复制或结果分配失败时抛出异常。
    int pushError(const std::string &code, const std::string &message);
    /// 只更新本回调诊断，不压栈；业务 parser 失败时供上层 pushError 使用。
    /// @param code 本次失败的稳定错误码；成功调用不会自动清除旧诊断。
    /// @param message 与错误码配对的诊断文本。
    void setError(const std::string &code, const std::string &message);
    /// @return 最近记录的错误码；尚未记录错误时为空字符串，成功操作不清除此值。
    const std::string &errorCode() const;

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
        void                *storage   = nullptr; // Lua 分配的原始存储；构造成功后才含有 T。
        int                  reference = LUA_NOREF; // 暂时保活该 userdata 的 registry 编号。
        if (!allocateUserdata(name, sizeof(T), storage, reference))
            return false;

        // 在 Lua pcall 外构造 T，避免 Lua longjmp 越过尚未析构的 C++ 对象。
        T *object = nullptr;
        try
        {
            object = new (storage) T(std::forward<Args>(args)...);
        }
        catch (...)
        {
            // 构造未完成时 alive 仍为 false，GC 不会析构 T；撤销临时强引用即可。
            luaL_unref(state_, LUA_REGISTRYINDEX, reference);
            setError("INTERNAL_ERROR", "userdata construction failed");
            return false;
        }

        // 构造成功后才置 alive；从此刻起对象析构责任交给 userdata 的 __gc。
        // 这些写入不分配；即使后续保活记录失败，Lua GC 仍能析构对象。
        lua_rawgeti(state_, LUA_REGISTRYINDEX, reference);
        lua_pushboolean(state_, 1);
        lua_setiuservalue(state_, -2, 1);
        if (!retainUserdata(object, reference))
            return false;

        // 只在 userdata 已构造、启用析构并由本回调保活后发布借用指针。
        output = object;
        return true;
    }
    /// 从 Lua 参数取得指定类型且尚未析构的 userdata，并在本回调期间保持其存活。
    /// @param index 含 userdata 的位置参数。
    /// @param name 已注册的精确类型名。
    /// @param output 成功接收本回调借用的 T*；失败保持原值。
    /// @return 类型匹配且存活为 true；失败 false 并记录诊断。
    template <typename T> bool readUserdata(int index, const std::string &name, T *&output)
    {
        return validIndex(index) && readUserdataAt(index, name, output);
    }
    /// 从闭包 upvalue 取得托管 userdata；指针与 readUserdata 一样只在本回调借用。
    /// @param index 从 1 开始的真实业务 upvalue 编号。
    /// @param name 已注册且对应 T 的精确类型名。
    /// @param output 成功接收本回调借用的 T*；失败保持原值。
    /// @return 类型匹配且 userdata 存活为 true；失败 false 并记录诊断。
    template <typename T> bool readUpvalueUserdata(int index, const std::string &name, T *&output)
    {
        return validUpvalue(index) && readUserdataAt(lua_upvalueindex(index), name, output);
    }

  private:
    friend class LuaTable;
    struct UserdataReference
    {
        void *object;    ///< 本回调借用的 C++ 地址；用于找回原 userdata。
        int   reference; ///< Lua registry 强引用；Binding 析构时释放。
    };

    // Lua GC 调用此闭包；确认 userdata 身份和 alive 标记后先置为失效，再析构 placement-new 对象。
    /// @param state GC 回调收到的栈；参数 1 应为由本类型元表管理的 userdata。
    /// @return 不产生 Lua 返回值；伪造对象、类型不符或已清理时安全地不做处理。
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

        // 元表身份通过后才读取 alive 标记，避免访问其他类型的 uservalue。
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
    // 在保护调用内按原顺序转换 ValueArguments；任一值无法表示时不报告部分结果。
    /// @param state protectedCall 提供的栈，索引 1 为 ValueArguments。
    /// @return 所有值成功时返回其数量；转换失败返回 0，由外层读取 failure。
    template <typename... Values> static int pushResults(lua_State *state) noexcept
    {
        auto *arguments = static_cast<ValueArguments<Values...> *>(lua_touserdata(state, 1));
        // 返回值数量已在编译期确定，先按实际结果数量预留输出槽。
        luaL_checkstack(state, sizeof...(Values), "Native results exceed stack capacity");

        // 按 Values 原顺序写入；首个转换失败时记录原因并停止后续写入。
        const bool ok = std::apply(
            [&](const auto &...values)
            { return (arguments->binding->pushRaw(state, values, &arguments->failure) && ...); },
            arguments->values);
        return ok ? sizeof...(Values) : 0;
    }
    // 在 protectedCall 内将普通值交给对应 ValueCodec；Lua 分配错误由保护调用捕获。
    /// @param state 当前受保护的 Lua State。
    /// @param value 要压入 Lua 栈的普通值。
    /// @param reason 失败时接收 ValueCodec 的常量诊断。
    /// @return 转换并压入成功为 true；无法表示为 false。
    template <typename T> bool pushRaw(lua_State *state, const T &value, const char **reason)
    {
        return detail::ValueCodec<T>::push(state, value, reason);
    }
    // 把本回调持有的 userdata 指针映射回 Lua 强引用；不允许把裸指针当作 lightuserdata 返回。
    /// @param state 当前受保护的 Lua State。
    /// @param value 当前 Binding 保活的 userdata 对象地址。
    /// @param reason 未由当前 Binding 保活时接收诊断。
    /// @return 找到并压入原 userdata 为 true；否则为 false。
    template <typename T> bool pushRaw(lua_State *state, T *value, const char **reason)
    {
        return pushObject(state, value, reason);
    }
    // 字符数组按 C 字符串首个零字节结束的规则转发到字符串重载。
    /// @param state 当前受保护的 Lua State。
    /// @param value 待转换的零结尾字符数组。
    /// @param reason 字符串重载失败时接收诊断。
    /// @return 转换并压入成功为 true；失败为 false。
    template <std::size_t N>
    bool pushRaw(lua_State *state, const char (&value)[N], const char **reason)
    {
        return pushRaw(state, static_cast<const char *>(value), reason);
    }
    // table 只能返回给创建它的 Binding 回调；实现通过 registry 引用压入原表。
    /// @param state 当前受保护的 Lua State。
    /// @param value 属于当前 Binding 的 LuaTable 句柄。
    /// @param reason 句柄无效或归属其他 Binding 时接收诊断。
    /// @return 原 table 成功压栈为 true；句柄无效为 false。
    bool pushRaw(lua_State *state, const LuaTable &value, const char **reason);
    // 非空指针按 C 字符串复制；nullptr 由单独重载映射为 Lua nil。
    /// @param state 当前受保护的 Lua State。
    /// @param value 非空零结尾字符串；空值应走 nullptr_t 重载。
    /// @param reason value 为空时接收诊断。
    /// @return 字符串成功压栈为 true；空指针为 false。
    bool pushRaw(lua_State *state, const char *value, const char **reason);
    // 显式空指针表示 Lua nil，与无效的 const char* 字符串区分。
    /// @param state 当前受保护的 Lua State。
    /// @param value 表示 Lua nil 的 nullptr。
    /// @param reason 为统一重载签名保留；此转换不会失败。
    /// @return 总是 true，栈顶新增 nil。
    bool pushRaw(lua_State *state, std::nullptr_t, const char **reason);
    // 用本回调持有的 registry 引用找回 userdata；未持有的地址返回失败原因。
    /// @param state 当前受保护的 Lua State。
    /// @param object 要返回给 Lua 的 Native 对象地址。
    /// @param reason 未找到本回调持有的 userdata 时接收诊断。
    /// @return 找到并压入其 userdata 为 true；否则为 false。
    bool pushObject(lua_State *state, const void *object, const char **reason);

    // 用 ValueCodec 严格读取单个 Lua 槽；失败时把 codec 诊断记录为 INVALID_ARGUMENT。
    /// @param index 已由调用方确认的参数、字段或 upvalue 槽。
    /// @param output 成功接收转换值；codec 失败时保持原值。
    /// @return 转换成功为 true；失败记录 INVALID_ARGUMENT 并返回 false。
    template <typename T> bool readAt(int index, T &output)
    {
        const char *reason = nullptr; // codec 写入的静态类型或范围诊断。
        if (!detail::ValueCodec<T>::read(state_, index, output, &reason))
        {
            setError("INVALID_ARGUMENT", reason);
            return false;
        }
        return true;
    }
    // 将存活检查返回的 void* 转为调用方请求的 T*；对象仍由 Lua userdata 所有。
    /// @param index 已由入口验证的参数槽或 upvalue 伪索引。
    /// @param name 当前 Lua State 中注册的精确元表名。
    /// @param output 成功接收借用指针；失败保持原值。
    /// @return 类型正确且 userdata 存活为 true；否则记录诊断并返回 false。
    template <typename T> bool readUserdataAt(int index, const std::string &name, T *&output)
    {
        void *object = checkUserdata(index, name); // 由 Lua userdata 持有、当前回调只借用的 T 存储地址。
        if (!object)
            return false;
        output = static_cast<T *>(object);
        return true;
    }
    // 处理 protectedCall 的结果：成功返回 true；Lua 错误或 failure 文本转成本次 Binding 诊断。
    /// @param succeeded protectedCall 是否得到 LUA_OK。
    /// @param failure 回调报告的常量输入错误；为 nullptr 时只处理 Lua 错误对象。
    /// @return 无错误为 true；否则记录诊断并返回 false。
    bool completeCall(bool succeeded, const char *failure = nullptr);
    // 确认 index 是当前参数栈中的正槽或真实负槽；伪索引和栈外位置记录 INVALID_ARGUMENT。
    /// @param index 要读取的 Lua 栈编号。
    /// @return 编号指向当前实际栈值为 true；否则记录 INVALID_ARGUMENT。
    bool validIndex(int index);
    // 确认 index 指向现有业务 upvalue，并限制在 Lua 5.4 允许的 upvalue 数范围内。
    /// @param index 从 1 开始的业务 upvalue 编号。
    /// @return 闭包持有该 upvalue 为 true；否则记录 INVALID_ARGUMENT。
    bool validUpvalue(int index);
    // 将已确认的 table 槽复制到 registry，成功后输出借用本 Binding 的独立 LuaTable 句柄。
    /// @param index 已确认的 table 栈槽。
    /// @param output 成功接管新 registry 引用；失败保持原句柄。
    /// @return 引用建立成功为 true；类型或 Lua 操作失败为 false。
    bool readTableAt(int index, LuaTable &output);
    // 按 Lua 真值读取已确认的槽位；结果写入 output，不改变栈。
    /// @param index 已确认的 Lua 值栈槽。
    /// @param output 接收 Lua truthiness；nil/false 为 false，其余值为 true。
    /// @return 总是 true；此读取不产生类型错误。
    bool readTruthAt(int index, bool &output);
    // 将 object 与 registry 引用加入当前回调的保活记录；重复对象释放多余引用，保存失败也释放引用。
    /// @param object 本次由 Lua userdata 持有的 Native 对象地址。
    /// @param reference 为该 userdata 新建的 registry 强引用编号。
    /// @return 记录成功或重复对象已由旧引用保活为 true；保存失败为 false。
    bool retainUserdata(void *object, int reference);
    // 托管析构闭包的元表字段保护；以精确元表身份拒绝替换 __gc，临时栈值在返回前清除。
    /// @param state 当前受保护的 Lua State。
    /// @param table_index 要写入字段的目标 table 栈槽。
    /// @param key_index 本次写入的 key 栈槽。
    /// @return 目标不是托管元表的 __gc 字段为 true；需要保护的写入为 false。
    static bool canWriteField(lua_State *state, int table_index, int key_index) noexcept;
    // 在 protectedCall 内按已注册元表名分配 Lua userdata，并返回其存储地址和 registry 强引用。
    /// @param name 当前 Lua State 中注册的精确元表名。
    /// @param bytes 要分配的 userdata 存储字节数。
    /// @param storage 成功接收 Lua-owned 存储地址；失败保持原值。
    /// @param reference 成功接收 registry 强引用编号；失败保持原值。
    /// @return 分配、挂接元表和引用建立成功为 true；失败记录诊断并返回 false。
    bool allocateUserdata(const std::string &name, std::size_t bytes, void *&storage,
                          int &reference);
    // 检查指定参数的 userdata 类型与 alive 标记，并由当前 Binding 持有它直到回调结束。
    /// @param index 已确认的参数槽或 upvalue 伪索引。
    /// @param name 当前 Lua State 中注册的精确元表名。
    /// @return 成功返回本回调借用的对象地址；失败返回 nullptr 并记录诊断。
    void *checkUserdata(int index, const std::string &name);
    // protectedCall 内验证 userdata 类型、元表和 alive 标记；成功输出指针并创建 registry 引用。
    /// @param state protectedCall 提供的 Lua State。
    /// @param index 待验证的 full userdata 栈索引。
    /// @param name 当前 Lua State 中注册的精确元表名。
    /// @param reference 成功时接收新建的 registry 强引用编号。
    /// @param failure 失败时接收静态诊断文本。
    /// @return userdata 对象地址；类型、元表或存活标记不符时返回 nullptr。
    static void *inspectUserdata(lua_State *state, int index, const char *name, int &reference,
                                 const char **failure);
    // 为当前 Lua State 注册具名元表、受控 __gc 闭包和 methods 索引表；返回时恢复入口栈高度。
    /// @param state 正在加载模块的 Lua State。
    /// @param name 本 State 唯一的元表注册名。
    /// @param collector 收到托管 userdata 后负责验证并析构对象的 GC 回调。
    /// @param methods 以空项结尾的 Lua 方法表；不得自行提供 __gc。
    /// @return 无；注册失败通过 Lua 模块加载错误退出。
    static void registerType(lua_State *state, const char *name, lua_CFunction collector,
                             const luaL_Reg *methods);

    lua_State                     *state_;              // 借用当前 VM，不负责关闭。
    std::string                    error_code_;         // 最近错误码；成功不清除，pushError 读取。
    std::string                    error_message_;      // 与错误码配对的诊断。
    std::vector<UserdataReference> userdata_refs_;      // 回调内保活对象及其 registry 引用。
};
} // namespace flywow_lua_binding
