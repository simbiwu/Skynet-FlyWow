# Lua Binding

最小 C++ Binding 读写示例见 [Lua Binding Sample](../../lua-binding/sample/README.md)。

Lua Binding 为 C++ Native 提供严格参数读取、table 字段读写、结果构造、静态函数注册和托管 userdata 生命周期。Gateway、Navigation、Word Filter 和 HotUpgrade 均通过该静态库接入；普通回调直接书写，在注册处使用 nativeCallback 接入异常边界；模块入口用静态 luaL_Reg 直接注册。

完整合同、构建、使用示例和 ABI 测试覆盖见 [Lua Binding 使用说明](../../lua-binding/使用说明.md)。测试源码为 `lua-binding/tests/lua_binding_test.cpp`，从 FlyWow 根目录执行 `bash scripts/build_flywow.sh /path/to/skynet lua_binding`，使用 Skynet 自带 Lua 5.4.7 构建并运行。源码位于根模块目录 `lua-binding/`，静态 target 为 `flywow_lua_binding`。
