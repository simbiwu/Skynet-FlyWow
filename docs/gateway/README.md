# FlyWow Gateway

## 文档入口

- 第一次接入：接入指南.md
- 运行主流程示例：[Gateway Sample](../../gateway/sample/README.md)
- 配置复制起点：flywow_gateway_config.example.lua
- 握手合同：握手合同.md

## 职责边界

FlyWow Gateway 是业务无关的 Skynet 接入 Service，负责 TCP/WebSocket 接入、握手、心跳、连接生命周期、Envelope 编解码、send_data 转发、指定连接发送、广播和 close 控制。

Gateway 不保存业务请求，不创建 pending，不生成 route_token，不等待 Battle 结果，不判断业务成功、失败或超时，不解释业务错误。

## 模块入口

Gateway内部Lua模块位于`gateway/lualib/`，分别以模块名 `handshake`、`codec` 和 `registry` 加载。
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
        peer = "127.0.0.1:52000",
        transport = "tcp",
        command_id = 1001,
        data = {...},
    }

Gateway 解码客户端请求后发送 send_data；peer 与 transport 是连接上下文，供宿主诊断使用。宿主处理完成后，也通过同一个 send_data 把数据发回 Gateway。Gateway 不区分请求响应和服务端主动下发。

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

registry 由构建阶段根据 CommandId 和消息定义生成：

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

TCP 使用 uint16 big-endian 长度和 Envelope bytes；Gateway 在读取完整 body 前校验 TCP 长度头。`max_frame_bytes` 限制单条业务 Envelope 的大小，不限制底层传输层接收内存，也不提供传输内存硬上限。WebSocket 使用 Skynet 固定 http.websocket，复用相同 Envelope 和 registry。WebSocket 的 ping/pong、fragment 和 close frame 由底层 transport 处理；TCP 应用层心跳由宿主协议按 command 定义。

写缓冲关闭阈值只在 Skynet warning 回调到达后判断：回调 `size` 非零且达到 `write_warning_close_kb` 时关闭连接，`size=0` 表示发送缓冲恢复并被忽略。Skynet 首次在 1 MiB 缓冲量时告警，后续按底层告警粒度递增，因此该配置不是精确内存上限。

`idle_timeout_ticks` 限制客户端完整业务消息之间的空闲时间。WebSocket ping/pong 与服务端 Push 不重置该计时；TCP 正在读取定长数据时使用独立的 `read_timeout_ticks`。

## 连接广播

connection_id=0 的广播只作用于当前 Gateway 实例。多 Gateway 节点的全局广播由上层节点管理器负责向每个 Gateway 实例分别发送 send_data。Gateway 不保存跨节点业务状态。

## 关闭连接

业务通过 close 请求关闭指定连接。Gateway 校验当前 gateway_epoch 和 connection_id，先摘除连接，再关闭底层 TCP/WebSocket。关闭不取消 Battle 已经接纳的业务操作。

## 生成与验证

运行时不读取 proto，也不 require 宿主的固定 config.gateway。每个课程构建入口使用固定 protoc 生成本课 descriptor，并调用 gateway/tools/generate_gateway_registry.py 生成 protocol_registry_<course>.lua；宿主 composition root 选择课程配置并显式传入 start。协议源、descriptor、Registry 和客户端生成物必须来自同一协议版本。

当前课程协议版本为4：Gateway不读取、生成或回传request_id。定向Push通过正connection_id投递，0广播；两者都必须匹配当前gateway_epoch与ready连接。业务需要的序号/幂等/关联保留在data中，由宿主负责。
