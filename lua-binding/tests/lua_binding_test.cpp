// 职责：用宿主真实 Lua 静态库验证 Binding 的类型、栈、引用、闭包和 GC 合同。
// 测试可以使用 C API 观测栈及构造敌意输入；业务示例只使用封装接口。
#include "lua_binding.h"
#include "lua_table.h"
extern "C"
{
#include <lualib.h>
}
#include <array>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>

using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
using flywow_lua_binding::LuaType;
using flywow_lua_binding::LuaValue;

namespace
{
// 测试断言在 Release 中也生效；condition 为假时用 message 报告具体失败，异常最终由测试主流程处理。
void require(bool condition, const char *message)
{
    if (!condition)
    {
        throw std::runtime_error(message); // 不用 assert，Release 构建也必须执行检查。
    }
}

struct TestEnvironment
{
    lua_State *state              = nullptr; // 只借用本测试 State，用于直接观测封装操作的栈高度。
    int        constructed        = 0;       // 本 State 成功构造的 Tracked 数量。
    int        destroyed          = 0;       // 本 State 已析构的 Tracked 数量。
    int        boundary_entered   = 0;       // OOM 回调进入次数。
    int        boundary_destroyed = 0;       // OOM 回调栈资源析构次数。
};

struct Tracked
{
    explicit Tracked(TestEnvironment *owner, bool fail = false) : owner(owner)
    {
        if (fail)
        {
            throw std::runtime_error("constructor failed");
        }
        ++owner->constructed;
    }
    ~Tracked() noexcept
    {
        ++owner->destroyed;
    }
    TestEnvironment *owner;     ///< 借用当前 State 的计数环境，构造与析构都写入它。
    int              value = 7; ///< Lua 往返读取的固定载荷，借用指针错误会使该断言失败。
};

struct Tiny
{
    ~Tiny() noexcept
    {
        ++destroyed;
    }
    unsigned char value = 3; ///< 一个字节的对象载荷，用于核对最小 userdata 存储不会被状态覆盖。
    static int    destroyed; // 测试单线程的析构观测值；不是封装 Runtime 全局状态。
};
int Tiny::destroyed = 0;

constexpr const char *kTracked   = "flywow_binding_test.Tracked";
constexpr const char *kTiny      = "flywow_binding_test.Tiny";
constexpr const char *kDuplicate = "flywow_binding_test.Duplicate";

// 从测试注册的第一个 upvalue 取出当前 State 的计数 owner；它覆盖该 State 的完整生命周期。
TestEnvironment *readTestEnvironment(LuaBinding &lua_binding)
{
    void *pointer = nullptr; // 闭包或测试宿主传入的外部借用地址，不归 Lua 释放。
    require(lua_binding.readUpvalue(1, pointer), "missing test environment");
    return static_cast<TestEnvironment *>(pointer);
}

// 通用标量用例：按 T 严格读位置 1 并原样返回；具体边界由 Lua 脚本选择输入。
template <typename T> int echo(lua_State *state)
{
    return LuaBinding::invoke(state,
                              [state]() -> int
                              {
                                  LuaBinding lua_binding(
                                      state); // 本回调的错误与短期引用 owner，不跨调用保存。
                                  T value{};
                                  if (!lua_binding.readValue(1, value))
                                  {
                                      return lua_binding.pushError();
                                  }
                                  return lua_binding.returnValues(value);
                              });
}

/// 往返 uint32，验证 0、上界及范围错误。
/// @param state 参数 1 是待往返的 Lua integer，按 uint32 范围检查。
/// @return 成功返回原 uint32 值；类型或范围失败返回 nil/error。
int uint(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<std::uint32_t>(state); });
}

/// 往返无符号整数，验证 Lua 有符号上界。
/// @param state 参数 1 是非负 Lua integer，最大允许 math.maxinteger。
/// @return 成功返回原整数；负数或类型错误返回 nil/error。
int uint64(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<std::uint64_t>(state); });
}

/// 往返有符号整数，验证 Lua 最小值和最大值。
/// @param state 参数 1 是待往返的 Lua integer，覆盖宿主有符号上下界。
/// @return 成功返回原整数，类型错误返回 nil/error。
int signed_value(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<std::int64_t>(state); });
}

/// 往返 int8，验证窄整数上下界。
/// @param state 参数 1 是待检查的 Lua integer，目标范围为 -128..127。
/// @return 成功返回原整数，越界或类型错误返回 nil/error。
int byte(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<std::int8_t>(state); });
}

/// 往返严格 bool，验证 false 不表示失败。
/// @param state 参数 1 必须为 Lua boolean，false 也是合法成功输入。
/// @return 成功返回原 boolean，false 不表示失败；类型错误返回 nil/error。
int boolean(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<bool>(state); });
}

/// 往返字符串，验证空串和零字节。
/// @param state 参数 1 必须为 Lua string，允许空串和内嵌零字节。
/// @return 成功返回完整原字符串，类型错误返回 nil/error。
int string(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<std::string>(state); });
}

/// 往返 float，验证非有限值与目标范围。
/// @param state 参数 1 是 Lua number，目标为有限的 float。
/// @return 成功返回 float 舍入后的数值，非有限或越界输入返回 nil/error。
int float_value(lua_State *state)
{
    return LuaBinding::invoke(state, [state]() -> int { return echo<float>(state); });
}

/// 拒绝非法位置索引和非 table，验证失败保留原输出与栈高。
/// @param state 参数 1 为非 table；upvalue 1 借用测试环境以观测栈高。
/// @return 所有输出与栈高断言通过后返回 true。
int conversion_boundaries(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
            const int     top = lua_gettop(env->state); // 本操作入口栈高，供结束或异常后核对恢复。
            std::uint32_t value = 19; // 本用例的数值转换输出，失败时须保留预设哨兵。
            require(!lua_binding.readValue(0, value) && value == 19, "zero index changed output");
            require(!lua_binding.readValue(top + 1, value), "positive overflow accepted");
            require(!lua_binding.readValue(-top - 1, value), "negative overflow accepted");

            LuaTable original = lua_binding.newTable(); // 失败读取前持有的原表，检查输出未被替换。
            require(original.writeValue("retained", 1), "initial table write failed");
            require(!lua_binding.readTable(1, original), "non-table accepted");
            int retained = 0; // 从原表回读的 retained 字段，确认失败保留句柄。
            require(original.readValue("retained", retained) && retained == 1,
                    "table output replaced");
            require(lua_gettop(env->state) == top, "conversion changed stack");
            return lua_binding.returnValues(true);
        });
}

