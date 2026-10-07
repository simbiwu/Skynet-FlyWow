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
using Callback = int (*)(LuaBinding &);

namespace detail
{
// 内部临时栈保护：只用于不会准备最终返回值的读写操作。
// gettop 保存入口栈项数量；settop 移除之后追加的临时值，恢复入口高度。
// 正常返回、提前失败和 C++ 异常都会执行析构；registry 引用不受弹栈影响。
// 最终返回值要留在栈上交给 Lua，所以 returnValues/pushError 不使用此保护器。
// lua_gettop 取得当前栈项数量；lua_settop 恢复此高度，移除本次操作压入的临时值。
// 正常返回、提前失败和 C++ 异常展开都会析构保护器；只恢复栈，不释放 registry 引用。
// 最终返回值必须留在栈顶交给 Lua，故 returnValues/pushError 不能使用此保护器。
class StackRestore
{
  public:
    // lua_gettop：取得当前栈项数量（同时是栈顶正索引，空栈为 0）；只读取高度，不压入或移除值。
    explicit StackRestore(lua_State *state) : state_(state), top_(lua_gettop(state))
    {
    }
    ~StackRestore()
    {
        // lua_settop：将栈恢复到指定高度：多出的槽被移除，增加高度则补 nil；此处按保存的基线清理临时值，不释放 registry 引用。
        lua_settop(state_, top_);
    }
    StackRestore(const StackRestore &)            = delete;
    StackRestore &operator=(const StackRestore &) = delete;

  private:
    lua_State *state_;
    int        top_; // 操作入口高度；成功、失败和 C++ 异常均恢复。
};

// 这不是业务数据容器，只用 alignof(LuaAlignment) 取得 Lua userdata 保证的对齐。
// 成员与宿主 Lua 5.4 的 LUAI_MAXALIGN 一致：union 的对齐取所有成员中的最大值。
// 对象存储区按此对齐；newUserdata/registerUserdata 拒绝要求更高对齐的 T，
// 避免在不满足地址要求的 Lua 内存里 placement-new（例如不能擅自假定支持 long double）。
union LuaAlignment
{
    lua_Number  number;
    double      real;
    void       *pointer;
    lua_Integer integer;
    long        native_long;
};

struct UserdataHeader
{
    const void *type = nullptr; // 精确 C++ 类型标记，生命周期为模块加载期。
    void (*destroy)(void *) =
        nullptr;               // 目标析构函数由模板约束为 noexcept；擦除后的函数指针保持稳定 ABI 类型。
    std::size_t size  = 0;     // T 的大小；同时校验 Lua 分配的字节数。
    bool        alive = false; // 构造成功后置 true；GC 先清除再析构。
    alignas(LuaAlignment) unsigned char storage[1];
};

inline std::size_t userdataBytes(std::size_t object_size)
{
    // 小型 T 也必须容纳完整头部（含尾部对齐）；否则 placement-new/GC 长度校验不一致。
    const std::size_t bytes = offsetof(UserdataHeader, storage) + object_size;
    return bytes < sizeof(UserdataHeader) ? sizeof(UserdataHeader) : bytes;
}

// 用每个 T 独有的静态地址作为类型身份证，不构造 T，也不保存业务数据。
// 注册时记录到 metatable/userdata 头部，读取时比较地址；即使两个类型 sizeof 相同，
// 也不能互相冒充。地址在模块加载期间有效，只用于身份比较，不能解引用为 T。
// 每个 T 独有的静态地址作为类型身份证，不构造 T，也不保存业务数据。
// 注册时写到 metatable/userdata 头部，读取时比较地址；同样大小的不同类型不能冒充。
// 地址在模块加载期间有效，仅用于身份比较，不能解引用为 T。
template <typename T> const void *typeTag()
{
    /*
        同一种 `T` 每次返回同一个地址，不同类型通常返回不同地址：
        if (typeTag<int>() == typeTag<int>()) {
            // true
        }
        if (typeTag<int>() != typeTag<float>()) {
            // true
        }
        用途：
        - 不使用 RTTI 判断类型
        - 实现类型擦除
        - 在容器中区分不同类型
        - 实现类似 `type_id` 的轻量类型标识
    */
    static const char tag = 0; // 每个 T 一份只读地址，无可变进程级 scratch。
    return &tag;
}

// 销毁 placement-new 构造在 Lua userdata 存储区中的 T。
// 只调用析构函数；userdata 原始内存由 Lua GC 回收。
template <typename T> void destroyObject(void *object) noexcept
{
    static_cast<T *>(object)->~T();
}

// ValueCodec 集中处理 Lua 值与 C++ 值的转换；read 不压栈、不弹栈，失败不改 output。
// C++17 的 if constexpr 将整数和浮点逻辑收敛到一个模板；bool、string 和 void* 仍使用专用特化。
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

/// 当前同步 Native 回调的操作对象；由入口适配器创建，不拥有 Lua State。
/// @note LuaTable/LuaValue/借用 userdata 指针只能在本回调内使用；禁止跨 yield/线程保存。
class LuaBinding
{
  public:
    LuaBinding(const LuaBinding &)            = delete;
    LuaBinding &operator=(const LuaBinding &) = delete;

