# Logger 接入与运维

## 职责和兼容

Logger 是 C++17 Native Skynet Service，固定验证 Skynet v1.8.0、bundled Lua 5.4.7、Linux/WSL2。它独占文件、日期、缓冲与登记表，不依赖 Gateway、Navigation 或业务 DTO，不修改 Skynet 源码，不自动删除日志，不替换 print，不上传日志。Lua preload、SDK 和 .so 按同一 FlyWow 提交发布。

## 源码、构建与首次接入

源码在 logger/lualib、logger/native、logger/tests。最终产物 build/native/flywow_logger.so 属于 Native Service，使用 Skynet cpath，不是 package.cpath/luaopen 的 Lua Binding。中间文件在 build/cmake/logger，测试 Service 只在中间目录，不发布。

在宿主 Server 根目录执行唯一公开构建入口：

~~~bash
./scripts/linux/run_server.sh build
~~~

也可在 FlyWow 根目录独立构建全部 Native 模块：

~~~bash
bash scripts/build_flywow.sh /path/to/server/third_party/skynet
~~~

产物统一在 FlyWow build/native；不需要 module_paths.py、生成的路径文件或环境变量。宿主进程配置按需直接写搜索路径：lua_path 查找 FlyWow Lua 模块，lua_cpath 查找 Lua Binding，cpath 查找 Native Service。配置路径相对 Server 根目录，启动前工作目录为 server/。

Gateway/Battle 的 Logger 配置是普通 Skynet 配置字段，无需 helper include：

~~~lua
logservice = "flywow_logger"
logger = "./logs/battle"
flywow_logger_level = "normal"
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
~~~

logservice 选择 Native Logger；Skynet 把 logger 字段作为日志服务参数传入，表示输出目录；flywow_logger_level 由 Lua 适配读取；preload 在每个 Lua Service 执行业务代码前安装 skynet.error 转发。业务代码继续只调用 skynet.error。

配置字段含义及按天写盘行为见本页“配置与文件”。每个 OS 进程在自己的进程配置中设置独立 log path。Skynet 配置是受限环境，因此使用普通赋值即可，不依赖 require、函数或路径生成器。

## 配置与文件

| 字段 | 类型/默认 | 合同 |
|---|---|---|
| log_path | string，必填 | 输出目录；相对路径基于 OS 进程启动 cwd，Native 启动时创建并固定绝对路径 |
| level | string，默认 normal | debug/normal/error，过滤低于阈值的日志；非法级别启动失败 |

配置修改需重启。每个输出目录由一个运行中的 Logger 使用；Gateway 和 Battle 分别设置 ./logs/gateway、./logs/battle，不自动增加层级，不配置 instance。空目录、路径为文件或无法打开当天文件，向 stderr 报告并阻止启动。

文件命名 YYYY-MM-DD.log，使用系统本地时间，部署机器时区由运维统一。Logger 接收时记毫秒时间；它可能晚于业务调用时间。跨天第一条日志刷新关闭旧文件再打开新文件；同日重启追加，无消息的次日不创建空文件。不做自动清理、压缩、保留期限或大小分片，运维自行处理。

## 唯一 Lua 接口

~~~lua
skynet.error("查询细节", "debug")
skynet.error("地图加载完成 map_id=", map_id, "normal")
skynet.error("地图加载失败")
~~~

最后参数等于 debug/normal/error 才解释为等级；这三个字符串作为最后参数属于保留用法。否则所有参数为正文且默认 error。多个参数空格拼接，nil 保留为 nil，其余 tostring；用户 __tostring 异常按 Lua 原行为传播。过滤先于 tostring，但调用前完成的 string.format 无法省掉。

~~~text
2026-10-06 00:10:18.125 [NORMAL] [battle_worker:00000012] 地图加载完成
~~~

只包含时间、等级、Service 名与 handle、正文。preload 从 SERVICE_NAME 登记，同名实例由 handle 区分。正常 skynet.exit 注销；未登记显示 unknown。固定 Skynet LAUNCH 日志能提供初始名，显式登记随后覆盖。正文换行转义，避免伪造日志行。不自动附加源码文件名、行号、调用栈；实际 traceback 可作为正文传入。

