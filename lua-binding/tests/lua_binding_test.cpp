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

constexpr const char *kTracked    = "flywow_binding_test.Tracked";
constexpr const char *kTiny       = "flywow_binding_test.Tiny";
constexpr const char *kStaticTiny = "flywow_binding_test.StaticTiny";

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
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    T          value{};
    if (!lua_binding.readValue(1, value))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(value);
}

/// 往返 uint32，验证 0、上界及范围错误。
/// @param state 参数 1 是待往返的 Lua integer，按 uint32 范围检查。
/// @return 成功返回原 uint32 值；类型或范围失败返回 nil/error。
int uint(lua_State *state)
{
    return echo<std::uint32_t>(state);
}

/// 往返无符号整数，验证 Lua 有符号上界。
/// @param state 参数 1 是非负 Lua integer，最大允许 math.maxinteger。
/// @return 成功返回原整数；负数或类型错误返回 nil/error。
int uint64(lua_State *state)
{
    return echo<std::uint64_t>(state);
}

/// 往返有符号整数，验证 Lua 最小值和最大值。
/// @param state 参数 1 是待往返的 Lua integer，覆盖宿主有符号上下界。
/// @return 成功返回原整数，类型错误返回 nil/error。
int signed_value(lua_State *state)
{
    return echo<std::int64_t>(state);
}

/// 往返 int8，验证窄整数上下界。
/// @param state 参数 1 是待检查的 Lua integer，目标范围为 -128..127。
/// @return 成功返回原整数，越界或类型错误返回 nil/error。
int byte(lua_State *state)
{
    return echo<std::int8_t>(state);
}

/// 往返严格 bool，验证 false 不表示失败。
/// @param state 参数 1 必须为 Lua boolean，false 也是合法成功输入。
/// @return 成功返回原 boolean，false 不表示失败；类型错误返回 nil/error。
int boolean(lua_State *state)
{
    return echo<bool>(state);
}

/// 往返字符串，验证空串和零字节。
/// @param state 参数 1 必须为 Lua string，允许空串和内嵌零字节。
/// @return 成功返回完整原字符串，类型错误返回 nil/error。
int string(lua_State *state)
{
    return echo<std::string>(state);
}

/// 往返 float，验证非有限值与目标范围。
/// @param state 参数 1 是 Lua number，目标为有限的 float。
/// @return 成功返回 float 舍入后的数值，非有限或越界输入返回 nil/error。
int float_value(lua_State *state)
{
    return echo<float>(state);
}

/// 拒绝非法位置索引和非 table，验证失败保留原输出与栈高。
/// @param state 参数 1 为非 table；upvalue 1 借用测试环境以观测栈高。
/// @return 所有输出与栈高断言通过后返回 true。
int conversion_boundaries(lua_State *state)
{
    LuaBinding    lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    auto         *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
    const int     top = lua_gettop(env->state); // 本操作入口栈高，供结束或异常后核对恢复。
    std::uint32_t value = 19;                   // 本用例的数值转换输出，失败时须保留预设哨兵。
    require(!lua_binding.readValue(0, value) && value == 19, "zero index changed output");
    require(!lua_binding.readValue(top + 1, value), "positive overflow accepted");
    require(!lua_binding.readValue(-top - 1, value), "negative overflow accepted");

    LuaTable original; // 失败读取前持有的原表，检查输出未被替换。
    if (!lua_binding.newTable(original))
    {
        return lua_binding.pushError();
    }
    require(original.writeValue("retained", 1), "initial table write failed");
    require(!lua_binding.readTable(1, original), "non-table accepted");
    int retained = 0; // 从原表回读的 retained 字段，确认失败保留句柄。
    require(original.readValue("retained", retained) && retained == 1, "table output replaced");
    require(lua_gettop(env->state) == top, "conversion changed stack");
    return lua_binding.returnValues(true);
}

