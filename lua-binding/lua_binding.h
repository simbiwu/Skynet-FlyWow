// 职责：提供同步 Lua Binding 的参数读取、结果、错误、闭包和 userdata 操作。
// 边界：只依赖 C++17 和宿主 Lua；不拥有 State，不 yield，不跨调用保存句柄。
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
// 局部 Lua 栈操作的作用域保护：记录进入高度，离开时恢复，清理由本操作压入的临时值。
// 用于操作结束后 C++ 还要继续执行的路径；最终返回值由 Lua 按返回数量取走，不用此保护器。
class StackRestore
{
  public:
    // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
    explicit StackRestore(lua_State *state) : state_(state), top_(lua_gettop(state))
    {
    }
    ~StackRestore()
    {
        // lua_settop：恢复局部操作开始时的栈高，移除本次操作留下的临时槽；registry 引用不受影响。
        lua_settop(state_, top_);
    }
    StackRestore(const StackRestore &)            = delete;
    StackRestore &operator=(const StackRestore &) = delete;

  private:
    lua_State *state_;
    int        top_; // 操作入口高度；成功、失败和 C++ 异常均恢复。
};

// ValueCodec 集中处理 Lua 值与 C++ 值的转换；read 不压栈、不弹栈，失败不改 output。
// C++17 的 if constexpr 按编译期条件选择分支，未选中的分支不会为当前 T 实例化。
// *_v 是类型特征 ::value 的 C++17 简写；这里按 T 的类别共用数值转换逻辑。
template <typename T> struct ValueCodec
{
    static bool read(lua_State *state, int index, T &output, std::string *reason)
    {
        if constexpr (std::is_integral_v<T> && !std::is_same_v<T, bool>)
        {
            if (!lua_isinteger(state, index))
            {
                *reason = "value must be an integer";
                return false;
            }
            const lua_Integer value = lua_tointeger(state, index);
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
            if (lua_type(state, index) != LUA_TNUMBER)
            {
                *reason = "value must be a number";
                return false;
            }
            const lua_Number value = lua_tonumber(state, index);
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

    static bool push(lua_State *state, T value, std::string *reason)
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
    static bool read(lua_State *state, int index, bool &output, std::string *reason);
    static bool push(lua_State *state, bool value, std::string *reason);
};
template <> struct ValueCodec<std::string>
{
    static bool read(lua_State *state, int index, std::string &output, std::string *reason);
    static bool push(lua_State *state, const std::string &value, std::string *reason);
};
template <> struct ValueCodec<void *>
{
    static bool read(lua_State *state, int index, void *&output, std::string *reason);
};
} // namespace detail

/// 当前同步 Lua C 回调的操作对象；由回调按需创建，不拥有 Lua State。
/// @note LuaTable/LuaValue/借用 userdata 指针只能在本回调内使用；禁止跨 yield/线程保存。
class LuaBinding
{
  public:
    explicit LuaBinding(lua_State *state);
    ~LuaBinding();
    LuaBinding(const LuaBinding &)            = delete;
    LuaBinding &operator=(const LuaBinding &) = delete;

    /// 严格读取位置参数；支持有效正/负 index，失败不改变输出值。
    /// @param index Lua 栈中的参数索引；支持有效的正索引和负索引。
    /// @param output 输出对象；类型由 T 推导，失败时保留原值。
    /// @return 成功为 true；失败写入最近错误，调用方明确 pushError()。
    template <typename T> bool readValue(int index, T &output)
    {
        if (!validIndex(index))
        {
            return false;
        }
        return readAt(index, output);
    }

    /// 读取可省略的位置参数；缺省或 nil 保留调用者设置的默认值。
    /// @param index 参数栈下标；@param output 默认值与成功读取的输出。
    /// @return 已省略或类型检查成功为 true；类型错误记录最近错误。
    template <typename T> bool readOptionalValue(int index, T &output)
    {
        return lua_isnoneornil(state_, index) || readValue(index, output);
    }

    /// 读取 table 引用，不占据长期栈槽；失败保留 output 原句柄。
    /// @param index Lua 栈中待读 table 的参数索引。
    /// @param output 输出对象；成功时写入借用 table 句柄，失败时保留原句柄。
    bool readTable(int index, LuaTable &output);
    /// 读取调用瞬间真实栈顶；仍检查类型，不维护隐含的“选定 table”。
    /// @param output 输出 table；从调用瞬间的真实栈顶读取，失败时保留原句柄。
    bool readTable(LuaTable &output);
    /// 创建空表并持有 registry 引用；失效句柄表示失败。
    /// @return 成功时返回带 registry 引用的表句柄；失败时返回失效句柄。
    LuaTable newTable();

    /// 按 Lua 原生编号读取第 index 个 upvalue。
    /// @param index 从 1 开始编号的 Lua upvalue 索引。
    /// @param output 输出对象；失败时保留原值。
    template <typename T> bool readUpvalue(int index, T &output)
    {
        return readAt(lua_upvalueindex(index), output);
    }
    /// 读取业务 upvalue 的 Table 引用；失败不改 output。
    /// @param index 从 1 开始编号的 Lua upvalue 索引。
    /// @param output 输出对象；成功时写入借用 table 句柄，失败时保留原句柄。
    bool readUpvalueTable(int index, LuaTable &output);
    /// 替换业务 upvalue，类型支持与写表一致；Table/userdata 继续由 closure 强引用。
    /// @param index 从 1 开始编号的 Lua upvalue 索引。
    /// @param value 待写入的 C++ 值；Table/userdata 由 closure 持有引用。
    template <typename T> bool writeUpvalue(int index, const T &value)
    {
        const int actual = lua_upvalueindex(index);
        detail::StackRestore stack(state_);
        if (!pushValue(value))
        {
            return false;
        }
        // [S, value] -> [S]：replace 消耗 value，替换闭包对应槽，不影响其它 upvalue。
        // lua_replace：消耗栈顶值并替换指定槽/upvalue；其它槽不变，index 使用 Lua 原生 upvalue 编号。
        lua_replace(state_, actual);
        return true;
    }

    /// 按参数顺序将结果压到当前栈顶；随后必须立即 return 返回数量。
    /// @note Lua 取栈顶指定数量作为结果，并在回调返回时清理其下的临时值；Table 由 registry 引用持有。
    /// @param values 按调用顺序压入 Lua 栈的返回值；支持已有 ValueCodec 类型。
    /// Values... 是返回值类型包，values... 是对应实参包，展开后按传入顺序逐项压栈。
    template <typename... Values> int returnValues(const Values &...values)
    {
        if (!pushValues(values...))
        {
            // 失败时可能已有部分结果留在栈上；pushError 追加 nil/error，Lua 仍取栈顶两个结果。
            return pushError();
        }
        // sizeof...(Values) 在编译期计算返回值个数，与刚压入的 Lua 结果数对应。
        // C 回调返回后，Lua 取栈顶 N 个结果，并清理这些结果下方的临时栈值。
        return static_cast<int>(sizeof...(Values));
    }

    /// 返回 nil,{code,message}；无参版本使用最近一次失败。
    /// @note 调用后应立即从 Lua C 回调返回；栈中更低的临时值由 Lua 一并清理。
    /// @return 返回 Lua 结果数量，固定为 2：nil 和错误表。
    int pushError();
    /// @param code 稳定错误码；用于业务判断，不应依赖 message 文本。
    /// @param message 面向调试的错误诊断文本。
    /// @return 返回 Lua 结果数量，固定为 2：nil 和错误表。
    int pushError(const std::string &code, const std::string &message);
    /// 业务 parser/visitor 只记录错误；不压结果、不自动中断业务。
    /// @param code 稳定错误码；用于业务判断。
    /// @param message 供调试和记录使用的诊断文本。
    void setError(const std::string &code, const std::string &message);
    /// 最近一次失败的稳定 code/诊断 message；成功操作不会自动清除。
    /// @return 最近一次失败的稳定错误码；没有错误时为空字符串。
    const std::string &errorCode() const;
    /// 最近一次失败的诊断文字；调用方应按 errorCode() 处理，不解析此文字。
    /// @return 最近一次失败的诊断文本；调用方不应解析其内容。
    const std::string &errorMessage() const;

    /// 注册 T 的具名 metatable，并设置直接调用 T 析构函数的 __gc。
    /// @note name 在当前 Lua State 中只能注册一次；重复注册返回 INVALID_ARGUMENT，且不修改原 metatable。
    /// @note T 必须 noexcept 析构，且对齐不超过 Lua userdata 的保证。
    /// @param name 由模块约定与 T 对应的 metatable 名称。
    /// @param output 输出对象；成功时写入 metatable 句柄。
    template <typename T> bool registerUserdata(const std::string &name, LuaTable &output)
    {
        static_assert(std::is_nothrow_destructible<T>::value,
                      "userdata destructor must be noexcept");
        return registerUserdataType(name, &LuaBinding::collectUserdata<T>, output);
    }

    /// 创建受 Lua GC 管理的 T；output 是本回调内的借用地址，失败保持 output。
    /// @note 可以直接 returnValues(output)，无需手动挂 metatable 或维护栈。
    /// @param name 已注册且对应 T 的 metatable 名称。
    /// @param output 输出指针引用；返回本回调中借用的 T 地址。
    /// @param args 转发给 T 构造函数的参数；构造失败时不产生活对象。
    /// Args&&... 是转发引用参数包；std::forward<Args>(args)... 逐项保留实参的左值/右值属性。
    template <typename T, typename... Args>
    bool newUserdata(const std::string &name, T *&output, Args &&...args)
    {
        detail::StackRestore stack(state_);
        luaL_getmetatable(state_, name.c_str());
        if (!lua_istable(state_, -1))
        {
            setError("INVALID_ARGUMENT", "userdata type must be registered before construction");
            return false;
        }

        // userdata 内存直接作为 T 的存储；先构造，成功后才挂 __gc，失败时不会析构未构造对象。
        void *storage = lua_newuserdatauv(state_, sizeof(T), 1);
        T *object = nullptr;
        try
        {
            object = new (storage) T(std::forward<Args>(args)...);
        }
        catch (...)
        {
            setError("INTERNAL_ERROR", "userdata construction failed");
            return false;
        }
        // 用 userdata 自己的 uservalue 记录对象仍存活；__gc 重复运行时据此跳过析构。
        lua_pushboolean(state_, 1);
        lua_setiuservalue(state_, -2, 1);
        // [S, metatable, userdata] -> [S, metatable, userdata, metatable] -> [S, metatable, userdata]。
        // userdata 绑定类型专属 metatable 后，Lua GC 才会用对应的 T 析构函数回收它。
        lua_pushvalue(state_, -2);
        lua_setmetatable(state_, -2);
        if (!holdUserdata(-1, object))
        {
            return false;
        }
        output = object;
        return true;
    }

    /// 按具名 metatable 读取 userdata；返回本回调内借用指针。
    /// @param index Lua 栈中的 userdata 参数索引。
    /// @param name 注册 userdata 时使用的 metatable 名称。
    /// @param output 输出指针引用；写入不拥有的 T 借用指针。
    template <typename T> bool readUserdata(int index, const std::string &name, T *&output)
    {
        return validIndex(index) && readUserdataAt(index, name, output);
    }
    /// 按 upvalue 中的具名 metatable 读取 userdata。
    /// @param index 从 1 开始编号的 Lua upvalue 索引。
    /// @param name 注册 userdata 时使用的 metatable 名称。
    /// @param output 输出指针引用；写入不拥有的 T 借用指针。
    template <typename T> bool readUpvalueUserdata(int index, const std::string &name, T *&output)
    {
        return readUserdataAt(lua_upvalueindex(index), name, output);
    }

  private:
    friend class LuaTable;
    friend class LuaValue;

    struct UserdataReference
    {
        void       *object; // 对齐后的 T 地址，用于返回/写表时找回原 userdata。
        int         reference; // 本回调持有；析构时 unref，Lua 返回值可继续持有对象。
    };

    // Lua 自动 GC 或手动 finalize 均只析构一次；状态保存在 userdata 自己的 uservalue。
    template <typename T> static int collectUserdata(lua_State *state) noexcept
    {
        const int state_type = lua_getiuservalue(state, 1, 1);
        if (state_type != LUA_TBOOLEAN || lua_toboolean(state, -1) == 0)
        {
            lua_pop(state, 1);
            return 0;
        }
        lua_pop(state, 1);
        lua_pushboolean(state, 0);
        lua_setiuservalue(state, 1, 1);
        static_cast<T *>(lua_touserdata(state, 1))->~T();
        return 0;
    }
    bool validIndex(int index);
    bool readTableAt(int index, LuaTable &output);
    bool readTruthAt(int index, bool &output);
    bool holdUserdata(int index, void *object);
    bool registerUserdataType(const std::string &name, lua_CFunction collector, LuaTable &output);
    void *checkUserdata(int index, const std::string &name);
    bool pushObject(const void *object);
    bool pushValue(const LuaTable &value);
    bool pushValue(const char *value);
    bool pushValue(std::nullptr_t);
    bool pushValue(void *value);

    template <typename T> bool readAt(int index, T &output)
    {
        std::string reason;
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
        if (object == nullptr)
        {
            return false;
        }
        output = static_cast<T *>(object);
        return true;
    }

    template <typename T> bool pushValue(T *value)
    {
        return pushObject(value);
    }
    template <typename T> bool pushValue(const T &value)
    {
        std::string reason;
        if (!detail::ValueCodec<T>::push(state_, value, &reason))
        {
            setError("INVALID_ARGUMENT", reason);
            return false;
        }
        return true;
    }
    template <std::size_t N> bool pushValue(const char (&value)[N])
    {
        return pushValue(static_cast<const char *>(value));
    }

    template <typename... Values> bool pushValues(const Values &...values)
    {
        // C++17 一元右折叠按参数顺序展开为 pushValue(v1) && (pushValue(v2) && ...)。
        // 内建 && 从左向右短路；空参数包的折叠结果为 true。
        return (pushValue(values) && ...);
    }

    lua_State                     *state_;     // 借用宿主 State。
    std::string                    error_code_;
    std::string                    error_message_;
    std::uint64_t                  error_revision_ = 0; // visitor 判断本轮是否产生新错误。
    std::vector<UserdataReference> userdata_refs_;
};
} // namespace flywow_lua_binding
