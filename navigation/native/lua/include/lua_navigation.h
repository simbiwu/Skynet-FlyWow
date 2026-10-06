// 职责：声明 flywow_navigation_native Lua C 模块入口。
// 边界：Server Native/Lua ABI；不暴露地图、Context 或 Path 实现。
// 输入/输出：当前 lua_State -> 栈顶一个模块 table。
// 不负责：不启动 Skynet Service，不持有或销毁 Lua State。
#pragma once

// 不透明声明：使用者无需通过本头文件依赖 Lua 完整头文件。
struct lua_State;

/// require "flywow_navigation_native" 调用的固定 Lua C ABI 入口。
/// @param state 宿主持有的有效 State；初始化通过 LuaBinding 适配器，不读取地图、不 yield。
/// @return 成功为模块 table（数量 1）；普通注册失败为 nil,error（数量 2）。
/// @note Registry 作为借用 upvalue 绑定，单例生命周期覆盖所有 State；类型与 GC 按 State 注册。
extern "C" int luaopen_flywow_navigation_native(lua_State *state);