/// 让第二个返回值越界，验证部分结果不会遮住最终 nil/error。
/// @param state 无位置参数，用超出 Lua 整数上界的第二个结果触发转换失败。
/// @return 两个结果 nil/error，不能暴露前面已压入的整数 1。
int invalid_return(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    return lua_binding.returnValues(1, std::numeric_limits<std::uint64_t>::max());
}

/// 验证 raw 字段读写、移动句柄、整数 key、零字节和父子引用独立性。
/// @param state 参数 1 是含 child.map_id、kept 的输入表；upvalue 1 提供栈高观测环境。
/// @return 依次返回 child 与原输入表，供 Lua 检查内容和对象身份。
int table_operations(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    auto      *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
    const int  top = lua_gettop(env->state);           // 本操作入口栈高，供结束或异常后核对恢复。
    LuaTable   input;                                  // Lua 传入的原表，后续移动只转移句柄所有权。
    LuaTable   child; // 从当前字段取得的子表引用，检查嵌套访问及独立存活。
    require(lua_binding.readTable(1, input), "implicit top table read failed");
    require(input.readTable("child", child), "child read failed");
    std::uint32_t map_id = 0; // 请求或子表中的地图编号，0 也可读取成功。
    require(child.readValue("map_id", map_id) && map_id == 17, "nested field read failed");
    require(!input.readValue("missing", map_id) && map_id == 17, "missing changed output");

    auto moved = std::move(input); // 接管 input 引用的句柄，原 input 此后失效。
    require(!input.valid() && moved.valid(), "table move failed");
    require(!moved.writeValue("kept", std::numeric_limits<std::uint64_t>::max()), "overflow write");
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

    LuaTable parent; // 临时父表，先释放它再检查子表独立引用。
    if (!lua_binding.newTable(parent))
    {
        return lua_binding.pushError();
    }
    require(parent.writeValue("child", child), "parent child write failed");
    parent = LuaTable{}; // 子表独立 registry 引用，父表先销毁不影响子表。
    require(child.readValue("map_id", map_id), "child did not survive parent");
    require(lua_gettop(env->state) == top, "table operations changed stack");
    return lua_binding.returnValues(child, moved);
}

/// 将临时表放入弱值表，返回后由 Lua GC 验证 registry 引用已释放。
/// @param state 参数 1 是 Lua 提供的弱值表，临时对象仅借它观测 GC。
/// @return 无 Lua 返回值；随后由脚本触发 GC 并检查弱引用。
int drop_temporary(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    LuaTable   weak;               // Lua 提供的弱值表，用于观察临时引用释放。
    require(lua_binding.readTable(1, weak), "weak table missing");
    LuaTable temporary; // 本回调唯一强引用的临时表，退出后应能被 GC。
    if (!lua_binding.newTable(temporary))
    {
        return lua_binding.pushError();
    }
    require(weak.writeValue(1, temporary), "weak write failed");
    return lua_binding.returnValues();
}

/// 验证稠密长度和稀疏输入失败时的输出保留。
/// @param state 参数 1 是待检查的数组或混合 key 表，空表也属于合法输入。
/// @return 成功返回稠密长度；稀疏数组返回 nil/error。
int array_lengths(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    LuaTable   table;
    if (!lua_binding.readTable(1, table))
    {
        return lua_binding.pushError();
    }
    std::size_t dense = 99; // 失败后必须仍为此哨兵值。
    if (!table.denseArrayLength(dense))
    {
        require(dense == 99, "dense length changed on failure");
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(dense);
}

/// 按参数选择构造成功或抛错，供 Lua 脚本核对构造与析构次数。
/// @param state 参数 1 是构造失败开关；upvalue 1 借用当前 State 的计数环境。
/// @return 成功返回 Tracked userdata，构造或参数失败返回 nil/error。
int new_tracked(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    auto      *env  = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
    bool       fail = false;                            // Lua 参数指定的构造失败开关。
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
}

/// 读取精确类型 userdata 并返回值和原对象，验证对象身份不变。
/// @param state 参数 1 为待检查的 Tracked userdata，也会测试错误类型和已析构对象。
/// @return 成功依次返回对象载荷与原 userdata，类型或生命周期错误返回 nil/error。
int read_tracked(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    Tracked   *object = nullptr;   // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
    if (!lua_binding.readUserdata(1, kTracked, object))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(object->value, object);
}

/// 重复调用同一 GC 并读取已析构对象，验证析构幂等与失效读取。
/// @param state 参数 1 为活的 Tracked userdata，测试会显式结束其 T 生命周期。
/// @return 重复析构和失效读取检查通过后返回 true。
int userdata_gc_idempotent(lua_State *state)
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
}

