# Native C++ 内存分配

FlyWow Native 共享库在 Skynet 进程内使用 Skynet 自带的 jemalloc。Skynet 可执行文件以 `je_` 前缀导出 `je_malloc` 和 `je_free`；FlyWow 在每个 Native 模块中定义 C++ 全局 `operator new/delete`，分配和释放均转调宿主符号。

因此，Native 模块内默认 allocator 管理的 `std::string`、`std::vector` 等 STL 容器也使用宿主 jemalloc。显式调用 `malloc/free` 或指定其它 allocator 的代码不受该重载影响。此接入不加载第二份 jemalloc、不修改 Skynet 源码，也不适用于脱离 Skynet 单独加载的 Native `.so`。

统一构建脚本会把分配器实现加入每个 Native 模块。构建产物依赖 Skynet 宿主在运行时提供 `je_malloc/je_free`；在 Skynet 外加载会因宿主符号缺失而失败。