/// 让第二个返回值越界，验证部分结果不会遮住最终 nil/error。
/// @param state 无位置参数，用超出 Lua 整数上界的第二个结果触发转换失败。
/// @return 两个结果 nil/error，不能暴露前面已压入的整数 1。
int invalid_return(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            return lua_binding.returnValues(1, std::numeric_limits<std::uint64_t>::max());
        });
}

/// 验证 raw 字段读写、移动句柄、整数 key、零字节和父子引用独立性。
/// @param state 参数 1 是含 child.map_id、kept 的输入表；upvalue 1 提供栈高观测环境。
/// @return 依次返回 child 与原输入表，供 Lua 检查内容和对象身份。
int table_operations(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
            const int top = lua_gettop(env->state); // 本操作入口栈高，供结束或异常后核对恢复。
            LuaTable  input;                        // Lua 传入的原表，后续移动只转移句柄所有权。
            LuaTable  child; // 从当前字段取得的子表引用，检查嵌套访问及独立存活。
            require(lua_binding.readTable(input), "implicit top table read failed");
            require(input.readTable("child", child), "child read failed");
            std::uint32_t map_id = 0; // 请求或子表中的地图编号，0 也可读取成功。
            require(child.readValue("map_id", map_id) && map_id == 17, "nested field read failed");
            require(!input.readValue("missing", map_id) && map_id == 17, "missing changed output");

            auto moved = std::move(input); // 接管 input 引用的句柄，原 input 此后失效。
            require(!input.valid() && moved.valid(), "table move failed");
            require(!moved.writeValue("kept", std::numeric_limits<std::uint64_t>::max()),
                    "overflow write");
            require(!moved.writeValue(std::numeric_limits<std::uint64_t>::max(), 1),
                    "overflow key accepted");
            require(!moved.readValue(std::numeric_limits<std::uint64_t>::max(), map_id),
                    "overflow key read");
            int kept = 0; // 失败写入后回读的旧字段值，确认没有覆盖。
            require(moved.readValue("kept", kept) && kept == 9, "failed write changed field");
            require(moved.writeValue("fresh", 11), "raw write invoked input __newindex");

            // key/value 内嵌零字节都按完整长度保存；nullptr 删除字段。
            const std::string key("k\0z", 3);  // 含内嵌零字节的字段名，验证按完整长度访问。
            const std::string text("v\0z", 3); // 含内嵌零字节的字段载荷，验证字节保真。
            std::string       result;          // 回读的完整字符串，与原 text 比较。
            require(child.writeValue(key, text) && child.readValue(key, result) && result == text,
                    "binary string lost");
            require(child.writeValue(key, nullptr) && child.isNil(key), "nil delete failed");
            require(child.writeValue(0, false) && child.writeValue(-1, 0), "integer keys rejected");
            bool truth = false; // 按 Lua 真值规则读取的布尔输出。
            require(child.readTruth(-1, truth) && truth, "zero truth changed");
            require(child.readTruth(0, truth) && !truth, "false truth changed");

            auto parent = lua_binding.newTable(); // 临时父表，先释放它再检查子表独立引用。
            require(parent.writeValue("child", child), "parent child write failed");
            parent = LuaTable{}; // 子表独立 registry 引用，父表先销毁不影响子表。
            require(child.readValue("map_id", map_id), "child did not survive parent");
            require(lua_gettop(env->state) == top, "table operations changed stack");
            return lua_binding.returnValues(child, moved);
        });
}

/// 将临时表放入弱值表，返回后由 Lua GC 验证 registry 引用已释放。
/// @param state 参数 1 是 Lua 提供的弱值表，临时对象仅借它观测 GC。
/// @return 无 Lua 返回值；随后由脚本触发 GC 并检查弱引用。
int drop_temporary(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            LuaTable   weak;               // Lua 提供的弱值表，用于观察临时引用释放。
            require(lua_binding.readTable(1, weak), "weak table missing");
            auto temporary = lua_binding.newTable(); // 本回调唯一强引用的临时表，退出后应能被 GC。
            require(weak.writeValue(1, temporary), "weak write failed");
            return lua_binding.returnValues();
        });
}

/// 比较 raw 边界与稠密长度，验证稀疏失败不覆盖长度哨兵。
/// @param state 参数 1 是待检查的数组或混合 key 表，空表也属于合法输入。
/// @return 成功依次返回 raw 边界与稠密长度；稀疏数组返回 nil/error。
int array_lengths(lua_State *state)
{
    return LuaBinding::invoke(state,
                              [state]() -> int
                              {
                                  LuaBinding lua_binding(
                                      state); // 本回调的错误与短期引用 owner，不跨调用保存。
                                  LuaTable table;
                                  if (!lua_binding.readTable(1, table))
                                  {
                                      return lua_binding.pushError();
                                  }
                                  std::size_t raw   = 0;  // rawlen 的数组边界，不承诺没有空洞。
                                  std::size_t dense = 99; // 失败后必须仍为此哨兵值。
                                  require(table.arrayLength(raw), "raw length failed");
                                  if (!table.denseArrayLength(dense))
                                  {
                                      require(dense == 99, "dense length changed on failure");
                                      return lua_binding.pushError();
                                  }
                                  return lua_binding.returnValues(raw, dense);
                              });
}

