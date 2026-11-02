// 使用宿主 Lua ABI 验证数据树、Lua 行为、GC 和独立 .so 之间的类型互操作。
// 同一文件分别编译测试宿主和两个 Native fixture，避免新增另一套生产接入实现。
#include "lua_native_data.h"
extern "C"
{
#include <lualib.h>
}
#include <iostream>
#include <stdexcept>

using namespace flywow_lua_binding;

#if defined(NATIVE_DATA_PEER_a) || defined(NATIVE_DATA_PEER_b)
// 独立 Native .so 创建根；测试必须在 require NativeData 模块之前调用。
int create(lua_State *state)
{
    LuaBinding binding(state);                           // 当前回调的统一返回入口。
    auto       root = std::make_shared<LuaNativeData>(); // 此回调创建的根 owner。
    root->set("hp", std::int64_t{1000});
    return binding.returnValues(root);
}

// 将另一个 .so 返回的根或子代理交给 readNativeData，并直接修改 Native 字段。
int update(lua_State *state)
{
    LuaBinding     binding(state); // 保活参数 userdata 到同步调用结束。
    LuaNativeData *node = nullptr; // 本回调借用，不跨回调保存。
    if (!binding.readNativeData(1, node))
    {
        return binding.pushError();
    }
    node->set("hp", std::int64_t{1500});
    return 0;
}

#ifdef NATIVE_DATA_PEER_a
extern "C" int luaopen_native_data_peer_a(lua_State *state)
#else
extern "C" int luaopen_native_data_peer_b(lua_State *state)
#endif
{
    static const luaL_Reg functions[] = {
        {"create", LuaBinding::nativeCallback<create>},
        {"update", LuaBinding::nativeCallback<update>},
        {nullptr, nullptr},
    };
    luaL_newlib(state, functions);
    return 1;
}
#else
// 不依赖 NDEBUG 的断言，Release 构建也必须验证行为。
void check(bool condition, const char *message)
{
    if (!condition)
    {
        throw std::runtime_error(message);
    }
}

// 执行独立 Lua 场景；错误对象在输出后弹出，失败抛给测试主入口。
void run(lua_State *state, const char *source)
{
    if (luaL_dostring(state, source) != LUA_OK)
    {
        const char *message = lua_tostring(state, -1); // Lua 栈保活的错误文本。
        std::string failure = message ? message : "non-string Lua failure"; // 抛错前复制。
        lua_pop(state, 1);
        throw std::runtime_error(failure);
    }
}

// 闭包 upvalue 借用测试主函数持有的根 owner 地址；它覆盖整个 Lua State 生命周期。
int retained_root(lua_State *state)
{
    auto *owner =
        static_cast<std::shared_ptr<LuaNativeData> *>(lua_touserdata(state, lua_upvalueindex(1)));
    LuaBinding binding(state); // 与业务 Native 模块相同的返回入口。
    return binding.returnValues(*owner);
}

