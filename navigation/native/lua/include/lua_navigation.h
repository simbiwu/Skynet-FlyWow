// 职责：声明 flywow_navigation_native Lua C 模块入口。
// 边界：Server Native/Lua ABI；不暴露地图、Context 或 Path 实现。
// 输入/输出：当前 lua_State -> 栈顶一个模块 table。
// 不负责：不启动 Skynet Service，不持有或销毁 Lua State。
#pragma once

// 不透明声明：使用者无需通过本头文件依赖 Lua 完整头文件。
struct lua_State;

// require "flywow_navigation_native" 查找此 C ABI 符号；在当前 State 注册类型与模块方法。
// L 由调用者持有且必须有效；注册会分配 Lua table/closure，不读取地图、不 yield。
// 正常返回 1：这是交给 Lua 的结果数量，Lua 收到的是栈顶模块 table，不是数字 1。
// require 缓存并返回此 table；注册 helper 的 lua_pop 只清理临时类型表，不删除注册。
// Registry 作为非 owning upvalue 绑定，其生命周期由 Native 单例保证。
// ABI 不匹配或 Lua 分配失败由 Lua 错误机制处理；不接管 State 的所有权。
extern "C" int luaopen_flywow_navigation_native(lua_State *L);
