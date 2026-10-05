# FlyWow Logger 初始化流程与接口

本文说明 FlyWow Logger 从 Skynet 进程启动，到 Lua 业务调用 skynet.error，再到 Native Logger 写入每日日志文件的完整链路。

## 一、整体链路

    Skynet 读取进程配置
        -> 创建 flywow_logger Native Service
        -> 每个 Lua Service 执行 preload
        -> 安装当前 Lua State 的 skynet.error 适配
        -> 业务调用 skynet.error
        -> Native callback 接收消息
        -> LogSink 写入当天文件
        -> 关闭时 flush

Logger 由四个部分组成：

| 部件 | 作用 | 创建 Logger | 直接写文件 |
| --- | --- | --- | --- |
| logger/native/src/service_logger.cpp | Skynet Native Logger Service | 是 | 是 |
| logger/lualib/flywow_logger.lua | Lua 适配和 flush 接口 | 否 | 否 |
| logger/lualib/flywow_logger_preload.lua | 自动安装 Lua 适配 | 否 | 否 |
| logger/native/include/flywow_logger.h | 其他 Native 模块的发送接口 | 否 | 否 |

最容易混淆的一点是：flywow_logger.so 和 flywow_logger.lua 不是同一个东西。前者由 Skynet 启动，后者只负责 Lua 层转发。

## 二、进程配置

Gateway、Battle 或其他 Skynet OS 进程需要配置：

~~~lua
-- 选择 FlyWow Native Logger。
logservice = "flywow_logger"

-- 传给 Native 初始化函数的参数；相对 Server 根目录。
logger = "./logs/battle"

-- 最低日志等级：debug、normal、error。
flywow_logger_level = "normal"

-- 每个 Lua Service 执行业务代码前执行。
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
~~~

同时必须配置模块搜索路径：

~~~lua
lua_path = lua_path ..
           ";./third_party/skynet-flywow/logger/lualib/?.lua"

lua_cpath = lua_cpath ..
            ";./third_party/skynet-flywow/build/native/?.so"

cpath = cpath ..
        ";./third_party/skynet-flywow/build/native/?.so"
~~~

三条路径的职责不同：

- lua_path 查找 Lua 文件，例如 flywow_logger.lua；
- lua_cpath 查找 Lua require 使用的 Native Binding；
- cpath 查找 Skynet Native Service，例如 flywow_logger.so。

Logger 是 Native Service，所以真正启动它的是 logservice，而不是业务代码中的 require。

构建命令：

~~~bash
cd server
./scripts/linux/run_server.sh build
~~~

最终产物：

~~~text
server/third_party/skynet-flywow/build/native/flywow_logger.so
~~~

## 三、Skynet 创建 Native Logger

Skynet 读取 logservice 和 logger 后加载 flywow_logger.so，并调用：

~~~cpp
flywow_logger_create();
flywow_logger_init(...);
~~~

进程结束时调用：

~~~cpp
flywow_logger_release(...);
~~~

### 1. flywow_logger_create

源码位于：

~~~text
logger/native/src/service_logger.cpp
~~~

~~~cpp
Logger* flywow_logger_create()
{
    return new Logger;
}
~~~

它只创建 Logger 的内存状态：

~~~cpp
struct Logger
{
    std::unique_ptr<LogSink> sink;
    std::unordered_map<uint32_t, ServiceEntry> services;
    int minimum = 1;
};
~~~

此时还没有打开文件，也没有注册消息回调。调用者是 Skynet 的 Native Service 加载器，不是 Lua 业务代码。

### 2. flywow_logger_init

函数合同：

~~~cpp
int flywow_logger_init(
    Logger* logger,
    skynet_context* context,
    const char* parm);
~~~

参数含义：

- logger：create 创建的状态；
- context：当前 Native Logger Service 的 Skynet 上下文；
- parm：配置中的 logger 值，例如 ./logs/battle。

初始化顺序：

    读取 flywow_logger_level
        -> 检查等级是否合法
        -> 创建 LogSink
        -> 打开当天日志文件
        -> 注册 Skynet callback
        -> 设置一秒刷新定时器

