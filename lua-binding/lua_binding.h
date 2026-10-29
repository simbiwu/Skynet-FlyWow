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
inline constexpr int kMaxUpvalues = 255; // 固定 Lua 5.4 C closure 上限，注册与索引校验共同使用。

// Lua 分配失败先由受保护调用接住，再用不分配内存的 C++ 标记展开本地 RAII。
class LuaFailure
{
};

// 与宿主 Lua userdata 存储采用同一对齐基线，不擅自假设支持 over-aligned 类型。
union UserdataAlignment
{
    LUAI_MAXALIGN;
};

// 为直接压栈和保护调用预留槽位；lua_checkstack 自己保护分配失败，失败后正常展开 C++。
void ensureStack(lua_State *state, int extra);

// 保护器只调用无 C++ 资源的 Lua 操作；operation 本身保留在外层 C++ 栈，longjmp 不跨越它。
// 内层参数 1 是借用 operation 地址，实际 Lua 输入从 2 开始；操作不得访问外层 upvalue 伪索引。
template <typename Operation> int executeOperation(lua_State *state)
{
    auto *operation = static_cast<Operation *>(lua_touserdata(state, 1));
    return (*operation)(state);
}

// 消耗栈顶 inputs 项并留下 outputs 项：[S, inputs...] -> [S, outputs...]。
// 只有此处跨越 Lua longjmp；传入操作必须 noexcept 且不得在内部持有需要析构的 C++ 局部对象。
template <typename Operation>
void runProtected(lua_State *state, Operation operation, int inputs, int outputs)
{
    static_assert(std::is_trivially_destructible_v<Operation>);
    static_assert(std::is_nothrow_invocable_r_v<int, Operation, lua_State *>);
    ensureStack(state, LUA_MINSTACK + 2);
    const int first = lua_gettop(state) - inputs + 1; // 输入组起点；其下方 S 保持不动。
    lua_pushcfunction(state, &executeOperation<Operation>);
    lua_insert(state, first);
    lua_pushlightuserdata(state, &operation);
    lua_insert(state, first + 1);
    if (lua_pcall(state, inputs + 1, outputs, 0) != LUA_OK)
    {
        // pcall 已消耗函数和输入，只留下错误对象；移除它后再展开外层 C++ 资源。
        lua_pop(state, 1);
        throw LuaFailure{};
    }
}

void pushString(lua_State *state, const char *bytes, std::size_t length);
void createTable(lua_State *state, int array_slots = 0, int fields = 0);
void *createUserdata(lua_State *state, std::size_t bytes);
int referenceValue(lua_State *state);
void pushNamedMetatable(lua_State *state, const std::string &name);
bool newMetatable(lua_State *state, const std::string &name);
void pushClosure(lua_State *state, lua_CFunction callback, int upvalues);
void rawSet(lua_State *state);
void setField(lua_State *state, int table_index, const char *key);
void setMetatable(lua_State *state);
bool nextEntry(lua_State *state, int table_index);
void *testUserdata(lua_State *state, int index, const std::string &name);
int callbackFailure(lua_State *state, bool module, const char *code, const char *message);

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
        // lua_settop 恢复入口高度，移除本次新压入的临时槽，registry 引用不受影响。
        // 本保护器要求操作不弹掉入口的既有值；settop 只能补 nil，无法恢复已弹出的原值。
        lua_settop(state_, top_);
    }
    StackRestore(const StackRestore &)            = delete;
    StackRestore &operator=(const StackRestore &) = delete;

  private:
    lua_State *state_; // 借用当前操作的 State，不拥有 VM，也不允许跨线程使用。
    int        top_;   // 操作入口高度；普通返回和 C++ 展开时恢复，不负责直接 C API 的 longjmp。
};