/// 验证原 key 不变形、嵌套遍历、错误序号及 visitor 异常后的栈恢复。
/// @param state 参数 1 是含数字 key 和子表的混合表；upvalue 1 提供栈高观测环境。
/// @return 依次返回数字 key 计数与子表字段总数。
int iterate(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
            const int top = lua_gettop(env->state); // 本操作入口栈高，供结束或异常后核对恢复。
            LuaTable  table;
            require(lua_binding.readTable(1, table), "iterate input missing");
            int numeric_keys = 0; // 本轮统计到的数字 key 数量。
            int children     = 0; // 嵌套子表中访问到的字段总数。
            require(
                table.forEach(
                    [&](const LuaValue &key, const LuaValue &value)
                    {
                        if (key.type() == LuaType::kNumber)
                        {
                            std::int64_t integer = 0; // 数字 key 的整数回读，验证原 key 不被转换。
                            require(key.readValue(integer), "numeric key lost");
                            std::string unchanged =
                                "unchanged"; // 错误读取的字符串哨兵，失败不能覆盖它。
                            require(!key.readValue(unchanged) && unchanged == "unchanged",
                                    "numeric key mutated");
                        }
                        if (value.type() == LuaType::kTable)
                        {
                            LuaTable child; // 从当前字段取得的子表引用，检查嵌套访问及独立存活。
                            require(value.readTable(child), "visitor table read failed");
                            require(child.forEach(
                                        [&](const LuaValue &, const LuaValue &)
                                        {
                                            ++children;
                                            return true;
                                        }),
                                    "nested iteration failed");
                        }
                        else if (key.type() == LuaType::kNumber)
                        {
                            ++numeric_keys;
                        }
                        return true; // 已处理 key 的类型错误不应令成功遍历自动失败。
                    }),
                "iteration failed");
            require(lua_gettop(env->state) == top, "iteration changed stack");

            lua_binding.setError("OLD_ERROR", "previously handled");
            require(!table.forEach([](const LuaValue &, const LuaValue &) { return false; }),
                    "silent visitor failure accepted");
            require(lua_binding.errorCode() == "INTERNAL_ERROR", "visitor reused stale error");
            require(!table.forEach(
                        [&](const LuaValue &, const LuaValue &)
                        {
                            lua_binding.setError("VISITOR_FAILED", "explicit failure");
                            return false;
                        }),
                    "explicit failure accepted");
            require(lua_binding.errorCode() == "VISITOR_FAILED", "visitor error overwritten");
            try
            {
                table.forEach([](const LuaValue &, const LuaValue &) -> bool
                              { throw std::runtime_error("visitor exception"); });
                require(false, "visitor exception missing");
            }
            catch (const std::runtime_error &)
            {
                require(lua_gettop(env->state) == top, "exception left iteration stack");
            }
            return lua_binding.returnValues(numeric_keys, children);
        });
}

/// 返回固定值，供元表身份测试观察真实 __index 调用。
/// @param state Lua __index 传入目标表与缺失 key，本用例不读取两项参数。
/// @return 固定返回 23，供缺省字段访问断言。
int count_metamethod(lua_State *state)
{
    return LuaBinding::invoke(state,
                              [state]() -> int
                              {
                                  LuaBinding lua_binding(
                                      state); // 本回调的错误与短期引用 owner，不跨调用保存。
                                  return lua_binding.returnValues(23);
                              });
}

/// 设置和重读同一元表，验证句柄身份与实际元方法行为。
/// @param state 当前测试 State 的回调栈，无位置参数。
/// @return 返回带有真实 __index 元方法的表。
int metatables(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            LuaTable   meta = lua_binding.newTable(); // 本用例的具名或普通元表引用。
            // __index 是 C++ 保留标识符，回调使用合法的 count_metamethod。
            require(meta.setFunction("__index", &count_metamethod), "metamethod registration");
            LuaTable table = lua_binding.newTable();
            require(table.setMetatable(meta), "setmetatable failed");
            LuaTable read_meta; // 重读的元表句柄，应与原 meta 指向同一表。
            require(table.readMetatable(read_meta), "readmetatable failed");
            require(read_meta.writeValue("marker", 11), "meta write failed");
            int marker = 0; // 回读 marker 字段，验证表身份或失败输出保留。
            require(meta.readValue("marker", marker) && marker == 11, "metatable identity lost");
            return lua_binding.returnValues(table);
        });
}

/// 按参数选择构造成功或抛错，供 Lua 脚本核对构造与析构次数。
/// @param state 参数 1 是构造失败开关；upvalue 1 借用当前 State 的计数环境。
/// @return 成功返回 Tracked userdata，构造或参数失败返回 nil/error。
int new_tracked(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
            bool  fail = false;                           // Lua 参数指定的构造失败开关。
            if (!lua_binding.readValue(1, fail))
            {
                return lua_binding.pushError();
            }
            Tracked *object = nullptr; // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
            if (!lua_binding.newUserdata(kTracked, object, env, fail))
            {
                return lua_binding.pushError();
            }
            return lua_binding.returnValues(object);
        });
}

/// 读取精确类型 userdata 并返回值和原对象，验证对象身份不变。
/// @param state 参数 1 为待检查的 Tracked userdata，也会测试错误类型和已析构对象。
/// @return 成功依次返回对象载荷与原 userdata，类型或生命周期错误返回 nil/error。
int read_tracked(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            Tracked *object = nullptr; // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
            if (!lua_binding.readUserdata(1, kTracked, object))
            {
                return lua_binding.pushError();
            }
            return lua_binding.returnValues(object->value, object);
        });
}

/// 重复调用同一 GC 并读取已析构对象，验证析构幂等与失效读取。
/// @param state 参数 1 为活的 Tracked userdata，测试会显式结束其 T 生命周期。
/// @return 重复析构和失效读取检查通过后返回 true。
int userdata_gc_idempotent(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。

            // gettop 记录入口高度，不改栈。两轮调用都从 [S, arg1] 开始，最后 settop 丢弃测试临时项。
            const int top = lua_gettop(state); // 本操作入口栈高，供结束或异常后核对恢复。
            // registry 查找压入 metatable，getfield 压入 collector，pushvalue 复制参数 1：
            // [S, userdata] -> [S, userdata, meta, gc, userdata-copy]。
            luaL_getmetatable(state, kTracked);
            lua_getfield(state, -1, "__gc");
            lua_pushvalue(state, 1);
            // lua_call 消耗 gc 和 1 个实参、不产生结果，回到 [S, userdata, meta]。
            lua_call(state, 1, 0);
            // 再以同样的栈形调用一次，验证 collector 的 alive 标记使析构幂等。
            lua_getfield(state, -1, "__gc");
            lua_pushvalue(state, 1);
            lua_call(state, 1, 0);
            // settop 移除 metatable 临时项并恢复入口高度；它不撤销已经发生的析构状态。
            lua_settop(state, top);
            Tracked *dead = nullptr; // 已析构对象的读取输出，必须保持空指针。
            require(!lua_binding.readUserdata(1, kTracked, dead),
                    "finalized userdata must not be readable");
            require(lua_binding.errorCode() == "INVALID_ARGUMENT",
                    "finalized userdata must report INVALID_ARGUMENT");
            return lua_binding.returnValues(true);
        });
}

