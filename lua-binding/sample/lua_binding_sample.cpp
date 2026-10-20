#include "lua_binding.h"
#include "lua_table.h"

#include <cstdio>
#include <cstdint>

extern "C"
{
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;

// Lua 可见名为 read_map_id；失败返回 nil,{code,message}。
int read_map_id(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaTable request;
    std::uint32_t map_id = 0;
    if (!lua_binding.readTable(1, request) ||
        !request.readValue("map_id", map_id))
    {
        return lua_binding.pushError();
    }

    LuaTable result = lua_binding.newTable();
    if (!result.writeValue("map_id", map_id))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(result);
}

int main()
{
    lua_State *state = luaL_newstate();
    if (state == nullptr)
    {
        std::fprintf(stderr, "无法创建 Lua State\n");
        return 1;
    }

    luaL_openlibs(state);
    lua_pushcfunction(state, read_map_id);
    lua_setglobal(state, "read_map_id");

    const char *script =
        "local result, err = read_map_id({ map_id = 0 })\n"
        "assert(result and result.map_id == 0 and err == nil)\n"
        "local invalid, failure = read_map_id({ map_id = 'invalid' })\n"
        "assert(invalid == nil and type(failure.code) == 'string')\n";
    const int status = luaL_dostring(state, script);
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
