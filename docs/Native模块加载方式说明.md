# Native 模块加载方式说明

本文说明 FlyWow 中两类 Native 动态库的加载方式：

1. Lua Binding：由 Lua 的 require 加载，例如 Navigation。
2. Skynet Native Service：由 Skynet 启动配置加载，例如 Logger。

两者最终都是 Linux 下的 .so 文件，但加载者、入口函数、生命周期和使用方式不同。

## 一、先看结论

| 类型 | 谁加载 | 配置位置 | 入口函数 | 主要用途 |
| --- | --- | --- | --- | --- |
| Lua Binding | Lua 虚拟机 | lua_cpath | luaopen_模块名 | 向 Lua 暴露 C/C++ API |
| Skynet Native Service | Skynet 模块加载器 | cpath、logservice 等 | 模块名_create、模块名_init、模块名_release | 创建并管理一个 Skynet 服务实例 |

例如：

- `flywow_navigation_native.so` 是 Lua Binding，由 `require` 触发。
- `flywow_logger.so` 是 Skynet Native Service，由 Skynet 启动 Logger 服务时触发。

## 二、Lua Binding 的加载流程

Navigation 的 Native 库属于 Lua Binding。Lua 代码通常通过模块入口引用它：

```lua
local navigation = require "flywow_navigation"
```

这句代码的作用不是启动一个独立的 Skynet Service，而是让当前 Lua 虚拟机加载对应的动态库，并取得库返回的 Lua 模块表。

### 2.1 Lua 如何找到 .so

Lua 使用 `package.cpath` 查找 C 模块。项目启动时会把 Navigation Native 库所在目录加入 `lua_cpath`，因此 Lua 会尝试匹配类似下面的路径：

```text
server/third_party/skynet-flywow/navigation/native/build/lib/flywow_navigation.so
```

实际目录以当前 FlyWow 的构建产物布局和 Skynet 启动配置为准。代码不应该写开发机绝对路径；运行时应使用项目内的相对路径配置。

### 2.2 Lua 调用哪个导出函数

当 Lua 执行：

```lua
require "flywow_navigation"
```

Lua 会把模块名转换为约定的初始化符号，并查找：

```cpp
extern "C" int luaopen_flywow_navigation_native(lua_State* L);
```

这个 `luaopen_...` 函数是 Lua C 模块的入口。它通常完成以下工作：

1. 注册 userdata、方法和元表。
2. 组装要返回给 Lua 的模块表。
3. 将模块表返回给 `require`。

因此，Lua Binding 的入口是 `luaopen_...`，不是 Skynet 的 `_create` 或 `_init`。

### 2.3 Lua Binding 的生命周期

Lua Binding 没有由 Skynet 统一管理的 Service 实例生命周期。它的初始化发生在当前 Lua State 执行 `require` 时，返回的模块表随后被 Lua 代码使用。

如果模块创建了 Lua userdata 或 C++ 资源，应通过 userdata 的元方法、显式 close 接口或 Lua GC 处理资源释放。具体资源边界由该模块自己定义。

## 三、Skynet Native Service 的加载流程

Logger 属于 Skynet Native Service。它不是被某个业务 Lua 文件简单 `require` 出来的，而是由 Skynet 在启动阶段创建一个服务上下文。

Skynet 启动时会读取配置中的日志服务设置，并执行类似：

```c
skynet_context_new(config->logservice, config->logger);
```

这里的 `config->logservice` 是模块名称，例如 `flywow_logger`；`config->logger` 是传给模块初始化函数的参数字符串，例如 Logger 配置路径。

### 3.1 Skynet 如何找到 .so

Skynet 使用配置中的 `cpath` 查找 Native Service 动态库。模块名为 `flywow_logger` 时，模块加载器会查找对应的：

```text
flywow_logger.so
```

这里的 `cpath` 与 Lua 的 `lua_cpath` 作用不同：

- `lua_cpath` 服务于 Lua 的 `require`。
- `cpath` 服务于 Skynet 的 Native Service 模块加载。

两者可以指向同一个构建目录，也可以指向不同目录；关键是每个加载器必须能找到自己需要的 .so。

### 3.2 Skynet 查找哪些符号

Skynet 的模块加载器会根据模块名拼接约定的符号名称，分别查找：

```c
get_api(mod, "_create");
get_api(mod, "_init");
get_api(mod, "_release");
get_api(mod, "_signal");
```