/// 拒绝同名类型注册、覆盖 GC、未注册构造及任意指针包装。
/// @param state 无位置参数；upvalue 1 提供构造用的借用测试环境。
/// @return 所有拒绝与输出保留检查通过后返回 true。
int userdata_errors(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            LuaTable   meta;               // 本用例的具名或普通元表引用。
            require(lua_binding.registerUserdata<Tracked>(kDuplicate, meta),
                    "first userdata registration failed");
            const int stack_top = lua_gettop(state); // 注册检查前的栈高，临时元表操作后恢复。
            // 取回原 collector 并记录身份：[S, meta] -> [S, meta, gc]；
            // tocfunction 只读函数指针，settop 随后移除新增项，恢复入口栈高。
            luaL_getmetatable(state, kDuplicate);
            lua_getfield(state, -1, "__gc");
            const lua_CFunction original_collector = lua_tocfunction(
                state, -1); // 注册完成时的析构函数地址，用来比较重复注册是否改写它。
            lua_settop(state, stack_top);

            LuaTable duplicate; // 重复注册的输出句柄，拒绝后应保持失效。
            require(!lua_binding.registerUserdata<Tracked>(kDuplicate, duplicate),
                    "duplicate same-type registration accepted");
            require(lua_binding.errorCode() == "INVALID_ARGUMENT" && !duplicate.valid(),
                    "same-type duplicate changed its output/error contract");
            require(!lua_binding.registerUserdata<Tiny>(kDuplicate, duplicate),
                    "duplicate different-type registration accepted");
            require(lua_binding.errorCode() == "INVALID_ARGUMENT" && !duplicate.valid(),
                    "different-type duplicate changed its output/error contract");

            // 重读元表字段并与原函数地址比较；此段压入 meta/gc 两项，末尾 settop 会统一清理。
            luaL_getmetatable(state, kDuplicate);
            lua_getfield(state, -1, "__gc");
            const bool collector_unchanged =
                lua_tocfunction(state, -1) ==
                original_collector; // 重读 GC 后与原函数地址比较的结果。
            lua_settop(state, stack_top);
            require(original_collector != nullptr && collector_unchanged,
                    "duplicate registration replaced the original collector");
            require(!meta.setFunction("__gc", &count_metamethod), "GC overwritten by registration");
            require(!meta.writeValue("__gc", nullptr), "GC removed by field write");
            Tracked *pointer = nullptr; // 闭包或测试宿主传入的外部借用地址，不归 Lua 释放。
            require(
                !lua_binding.newUserdata("missing.Type", pointer, readTestEnvironment(lua_binding)),
                "unregistered construction accepted");
            int  arbitrary = 0; // 未由封装创建的栈对象，必须拒绝包装为 userdata。
            auto table     = lua_binding.newTable();
            require(!table.writeValue("arbitrary", &arbitrary),
                    "arbitrary pointer wrapped as userdata");
            return lua_binding.returnValues(true);
        });
}

/// 构造小于一个机器字的 userdata，验证封装没有越界附加对象头。
/// @param state 当前测试 State 的回调栈，无位置参数。
/// @return 返回由 Lua GC 管理的单字节 Tiny userdata。
int new_tiny(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            Tiny *object = nullptr; // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
            require(lua_binding.newUserdata(kTiny, object), "tiny construction failed");
            return lua_binding.returnValues(object);
        });
}

/// 返回当前 State 的构造、析构计数和单线程 Tiny 析构计数。
/// @param state 无位置参数；upvalue 1 提供当前 State 的独立计数环境。
/// @return 依次返回成功构造数、析构数和 Tiny 析构数。
int counters(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
            return lua_binding.returnValues(env->constructed, env->destroyed, Tiny::destroyed);
        });
}

/// 读取四种业务 upvalue 并更新计数，验证保护调用没有改变原生编号。
/// @param state 无位置参数；四个 upvalue 依次为计数、表、外部指针和 Tracked 对象。
/// @return 依次返回更新前的计数值与原 Tracked userdata。
int run(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            int        counter = 0;        // 闭包捕获的调用计数，成功后写回递增值。
            LuaTable   captured;           // 闭包强引用的表，检查 GC 后字段仍存在。
            void      *pointer = nullptr;  // 闭包或测试宿主传入的外部借用地址，不归 Lua 释放。
            Tracked *object = nullptr; // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
            if (!lua_binding.readUpvalue(1, counter) ||
                !lua_binding.readUpvalueTable(2, captured) ||
                !lua_binding.readUpvalue(3, pointer) ||
                !lua_binding.readUpvalueUserdata(4, kTracked, object))
            {
                return lua_binding.pushError();
            }
            int marker = 0; // 回读 marker 字段，验证表身份或失败输出保留。
            require(captured.readValue("marker", marker) && marker == 17, "captured table lost");
            require(object->owner == pointer, "borrowed pointer changed");
            require(lua_binding.writeUpvalue(1, counter + 1), "upvalue update failed");
            require(!lua_binding.readUpvalue(0, marker) && !lua_binding.readUpvalue(5, marker),
                    "invalid business upvalue accepted");
            return lua_binding.returnValues(counter, object);
        });
}

/// 捕获 table、外部指针和 userdata，供 GC 测试验证强引用持有与释放。
/// @param state 无位置参数；upvalue 1 借用计数环境，创建出的闭包将继续引用它。
/// @return 返回包含 run 闭包的表。
int make_closure(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
            Tracked *object = nullptr; // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
            require(lua_binding.newUserdata(kTracked, object, env), "captured object creation");
            auto captured = lua_binding.newTable(); // 闭包强引用的表，检查 GC 后字段仍存在。
            require(captured.writeValue("marker", 17), "captured table setup");
            auto functions = lua_binding.newTable(); // 保存业务闭包的返回表，供 Lua 验证捕获值。
            require(
                functions.setFunction("run", &run, 0, captured, static_cast<void *>(env), object),
                "closure registration failed");
            return lua_binding.returnValues(functions);
        });
}

/// 通过封装读取真实 request.map_id，作为固定形态性能对照。
/// @param state 参数 1 为请求表，本用例读取其 uint32 map_id 字段。
/// @return 成功返回 map_id，字段或类型错误返回 nil/error。
int read_map(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding    lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            LuaTable      request;            // 位置参数中的请求表，读取它的 map_id。
            std::uint32_t map_id = 0;         // 请求或子表中的地图编号，0 也可读取成功。
            if (!lua_binding.readTable(1, request) || !request.readValue("map_id", map_id))
            {
                return lua_binding.pushError();
            }
            return lua_binding.returnValues(map_id);
        });
}