/// 拒绝同名类型注册、覆盖 GC、未注册构造及任意指针包装。
/// @param state 无位置参数；upvalue 1 提供构造用的借用测试环境。
/// @return 所有拒绝与输出保留检查通过后返回 true。
int userdata_errors(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    const int stack_top = lua_gettop(state);
    luaL_getmetatable(state, kTracked);
    LuaTable meta;
    require(lua_binding.readTable(-1, meta), "managed metatable missing");
    lua_settop(state, stack_top);
    require(!meta.writeValue("__gc", nullptr), "managed collector could be overwritten");
    LuaTable ordinary;
    require(lua_binding.newTable(ordinary) && ordinary.writeValue("__gc", nullptr),
            "ordinary field incorrectly reserved");
    Tracked *pointer = nullptr; // 闭包或测试宿主传入的外部借用地址，不归 Lua 释放。
    require(!lua_binding.newUserdata("missing.Type", pointer, readTestEnvironment(lua_binding)),
            "unregistered construction accepted");
    int      arbitrary = 0; // 未由封装创建的栈对象，必须拒绝包装为 userdata。
    LuaTable table;
    if (!lua_binding.newTable(table))
    {
        return lua_binding.pushError();
    }
    require(!table.writeValue("arbitrary", &arbitrary), "arbitrary pointer wrapped as userdata");
    return lua_binding.returnValues(true);
}

/// 构造小于一个机器字的 userdata，验证封装没有越界附加对象头。
/// @param state 当前测试 State 的回调栈，无位置参数。
/// @return 返回由 Lua GC 管理的单字节 Tiny userdata。
int new_tiny(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    Tiny      *object = nullptr;   // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
    require(lua_binding.newUserdata(kTiny, object), "tiny construction failed");
    return lua_binding.returnValues(object);
}

/// 读取静态模块注册的 Tiny 方法，验证 userdata 的精确类型与 __index 方法表。
/// @param state 参数 1 是静态模块创建的 Tiny userdata。
/// @return 成功返回对象载荷；类型错误返回 nil/error。
int static_tiny_value(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    Tiny      *object = nullptr;   // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
    if (!lua_binding.readUserdata(1, kStaticTiny, object))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(object->value);
}

/// 创建静态模块注册的 Tiny userdata，交由 Lua GC 负责析构。
/// @param state 当前静态模块函数的调用栈，无位置参数。
/// @return 成功返回 Tiny userdata；构造失败返回 nil/error。
int new_static_tiny(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    Tiny      *object = nullptr;   // 当前 Binding 内借用的 userdata 地址，由 Lua GC 负责释放。
    if (!lua_binding.newUserdata(kStaticTiny, object))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(object);
}

/// 按真实 luaopen 流程静态注册 userdata 方法表并返回模块表。
/// @param state Lua require 提供的 State；初始化失败按原生 Lua 加载错误传播。
/// @return 返回含 new 函数的模块 table。
int open_static_module(lua_State *state)
{
    static const luaL_Reg methods[] = {
        {"value", &LuaBinding::nativeCallback<static_tiny_value>},
        {nullptr, nullptr},
    };
    static const luaL_Reg functions[] = {
        {"new", &LuaBinding::nativeCallback<new_static_tiny>},
        {nullptr, nullptr},
    };
    LuaBinding::registerUserdata<Tiny>(state, kStaticTiny, methods);
    luaL_newlib(state, functions);
    return 1;
}