等级 debug < normal < error。normal 记录 normal/error，error 仅记录 error。Skynet C 原生文本没有等级，按 error 保留，包括启动与诊断消息。

## Native API 与默认回退

公共头 logger/native/flywow_logger.h 编入调用者，不链接 Logger .so；提供固定 Skynet skynet-src 头路径，使用宿主导出的 C API：
~~~cpp
flywow_logger::register_service(ctx, "my_native_service");
flywow_logger::log_write(
    ctx,
    flywow_logger::LogLevel::Normal,
    "地图加载完成");
~~~

ctx 必须在当前 Service 有效调用期间借用，不能从自建线程借用或放入跨 Service 可变全局状态。正文调用时复制，单条上限 8 KiB。分配失败不破坏业务；空 ctx/正文无操作。

启用 FlyWow 时提前过滤并发送带等级的 L 消息；未启用则调用原生 skynet_error，保留 [DEBUG]/[NORMAL]/[ERROR] 标记，官方 Logger 不过滤级别。启动时还没有默认 Logger 目标可能丢消息。

Lua Native 模块不自动拥有 skynet_context。Navigation 核心不依赖日志模块；需要日志时在绑定层显式注入，本次不声称已给 Navigation 加上日志调用。Native Service 的 SDK 调用和默认回退已有真实测试。

## 性能、资源与失败

单个 Logger callback 串行处理，不创建写线程。普通日志缓冲写，每 100 tick（一秒）刷新，error 立即刷新。flush 是用户态缓冲提交给 OS，不是 fsync，断电/强杀不保证持久性。磁盘阻塞仍占用 Skynet 工作线程。

名称表最多 4096 项，超出来源共享受限桶。单条正文限制 8 KiB，截断带 TRUNCATED；按字节截断，可能切开 UTF-8 最后字符。

这些限制不是 Skynet mailbox 硬容量。原生 C 日志、多来源高压仍可能积压；Native SDK 不创建额外共享队列，不承诺无限吞吐。Skynet overload 日志可提示积压，商业负载容量需独立压测。

运行时写盘失败直接向 stderr 限频报告，关闭文件，下次日志最多每秒尝试重开。故障期可能丢日志，没有无界补偿缓存。刷新失败返回 ERROR，Lua flush 抛异常，关闭流程不能谎报成功。

## 内部协议与优雅关闭

内部文本消息的第一个字符是命令：
- L：后跟等级 0/1/2 和正文，表示写入日志。
- R：后跟来源名称，登记 source handle 的可读名称。
- U：不带正文，注销当前 source 的名称。
- F：不带正文，请求刷新文件并通过 session 返回 OK/ERROR。

普通未标记文本按 error。只允许本机 Service 调用，不提供网络日志控制口。Skynet 标准 .logger 是其启动链明确的发现合同。

~~~lua
require("flywow_logger").flush()
~~~

flush 会 yield；确认 Logger 已处理到此控制消息并刷新，不能替代其他 Service 的静止屏障。先停止接入、收齐业务清理回复、写最后日志，再等待 flush 成功，最后退出进程。Gateway/Battle shutdown_coordinator 已按该顺序接入。SIGKILL 无法执行收尾。

## 独立验证与运维

~~~bash
bash scripts/build_flywow.sh /path/to/skynet
python3 logger/tests/integration_test.py \
  --skynet /path/to/skynet --build /path/to/flywow/build
~~~

C++ 文件测试实际验证跨天、追加、转义、非法目录、/dev/full 写失败与恢复。真实 Skynet 集成验证三个等级、自动子 Service 名称、nil、长消息、Native SDK、默认回退、配置入口和刷新。测试自己的临时目录自动释放，不操作开发者日志。

没有文件时先查 stderr、路径权限、磁盘和 cpath/.so；正常日志在每日文件，启动脚本重定向只收诊断。当前未发布跨硬件吞吐数字，未验证断电持久性。跨天测试注入时钟，不修改系统日期。

## 升级与回滚

同一固定提交成套更新 SDK、Lua 与 Native，L/R/U/F 命令格式不兼容变化必须升级版本。无在线配置重载。回滚时移除 flywow_logger 配置与 Logger preload，恢复默认 logservice/logger；业务 skynet.error 保持可用，但级别字符串被原生接口当正文。Native SDK 自动回退且保留级别标记。