// 超过最低保证的返回数量必须扩栈；参数包生成 0..63，Lua 按原顺序收到每个值。
template <std::size_t... Index>
int returnManyValues(LuaBinding &lua_binding, std::index_sequence<Index...>)
{
    return lua_binding.returnValues(Index...);
}

/// Lua 测试读取 64 个结果，验证结果压栈不依赖 LUA_MINSTACK。
/// @param state 本次测试调用栈；不需要位置参数。
/// @return 64 个按顺序排列的整数。
int many_values(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            return returnManyValues(lua_binding, std::make_index_sequence<64>{});
        });
}

/// 检查大型闭包中最后一个真实 upvalue，保护调用的内部参数不能混入业务编号。
/// @param state 由 make_large_closure 返回的闭包调用栈。
/// @return 第 64 个业务 upvalue，预期为 63。
int many_upvalues(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            int        last = -1;          // 闭包捕获序列末项，读取失败不得覆盖该哨兵。
            require(lua_binding.readUpvalue(64, last), "large closure lost its last upvalue");
            return lua_binding.returnValues(last);
        });
}

// 构造真实 64-upvalue 闭包，既检查临时压栈容量，也检查创建后编号未偏移。
template <std::size_t... Index>
bool registerManyUpvalues(LuaTable &functions, std::index_sequence<Index...>)
{
    return functions.setFunction("many_upvalues", &many_upvalues, Index...);
}

/// Lua 测试获取大型闭包并执行，覆盖多于最低栈槽数的函数注册。
/// @param state 当前同步测试调用栈。
/// @return 包含 many_upvalues 的函数表。
int make_large_closure(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            auto       functions = lua_binding.newTable(); // 以真实表字段保持闭包存活。
            require(registerManyUpvalues(functions, std::make_index_sequence<64>{}),
                    "large closure setup failed");
            return lua_binding.returnValues(functions);
        });
}

/// 验证非法编号不会读取 registry、改写不存在的 upvalue，失败也保留表句柄。
/// @param state 此闭包只有一个业务 upvalue，值为 42。
/// @return 所有编号、输出保留及合法值检查通过时返回 true。
int upvalue_boundaries(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state);           // 本回调的错误与短期引用 owner，不跨调用保存。
            auto preserved = lua_binding.newTable(); // 用于确认失败不会把输出替换成 registry。
            require(preserved.writeValue("marker", 17), "upvalue sentinel setup failed");
            for (int index :
                 {0, -1, 2, 256, std::numeric_limits<int>::min(), std::numeric_limits<int>::max()})
            {
                int value = 19; // 每轮读取失败后必须保留的整数哨兵。
                require(!lua_binding.readUpvalue(index, value) && value == 19,
                        "invalid upvalue read accepted");
                require(!lua_binding.readUpvalueTable(index, preserved),
                        "invalid upvalue table accepted");
                Tracked *object = nullptr; // 非法编号不能读取 registry 或改变借用输出。
                require(!lua_binding.readUpvalueUserdata(index, kTracked, object) &&
                            object == nullptr,
                        "invalid userdata upvalue accepted");
                require(!lua_binding.writeUpvalue(index, 99), "invalid upvalue write accepted");
            }
            int marker = 0; // 仍应从原表读取，而不是从 registry 或新表读取。
            int value  = 0; // 合法业务 upvalue 必须仍为初始值，证明非法写入没有污染它。
            require(preserved.readValue("marker", marker) && marker == 17,
                    "upvalue failure changed table output");
            require(lua_binding.readUpvalue(1, value) && value == 42,
                    "upvalue failure changed closure");
            require(lua_binding.writeUpvalue(1, nullptr), "valid nil upvalue write failed");
            require(lua_binding.writeUpvalue(1, 42),
                    "existing nil upvalue was mistaken for missing");
            return lua_binding.returnValues(true);
        });
}

/// 让 C++ 异常经过真实 Lua 回调，验证不会越过 C ABI。
/// @param state 参数 1 选择 bad_alloc 或普通意外异常。
/// @return 正常路径不返回；invoke 将异常转换为 nil 和 INTERNAL_ERROR。
int native_exception(lua_State *state)
{
    return LuaBinding::invoke(state,
                              [state]() -> int
                              {
                                  if (lua_toboolean(state, 1))
                                  {
                                      throw std::bad_alloc();
                                  }
                                  throw std::runtime_error("injected native exception");
                              });
}

/// require 加载失败模块，不得把 nil/error 当成成功模块并缓存 true。
/// @param state Lua loader 提供的模块名等参数。
/// @return 失败按 Lua 加载错误传播，不正常返回。
int failing_module(lua_State *state)
{
    return LuaBinding::invokeModule(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            return lua_binding.pushError("INIT_FAILED", "injected initialization failure");
        });
}

// OOM 故障期间仍必须通过 C++ 展开析构的栈资源；计数由单个测试 State 独占。
struct BoundaryResource
{
    TestEnvironment *owner; ///< 本轮测试计数 owner，生命周期覆盖资源和对应 Lua State。
    explicit BoundaryResource(TestEnvironment *test_environment) : owner(test_environment)
    {
        ++owner->boundary_entered;
    }
    ~BoundaryResource() noexcept
    {
        ++owner->boundary_destroyed;
    }
};

/// 在栈资源、userdata 和表均存在时触发 Lua 分配，检查错误不会跳过 C++ 析构或遗失 userdata。
/// @param state upvalue 1 是本轮 TestEnvironment 的借用指针，故障期间不解析 Lua 参数。
/// @return 成功返回表；Lua OOM 经 invoke 返回错误结果或在持续 OOM 时抛 Lua 错误。
int allocation_failure(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            auto *env = static_cast<TestEnvironment *>(
                lua_touserdata(state, lua_upvalueindex(1))); // 故障前注册的测试 owner。
            BoundaryResource resource(env);      // 必须先于任何可能失败的封装分配建立析构观测。
            LuaBinding       lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            Tracked *object = nullptr; // 构造成功后由 Lua GC 管理，不能因后续表分配失败而泄漏。
            if (!lua_binding.newUserdata(kTracked, object, env))
            {
                return lua_binding.pushError();
            }
            auto table =
                lua_binding.newTable(); // 字符串、字段扩容、registry 引用分别经过受保护操作。
            const std::string payload(4096, 'x'); // 本地 C++ 字节串，Lua OOM 后也必须析构。
            require(table.writeValue("payload", payload), "allocation probe field write failed");
            require(table.writeValue("object", object), "allocation probe userdata write failed");
            return lua_binding.returnValues(table);
        });
}