    /// 标准 luaopen_* 的唯一适配入口；ABI 检查在创建 C++ 业务对象之前执行。
    /// @return callback 准备的 Lua 结果数量；普通失败为 nil,{code,message}。
    /// @param state 宿主 Lua State；由调用方保证在当前 C 回调期间有效。
    /// @param callback 同步业务回调；不拥有 state，不异步、不跨 yield 保存引用。
    static int initialize(lua_State *state, Callback callback);

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

    /// 从 1 编号的业务 upvalue 读取；内部回调描述占据的 upvalue 不可见。
    /// @param index 从 1 开始编号的业务 upvalue 索引；不包含内部回调描述。
    /// @param output 输出对象；失败时保留原值。
    template <typename T> bool readUpvalue(int index, T &output)
    {
        const int actual = upvalueIndex(index);
        return actual != 0 && readAt(actual, output);
    }
    /// 读取业务 upvalue 的 Table 引用；失败不改 output。
    /// @param index 从 1 开始编号的业务 upvalue 索引。
    /// @param output 输出对象；成功时写入借用 table 句柄，失败时保留原句柄。
    bool readUpvalueTable(int index, LuaTable &output);
    /// 替换业务 upvalue，类型支持与写表一致；Table/userdata 继续由 closure 强引用。
    /// @param index 从 1 开始编号的业务 upvalue 索引。
    /// @param value 待写入的 C++ 值；Table/userdata 由 closure 持有引用。
    template <typename T> bool writeUpvalue(int index, const T &value)
    {
        const int actual = upvalueIndex(index);
        if (actual == 0)
        {
            return false;
        }
        detail::StackRestore stack(state_);
        if (!pushValue(value))
        {
            return false;
        }
        // [S, value] -> [S]：replace 消耗 value，替换闭包对应槽，不影响其它 upvalue。
        // lua_replace：消耗栈顶值并替换指定槽/upvalue；其它槽不变，本封装已将业务编号映射到真实 upvalue 伪索引。
        lua_replace(state_, actual);
        return true;
    }

    /// 先恢复回调入栈基线，再按参数顺序准备结果；随后必须立即 return。
    /// @note Table 由 registry 另压引用，局部句柄析构不会弹掉结果。
    /// @param values 按调用顺序压入 Lua 栈的返回值；支持已有 ValueCodec 类型。
    template <typename... Values> int returnValues(const Values &...values)
    {
        // 丢弃回调过程中残留的临时栈项，保留原参数：[参数, 临时项...] -> [参数]。
        // 随后按参数顺序压结果，Lua 在 C 回调 return count 后取走栈顶 count 个值。
        // lua_settop：将栈恢复到指定高度：多出的槽被移除，增加高度则补 nil；此处按保存的基线清理临时值，不释放 registry 引用。
        lua_settop(state_, entry_top_);
        if (sizeof...(Values) > static_cast<std::size_t>(std::numeric_limits<int>::max()) ||
            !reserveStack(static_cast<int>(sizeof...(Values))))
        {
            return pushError();
        }
        if (!pushValues(values...))
        {
            return pushError();
        }
        result_count_  = sizeof...(Values);
        results_ready_ = true;
        return result_count_;
    }

    /// 返回 nil,{code,message}；无参版本使用最近一次失败。
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

    /// 注册具名 metatable；首次创建通过 created 返回 true，已有表不自动覆盖。
    /// @param name 注册用的 metatable 名称；同一名称不自动覆盖已有表。
    /// @param output 输出对象；成功时写入 metatable 的借用句柄。
    /// @param created 输出标记；写入本次是否新建了 metatable。
    bool registerMetatable(const std::string &name, LuaTable &output, bool &created);

    /// 注册精确 T 类型和统一 __gc；同名不同 T 正常失败。
    /// @note T 必须 noexcept 析构，且对齐不超过 Lua userdata 的保证。
    /// @param name 与 T 精确类型关联的 metatable 名称。
    /// @param output 输出对象；成功时写入 metatable 句柄。
    /// @param created 输出标记；写入是否新建。
    template <typename T>
    bool registerUserdata(const std::string &name, LuaTable &output, bool &created)
    {
        static_assert(std::is_nothrow_destructible<T>::value,
                      "userdata destructor must be noexcept");
        static_assert(alignof(T) <= alignof(detail::LuaAlignment),
                      "over-aligned userdata unsupported");
        return registerType(name, detail::typeTag<T>(), sizeof(T), output, created);
    }