int main(int argc, char **argv)
{
    if (argc != 3)
    {
        return 2;
    }
    lua_State *state = nullptr; // 测试唯一 owner，正常和失败出口均关闭。
    try
    {
        auto root = std::make_shared<LuaNativeData>(); // C++ API 独立验证所用根。
        root->set("hp", std::int64_t{1});
        root->set(std::int64_t{1}, false);
        root->set(std::int64_t{3}, 3.0);
        check(root->size() == 3 && root->arrayLength() == 1, "C++ field/array size");
        check(!root->get("missing"), "C++ missing");
        auto child = std::make_unique<LuaNativeData>(); // 移动前由本作用域持有的子树。
        child->set("x", std::int64_t{9});
        auto child_state = child->proxyState(); // 只观察失效，不拥有子树。
        root->set("child", std::move(child));
        auto copy = root->clone(); // 独立树，后续修改不能影响来源。
        check(copy->proxyState() != root->proxyState(), "clone identity");
        root->erase("child");
        check(!child_state->node && copy->get("child"), "erase invalidation/clone independence");
        bool rejected = false; // C++ 公开写入入口应拒绝空独占子树。
        try
        {
            root->set("hp", std::unique_ptr<LuaNativeData>{});
        }
        catch (const std::invalid_argument &)
        {
            rejected = true;
        }
        check(rejected && std::get<std::int64_t>(*root->get("hp")) == 1, "null child atomicity");

        state = luaL_newstate();
        check(state != nullptr, "Lua State allocation");
        luaL_openlibs(state);
        lua_getglobal(state, "package");
        std::string cpath =
            std::string(argv[1]) + "/?.so;" + argv[2] + "/?.so"; // 两类真实 .so 搜索路径。
        lua_pushlstring(state, cpath.data(), cpath.size());
        lua_setfield(state, -2, "cpath");
        lua_pop(state, 1);

        auto owner = std::make_shared<LuaNativeData>(); // C++ 跨回调保留根所有权。
        owner->set("hp", std::int64_t{100});
        std::weak_ptr<LuaNativeData> weak = owner; // 仅用于观测根最终释放。
        lua_pushlightuserdata(state, &owner);
        lua_pushcclosure(state, LuaBinding::nativeCallback<retained_root>, 1);
        lua_setglobal(state, "retained_root");
        run(state, R"lua(
            local a = require "native_data_peer_a"
            local b = require "native_data_peer_b"
            assert(package.loaded.flywow_native_data == nil)
            local p = a.create()
            b.update(p)
            assert(p.hp == 1500)
            local q = b.create()
            a.update(q)
            assert(q.hp == 1500)
            local result, err = a.update({})
            assert(result == nil and err.code == "INVALID_ARGUMENT")
            local NativeData = require "flywow_native_data"
            local d = NativeData.new()
            assert(type(d) == "userdata" and d.missing == nil)
            d.flag = false; d[1] = "one"; d[2] = "two"; d[4] = "four"; d["1"] = 77
            d.integer = math.maxinteger; d.number = 1.25
            d.binary = "a\0b"
            d["k\0z"] = "v\0x"
            assert(d.flag == false and d.integer == math.maxinteger and math.type(d.number) == "float")
            assert(d.binary == "a\0b" and d["k\0z"] == "v\0x" and d["1"] == 77 and d[1] == "one")
            assert(#d == 2)
            local n = 0
            for i, value in ipairs(d) do n = n + 1; assert(value == d[i]) end
            assert(n == 2)
            n = 0
            for key, value in pairs(d) do n = n + 1; assert(value == d[key]) end
            assert(n == 9)
            local sub = { hp = 10 }
            d.source = setmetatable({a = sub, b = sub}, {__pairs = function() error("must use raw fields") end})
            sub.hp = 99
            assert(d.source.a.hp == 10 and d.source.b.hp == 10)
            assert(d.source.a ~= d.source.b)
            local first = d.source.a
            assert(first == d.source.a)
            first.hp = 20
            assert(d.source.a.hp == 20 and d.source.b.hp == 10)
            d.copy = first
            assert(d.copy ~= first and d.copy.hp == 20)
            b.update(d.copy)
            assert(d.copy.hp == 1500)
            d.copy = d.copy
            assert(d.copy.hp == 1500)
            local old_copy = d.copy
            d.copy = nil
            local function expired(f)
                local ok, message = pcall(f)
                assert(not ok and message:find("LuaNativeData node has expired", 1, true))
            end
            expired(function() return old_copy.hp end)
            expired(function() old_copy.hp = 1 end)
            expired(function() return #old_copy end)
            expired(function() return pairs(old_copy) end)
            local old = d.source
            local iter, container, key = pairs(old)
            d.source = { hp = 3 }
            expired(function() return iter(container, key) end)
            assert(old == old)
            -- 超过默认 C 回调栈空间的合法嵌套必须成功导入，底部错误仍保留旧字段。
            local deep = { leaf = 42 }
            local cursor = deep
            for i = 1, 256 do cursor.child = {}; cursor = cursor.child end
            cursor.value = 123
            d.deep = deep
            cursor = d.deep
            for i = 1, 256 do cursor = cursor.child end
            assert(cursor.value == 123)
            cursor = deep
            for i = 1, 256 do cursor = cursor.child end
            cursor.bad = function() end
            assert(not pcall(function() d.source = deep end))
            assert(d.source.hp == 3)
            local cyc = {}; cyc.self = cyc
            local ok = pcall(function() d.source = cyc end)
            assert(not ok and d.source.hp == 3)
            for _, bad in ipairs({function() end, coroutine.create(function() end), io.stdout}) do
                assert(not pcall(function() d.source = { bad = bad } end))
                assert(d.source.hp == 3)
            end
            for _, key_bad in ipairs({true, {}, 1.5}) do
                assert(not pcall(function() d[key_bad] = 1 end))
            end
            assert(not pcall(function() return d[1.0] end))
            assert(not pcall(function() d.source = {[true] = 1} end))
            d.flag = nil; assert(d.flag == nil)
            local root = NativeData.new(); root.child = {hp = 1}
            local borrowed = root.child
            root = nil; collectgarbage("collect")
            expired(function() return borrowed.hp end)
            local stale, e = a.update(borrowed)
            assert(stale == nil and e.code == "INVALID_ARGUMENT")
            -- 仅持有子代理时，压入嵌套结果或 pairs 输出可能触发根 GC。
            -- 允许根在访问前已失效；无论时机如何，都不能解引用已销毁字段。
            for i = 1, 500 do
                collectgarbage("stop")
                local transient = NativeData.new()
                transient.child = { nested = { hp = i }, text = string.rep("x", 1024) }
                local subproxy = transient.child
                transient = nil
                collectgarbage("restart")
                local ok, message = pcall(function()
                    local nested = subproxy.nested
                    assert(nested.hp == i)
                    local count = 0
                    for k, v in pairs(subproxy) do
                        count = count + 1
                        if k == "nested" then
                            assert(v.hp == i)
                        else
                            assert(k == "text" and v == string.rep("x", 1024))
                        end
                    end
                    assert(count == 2)
                end)
                if not ok then
                    assert(type(message) == "string"
                        and message:find("LuaNativeData node has expired", 1, true))
                end
                collectgarbage("collect")
                expired(function() return subproxy.text end)
            end
            local _, light = debug.getupvalue(retained_root, 1)
            assert(not pcall(function() d.source = light end))
            assert(not pcall(function() d[nil] = 1 end))
            kept = retained_root()
            local same = retained_root()
            assert(same == kept)
            kept.hp = 500
            kept.child = { hp = 7 }
            borrowed_kept = kept.child
            same = nil; kept = nil; collectgarbage("collect")
            assert(borrowed_kept.hp == 7)
        )lua");
        check(std::get<std::int64_t>(*owner->get("hp")) == 500, "Lua writes visible in C++");
        owner->set("hp", std::int64_t{600});
        run(state, "kept = retained_root(); assert(kept.hp == 600)");
        owner.reset();
        check(!weak.expired(), "Lua root must retain root");
        run(state, "kept = nil; collectgarbage('collect'); assert(not pcall(function() return "
                   "borrowed_kept.hp end))");
        check(weak.expired(), "child proxy must not retain root");
        check(lua_gettop(state) == 0, "test scenarios leave balanced stack");
        lua_close(state);
        state = nullptr;
        std::cout << "FLYWOW_NATIVE_DATA_OK" << std::endl;
        return 0;
    }
    catch (const std::exception &error)
    {
        std::cerr << error.what() << std::endl;
        if (state)
        {
            lua_close(state);
        }
        return 1;
    }
}
#endif