当模块名是 `flywow_logger` 时，对应的导出函数就是：

```cpp
flywow_logger_create
flywow_logger_init
flywow_logger_release
flywow_logger_signal
```

`_signal` 是可选能力；前三个函数构成创建、初始化和释放的基本生命周期。

### 3.3 谁调用 create、init、release

业务 Lua 代码通常不直接调用 `flywow_logger_create()`。

调用链是：

```text
Skynet 启动
  -> skynet_context_new
  -> skynet_module_query
  -> skynet_module_instance_create
  -> flywow_logger_create
  -> skynet_module_instance_init
  -> flywow_logger_init
  -> Logger Service 开始工作
```

服务销毁时，Skynet 模块加载器调用：

```text
skynet_module_instance_release
  -> flywow_logger_release
```

因此，`flywow_logger_create` 是 Skynet 模块生命周期的一部分，不是一个需要在业务 Lua 中手动到处调用的普通工厂函数。

## 四、这些参数哪些由 Skynet 规定

Skynet 为 Native Service 规定了函数指针槽位和调用时机。典型签名来自 Skynet 的模块接口：

```c
typedef void * (*skynet_dl_create)(void);
typedef int (*skynet_dl_init)(void * inst, struct skynet_context *, const char * parm);
typedef void (*skynet_dl_release)(void * inst);
```

因此：

- `void* inst` 是 Skynet 保存的模块实例指针，具体类型由模块自己决定。
- `skynet_context*` 是当前 Skynet Service 的上下文，由 Skynet 传入。
- `const char* parm` 是启动配置传入的参数字符串；参数的具体格式由模块自己定义。

Logger 可以把 `void* inst` 转换为自己的 `Logger*`。`Logger` 结构体、日志目录解析、日志等级和文件滚动规则都属于 FlyWow 的实现，不是 Skynet 自动提供的功能。

## 五、两类 .so 为什么不能混用

虽然两者都是 .so，但它们面对的调用协议不同。

### 5.1 Lua Binding

```text
Lua require
  -> lua_cpath 查找 .so
  -> 查找 luaopen_模块名
  -> luaopen 函数注册 Lua API
  -> 返回 Lua 模块表
```

它的重点是把 C/C++ 函数、userdata 和常量暴露给 Lua。

### 5.2 Skynet Native Service

```text
Skynet 配置启动服务
  -> cpath 查找 .so
  -> 查找 _create/_init/_release
  -> 创建 Service 实例
  -> 绑定 skynet_context
  -> 由 Skynet 管理服务生命周期
```

它的重点是成为一个 Skynet Service，并接受 Skynet 的生命周期管理和消息调度。

如果把 Lua Binding 当作 Skynet Service 加载，Skynet 找不到它需要的 `_create` 和 `_init` 符号；如果把 Skynet Service 当作 Lua Binding `require`，Lua 找不到对应的 `luaopen_...` 入口。两者不能只因为文件扩展名相同就互相替代。

## 六、在代码中第一次引用时应该说明什么

第一次出现下面这类代码时，应在附近说明四件事：

```lua
local navigation = require "flywow_navigation"
```

1. 这是 Lua Binding 的入口，不是启动新的 Skynet Service。
2. 它由哪一个构建脚本生成，构建产物是什么。
3. 运行时通过哪个 `lua_cpath` 找到 .so。
4. `require` 最终触发哪个 `luaopen_...` 函数。

例如，注释应说明实际项目中的构建命令、产物路径和配置来源；不要只写“加载模块”这种无法帮助排查问题的描述。

第一次配置 Logger 时，也应说明：

1. `flywow_logger` 是 Skynet Native Service 模块名。
2. Skynet 通过 `cpath` 找到 `flywow_logger.so`。
3. Skynet 自动调用 `flywow_logger_create/init`。
4. Logger 的参数字符串由 FlyWow 定义，例如日志配置路径。

## 七、排查加载失败的方法

遇到加载错误时，先判断是哪一层失败：

| 现象 | 优先检查 |
| --- | --- |
| Lua 报 module not found | `lua_cpath`、文件名、.so 是否生成 |
| Lua 报 undefined symbol: luaopen_... | Lua 入口函数命名、`extern "C"`、导出符号 |
| Skynet 报 module not found | `cpath`、模块名和 .so 文件名 |
| Skynet 报找不到 `_create` 或 `_init` | Native Service 导出函数命名和签名 |
| 服务初始化返回失败 | `parm` 内容、配置路径、权限和资源初始化 |

