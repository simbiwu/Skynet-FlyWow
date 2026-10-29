# Lua Binding 运行示例

本示例用真实 Lua 宿主调用 Native 回调：Lua 请求 `{map_id=0}` → `read_map_id` → `invoke` → LuaBinding 严格读表 → 返回 `{map_id=0}`。再传入字符串形式的地图编号，验证得到 `nil,{code="INVALID_ARGUMENT",message=...}`。

前提：Linux/WSL、C++17 编译器、CMake，以及已经构建的固定 Skynet v1.8.0 自带 Lua 5.4.7（头文件和 `liblua.a`）。不链接系统 Lua；这个独立宿主没有链接 Native 专用的 Skynet allocator，不额外要求 jemalloc。

从 FlyWow 根目录执行：

```bash
bash lua-binding/sample/run_lua_binding_sample.sh ../skynet
```

脚本根据自身位置解析源码和产物目录，先通过统一入口构建静态库并执行 ABI 回归，再编译、运行 `lua_binding_sample.cpp`。产物位于 `build/lua-binding-sample/`，任何构建或断言失败均返回非零状态。成功输出：

```text
FLYWOW_LUA_BINDING_SAMPLE_OK
```

回调中的 `invoke` 包住完整 C++ 业务资源生命周期；`returnValues` 压入结果后，局部 table 句柄只释放 registry 引用，Lua 收到的结果仍然存活。宿主在所有正常出口关闭 State。源码中的原生 C API 只用于建立宿主、注册函数和运行断言；模块内部关键栈机制见 [使用说明](../使用说明.md)。