读取等级：

~~~cpp
const char* level =
    skynet_command(context, "GETENV", "flywow_logger_level");
~~~

没有配置时默认 normal；未知等级会导致启动失败。

创建写入对象并打开当天日志：

~~~cpp
logger->sink.reset(
    new flywow_logger::LogSink(parm ? parm : ""));

logger->sink->open_day(std::chrono::system_clock::now());
~~~

例如：

~~~text
./logs/battle/2026-10-06.log
~~~

目录不存在、路径是普通文件、权限不足或文件无法打开时，初始化失败，进程不会继续假装自己具备日志能力。

注册回调和一秒刷新：

~~~cpp
skynet_callback(context, logger, callback);
skynet_command(context, "TIMEOUT", "100");
~~~

以后 Logger 收到消息时，Skynet 调用：

~~~cpp
callback(context, logger, type, session, source, data, size);
~~~

### 3. flywow_logger_release

~~~cpp
void flywow_logger_release(Logger* logger)
{
    delete logger;
}
~~~

Skynet 调用它时，Logger 关闭文件并释放状态，不删除历史日志。

## 四、Lua preload 如何安装适配

文件：

~~~text
logger/lualib/flywow_logger_preload.lua
~~~

内容：

~~~lua
require("flywow_logger").install()
~~~

preload 不创建 Native Logger、不打开文件，也不启动第二个 Service。Native Logger 已经由 Skynet 启动链创建；preload 只负责当前 Lua State。

安装函数首先检查当前进程：

~~~lua
if installed or skynet.getenv("logservice") ~= "flywow_logger" then
    return
end
~~~

没有启用时，当前 Lua State 的 skynet.error 不会被修改。

然后读取等级、登记 Service，并替换当前 State 的 skynet.error：

~~~lua
local level = skynet.getenv("flywow_logger_level") or "normal"
local minimum = assert(levels[level], "invalid flywow_logger_level")

original_error("R" .. tostring(SERVICE_NAME or "unknown"):sub(1, 128))
skynet.error = make_adapter(minimum)
~~~

SERVICE_NAME 来自 Skynet 标准 loader。每个 Service 有独立 Lua State，所以每个 Service 都会独立执行一次安装和登记。

## 五、业务调用 skynet.error

业务代码不需要改变：

~~~lua
skynet.error("地图加载完成")
skynet.error("路径查询失败", "error")
skynet.error("调试信息", "debug")
~~~

适配器依次执行：

    接收变长参数
        -> 检查最后一个参数是否为等级
        -> 按最低等级过滤
        -> tostring 并用空格拼接
        -> 限制正文最大 8 KiB
        -> 拼接 L + 等级 + 正文
        -> 调用原始 skynet.error

例如：

~~~lua
skynet.error("地图加载完成", "normal")
~~~

会转换成类似：

~~~text
L1地图加载完成
~~~

Lua 适配层不写文件，只负责过滤、格式化和转发。原始 skynet.error 再把消息交给 Skynet Logger 路由，最终进入 Native callback。

当配置为 normal 时，debug 消息会在 Lua 层被过滤；Native 层也会再次检查等级，防止其他 Native 调用方绕过 Lua 过滤。

## 六、Native callback 如何识别消息

| 标记 | 含义 | 发送者 |
| --- | --- | --- |
| R | 登记 Service 名 | Lua preload 或 Native SDK |
| U | 注销 Service | 包装后的 skynet.exit |
| L0 | debug | Lua 适配或 Native SDK |
| L1 | normal | Lua 适配或 Native SDK |
| L2 | error | Lua 适配或 Native SDK |
| F | flush | 关闭流程 |

Service 名通过 source handle 保存：

~~~text
source handle -> ServiceEntry.name
~~~

最终日志可以显示：

~~~text
2026-10-06 00:10:18.125 [NORMAL] [battle_worker:00000012] 地图加载完成
~~~

如果登记尚未到达，会暂时显示 unknown。Logger 还会解析 Skynet 原始 LAUNCH 日志，在 preload 之前尽量取得 Service 名；后续 R 消息会覆盖初始名称。