排查时不要只看 .so 是否存在。必须同时确认加载器、搜索路径、模块名和入口符号四者一致。

## 八、与当前 FlyWow 模块的对应关系

| FlyWow 模块 | 模块类别 | Lua/Skynet 入口 |
| --- | --- | --- |
| Navigation Native | Lua Binding | `luaopen_flywow_navigation_native` |
| Gateway Crypto Native | Lua Binding | `luaopen_flywow_gateway_crypto` |
| Logger Native | Skynet Native Service | `flywow_logger_create/init/release` |

这个分类决定了接入方式：Navigation 和 Gateway Crypto 通常在 Lua 文件中 `require`；Logger 由 Skynet 启动配置创建服务。后续阅读代码时，先确认模块属于哪一类，再去找对应的入口函数和调用方。

## 九、完整例子：Navigation 从构建到 require

下面用一个最小链路说明“谁生成、谁查找、谁调用”。假设当前工程位于：

```text
/home/simbi/workspace/skynet-battle-navigation-commercial-learning
```

### 9.1 第一步：构建 Native 库

在 WSL 中进入 FlyWow Navigation 的构建脚本目录，执行项目规定的构建命令。例如：

```bash
cd /home/simbi/workspace/skynet-battle-navigation-commercial-learning/server/third_party/skynet-flywow/navigation
./scripts/build.sh
```

脚本的职责是调用 CMake 和编译器，生成 Navigation 的 Native 动态库。它不是 Lua 的加载器，也不会自动把模块注入某个 Service。

构建完成后，应先确认产物存在：

```bash
find . -name 'flywow_navigation*.so' -type f
```

假设产物是：

```text
navigation/native/build/lib/flywow_navigation.so
```

实际产物目录以当前脚本和 CMake 配置为准；这里的路径只是帮助理解加载链路。

### 9.2 第二步：配置 lua_cpath

运行 Skynet 前，配置中的 `lua_cpath` 必须包含产物所在目录。例如：

```lua
lua_cpath = root .. "/server/third_party/skynet-flywow/navigation/native/build/lib/?.so"
```

其中 `?.so` 是 Lua 的路径模板。执行 `require "flywow_navigation"` 时，Lua 会把 `?` 替换成模块名，得到类似：

```text
.../navigation/native/build/lib/flywow_navigation.so
```

如果这里写成了 `cpath` 而不是 `lua_cpath`，Lua Binding 仍然可能找不到，因为两个配置项服务于不同的加载器。

### 9.3 第三步：Lua 文件执行 require

业务 Lua 文件第一次使用 Navigation 时可以写成：

```lua
-- Navigation 是 Lua Binding；require 会让当前 Lua State 加载 .so，
-- 然后调用 luaopen_flywow_navigation_native，得到 Lua 模块表。
local navigation = require "flywow_navigation"

local path = navigation.find_path(start_x, start_z, target_x, target_z)
```

这里的 `require` 只发生一次实际加载；后续相同模块名通常直接从 `package.loaded` 取出已经加载的模块表。

### 9.4 第四步：Lua 入口注册 API

Native 入口大致会做这样的工作：

```cpp
extern "C" int luaopen_flywow_navigation_native(lua_State* L)
{
    // 创建或取得 Lua 侧的模块表。
    lua_newtable(L);

    // 把 C++ 实现的函数挂到模块表上。
    lua_pushcfunction(L, l_find_path);
    lua_setfield(L, -2, "find_path");

    // 返回模块表；Lua 会把它作为 require 的结果。
    return 1;
}
```

此时栈顶的模块表就是返回值。`return 1` 的含义是告诉 Lua：这个 C 函数向 Lua 返回一个值，也就是刚刚创建并填充好的模块表。

## 十、完整例子：Logger 从配置到 create/init

Logger 的链路与 Navigation 不同。业务 Lua 不需要先 `require` Logger Native 来创建 Skynet 服务。

### 10.1 第一步：配置模块搜索路径

Skynet 配置需要让 Native Service 加载器能够找到 Logger 的 .so：

```lua
cpath = root .. "/server/third_party/skynet-flywow/logger/native/build/lib/?.so"
```