/// 注册本 State 独占的测试类型和回调，把借用测试环境传入需要计数的闭包。
/// @param state 参数 1 为测试宿主持有的 TestEnvironment lightuserdata 地址。
/// @return 返回注册完成的测试模块表。
int registerTestModule(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
            void      *pointer = nullptr;  // 闭包或测试宿主传入的外部借用地址，不归 Lua 释放。
            require(lua_binding.readValue(1, pointer), "test setup pointer missing");
            auto module = lua_binding.newTable(); // 当前 State 独占的测试函数表，注册完成后才返回。
            LuaTable meta;                        // 本用例的具名或普通元表引用。
            require(lua_binding.registerUserdata<Tracked>(kTracked, meta),
                    "tracked registration failed");
            require(lua_binding.registerUserdata<Tiny>(kTiny, meta), "tiny registration failed");
            // signed/float 是 C++ 关键字，使用合法回调名；Lua 测试 API 保持原名。
            require(module.setFunction("uint", &uint) && module.setFunction("uint64", &uint64) &&
                        module.setFunction("signed", &signed_value) &&
                        module.setFunction("byte", &byte) &&
                        module.setFunction("boolean", &boolean) &&
                        module.setFunction("string", &string) &&
                        module.setFunction("float", &float_value),
                    "scalar registration failed");
            require(module.setFunction("conversion_boundaries", &conversion_boundaries, pointer) &&
                        module.setFunction("invalid_return", &invalid_return) &&
                        module.setFunction("table_operations", &table_operations, pointer) &&
                        module.setFunction("drop_temporary", &drop_temporary) &&
                        module.setFunction("array_lengths", &array_lengths) &&
                        module.setFunction("iterate", &iterate, pointer) &&
                        module.setFunction("metatables", &metatables) &&
                        module.setFunction("new_tracked", &new_tracked, pointer) &&
                        module.setFunction("read_tracked", &read_tracked) &&
                        module.setFunction("userdata_errors", &userdata_errors, pointer) &&
                        module.setFunction("userdata_gc_idempotent", &userdata_gc_idempotent) &&
                        module.setFunction("new_tiny", &new_tiny) &&
                        module.setFunction("counters", &counters, pointer) &&
                        module.setFunction("make_closure", &make_closure, pointer) &&
                        module.setFunction("read_map", &read_map),
                    "operation registration failed");
            require(module.setFunction("many_values", &many_values) &&
                        module.setFunction("make_large_closure", &make_large_closure) &&
                        module.setFunction("upvalue_boundaries", &upvalue_boundaries, 42) &&
                        module.setFunction("native_exception", &native_exception) &&
                        module.setFunction("failing_module", &failing_module),
                    "boundary regression registration failed");
            return lua_binding.returnValues(module);
        });
}

// 对照基线仅用于测量同一个固定参数的 raw 读取，不作为生产模块或新公开接口。
/// 按同一 uint32 范围读取 request.map_id，作为封装读表的 raw 性能对照。
/// @param state 参数 1 为同一性能对照请求表，raw 读取其 uint32 map_id。
/// @return 成功返回 map_id，范围或类型错误只返回 nil，作为固定 raw 性能基线。
int raw_read_map(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            // [request] -> [request, key]；rawget 消耗 key 并压入字段值，不触发 __index。
            lua_pushliteral(state, "map_id");
            lua_rawget(state, 1);
            // 类型与数值读取都不改栈；value 对应当前栈顶的 raw 字段。
            const lua_Integer value =
                lua_tointeger(state, -1); // raw 字段中的 Lua 整数，返回前验证 uint32 范围。
            if (!lua_isinteger(state, -1) || value < 0 ||
                static_cast<std::uint64_t>(value) > std::numeric_limits<std::uint32_t>::max())
            {
                // 失败时压入 nil 并返回 1；Lua 取栈顶 nil，底层 request/key/value 临时项随回调清理。
                lua_pushnil(state);
                return 1;
            }
            // 成功时把栈顶字段值作为唯一结果；下方参数与临时 key 由 Lua 在回调返回时清理。
            return 1;
        });
}

void runScript(lua_State *state, const char *script)
{
    // 本测试脚本不显式返回值，因此成功后栈高不变；失败时错误对象留在栈顶供下方读取。
    if (luaL_dostring(state, script) != LUA_OK)
    {
        // lua_tostring(-1) 读取错误文本、不弹栈；异常由测试主流程捕获并清理 State。
        throw std::runtime_error(lua_tostring(state, -1));
    }
}

struct StateDeleter
{
    void operator()(lua_State *state) const
    {
        lua_close(state);
    }
};

// 创建独立 State 并注册测试模块；environment 由测试栈持有，必须晚于 State 销毁。
std::unique_ptr<lua_State, StateDeleter> createState(TestEnvironment *environment)
{
    std::unique_ptr<lua_State, StateDeleter> state(
        luaL_newstate()); // 本用例独占的 State，关闭前计数环境必须保持存活。
    require(state != nullptr, "State creation failed");
    environment->state = state.get();
    luaL_openlibs(state.get());

    // 建立测试模块：push 函数和借用环境指针使栈从 [] 变为 [registerTestModule, env]；
    // lua_call 消耗两项并压回模块 table，setglobal 消耗 table，栈恢复为空。
    lua_pushcfunction(state.get(), &registerTestModule);
    lua_pushlightuserdata(state.get(), environment);
    lua_call(state.get(), 1, 1);
    lua_setglobal(state.get(), "binding");
    // 注册只用于性能对照的 raw 回调：push 函数后 setglobal 消耗函数，栈仍为空。
    lua_pushcfunction(state.get(), &raw_read_map);
    lua_setglobal(state.get(), "raw_read_map");
    return state;
}

