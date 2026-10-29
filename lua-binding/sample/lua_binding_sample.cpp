#include "lua_binding.h"
#include "lua_table.h"

#include <cstdint>
#include <cstdio>

extern "C"
{
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;

/// Lua 宿主调用 read_map_id，严格读取 request.map_id 并返回同值结果表。
/// @param state 参数 1 是请求表，map_id 为 uint32，0 是合法值。
/// @return 成功返回 {map_id=...}；参数错误或 Native 异常返回 nil,{code,message}。
int read_map_id(lua_State *state)
{
    return LuaBinding::invoke(
        state,
        [state]() -> int
        {
            LuaBinding    lua_binding(state);
            LuaTable      request;    // 持有参数表的短期引用，读取 map_id 后在本次回调结束前释放。
            std::uint32_t map_id = 0; // 请求中的地图编号；是否读取成功由 bool 判断，不能依赖非零。
            if (!lua_binding.readTable(1, request) || !request.readValue("map_id", map_id))
            {
                return lua_binding.pushError();
            }

            LuaTable result =
                lua_binding.newTable(); // 返回表拥有独立引用，压入结果后析构不会删掉 Lua 返回值。
            if (!result.writeValue("map_id", map_id))
            {
                return lua_binding.pushError();
            }
            return lua_binding.returnValues(result);
        });
}

// 创建真实 Lua 宿主、注册回调并执行成功/失败断言；所有出口关闭 State，成功输出固定标记。
int main()
{
    lua_State *state = luaL_newstate();
    if (state == nullptr)
    {
        std::fprintf(stderr, "无法创建 Lua State\n");
        return 1;
    }

    // [] -> [read_map_id] -> []：注册标准 C 回调；函数执行时再建立 LuaBinding。
    luaL_openlibs(state);
    lua_pushcfunction(state, read_map_id);
    lua_setglobal(state, "read_map_id");

    const char *script = "local result, err = read_map_id({ map_id = 0 })\n"
                         "assert(result and result.map_id == 0 and err == nil)\n"
                         "local invalid, failure = read_map_id({ map_id = 'invalid' })\n"
                         "assert(invalid == nil and type(failure.code) == 'string')\n";
    // load/pcall 由 luaL_dostring 完成；脚本不返回值，成功保持空栈，失败在栈顶留下错误对象。
    const int   status = luaL_dostring(state, script);
    if (status != LUA_OK)
    {
        std::fprintf(stderr, "%s\n", lua_tostring(state, -1));
        lua_close(state);
        return 1;
    }

    std::puts("FLYWOW_LUA_BINDING_SAMPLE_OK");
    lua_close(state);
    return 0;
}