这里的 `cpath` 是 Skynet Native Service 使用的搜索路径。模块名写成 `flywow_logger` 时，Skynet 会查找：

```text
.../logger/native/build/lib/flywow_logger.so
```

### 10.2 第二步：配置 Logger 模块名和参数

Skynet 启动配置可以指定日志模块和传入参数。例如：

```lua
logservice = "flywow_logger"
logger = "./logs/battle"
```

这里需要区分两个概念：

- `logservice` 告诉 Skynet 使用哪个 Native Service 模块。
- `logger` 是传给模块 `init` 的参数字符串；在 FlyWow Logger 中，它可以被约定为日志目录路径。

### 10.3 第三步：Skynet 创建实例

Skynet 启动阶段大致执行：

```c
skynet_context_new(config->logservice, config->logger);
```

随后模块加载器完成：

```c
void *inst = flywow_logger_create();
int ok = flywow_logger_init(inst, context, "./logs/battle");
```

这段伪代码表示调用关系，不是要求业务代码手动复制。真正调用者是 Skynet 的 `skynet_module.c` 和 `skynet_server.c`。

### 10.4 create、init 各自做什么

`flywow_logger_create()` 只负责创建 Logger 实例及其默认状态，例如默认等级、文件句柄状态和互斥锁。此时它还不应假设已经拿到 Skynet 上下文或完整配置。

`flywow_logger_init()` 接收 Skynet 上下文和配置参数，完成日志目录解析、文件打开、服务上下文保存以及消息处理所需的初始化。初始化失败时应返回非零，让 Skynet 知道这个 Service 没有启动成功。

### 10.5 Logger Service 何时真正收到日志

当 Skynet 的日志接口产生一条日志时，消息会被发送给已经创建的 Logger Service。Logger 根据配置的最低等级决定是否写盘：

```text
当前等级为 normal
debug   -> 丢弃
normal  -> 写入当天文件
error   -> 写入当天文件
```

业务代码只需要继续使用统一的日志接口；Logger Service 负责时间、等级、文件路径和写盘。

## 十一、用 nm 检查两种 .so 的入口

当你不确定一个 .so 属于哪种加载方式时，可以直接查看导出符号。

### 11.1 检查 Navigation

```bash
nm -D --defined-only path/to/flywow_navigation.so | grep luaopen
```

如果输出类似：

```text
000000000000xxxx T luaopen_flywow_navigation_native
```

说明它提供 Lua Binding 入口，应该从 `lua_cpath` 和 `require` 链路排查。

### 11.2 检查 Logger

```bash
nm -D --defined-only path/to/flywow_logger.so | grep flywow_logger_
```

预期能看到类似：

```text
000000000000xxxx T flywow_logger_create
000000000000xxxx T flywow_logger_init
000000000000xxxx T flywow_logger_release
```

如果只有 `luaopen_...` 而没有 `_create/_init` 对应导出，Skynet 就不能把它当作 Logger Service 加载。

## 十二、两个最容易混淆的错误例子

### 12.1 把 Navigation 配到 cpath

错误思路：

```lua
cpath = ".../flywow_navigation.so"
require "flywow_navigation"
```

问题在于：`require` 使用的是 `lua_cpath`，不是 Skynet Native Service 的 `cpath`。正确做法是把 Navigation 的目录加入 `lua_cpath`。

### 12.2 把 Logger 当作普通 Lua 模块 require

错误思路：

```lua
local logger = require "flywow_logger"
```

这要求 Logger 导出 `luaopen_flywow_logger`，但当前 Logger 的设计是 Skynet Native Service，导出的是 `flywow_logger_create/init/release`。正确做法是让 Skynet 启动配置创建 Logger Service，再由 Skynet 日志机制把日志交给它。

## 十三、阅读源码时的固定顺序

遇到任何 FlyWow Native 模块，可以按下面顺序阅读：

1. 先看生成的 .so 文件名。
2. 再判断它属于 Lua Binding 还是 Skynet Native Service。
3. 如果是 Lua Binding，查 `lua_cpath`、`require` 和 `luaopen_...`。
4. 如果是 Skynet Service，查 `cpath`、模块配置和 `_create/_init/_release`。
5. 再回到实现代码，确认参数解析、资源所有权、错误返回和释放时机。

这样可以先建立调用链，再进入函数细节，避免看到一个 `create` 函数就误以为它一定是业务代码直接调用的。