/// 返回当前 State 的构造、析构计数和单线程 Tiny 析构计数。
/// @param state 无位置参数；upvalue 1 提供当前 State 的独立计数环境。
/// @return 依次返回成功构造数、析构数和 Tiny 析构数。
int counters(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    auto      *env = readTestEnvironment(lua_binding); // 第一个业务 upvalue 指向的独立计数环境。
    return lua_binding.returnValues(env->constructed, env->destroyed, Tiny::destroyed);
}

/// @return 成功返回 map_id，字段或类型错误返回 nil/error。
int read_map(lua_State *state)
{
    LuaBinding    lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    LuaTable      request;            // 位置参数中的请求表，读取它的 map_id。
    std::uint32_t map_id = 0;         // 请求或子表中的地图编号，0 也可读取成功。
    if (!lua_binding.readTable(1, request) || !request.readValue("map_id", map_id))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(map_id);
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
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    return returnManyValues(lua_binding, std::make_index_sequence<64>{});
}

/// 检查大型闭包中最后一个真实 upvalue，保护调用的内部参数不能混入业务编号。
/// @param state 由 make_large_closure 返回的闭包调用栈。
/// @return 第 64 个业务 upvalue，预期为 63。
int many_upvalues(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    int        last = -1;          // 闭包捕获序列末项，读取失败不得覆盖该哨兵。
    require(lua_binding.readUpvalue(64, last), "large closure lost its last upvalue");
    return lua_binding.returnValues(last);
}

/// 验证非法 upvalue 编号不会读取 registry，失败保留读取输出和已有表句柄。
/// @param state 此闭包只有一个业务 upvalue，值为 42。
/// @return 所有编号、输出保留及合法值检查通过时返回 true。
int upvalue_boundaries(lua_State *state)
{
    LuaBinding lua_binding(state); // 本回调的错误与短期引用 owner，不跨调用保存。
    LuaTable   preserved;          // 用于确认失败不会把输出替换成 registry。
    if (!lua_binding.newTable(preserved))
    {
        return lua_binding.pushError();
    }
    require(preserved.writeValue("marker", 17), "upvalue sentinel setup failed");
    for (int index :
         {0, -1, 2, 256, std::numeric_limits<int>::min(), std::numeric_limits<int>::max()})
    {
        int value = 19; // 每轮读取失败后必须保留的整数哨兵。
        require(!lua_binding.readUpvalue(index, value) && value == 19,
                "invalid upvalue read accepted");
        Tracked *object = nullptr; // 非法编号不能读取 registry 或改变借用输出。
        require(!lua_binding.readUpvalueUserdata(index, kTracked, object) && object == nullptr,
                "invalid userdata upvalue accepted");
    }
    int marker = 0; // 仍应从原表读取，而不是从 registry 或新表读取。
    int value  = 0; // 合法业务 upvalue 必须仍为初始值，证明非法读取没有污染它。
    require(preserved.readValue("marker", marker) && marker == 17,
            "upvalue failure changed table output");
    require(lua_binding.readUpvalue(1, value) && value == 42, "upvalue failure changed closure");
    return lua_binding.returnValues(true);
}

/// 让 C++ 异常经过真实 Lua 回调，验证不会越过 C ABI。
/// @param state 参数 1 选择 bad_alloc 或普通意外异常。
/// @return 正常路径不返回；注册入口将异常转换为 nil 和 INTERNAL_ERROR。
int native_exception(lua_State *state)
{
    if (lua_toboolean(state, 1))
    {
        throw std::bad_alloc();
    }
    throw std::runtime_error("injected native exception");
}

