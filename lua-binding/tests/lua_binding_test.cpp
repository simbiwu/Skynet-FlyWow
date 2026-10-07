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
void require(bool condition, const char *message)
{
    if (!condition)
    {
        throw std::runtime_error(message); // 不用 assert，Release 构建也必须执行检查。
    }
}

struct TestEnvironment
{
    lua_State *state       = nullptr; // 只借用本测试 State，用于直接观测封装操作的栈高度。
    int        constructed = 0;
    int        destroyed   = 0;
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
    TestEnvironment *owner;
    int              value = 7;
};

struct Tiny
{
    ~Tiny() noexcept
    {
        ++destroyed;
    }
    unsigned char value = 3;
    static int    destroyed; // 测试单线程的析构观测值；不是封装 Runtime 全局状态。
};
int Tiny::destroyed = 0;

struct Other
{
    TestEnvironment *owner = nullptr;
    int              value = 0;
};
static_assert(sizeof(Other) == sizeof(Tracked), "conflict must check type, not only size");

constexpr const char *kTracked = "flywow_binding_test.Tracked";
constexpr const char *kTiny    = "flywow_binding_test.Tiny";

TestEnvironment *environment(LuaBinding &lua_binding)
{
    void *pointer = nullptr;
    require(lua_binding.readUpvalue(1, pointer), "missing test environment");
    return static_cast<TestEnvironment *>(pointer);
}

template <typename T> int echo(LuaBinding &lua_binding)
{
    T value{};
    if (!lua_binding.readValue(1, value))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(value);
}

int conversionBoundaries(LuaBinding &lua_binding)
{
    auto         *env   = environment(lua_binding);
    const int     top   = lua_gettop(env->state);
    std::uint32_t value = 19;
    require(!lua_binding.readValue(0, value) && value == 19, "zero index changed output");
    require(!lua_binding.readValue(top + 1, value), "positive overflow accepted");
    require(!lua_binding.readValue(-top - 1, value), "negative overflow accepted");

    LuaTable original = lua_binding.newTable();
    require(original.writeValue("retained", 1), "initial table write failed");
    require(!lua_binding.readTable(1, original), "non-table accepted");
    int retained = 0;
    require(original.readValue("retained", retained) && retained == 1, "table output replaced");
    require(lua_gettop(env->state) == top, "conversion changed stack");
    return lua_binding.returnValues(true);
}

int invalidReturn(LuaBinding &lua_binding)
{
    return lua_binding.returnValues(1, std::numeric_limits<std::uint64_t>::max());
}

int invalidCallback(LuaBinding &)
{
    return 1;
}
int throwCallback(LuaBinding &)
{
    throw std::runtime_error("callback failed");
}
int throwUnknown(LuaBinding &)
{
    throw 42;
}

int tableOperations(LuaBinding &lua_binding)
{
    auto     *env = environment(lua_binding);
    const int top = lua_gettop(env->state);
    LuaTable  input;
    LuaTable  child;
    require(lua_binding.readTable(input), "implicit top table read failed");
    require(input.readTable("child", child), "child read failed");
    std::uint32_t map_id = 0;
    require(child.readValue("map_id", map_id) && map_id == 17, "nested field read failed");
    require(!input.readValue("missing", map_id) && map_id == 17, "missing changed output");

    auto moved = std::move(input);
    require(!input.valid() && moved.valid(), "table move failed");
    require(!moved.writeValue("kept", std::numeric_limits<std::uint64_t>::max()), "overflow write");
    require(!moved.writeValue(std::numeric_limits<std::uint64_t>::max(), 1),
            "overflow key accepted");
    require(!moved.readValue(std::numeric_limits<std::uint64_t>::max(), map_id),
            "overflow key read");
    int kept = 0;
    require(moved.readValue("kept", kept) && kept == 9, "failed write changed field");
    require(moved.writeValue("fresh", 11), "raw write invoked input __newindex");

    // key/value 内嵌零字节都按完整长度保存；nullptr 删除字段。
    const std::string key("k\0z", 3);
    const std::string text("v\0z", 3);
    std::string       result;
    require(child.writeValue(key, text) && child.readValue(key, result) && result == text,
            "binary string lost");
    require(child.writeValue(key, nullptr) && child.isNil(key), "nil delete failed");
    require(child.writeValue(0, false) && child.writeValue(-1, 0), "integer keys rejected");
    bool truth = false;
    require(child.readTruth(-1, truth) && truth, "zero truth changed");
    require(child.readTruth(0, truth) && !truth, "false truth changed");

    auto parent = lua_binding.newTable();
    require(parent.writeValue("child", child), "parent child write failed");
    parent = LuaTable{}; // 子表独立 registry 引用，父表先销毁不影响子表。
    require(child.readValue("map_id", map_id), "child did not survive parent");
    require(lua_gettop(env->state) == top, "table operations changed stack");
    return lua_binding.returnValues(child, moved);
}

