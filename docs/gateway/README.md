# FlyWow Gateway

## 文档入口

- 第一次接入：接入指南.md
- 配置复制起点：flywow_gateway_config.example.lua
- 握手合同：握手合同.md

## 职责边界

FlyWow Gateway 是业务无关的 Skynet 接入 Service，负责 TCP/WebSocket 接入、握手、心跳、连接生命周期、Envelope 编解码、send_data 转发、指定连接发送、广播和 close 控制。

Gateway 不保存业务请求，不创建 pending，不生成 route_token，不等待 Battle 结果，不判断业务成功、失败或超时，不解释业务错误。

## Service 合同

宿主通过 start 注入业务 handler：

    local gateway = skynet.newservice("flywow_gateway")
    skynet.call(gateway, "lua", "start",
    {
        handler_service = handler_service,
    })

handler Service 接收 send_data：

    {
        gateway_epoch = "...",
        connection_id = 123,
        command_id = 1001,
        data = {...},
    }

Gateway 解码客户端请求后发送 send_data。宿主处理完成后，也通过同一个 send_data 把数据发回 Gateway。Gateway 不区分请求响应和服务端主动下发。

连接控制使用 close：

    {
        gateway_epoch = "...",
        connection_id = 123,
    }

connection_id 大于 0 时发送给指定连接，等于 0 时广播给当前 Gateway 中所有已经握手成功且仍然有效的连接。

## 协议合同

客户端 Envelope 只包含：

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
- Battle 业务失败、业务超时、重试和顺序：由业务 Service 负责

## Transport

TCP 使用 uint16 big-endian 长度和 Envelope bytes。WebSocket 使用 Skynet 固定 http.websocket，复用相同 Envelope 和 registry。WebSocket 的 ping/pong、fragment 和 close frame 由底层 transport 处理；TCP 应用层心跳由宿主协议按 command 定义。

## 连接广播

connection_id=0 的广播只作用于当前 Gateway 实例。多 Gateway 节点的全局广播由上层节点管理器负责向每个 Gateway 实例分别发送 send_data。Gateway 不保存跨节点业务状态。

## 关闭连接

业务通过 close 请求关闭指定连接。Gateway 校验当前 gateway_epoch 和 connection_id，先摘除连接，再关闭底层 TCP/WebSocket。关闭不取消 Battle 已经接纳的业务操作。

## 生成与验证

运行时不读取 proto。构建阶段使用固定 protoc 生成 descriptor，使用 gateway/tools/generate_gateway_registry.py 生成 registry。协议源、descriptor、registry 和客户端生成物必须来自同一提交。