// ValueCodec 集中处理 Lua 值与 C++ 值的转换；read 不压栈、不弹栈，失败不改 output。
// C++17 的 if constexpr 按编译期条件选择分支，未选中的分支不会为当前 T 实例化。
// *_v 是类型特征 ::value 的 C++17 简写；这里按 T 的类别共用数值转换逻辑。
// read 只检查已有栈槽，成功/失败均不改变栈高；output 仅在校验成功后更新。
// push 先完成数值范围检查：失败时净栈变化为 0，成功时恰好压入 1 个值。
template <typename T> struct ValueCodec
{
    /// 将已有 Lua 数值槽严格转换成 T；失败不改变 output，也不压栈。
    /// @param state 当前操作借用的 Lua State。
    /// @param index 调用方已验证的参数、字段或 upvalue 槽。
    /// @param output 转换成功后接收 C++ 数值。
    /// @param reason 非空诊断输出，类型或范围错误时供 Binding 记录。
    /// @return 严格类型及目标范围正确为 true，否则为 false。
    static bool read(lua_State *state, int index, T &output, std::string *reason)
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
    static bool push(lua_State *state, T value, std::string *reason)
    {
        ensureStack(state, 1);
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
/// @note 封装内 Lua 分配错误转换为 C++ 展开；回调须通过 invoke/invokeModule 捕获。直接 C API 仍由调用方负责。
class LuaBinding
{
  public:
    explicit LuaBinding(lua_State *state);
    ~LuaBinding();
    LuaBinding(const LuaBinding &)            = delete;
    LuaBinding &operator=(const LuaBinding &) = delete;

    /// Native 回调入口捕获完整业务调用的 C++ 异常；参数错误仍由业务返回原有 nil/error。
    /// @param state Lua 提供的当前回调栈。
    /// @param callback 只捕获借用参数的同步操作；资源必须在操作内部声明，异常后先析构再返回错误。
    /// @return 业务原返回数量；意外异常返回 nil,{code,message}；持续 Lua OOM 作为 Lua 错误传播。
    template <typename Function> static int invoke(lua_State *state, Function callback)
    {
        return invokeBoundary(state, callback, false);
    }

    /// require 的 Native 入口；成功保持模块返回值，失败在 C++ 资源清理完成后抛出 Lua 加载错误。
    /// @param state Lua 加载器提供的当前栈。
    /// @param callback 与 invoke 相同的同步操作，成功返回模块表。
    /// @return 成功返回模块结果数量；失败不正常返回，不让 require 把 nil 模块缓存成 true。
    template <typename Function> static int invokeModule(lua_State *state, Function callback)
    {
        return invokeBoundary(state, callback, true);
    }

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

    /// 读取可省略的位置参数；nil 或省略时保留 output 默认值。
    /// @param index 本次回调的位置参数编号，正编号可超过实参数量表示省略；负编号必须指向已有槽。
    /// @param output 调用者设置的默认值，提供参数时按该类型严格读取。
    /// @return 缺省或读取成功为 true；非法索引或类型错误为 false 并记录错误。
    template <typename T> bool readOptionalValue(int index, T &output)
    {
        // lua_isnoneornil 只检查参数槽，不压栈；省略/nil 时保留默认 output。
        // 有值时再走 readValue；两个分支都不改变回调参数栈。
        if (index > lua_gettop(state_))
        {
            return true;
        }
        return validIndex(index) && (lua_isnil(state_, index) || readAt(index, output));
    }

    /// 判断可选参数是否省略/nil；只读栈类型，栈高度不变，不触发元方法。
    bool isNoneOrNil(int index) const noexcept
    {
        const int top =
            lua_gettop(state_); // 缺省只对应超过实参数量的正编号，非法负编号不能交给 C API。
        if (index > top)
        {
            return true;
        }
        return index != 0 && index >= -top && lua_isnil(state_, index);
    }

    /// 从位置参数取得 table 的独立 registry 引用；净栈高度不变。
    /// @param index 当前回调的正或负参数索引。
    /// @param output 成功后拥有新引用并借用此 Binding；失败保留原句柄，须早于 Binding 析构。
    /// @return table 读取成功为 true；索引或类型错误为 false 并记录错误。
    bool readTable(int index, LuaTable &output);
    /// 从调用瞬间的真实栈顶读取 table，不维护额外的选表状态。
    /// @param output 成功后拥有 table 引用，失败保留原句柄；生命周期限当前 Binding。
    /// @return 栈顶为 table 时成功；空栈或类型错误返回 false 并记录错误。
    bool readTable(LuaTable &output);
    /// 创建空表并转为 registry 引用，不留下临时栈项。
    /// @return 拥有独立引用的有效句柄；Lua 分配失败抛 C++ 标记，由 invoke 清理资源并交付错误。
    /// @note 不存在普通的失效句柄失败分支；不得把 valid() 当作内存错误捕获机制。
    LuaTable newTable();

    /// 按原生编号读取当前 C 闭包捕获的值，不改变参数栈。
    /// @param index 从 1 开始且真实存在的业务 upvalue 编号，不能使用 registry 或位置参数索引。
    /// @param output 按 T 严格转换的输出对象，失败保持原值。
    /// @return 编号和类型正确为 true；否则为 false 并记录 INVALID_ARGUMENT。
    template <typename T> bool readUpvalue(int index, T &output)
    {
        // lua_upvalueindex 生成 C API 伪索引，不是参数栈槽，也不改变栈。
        // readAt 读取 closure 捕获值；它与回调参数 index=1 是两个独立索引空间。
        return validUpvalue(index) && readAt(lua_upvalueindex(index), output);
    }
    /// 为当前闭包中的 table 创建独立 registry 引用，业务 upvalue 编号没有内部偏移。
    /// @param index 从 1 开始且真实存在的闭包捕获值编号。
    /// @param output 成功时拥有新 table 引用；失败保留原句柄。
    /// @return 编号有效且捕获值为 table 时为 true，否则记录错误并返回 false。
    bool readUpvalueTable(int index, LuaTable &output);
    /// 更新当前闭包已有捕获槽；先验证编号，再压值，失败不会改写 registry 或其他槽。
    /// @param index 从 1 开始且真实存在的业务 upvalue 编号。
    /// @param value 替换值；table 和 userdata 由闭包继续强引用，借用 void* 的外部 owner 须长期有效。
    /// @return 替换完成为 true；编号或值非法为 false 并记录错误。
    template <typename T> bool writeUpvalue(int index, const T &value)
    {
        if (!validUpvalue(index))
        {
            return false;
        }
        const int            actual = lua_upvalueindex(index);
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

    /// 按传入顺序压入 Native 结果；调用方须立即 return 返回的数量。
    /// @param values 要交给 Lua 的零个或多个结果；table/userdata 保留同一对象身份。
    /// @return 全部成功时为结果个数；值转换失败时改为 2，栈顶为 nil 和错误表。
    /// @note 更低的部分结果由 Lua 在回调返回时丢弃；registry 句柄析构不移除已压入的结果。
    template <typename... Values> int returnValues(const Values &...values)
    {
        detail::ensureStack(state_, static_cast<int>(sizeof...(Values)) + 4);
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

    /// 模块初始化时注册 T 的具名元表及其析构闭包，重复注册保持原元表。
    /// @param name 当前 State 中仅对应 T 的非空类型名，由模块约定并用于后续创建和读取。
    /// @param output 成功后拥有元表的独立引用，失败保留原句柄。
    /// @return 首次注册完成为 true；名称为空或重复时记录 INVALID_ARGUMENT 并返回 false。
    /// @note T 必须 noexcept 析构且满足宿主对齐；GC 私有 upvalue 捕获元表，不改变业务闭包编号。
    template <typename T> bool registerUserdata(const std::string &name, LuaTable &output)
    {
        static_assert(alignof(T) <= alignof(detail::UserdataAlignment),
                      "userdata alignment exceeds host Lua guarantee");
        static_assert(std::is_nothrow_destructible<T>::value,
                      "userdata destructor must be noexcept");
        return registerUserdataType(name, &LuaBinding::collectUserdata<T>, output);
    }

    /// 创建 Lua GC 管理的 T；先为未构造存储安装禁用的 GC，构造成功后才标记存活。
    /// @param name 已注册且仅对应 T 的类型名，须与 registerUserdata 使用相同名称。
    /// @param output 成功时取得当前 Binding 内借用的 T 地址；失败保持原指针，不能 delete。
    /// @param args 转发给 T 构造函数的参数，保持实参的左值/右值属性。
    /// @return 创建和短期保活成功为 true；未注册或构造异常时记录错误并返回 false。
    /// @note Lua 分配失败经 C++ 展开交 invoke；已构造对象在后续失败时仍由 GC 回收，可能晚于函数返回。
    template <typename T, typename... Args>
    bool newUserdata(const std::string &name, T *&output, Args &&...args)
    {
        static_assert(alignof(T) <= alignof(detail::UserdataAlignment),
                      "userdata alignment exceeds host Lua guarantee");
        static_assert(std::is_nothrow_destructible_v<T>, "userdata destructor must be noexcept");
        // 入口为 [S]；作用域保护器在所有普通返回路径移除临时 metatable/userdata。
        detail::StackRestore stack(state_);

        // luaL_getmetatable 查找 registry 并压入元表：[S] -> [S, metatable]；
        // 未注册时压入 nil。此栈项只用于设置 userdata 类型，不转移 registry 的所有权。
        detail::pushNamedMetatable(state_, name);
        if (!lua_istable(state_, -1))
        {
            setError("INVALID_ARGUMENT", "userdata type must be registered before construction");
            return false;
        }

        // Lua-owned 存储先标为未构造，再挂注册元表；之后即使分配失败也不会遗失已构造对象。
        // [S,meta] -> [S,meta,userdata]；false 槽让 __gc 跳过尚未完成构造的 T。
        void *storage = detail::createUserdata(state_, sizeof(T));
        lua_pushboolean(state_, 0);
        lua_setiuservalue(state_, -2, 1);
        lua_pushvalue(state_, -2);
        // [S,meta,userdata,meta] -> [S,meta,userdata]；此时只有存储，没有活的 T。
        detail::setMetatable(state_);

        T *object = nullptr; // 构造成功才成为可借用对象；失败时 output 保持不变。
        try
        {
            object = new (storage) T(std::forward<Args>(args)...);
        }
        catch (...)
        {
            setError("INTERNAL_ERROR", "userdata construction failed");
            return false;
        }

        // 构造完成后只执行不分配的 alive 写入；从此 __gc 负责且只负责析构一次。
        lua_pushboolean(state_, 1);
        lua_setiuservalue(state_, -2, 1);
        // 后续保活引用失败时，外层恢复栈，已构造对象仍带 GC，稍后回收而不是立即析构。
        if (!holdUserdata(-1, object))
        {
            return false;
        }
        output = object;
        return true;
    }

    /// 读取精确具名类型且尚未析构的 userdata，并在本 Binding 内短期保活。
    /// @param index 当前回调中的 userdata 参数槽。
    /// @param name 由模块注册且与 T 对应的精确类型名。
    /// @param output 成功写入借用地址，失败保持原值；不能手工释放或跨 Binding 保存。
    /// @return 类型、生命周期及引用持有均正确为 true；否则记录错误并返回 false。
    template <typename T> bool readUserdata(int index, const std::string &name, T *&output)
    {
        return validIndex(index) && readUserdataAt(index, name, output);
    }
    /// 读取业务闭包中的存活 userdata，并取得本 Binding 内的短期引用。
    /// @param index 从 1 开始且真实存在的业务 upvalue 编号。
    /// @param name 与 T 对应的注册元表名。
    /// @param output 当前 Binding 内借用的 T 地址，失败保持原指针。
    /// @return 编号、类型及生命周期正确为 true，否则记录错误并返回 false。
    template <typename T> bool readUpvalueUserdata(int index, const std::string &name, T *&output)
    {
        return validUpvalue(index) && readUserdataAt(lua_upvalueindex(index), name, output);
    }

  private:
    // 两类入口共用异常捕获；callback 必须无析构责任，实际资源位于其执行体，先展开再交给 Lua。
    template <typename Function>
    static int invokeBoundary(lua_State *state, Function callback, bool module)
    {
        static_assert(std::is_trivially_destructible_v<Function>);
        const char *failure = nullptr; // 只保留静态文本，catch 结束后不携带异常对象进入 Lua 抛错。
        try
        {
            const int results =
                callback(); // 业务按 Lua C API 返回的结果数，lambda 已完成本地资源清理。
            if (!module || results == 0 || !lua_isnil(state, -results))
            {
                return results;
            }
            failure = "Native module initialization failed";
        }
        catch (const detail::LuaFailure &)
        {
            failure = "Lua allocation or protected operation failed";
        }
        catch (const std::bad_alloc &)
        {
            failure = "Native allocation failed";
        }
        catch (...)
        {
            failure = "Unexpected Native exception";
        }
        // 已退出业务 lambda 和 catch，C++ 资源与异常对象均已销毁；此后才允许最终 Lua 错误。
        return detail::callbackFailure(state, module, "INTERNAL_ERROR", failure);
    }

    friend class LuaTable;
    friend class LuaValue;

    struct UserdataReference
    {
        void *object;    ///< Lua-owned T 的借用地址，用于返回/写表时找回原 userdata。
        int   reference; ///< 本 Binding 持有的 registry 编号；析构时 unref，Lua 返回值仍可保活。
    };

    // Lua 自动 GC 或手动 finalize 均只析构一次；状态保存在 userdata 自己的 uservalue。
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
    bool validIndex(int index);
    bool validUpvalue(int index);
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

    // 已验证 index 所在索引空间，按输出类型读取并将 codec 的诊断写入本 Binding。
    template <typename T> bool readAt(int index, T &output)
    {
        std::string reason; // codec 失败时的诊断，离开本次转换即释放，不跨调用保存。
        if (!detail::ValueCodec<T>::read(state_, index, output, &reason))
        {
            setError("INVALID_ARGUMENT", reason);
            return false;
        }
        return true;
    }

    // 字段或 upvalue 已准备到 index，核对注册类型及存活后才更新 output 的借用地址。
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
        std::string reason; // codec 失败时的诊断，离开本次转换即释放，不跨调用保存。
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

    // 当前 Binding 独占这些短期状态；成功不抹掉最近错误，只有 setError 推进错误序号。
    lua_State                     *state_;              // 借用宿主 VM。
    std::string                    error_code_;         // 最近失败码，供返回或程序判断。
    std::string                    error_message_;      // 与错误码配对的诊断。
    std::uint64_t                  error_revision_ = 0; // visitor 用来识别新错误。
    std::vector<UserdataReference> userdata_refs_;      // 写表/返回时定位对象；析构统一 unref。
};
} // namespace flywow_lua_binding