    /// 创建受 Lua GC 管理的 T；output 是本回调内的借用地址，失败保持 output。
    /// @note 可以直接 returnValues(output)，无需手动挂 metatable 或维护栈。
    /// @param name 已注册且对应 T 的 metatable 名称。
    /// @param output 输出指针引用；返回本回调中借用的 T 地址。
    /// @param args 转发给 T 构造函数的参数；构造失败时不产生活对象。
    template <typename T, typename... Args>
    bool newUserdata(const std::string &name, T *&output, Args &&...args)
    {
        static_assert(std::is_nothrow_destructible<T>::value,
                      "userdata destructor must be noexcept");
        static_assert(alignof(T) <= alignof(detail::LuaAlignment),
                      "over-aligned userdata unsupported");
        detail::UserdataHeader *header = nullptr;
        if (!allocateUserdata(name, detail::typeTag<T>(), sizeof(T), &detail::destroyObject<T>,
                              header))
        {
            return false;
        }
        // 未构造状态和 __gc 已建立；构造抛异常时 GC 只回收 Lua 内存，不调用 ~T。
        auto *object  = new (header->storage) T(std::forward<Args>(args)...);
        header->alive = true;
        output        = object;
        return true;
    }

    /// 核验 full userdata 的 metatable、T、大小和存活状态；返回借用指针。
    /// @param index Lua 栈中的 userdata 参数索引。
    /// @param name 期望的 metatable 名称。
    /// @param output 输出指针引用；写入不拥有的 T 借用指针。
    template <typename T> bool readUserdata(int index, const std::string &name, T *&output)
    {
        return validIndex(index) && readUserdataAt(index, name, output);
    }
    /// 与 readUserdata 相同的精确类型检查；index 是从 1 编号的业务 upvalue。
    /// @param index 从 1 开始编号的业务 upvalue 索引。
    /// @param name 期望的 metatable 名称。
    /// @param output 输出指针引用；写入不拥有的 T 借用指针。
    template <typename T> bool readUpvalueUserdata(int index, const std::string &name, T *&output)
    {
        const int actual = upvalueIndex(index);
        return actual != 0 && readUserdataAt(actual, name, output);
    }

  private:
    friend class LuaTable;
    friend class LuaValue;

    struct UserdataReference
    {
        void       *object; // 对齐后的 T 地址，用于返回/写表时找回原 userdata。
        const void *type;
        int         reference; // 本回调持有；析构时 unref，Lua 返回值可继续持有对象。
    };

    explicit LuaBinding(lua_State *state);
    ~LuaBinding();
    static int dispatch(lua_State *state);
    static int invoke(lua_State *state, Callback callback);
    int runCallback(Callback callback);
    static int collectUserdata(lua_State *state) noexcept;
    bool reserveStack(int slots);
    bool validIndex(int index);
    int upvalueIndex(int index);
    bool readTableAt(int index, LuaTable &output);
    bool readTruthAt(int index, bool &output);
    bool holdUserdata(int index, detail::UserdataHeader *header);
    bool registerType(const std::string &name, const void *type, std::size_t size, LuaTable &output,
                      bool &created);
    bool allocateUserdata(const std::string &name, const void *type, std::size_t size,
                          void (*destroy)(void *), detail::UserdataHeader *&output);
    void *checkUserdata(int index, const std::string &name, const void *type, std::size_t size);
    bool pushObject(const void *object, const void *type);
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
        void *object = checkUserdata(index, name, detail::typeTag<T>(), sizeof(T));
        if (object == nullptr)
        {
            return false;
        }
        output = static_cast<T *>(object);
        return true;
    }

    template <typename T> bool pushValue(T *value)
    {
        return pushObject(value, detail::typeTag<T>());
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
        bool success    = true;
        // initializer_list 按顺序执行；失败后短路，调用方负责清理已压入的半成品。
        using Expansion = int[];
        (void)Expansion{0, (success = success && pushValue(values), 0)...};
        return success;
    }

    lua_State                     *state_;     // 借用宿主 State。
    int                            entry_top_; // 当前回调初始参数栈高度。
    int                            result_count_  = 0;
    bool                           results_ready_ = false;
    std::string                    error_code_;
    std::string                    error_message_;
    std::uint64_t                  error_revision_ = 0; // visitor 判断本轮是否产生新错误。
    std::vector<UserdataReference> userdata_refs_;
};
} // namespace flywow_lua_binding
