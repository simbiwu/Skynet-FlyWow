// 直接 require 的模块入口；数据实现和 userdata 构造统一由静态 Binding 库负责。
#include "lua_native_data.h"

namespace
{
// Lua 导出 new 是 V5 固定合同，但 new 是 C++ 关键字，因此此回调采用合法名称。
int new_native_data(lua_State *state)
{
    flywow_lua_binding::LuaBinding binding(state);                     // 当前同步回调的结果出口。
    auto root = std::make_shared<flywow_lua_binding::LuaNativeData>(); // 新建根的首个 owner。
    return binding.returnValues(root);
}
} // namespace

extern "C" int luaopen_flywow_native_data(lua_State *state)
{
    static const luaL_Reg functions[] = {
        {"new", flywow_lua_binding::LuaBinding::nativeCallback<new_native_data>},
        {nullptr, nullptr},
    };
    luaL_newlib(state, functions);
    return 1;
}
