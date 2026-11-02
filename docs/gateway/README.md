# FlyWow Gateway

## 文档入口

- 第一次接入：接入指南.md
- 运行主流程示例：[Gateway Sample](../../gateway/sample/README.md)
- 配置复制起点：flywow_gateway_config.example.lua
- 握手合同：握手合同.md

## 职责边界

FlyWow Gateway 是业务无关的 Skynet 接入 Service，负责 TCP/WebSocket 接入、握手、连接生命周期、Envelope 编解码、send_data 转发、指定连接发送、广播和 close 控制。WebSocket ping/pong 由 transport 处理；TCP 心跳由宿主协议定义；idle timeout 按客户端完整业务消息计时。

Gateway 不保存业务请求，不创建 pending，不生成 route_token，不等待 Battle 结果，不判断业务成功、失败或超时，不解释业务错误。

## 模块入口

Gateway内部Lua模块位于`gateway/lualib/`，以模块名 `handshake` 和 `codec` 加载。
Service为`flywow_gateway`；协议registry由宿主唯一Proto源生成。
Navigation独立使用`flywow_navigation`；不因命名接近而建立模块依赖。

## Service 合同

宿主通过 start 注入完整的课程配置和业务 handler：

    -- 先为 handler 注册稳定的本地服务名；名称由宿主选取并避免冲突。
    skynet.name(".my_gateway_handler", skynet.self())
    local gateway = skynet.newservice("flywow_gateway")
    local options = {}
    for key, value in pairs(require "config.gateway_lesson_02") do
        options[key] = value
    end
    options.handler_service = ".my_gateway_handler"
    local start_result = skynet.call(gateway, "lua", "start", options)
    if not start_result.ok then
        skynet.error("Gateway 启动失败：", start_result.code, " ", start_result.message)
        skynet.abort()
        return
    end

Gateway 每次发送时由 Skynet 按名称解析当前注册的 Service；名称未注册期间发送会失败，不排队、不重试。
Gateway 不校验 send_data/close 的回复来源身份；宿主负责控制本地服务访问边界。

handler Service 接收 send_data：

    {
        gateway_epoch = "...",
        connection_id = 123,
        command_id = 1001,
        data = {...},
    }

Gateway 解码客户端请求后发送仅含 `gateway_epoch`、`connection_id`、`command_id`、`data` 四个字段的 `send_data`。宿主处理完成后，也通过同一个 send_data 把数据发回 Gateway。Gateway 不区分请求响应和服务端主动下发。

连接控制使用 close：

    {
        gateway_epoch = "...",
        connection_id = 123,
    }

connection_id 大于 0 时发送给指定连接，等于 0 时广播给当前 Gateway 中所有已经握手成功且仍然有效的连接。

## 协议合同

各课程共用的传输类型为 `battle.transport.v1.Envelope`；业务命令与消息由课程各自定义。客户端 Envelope 只包含：

    message Envelope {
      uint32 protocol_version = 1;
      uint32 command = 2;
      bytes body = 3;
    }

客户端只根据 command 选择消息类型。协议不定义 request_id，也不要求 Gateway 保存请求响应关联。

registry 由构建阶段根据 CommandId 和消息定义生成，Codec 初始化时校验并独占查询其中按数字 command ID 索引的 `commands`，不再建立第二份索引；生成文件仍提供 `command_ids`，供宿主业务代码按枚举名称引用命令号：

- XxxRequest 与 XxxResponse 都存在：请求-响应命令
- 只有 XxxRequest：单向请求命令
- 只有 XxxResponse：服务端主动下发命令

## 传输失败

Gateway 只处理本地传输结果：

- 未知连接、旧 gateway_epoch 或未握手连接：丢弃
- 编码失败：记录错误并拒绝本次发送
- Socket 写失败：摘除连接并关闭 transport
- 单连接或 Gateway 实例每秒接纳请求数超限：拒绝当前帧并关闭触发超限的连接
- Battle 业务失败、业务超时、重试和顺序：由业务 Service 负责

入口速率分别由 `max_requests_per_second` 和 `max_total_requests_per_second` 限制，
默认每连接 200 个、每实例 10000 个请求/秒；两项可按部署容量调低或调高。

## Transport

TCP 使用 uint16 big-endian 长度和 Envelope bytes；Gateway 在读取完整 body 前校验 TCP 长度头。`max_frame_bytes` 限制单条业务 Envelope 的大小，不限制底层传输层接收内存，也不提供传输内存硬上限。WebSocket 使用明文 `ws`，TLS/WSS 由宿主外部终止；底层使用 Skynet 固定 http.websocket，复用相同 Envelope 和 registry。WebSocket 的 ping/pong、fragment 和 close frame 由底层 transport 处理；TCP 应用层心跳由宿主协议按 command 定义。

写缓冲关闭阈值只在 Skynet warning 回调到达后判断：回调 `size` 非零且达到 `write_warning_close_kb` 时关闭连接，`size=0` 表示发送缓冲恢复并被忽略。Skynet 首次在 1 MiB 缓冲量时告警，后续按底层告警粒度递增，因此该配置不是精确内存上限。

`read_timeout_ms`、`idle_timeout_ms` 和 `handshake_timeout_ms` 均以毫秒配置。Skynet 时钟每 10ms 前进一步，Gateway 每 100ms 扫描超时连接，因此实际关闭可能晚于配置期限。`idle_timeout_ms` 限制客户端完整业务消息之间的空闲时间。WebSocket ping/pong 与服务端 Push 不重置该计时；TCP 正在读取定长数据时使用独立的 `read_timeout_ms`，同样以毫秒配置。旧的 `*_timeout_ticks` 配置字段会作为配置错误拒绝，需迁移到对应的 `*_timeout_ms` 字段。