/// require 加载失败模块，不得把 nil/error 当成成功模块并缓存 true。
/// @param state Lua loader 提供的模块名等参数。
/// @return 失败按 Lua 加载错误传播，不正常返回。
int failing_module(lua_State *state)
{
    // 托管类型注册拒绝覆盖析构方法；按原生 Lua 模块加载错误传播。
    static const luaL_Reg methods[] = {
        {"__gc", &LuaBinding::nativeCallback<native_exception>},
        {nullptr, nullptr},
    };
    LuaBinding::registerUserdata<Tracked>(state, "binding.Invalid", methods);
    lua_newtable(state);
    return 1;
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
/// @return 成功返回表；Lua OOM 经注册入口返回错误结果或在持续 OOM 时抛 Lua 错误。
int allocation_failure(lua_State *state)
{
    auto *env = static_cast<TestEnvironment *>(
        lua_touserdata(state, lua_upvalueindex(1))); // 故障前注册的测试 owner。
    BoundaryResource resource(env);                  // 必须先于任何可能失败的封装分配建立析构观测。
    LuaBinding       lua_binding(state);             // 本回调的错误与短期引用 owner，不跨调用保存。
    Tracked         *object = nullptr; // 构造成功后由 Lua GC 管理，不能因后续表分配失败而泄漏。
    if (!lua_binding.newUserdata(kTracked, object, env))
    {
        return lua_binding.pushError();
    }
    LuaTable table; // 字符串、字段扩容、registry 引用分别经过受保护操作。
    if (!lua_binding.newTable(table))
    {
        return lua_binding.pushError();
    }
    const std::string payload(4096, 'x'); // 本地 C++ 字节串，Lua OOM 后也必须析构。
    require(table.writeValue("payload", payload), "allocation probe field write failed");
    require(table.writeValue("object", object), "allocation probe userdata write failed");
    return lua_binding.returnValues(table);
}

/// 注册本 State 独占的测试类型和回调，把借用测试环境传入需要计数的闭包。
/// @param state 参数 1 为测试宿主持有的 TestEnvironment lightuserdata 地址。
/// @return 返回注册完成的测试模块表。
int registerTestModule(lua_State *state)
{
    LuaBinding::registerUserdata<Tracked>(state, kTracked, nullptr);
    LuaBinding::registerUserdata<Tiny>(state, kTiny, nullptr);
    lua_newtable(state);
    luaL_checkstack(state, 64, "test closure upvalues");
    for (int index = 0; index < 64; ++index)
    {
        lua_pushinteger(state, index);
    }
    lua_pushcclosure(state, &LuaBinding::nativeCallback<many_upvalues>, 64);
    lua_setfield(state, -2, "many_upvalues");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<uint>);
    lua_setfield(state, -2, "uint");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<uint64>);
    lua_setfield(state, -2, "uint64");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<signed_value>);
    lua_setfield(state, -2, "signed");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<byte>);
    lua_setfield(state, -2, "byte");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<boolean>);
    lua_setfield(state, -2, "boolean");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<string>);
    lua_setfield(state, -2, "string");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<float_value>);
    lua_setfield(state, -2, "float");
    lua_pushvalue(state, 1);
    lua_pushcclosure(state, &LuaBinding::nativeCallback<conversion_boundaries>, 1);
    lua_setfield(state, -2, "conversion_boundaries");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<invalid_return>);
    lua_setfield(state, -2, "invalid_return");
    lua_pushvalue(state, 1);
    lua_pushcclosure(state, &LuaBinding::nativeCallback<table_operations>, 1);
    lua_setfield(state, -2, "table_operations");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<drop_temporary>);
    lua_setfield(state, -2, "drop_temporary");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<array_lengths>);
    lua_setfield(state, -2, "array_lengths");
    lua_pushvalue(state, 1);
    lua_pushcclosure(state, &LuaBinding::nativeCallback<new_tracked>, 1);
    lua_setfield(state, -2, "new_tracked");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<read_tracked>);
    lua_setfield(state, -2, "read_tracked");
    lua_pushvalue(state, 1);
    lua_pushcclosure(state, &LuaBinding::nativeCallback<userdata_errors>, 1);
    lua_setfield(state, -2, "userdata_errors");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<userdata_gc_idempotent>);
    lua_setfield(state, -2, "userdata_gc_idempotent");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<new_tiny>);
    lua_setfield(state, -2, "new_tiny");
    lua_pushvalue(state, 1);
    lua_pushcclosure(state, &LuaBinding::nativeCallback<counters>, 1);
    lua_setfield(state, -2, "counters");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<read_map>);
    lua_setfield(state, -2, "read_map");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<many_values>);
    lua_setfield(state, -2, "many_values");
    lua_pushinteger(state, 42);
    lua_pushcclosure(state, &LuaBinding::nativeCallback<upvalue_boundaries>, 1);
    lua_setfield(state, -2, "upvalue_boundaries");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<native_exception>);
    lua_setfield(state, -2, "native_exception");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<failing_module>);
    lua_setfield(state, -2, "failing_module");
    lua_pushcfunction(state, &LuaBinding::nativeCallback<open_static_module>);
    lua_setfield(state, -2, "open_static_module");
    return 1;
}