int dropTemporary(LuaBinding &lua_binding)
{
    LuaTable weak;
    require(lua_binding.readTable(1, weak), "weak table missing");
    auto temporary = lua_binding.newTable();
    require(weak.writeValue(1, temporary), "weak write failed");
    return lua_binding.returnValues();
}

int arrayLengths(LuaBinding &lua_binding)
{
    LuaTable table;
    if (!lua_binding.readTable(1, table))
    {
        return lua_binding.pushError();
    }
    std::size_t raw   = 0;
    std::size_t dense = 99; // 失败后必须仍为此哨兵值。
    require(table.arrayLength(raw), "raw length failed");
    if (!table.denseArrayLength(dense))
    {
        require(dense == 99, "dense length changed on failure");
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(raw, dense);
}

int iterate(LuaBinding &lua_binding)
{
    auto     *env = environment(lua_binding);
    const int top = lua_gettop(env->state);
    LuaTable  table;
    require(lua_binding.readTable(1, table), "iterate input missing");
    int numeric_keys = 0;
    int children     = 0;
    require(table.forEach(
                [&](const LuaValue &key, const LuaValue &value)
                {
                    if (key.type() == LuaType::kNumber)
                    {
                        std::int64_t integer = 0;
                        require(key.readValue(integer), "numeric key lost");
                        std::string unchanged = "unchanged";
                        require(!key.readValue(unchanged) && unchanged == "unchanged",
                                "numeric key mutated");
                    }
                    if (value.type() == LuaType::kTable)
                    {
                        LuaTable child;
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
}

int countMetamethod(LuaBinding &lua_binding)
{
    return lua_binding.returnValues(23);
}

int metatables(LuaBinding &lua_binding)
{
    LuaTable meta;
    LuaTable same;
    bool     created = false;
    require(lua_binding.registerMetatable("flywow_binding_test.Meta", meta, created) && created,
            "first metatable registration");
    require(meta.setFunction("__index", &countMetamethod), "metamethod registration");
    require(lua_binding.registerMetatable("flywow_binding_test.Meta", same, created) && !created,
            "repeat metatable registration");
    auto table = lua_binding.newTable();
    require(table.setMetatable(meta), "setmetatable failed");
    LuaTable read_meta;
    require(table.readMetatable(read_meta), "readmetatable failed");
    require(read_meta.writeValue("marker", 11), "meta write failed");
    int marker = 0;
    require(same.readValue("marker", marker) && marker == 11, "metatable identity lost");
    return lua_binding.returnValues(table);
}

int newTracked(LuaBinding &lua_binding)
{
    auto *env  = environment(lua_binding);
    bool  fail = false;
    if (!lua_binding.readValue(1, fail))
    {
        return lua_binding.pushError();
    }
    Tracked *object = nullptr;
    if (!lua_binding.newUserdata(kTracked, object, env, fail))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(object);
}

int readTracked(LuaBinding &lua_binding)
{
    Tracked *object = nullptr;
    if (!lua_binding.readUserdata(1, kTracked, object))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(object->value, object);
}

int userdataErrors(LuaBinding &lua_binding)
{
    LuaTable meta;
    bool     created = true;
    require(lua_binding.registerUserdata<Tracked>(kTracked, meta, created) && !created,
            "same type registration failed");
    LuaTable output = lua_binding.newTable();
    require(output.writeValue("retained", 41), "registration output setup failed");
    require(!lua_binding.registerUserdata<Other>(kTracked, output, created),
            "same name different type accepted");
    require(output.valid(), "failed registration changed output");
    int retained = 0;
    require(output.readValue("retained", retained) && retained == 41,
            "failed registration replaced output reference");
    require(!meta.setFunction("__gc", &countMetamethod), "GC overwritten by registration");
    require(!meta.writeValue("__gc", nullptr), "GC removed by field write");
    Tracked *pointer = nullptr;
    require(!lua_binding.newUserdata("missing.Type", pointer, environment(lua_binding)),
            "unregistered construction accepted");
    Other arbitrary;
    auto  table = lua_binding.newTable();
    require(!table.writeValue("arbitrary", &arbitrary), "arbitrary pointer wrapped as userdata");
    return lua_binding.returnValues(true);
}

int newTiny(LuaBinding &lua_binding)
{
    Tiny *object = nullptr;
    require(lua_binding.newUserdata(kTiny, object), "tiny construction failed");
    return lua_binding.returnValues(object);
}

int counters(LuaBinding &lua_binding)
{
    auto *env = environment(lua_binding);
    return lua_binding.returnValues(env->constructed, env->destroyed, Tiny::destroyed);
}

int useClosure(LuaBinding &lua_binding)
{
    int      counter = 0;
    LuaTable captured;
    void    *pointer = nullptr;
    Tracked *object  = nullptr;
    if (!lua_binding.readUpvalue(1, counter) || !lua_binding.readUpvalueTable(2, captured) ||
        !lua_binding.readUpvalue(3, pointer) ||
        !lua_binding.readUpvalueUserdata(4, kTracked, object))
    {
        return lua_binding.pushError();
    }
    int marker = 0;
    require(captured.readValue("marker", marker) && marker == 17, "captured table lost");
    require(object->owner == pointer, "borrowed pointer changed");
    require(lua_binding.writeUpvalue(1, counter + 1), "upvalue update failed");
    require(!lua_binding.readUpvalue(0, marker) && !lua_binding.readUpvalue(5, marker),
            "invalid business upvalue accepted");
    return lua_binding.returnValues(counter, object);
}

int makeClosure(LuaBinding &lua_binding)
{
    auto    *env    = environment(lua_binding);
    Tracked *object = nullptr;
    require(lua_binding.newUserdata(kTracked, object, env), "captured object creation");
    auto captured = lua_binding.newTable();
    require(captured.writeValue("marker", 17), "captured table setup");
    auto functions = lua_binding.newTable();
    require(
        functions.setFunction("run", &useClosure, 0, captured, static_cast<void *>(env), object),
        "closure registration failed");
    return lua_binding.returnValues(functions);
}

int maxUpvalue(LuaBinding &lua_binding)
{
    int value = -1;
    require(lua_binding.readUpvalue(254, value) && value == 253, "last business upvalue wrong");
    require(lua_binding.writeUpvalue(254, 19) && lua_binding.readUpvalue(254, value) &&
                value == 19,
            "last business upvalue update failed");
    return lua_binding.returnValues(true);
}

template <std::size_t... I> bool manyUpvalues(LuaTable &module, std::index_sequence<I...>)
{
    return module.setFunction("max_upvalue", &maxUpvalue, static_cast<int>(I)...);
}

int readMap(LuaBinding &lua_binding)
{
    LuaTable      request;
    std::uint32_t map_id = 0;
    if (!lua_binding.readTable(1, request) || !request.readValue("map_id", map_id))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(map_id);
}

int initializeTest(LuaBinding &lua_binding)
{
    void *pointer = nullptr;
    require(lua_binding.readValue(1, pointer), "test setup pointer missing");
    auto     module = lua_binding.newTable();
    LuaTable meta;
    bool     created = false;
    require(lua_binding.registerUserdata<Tracked>(kTracked, meta, created) && created,
            "tracked registration failed");
    require(lua_binding.registerUserdata<Tiny>(kTiny, meta, created) && created,
            "tiny registration failed");
    require(module.setFunction("uint", &echo<std::uint32_t>) &&
                module.setFunction("uint64", &echo<std::uint64_t>) &&
                module.setFunction("signed", &echo<std::int64_t>) &&
                module.setFunction("byte", &echo<std::int8_t>) &&
                module.setFunction("boolean", &echo<bool>) &&
                module.setFunction("string", &echo<std::string>) &&
                module.setFunction("float", &echo<float>),
            "scalar registration failed");
    require(module.setFunction("conversion_boundaries", &conversionBoundaries, pointer) &&
                module.setFunction("invalid_return", &invalidReturn) &&
                module.setFunction("invalid_callback", &invalidCallback) &&
                module.setFunction("throw_callback", &throwCallback) &&
                module.setFunction("throw_unknown", &throwUnknown) &&
                module.setFunction("table_operations", &tableOperations, pointer) &&
                module.setFunction("drop_temporary", &dropTemporary) &&
                module.setFunction("array_lengths", &arrayLengths) &&
                module.setFunction("iterate", &iterate, pointer) &&
                module.setFunction("metatables", &metatables) &&
                module.setFunction("new_tracked", &newTracked, pointer) &&
                module.setFunction("read_tracked", &readTracked) &&
                module.setFunction("userdata_errors", &userdataErrors, pointer) &&
                module.setFunction("new_tiny", &newTiny) &&
                module.setFunction("counters", &counters, pointer) &&
                module.setFunction("make_closure", &makeClosure, pointer) &&
                module.setFunction("read_map", &readMap),
            "operation registration failed");
    require(manyUpvalues(module, std::make_index_sequence<254>{}),
            "254 business upvalues rejected");
    require(!manyUpvalues(module, std::make_index_sequence<255>{}),
            "255 business upvalues accepted");
    return lua_binding.returnValues(module);
}

int openTest(lua_State *state)
{
    return LuaBinding::initialize(state, &initializeTest);
}

// 对照基线仅用于测量同一个固定参数的 raw 读取，不作为生产模块或新公开接口。
int rawReadMap(lua_State *state)
{
    lua_pushliteral(state, "map_id");
    lua_rawget(state, 1);
    const lua_Integer value = lua_tointeger(state, -1);
    if (!lua_isinteger(state, -1) || value < 0 ||
        static_cast<std::uint64_t>(value) > std::numeric_limits<std::uint32_t>::max())
    {
        lua_pushnil(state);
        return 1;
    }
    return 1;
}

void run(lua_State *state, const char *script)
{
    if (luaL_dostring(state, script) != LUA_OK)
    {
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

std::unique_ptr<lua_State, StateDeleter> createState(TestEnvironment *environment)
{
    std::unique_ptr<lua_State, StateDeleter> state(luaL_newstate());
    require(state != nullptr, "State creation failed");
    environment->state = state.get();
    luaL_openlibs(state.get());
    lua_pushcfunction(state.get(), &openTest);
    lua_pushlightuserdata(state.get(), environment);
    lua_call(state.get(), 1, 1);
    lua_setglobal(state.get(), "binding");
    lua_pushcfunction(state.get(), &rawReadMap);
    lua_setglobal(state.get(), "raw_read_map");
    return state;
}

const char *kScalarTests = R"lua(
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
failure(binding.invalid_callback, "INTERNAL_ERROR")
failure(binding.throw_callback, "INTERNAL_ERROR")
failure(binding.throw_unknown, "INTERNAL_ERROR")
failure(binding.new_tracked, "INTERNAL_ERROR", true)
local created, destroyed = binding.counters()
assert(created == 0 and destroyed == 0, "failed constructor was destroyed")
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
local meta = getmetatable(object)
meta.__gc(object)
meta.__gc(object)
bad, err = binding.read_tracked(object)
assert(bad == nil and err.code == "INVALID_ARGUMENT")
object = nil
tiny = nil
collectgarbage("collect")
local created, destroyed, tiny_destroyed = binding.counters()
assert(created == 1 and destroyed == 1 and tiny_destroyed == 1, "duplicate or missing destructor")
local closure = binding.make_closure()
collectgarbage("collect")
assert(closure.run() == 0 and closure.run() == 1)
assert(binding.max_upvalue())
created, destroyed = binding.counters()
assert(created == 2 and destroyed == 1, "closure did not retain userdata")
closure = nil
collectgarbage("collect")
created, destroyed = binding.counters()
assert(created == 2 and destroyed == 2, "closure registry reference leaked")
)lua";

void measure(lua_State *state)
{
    const auto begin = std::chrono::steady_clock::now();
    run(state, "local t={map_id=17}; for i=1,100000 do assert(raw_read_map(t)==17) end");
    const auto middle = std::chrono::steady_clock::now();
    run(state, "local t={map_id=17}; for i=1,100000 do assert(binding.read_map(t)==17) end");
    const auto end = std::chrono::steady_clock::now();
    std::cout << "READ_TABLE_100000 raw_us="
              << std::chrono::duration_cast<std::chrono::microseconds>(middle - begin).count()
              << " binding_us="
              << std::chrono::duration_cast<std::chrono::microseconds>(end - middle).count()
              << '\n';
}

void testConcurrentStates()
{
    // 每个 OS Thread 独占自己的 State 和 Environment；同一 State 不并发访问。
    std::array<std::exception_ptr, 4> errors{};
    std::array<std::thread, 4>        workers;
    for (std::size_t i = 0; i < workers.size(); ++i)
    {
        workers[i] = std::thread(
            [&, i]()
            {
                try
                {
                    TestEnvironment env;
                    auto            state = createState(&env);
                    run(state.get(), "for i=1,100 do local o=binding.new_tracked(false); "
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

int main()
{
    try
    {
        TestEnvironment first_env;
        TestEnvironment second_env;
        auto            first  = createState(&first_env);
        auto            second = createState(&second_env);
        run(first.get(), kScalarTests);
        run(first.get(), kTableTests);
        run(first.get(), kUserdataTests);
        // 第二个 State 拥有独立 metatable/registry/闭包，只读 T 标记允许共享。
        run(second.get(), "assert(binding.uint(0)==0); object=binding.new_tracked(false)");
        require(first_env.constructed == 2 && second_env.constructed == 1, "State counters shared");
        run(first.get(), "collectgarbage('collect')");
        require(second_env.destroyed == 0, "other State GC touched object");
        second.reset(); // lua_close 也必须执行仍存活对象的统一 __gc。
        require(second_env.destroyed == 1, "State close missed destructor");
        testConcurrentStates();
        measure(first.get());
        std::cout << "FLYWOW_LUA_BINDING_TEST_OK\n";
    }
    catch (const std::exception &exception)
    {
        std::cerr << exception.what() << '\n';
        return 1;
    }
    return 0;
}