## 连接广播

connection_id=0 的广播只作用于当前 Gateway 实例。多 Gateway 节点的全局广播由上层节点管理器负责向每个 Gateway 实例分别发送 send_data。Gateway 不保存跨节点业务状态。

## 启动失败与重试

`start()` 仅接受 `created` 状态。配置、Registry、Codec 或 Native/握手初始化在发布 `starting` 前返回失败时，实例仍处于 `created`，修正输入或依赖后可重新尝试；已完成的模块初始化不主动回滚。监听绑定或 listener 启动失败后转为 `stopped`，此时需要创建新的 Gateway Service。正常启动和停止后也不能再次启动同一实例。

## 关闭连接

业务通过 close 请求关闭指定连接。Gateway 校验当前 gateway_epoch 和 connection_id，先摘除连接，再关闭底层 TCP/WebSocket。关闭不取消 Battle 已经接纳的业务操作。

宿主调用 Gateway 的 stop RPC 时，首个调用负责关闭监听与全部活动连接；Socket 关闭可能 yield，期间到达的重复 stop 立即成功返回 closed_connections=0，不等待或共享首次结果；此返回不表示首次停止已完成。停止完成后的重复调用返回成功且 `closed_connections=0`。

`closed_connections` 统计 listener 关闭完成后连接快照中，由本次 stop 首次摘除并提交关闭的连接数。此前已经由 TCP 会话、超时或回调摘除的连接不计入；底层关闭失败仍计入，并通过 `GATEWAY_STOP_CLOSE_FAILED` 的 details 返回计数，因此它不代表 transport 关闭成功数量。

## 生成与验证

运行时不读取 proto，也不 require 宿主的固定 config.gateway。每个课程构建入口使用固定 protoc 生成本课 descriptor，并调用 gateway/tools/generate_gateway_registry.py 生成 protocol_registry_<course>.lua；宿主 composition root 选择课程配置并显式传入 start。协议源、descriptor、Registry 和客户端生成物必须来自同一协议版本。

当前课程协议版本为4：Gateway不读取、生成或回传request_id。定向Push通过正connection_id投递，0广播；两者都必须匹配当前gateway_epoch与ready连接。业务需要的序号/幂等/关联保留在data中，由宿主负责。

## 本轮最小整改验证记录（2026-11-03）

- 停止竞态：TCP read 和超时 sleep 恢复后检查运行阶段；WS message 在入口检查。回归覆盖 listener close 挂起期间的数据与回调。
- 关闭所有权：主动关闭由首次成功 detach 的调用者执行；TCP 正常和异常退出归 accept_client 外层协程统一清理。移除 close_requested，保留跨 yield 和 fd 身份检查。
- 传输写帧：握手和业务复用私有 write_frame；错误映射、握手确认和关闭决定仍在原调用方。
- Handshake：长期状态集中到私有 module_state；release_context 释放名额和 Native 对象，直接提交 ready/closed；HELLO 保存前校验 userdata，失败仍主动释放资源。
- Codec：使用文件 I/O 原生返回值并保证关闭；直接遍历 descriptor 引用类型；保留 pb.load/decode/encode 异常边界。
- 命名：仅整理内部连接字段、局部对象及 SDK/Native 标识符；Unity 内部数字阶段改为具名枚举。
- H5：等待业务回调 Promise 后再处理下一条；回调拒绝沿已有 fail 路径关闭。新增顺序和拒绝回归。
- CI：将既有 Native 互通测试纳入 Gateway 测试模块，补充其 cryptography 依赖与 SKYNET_JEMALLOC 环境。

验证结果：Gateway Python 测试 15 项通过（包含新增 Lua/H5 场景及真实 Native 互通）；Gateway Native 重新构建成功；质量检查器单测 52 项通过；Skill 结构检查和 git diff --check 通过。仓库总门禁失败的 3 条均位于本轮未修改的既有脏文件 gateway/sample/master_course/service/world_service.lua：缺末尾换行及两处阶段说明缺失。

历史 CI 基线 a67a6ee9 的 WebSocket 步骤失败，后续 TCP 步骤被跳过。临时诊断确认根因为宿主配置仍使用旧 *_timeout_ticks 字段。随后 Server 各 Gateway 课程配置及 master_course Service 已迁移为毫秒字段；本地 WebSocket、TCP Protobuf、TCP Binary 三个 Sample 均实际运行并成功，输出对应 FLYWOW_GATEWAY_SAMPLE_OK 标记。

待确认：第 9 项 Registry 重复查询暂不实施；has_command/has_response 与未知命令、缺少请求/响应类型的错误区分继续保留。Sample 宿主超时配置已迁移至毫秒合同并完成三种传输 Sample 验证。本机缺少 Unity/C# 编译工具，Unity SDK 的内部重命名和枚举仅完成静态核对，未完成 Unity 编译验证。

公开 Service/SDK API、协议字段与握手字节合同保持原有约定；本轮指定的停止竞态修复及 H5 异步回调等待按整改清单落实。后续最小化收尾已恢复显式逐字段配置校验，并删除并发 stop 的等待及结果共享；stopping 重复调用立即返回零，不代表首次清理完成。未修改第三方源码，未提交或推送。