// 对照基线仅用于测量同一个固定参数的 raw 读取，不作为生产模块或新公开接口。
/// 按同一 uint32 范围读取 request.map_id，作为封装读表的 raw 性能对照。
/// @param state 参数 1 为同一性能对照请求表，raw 读取其 uint32 map_id。
/// @return 成功返回 map_id，范围或类型错误只返回 nil，作为固定 raw 性能基线。
int raw_read_map(lua_State *state)
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
    lua_pushcfunction(state.get(), &LuaBinding::nativeCallback<registerTestModule>);
    lua_pushlightuserdata(state.get(), environment);
    lua_call(state.get(), 1, 1);
    lua_setglobal(state.get(), "binding");
    // 注册只用于性能对照的 raw 回调：push 函数后 setglobal 消耗函数，栈仍为空。
    lua_pushcfunction(state.get(), &LuaBinding::nativeCallback<raw_read_map>);
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
local length = binding.array_lengths({})
assert(length == 0)
length = binding.array_lengths({[0]=7,[-1]=8,[1]=9,[2]=10,source="config",[1.5]="ignored"})
assert(length == 2)
length = binding.array_lengths(setmetatable({1,2}, {
    __len = function() error("raw length invoked __len") end,
}))
assert(length == 2)
local sparse, err = binding.array_lengths({[1]=7,[3]=8})
assert(sparse == nil and err.code == "INVALID_ARGUMENT")
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
local closure
 do
    local captured = binding.new_tracked(false)
    closure = function() return binding.read_tracked(captured) end
 end
collectgarbage("collect")
assert(closure() == 7)
created, destroyed = binding.counters()
assert(created == 2 and destroyed == 1, "closure did not retain userdata")
closure = nil
collectgarbage("collect")
created, destroyed = binding.counters()
assert(created == 2 and destroyed == 2, "closure userdata leaked")
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
        lua_pushcclosure(state.get(), &LuaBinding::nativeCallback<allocation_failure>, 1);
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
        runScript(first.get(), R"lua(
            package.preload.flywow_binding_static = binding.open_static_module
            local module = require "flywow_binding_static"
            assert(require "flywow_binding_static" == module, "module was not cached")
            local object = module.new()
            assert(object:value() == 3, "static userdata method was not registered")
            object = nil
            collectgarbage("collect")
            local _, _, tiny_destroyed = binding.counters()
            assert(tiny_destroyed == 3, "static userdata collector did not release its object")
        )lua");
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
            assert(binding.many_upvalues() == 63)
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