const char *kScalarTests = R"lua(
--- 调用真实 Native 并验证失败以返回值交付，pcall 只观察是否意外抛出 Lua 异常。
---@param fn function 要验证的 Native 回调。
---@param expected string|nil 预期错误码，nil 表示 INVALID_ARGUMENT。
---@param ... any 传给 Native 的测试参数，保留 nil 与参数个数。
---@return nil
local function failure(fn, expected, ...)
    local ok, value, err = pcall(fn, ...)
    assert(ok, "error unexpectedly raised")
    assert(value == nil and err.code == (expected or "INVALID_ARGUMENT"), err and err.message)
end
assert(binding.uint(0) == 0)
assert(binding.uint(4294967295) == 4294967295)
failure(binding.uint, nil, -1)
failure(binding.uint, nil, 4294967296)
failure(binding.uint, nil, 1.0)
failure(binding.uint, nil, "1")
failure(binding.uint, nil)
assert(binding.uint64(math.maxinteger) == math.maxinteger)
failure(binding.uint64, nil, -1)
assert(binding.signed(math.mininteger) == math.mininteger)
assert(binding.signed(math.maxinteger) == math.maxinteger)
assert(binding.byte(-128) == -128 and binding.byte(127) == 127)
failure(binding.byte, nil, 128)
assert(binding.boolean(false) == false)
failure(binding.boolean, nil, 0)
assert(binding.string("") == "" and binding.string("a\0b") == "a\0b")
failure(binding.string, nil, 17)
assert(binding.float(1) == 1)
failure(binding.float, nil, "1")
failure(binding.float, nil, 1/0)
failure(binding.float, nil, 0/0)
failure(binding.float, nil, 1e39)
assert(binding.conversion_boundaries(false))
failure(binding.invalid_return, nil)
failure(binding.new_tracked, "INTERNAL_ERROR", true)
local failed_created, failed_destroyed = binding.counters()
assert(failed_created == 0 and failed_destroyed == 0, "failed constructor was destroyed")
collectgarbage("collect")
)lua";

const char *kTableTests = R"lua(
local hostile = { child={map_id=17}, kept=9 }
setmetatable(hostile, {
    __index = function() error("raw read invoked __index") end,
    __newindex = function() error("raw write invoked __newindex") end,
})
local child, parent = binding.table_operations(hostile)
assert(child.map_id == 17 and parent == hostile and child[0] == false and child[-1] == 0)
local weak = setmetatable({}, {__mode="v"})
binding.drop_temporary(weak)
collectgarbage("collect")
assert(weak[1] == nil, "temporary registry reference leaked")
local _, length = binding.array_lengths({})
assert(length == 0)
_, length = binding.array_lengths({[0]=7,[-1]=8,[1]=9,[2]=10,source="config",[1.5]="ignored"})
assert(length == 2)
_, length = binding.array_lengths(setmetatable({1,2}, {
    __len = function() error("raw length invoked __len") end,
}))
assert(length == 2)
local sparse, err = binding.array_lengths({[1]=7,[3]=8})
assert(sparse == nil and err.code == "INVALID_ARGUMENT")
local numeric, children = binding.iterate({[0]=1,[1]=2,word=false,child={x=1,y=2}})
assert(numeric == 2 and children == 2)
assert(binding.metatables().unknown == 23, "registered metamethod missing")
)lua";

const char *kUserdataTests = R"lua(
assert(binding.userdata_errors())
local object = binding.new_tracked(false)
assert(binding.read_tracked(object) == 7)
local tiny = binding.new_tiny()
local bad, err = binding.read_tracked(tiny)
assert(bad == nil and err.code == "INVALID_ARGUMENT")
bad, err = binding.read_tracked({})
assert(bad == nil and err.code == "INVALID_ARGUMENT")
object = nil
tiny = nil
collectgarbage("collect")
local created, destroyed, tiny_destroyed = binding.counters()
assert(created == 1 and destroyed == 1 and tiny_destroyed == 1, "duplicate or missing destructor")
local closure = binding.make_closure()
collectgarbage("collect")
assert(closure.run() == 0 and closure.run() == 1)
created, destroyed = binding.counters()
assert(created == 2 and destroyed == 1, "closure did not retain userdata")
closure = nil
collectgarbage("collect")
created, destroyed = binding.counters()
assert(created == 2 and destroyed == 2, "closure registry reference leaked")
local finalized = binding.new_tracked(false)
assert(binding.userdata_gc_idempotent(finalized))
local collector = getmetatable(finalized).__gc
local plain = setmetatable({}, getmetatable(finalized))
plain = nil
collectgarbage("collect")
assert(pcall(collector, 7))
local wrong_type = binding.new_tiny()
collector(wrong_type)
local _, _, before_tiny_gc = binding.counters()
assert(before_tiny_gc == 1, "wrong collector destroyed another userdata type")
wrong_type = nil
collectgarbage("collect")
local _, _, after_tiny_gc = binding.counters()
assert(after_tiny_gc == 2, "wrong collector prevented the actual destructor")
local dead, dead_error = binding.read_tracked(finalized)
assert(dead == nil and dead_error.code == "INVALID_ARGUMENT")
finalized = nil
collectgarbage("collect")
created, destroyed = binding.counters()
assert(created == 3 and destroyed == 3, "manual and automatic GC destroyed userdata more than once")
)lua";

// 替换当前 State 的 allocator 仅用于故障注入；释放与缩容始终交原 allocator，不影响清理路径。
struct FaultAllocator
{
    lua_Alloc original;         ///< 创建该 State 的真实 allocator，故障关闭后恢复原函数。
    void     *original_context; ///< 与 original 配套的借用上下文，不由测试释放。
    int       allocations_left; ///< 允许的增长分配次数；到零后持续拒绝，覆盖 Lua 紧急 GC 后的重试。
    int       rejected;         ///< 实际拒绝次数，证明故障确实进入 Lua 分配路径。
};

// Lua 内存故障替身只拒绝增长，不持有资源，不抛 C++ 异常穿过 Lua allocator ABI。
void *faultAllocator(void *context, void *memory, std::size_t old_size, std::size_t new_size)
{
    auto *fault = static_cast<FaultAllocator *>(context); // 单次用例独占的分配计数。
    if (new_size != 0 && (memory == nullptr || new_size > old_size))
    {
        if (fault->allocations_left == 0)
        {
            ++fault->rejected;
            return nullptr;
        }
        --fault->allocations_left;
    }
    return fault->original(fault->original_context, memory, old_size, new_size);
}