## 七、Service 退出和 flush

install 会包装 skynet.exit：

~~~lua
local exit = skynet.exit

skynet.exit = function()
    original_error("U")
    return exit()
end
~~~

退出顺序：

    发送 U
        -> Native Logger 删除 Service 登记
        -> 调用原始 skynet.exit

这只维护 Logger 的名称表，不负责业务资源清理。

Lua 模块还提供：

~~~lua
require("flywow_logger").flush()
~~~

启用 FlyWow Logger 时，内部发送：

~~~lua
skynet.call(".logger", "text", "F")
~~~

Native callback 收到后执行 LogSink flush，成功返回 OK，失败返回 ERROR。flush 会 yield，因为它使用 skynet.call；它不等价于 fsync，也不能代替其他 Service 的关闭屏障。

推荐关闭顺序：

    停止接收新请求
        -> 等业务 Service 清理完成
        -> 写最后一条日志
        -> logger.flush()
        -> flush 成功
        -> skynet.exit()

## 八、Native 模块调用接口

其他 Native 模块包含：

~~~cpp
#include "flywow_logger.h"
~~~

### enabled

~~~cpp
bool enabled(skynet_context* context);
~~~

读取 logservice，判断当前进程是否启用 FlyWow Logger。

### log_write

~~~cpp
void log_write(
    skynet_context* context,
    LogLevel level,
    const char* message) noexcept;
~~~

调用示例：

~~~cpp
flywow_logger::log_write(
    context,
    flywow_logger::LogLevel::Normal,
    "地图加载完成");
~~~

启用时发送 L + 等级 + 正文；未启用时回退到 Skynet 原生 skynet_error。它不直接写文件，也不链接 flywow_logger.so。

### register_service

~~~cpp
void register_service(
    skynet_context* context,
    const char* name);
~~~

调用示例：

~~~cpp
flywow_logger::register_service(
    context,
    "navigation_native");
~~~

没有启用 FlyWow Logger 时，这个函数无副作用。

## 九、未启用 Logger 时

如果没有：

~~~lua
logservice = "flywow_logger"
~~~

那么：

- preload 不替换 skynet.error；
- Native log_write 回退到 Skynet 原生日志；
- 不创建 FlyWow Logger Service；
- 不写入 FlyWow 的按天日志文件。

业务代码不需要根据配置切换调用方式。

## 十、接口和调用者总表

| 接口 | 所在层 | 直接调用者 | 职责 |
| --- | --- | --- | --- |
| flywow_logger_create | Native | Skynet | 创建 Logger 状态 |
| flywow_logger_init | Native | Skynet | 读取配置、打开文件、注册 callback |
| callback | Native | Skynet | 接收日志和控制消息 |
| flywow_logger_release | Native | Skynet | 关闭文件并释放状态 |
| logger.install | Lua | preload | 安装当前 Lua State 的适配 |
| skynet.error 适配器 | Lua | 业务 Lua | 过滤、格式化、发送 |
| logger.flush | Lua | 关闭流程 | 等待 Logger 刷新 |
| enabled | C++ header | Native 调用方 | 判断是否启用 |
| log_write | C++ header | 其他 Native 模块 | 发送分级日志 |
| register_service | C++ header | 其他 Native 模块 | 登记 Native Service 名称 |

关键边界：

~~~text
Skynet 负责启动和调度
Lua preload 负责适配 skynet.error
Native callback 负责接收和写盘
LogSink 负责文件、日期和缓冲
业务 Service 负责产生日志和关闭时 flush
~~~

## 十一、验证

~~~bash
cd server
./scripts/linux/run_server.sh build
./scripts/linux/run_server.sh start
ls logs/battle
tail -f logs/battle/$(date +%F).log
./scripts/linux/run_server.sh stop
~~~

重点观察：

1. 是否生成当天日志文件；
2. 是否显示正确的 Service 名和 handle；
3. debug 是否按最低等级过滤；
4. shutdown 是否完成 flush；
5. 进程退出后是否没有残留 Logger Service。
