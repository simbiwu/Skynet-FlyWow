# Lua Binding 运行示例

Lua Binding 是供 Native 模块静态链接的 C++ helper，不是 Lua 插件。本示例编译一个最小 Lua 宿主回调，通过 LuaBinding/LuaTable 读取 request.map_id 并返回结果，再检查非法字段的结构化错误。

从 FlyWow 根目录运行：bash lua-binding/sample/run_lua_binding_sample.sh ../skynet

脚本先调用现有构建入口，再使用 Skynet 自带 Lua 头文件、liblua.a 和同版本 jemalloc 编译运行。lua_binding_sample.cpp 展示一次输入、转换、输出和失败返回。