// 每个故障点使用全新 State；恢复 allocator 后回收所有 Lua 对象，核对栈资源和 userdata 的真实析构。
void testAllocationFailures()
{
    int rejected_cases = 0; // 至少一个用例必须真实触发 OOM，不能仅验证无故障成功路径。
    for (int allowed = 0; allowed < 32; ++allowed)
    {
        TestEnvironment env;            // 覆盖本轮 State、栈资源及 userdata 的完整生命周期。
        auto state = createState(&env); // 本用例独占的 State，关闭前计数环境必须保持存活。
        lua_pushlightuserdata(state.get(), &env);
        lua_pushcclosure(state.get(), &allocation_failure, 1);
        FaultAllocator fault{}; // allocator 上下文在恢复原 allocator 前一直存活。
        fault.original         = lua_getallocf(state.get(), &fault.original_context);
        fault.allocations_left = allowed;
        lua_setallocf(state.get(), &faultAllocator, &fault);
        const int status =
            lua_pcall(state.get(), 0, LUA_MULTRET, 0); // 捕获持续 OOM 的最终 Lua 错误。
        lua_setallocf(state.get(), fault.original, fault.original_context);

        require(status == LUA_OK || status == LUA_ERRMEM || status == LUA_ERRRUN,
                "unexpected allocator failure status");
        rejected_cases += fault.rejected != 0;
        lua_settop(state.get(), 0);
        lua_gc(state.get(), LUA_GCCOLLECT);
        state.reset();
        require(env.boundary_entered == 1 && env.boundary_destroyed == 1,
                "Lua OOM skipped C++ resource destruction");
        require(env.constructed == env.destroyed, "Lua OOM leaked a constructed userdata");
    }
    require(rejected_cases > 0, "allocation failure injection never rejected an allocation");
}

// 固定 100000 次请求字段读取的同进程对照，仅报告此调用形态耗时，不推导服务器容量。
void measureTableReads(lua_State *state)
{
    const auto begin = std::chrono::steady_clock::now(); // raw 读取对照开始时间，使用单调时钟。
    runScript(state, "local t={map_id=17}; for i=1,100000 do assert(raw_read_map(t)==17) end");
    const auto middle = std::chrono::steady_clock::now(); // raw 完成和 Binding 开始的共同计时点。
    runScript(state, "local t={map_id=17}; for i=1,100000 do assert(binding.read_map(t)==17) end");
    const auto end = std::chrono::steady_clock::now(); // Binding 对照结束时间，与 middle 计算耗时。
    std::cout << "READ_TABLE_100000 raw_us="
              << std::chrono::duration_cast<std::chrono::microseconds>(middle - begin).count()
              << " binding_us="
              << std::chrono::duration_cast<std::chrono::microseconds>(end - middle).count()
              << '\n';
}

// 四个线程各自创建并关闭 State，分别核对生命周期；不把同一 State 的并发访问当支持能力。
void testConcurrentStates()
{
    // 每个 OS Thread 独占自己的 State 和 Environment；同一 State 不并发访问。
    std::array<std::exception_ptr, 4> errors{}; // 每个线程各写一个异常槽，join 后由主线程检查。
    std::array<std::thread, 4>        workers;  // 本轮创建的四个独立 State 工作线程。
    for (std::size_t i = 0; i < workers.size(); ++i)
    {
        workers[i] = std::thread(
            [&, i]()
            {
                try
                {
                    TestEnvironment env; // 第一个业务 upvalue 指向的独立计数环境。
                    auto            state =
                        createState(&env); // 本用例独占的 State，关闭前计数环境必须保持存活。
                    runScript(state.get(), "for i=1,100 do local o=binding.new_tracked(false); "
                                           "assert(binding.read_tracked(o)==7) end");
                    state.reset();
                    require(env.constructed == 100 && env.destroyed == 100,
                            "thread-local State lifecycle mismatch");
                }
                catch (...)
                {
                    errors[i] = std::current_exception();
                }
            });
    }
    for (auto &worker : workers)
    {
        worker.join();
    }
    for (const auto &error : errors)
    {
        if (error)
        {
            std::rethrow_exception(error);
        }
    }
}
} // namespace

// 串行跑 ABI、生命周期、故障与跨 State 用例；异常报告到 stderr，失败返回非零状态。
int main()
{
    try
    {
        TestEnvironment first_env;              // 第一个 State 的计数 owner，生命周期覆盖 first。
        TestEnvironment second_env;             // 第二个 State 的计数 owner，生命周期覆盖 second。
        auto first  = createState(&first_env);  // 先执行完整测试的 State，不与其他线程共享。
        auto second = createState(&second_env); // 验证隔离与 lua_close 析构的独立 State。
        runScript(first.get(), kScalarTests);
        runScript(first.get(), kTableTests);
        runScript(first.get(), kUserdataTests);
        // 第二个 State 拥有独立 metatable/registry/闭包，只读 T 标记允许共享。
        runScript(second.get(), "assert(binding.uint(0)==0); object=binding.new_tracked(false)");
        require(first_env.constructed == 3 && second_env.constructed == 1, "State counters shared");
        runScript(first.get(), "collectgarbage('collect')");
        require(second_env.destroyed == 0, "other State GC touched object");
        second.reset(); // lua_close 也必须执行仍存活对象的统一 __gc。
        require(second_env.destroyed == 1, "State close missed destructor");
        runScript(first.get(), R"lua(
            local values = table.pack(binding.many_values())
            assert(values.n == 64 and values[1] == 0 and values[64] == 63)
            assert(binding.make_large_closure().many_upvalues() == 63)
            assert(binding.upvalue_boundaries())
            for _, mode in ipairs({true, false}) do
                local ok, value, err = pcall(binding.native_exception, mode)
                assert(ok and value == nil and err.code == "INTERNAL_ERROR")
            end
            package.preload.flywow_binding_failing = binding.failing_module
            local loaded = pcall(require, "flywow_binding_failing")
            assert(not loaded and package.loaded.flywow_binding_failing == nil)
        )lua");
        testAllocationFailures();
        testConcurrentStates();
        measureTableReads(first.get());
        std::cout << "FLYWOW_LUA_BINDING_TEST_OK\n";
    }
    catch (const std::exception &exception)
    {
        std::cerr << exception.what() << '\n';
        return 1;
    }
    return 0;
}
