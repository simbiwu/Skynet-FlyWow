# FlyWow Gateway

## 解决的问题

`flywow_gateway` 是业务无关的 Skynet 接入 Service。它把 TCP 或 Skynet 内置 `http.websocket` transport 统一转换成：

```text
Envelope bytes
-> descriptor/registry 校验
-> command + 已解码 request
-> handler Service
-> response table
-> response Envelope bytes
```

宿主不需要注册 command，也不接触 `fd`、`netpack`、WebSocket frame、Protobuf body 或写缓冲区。

## 边界和依赖

- 需要宿主提供 pinned Skynet；WebSocket 使用 `http.websocket`，不重复实现握手和 frame parser。
- 需要宿主提供 `lua-protobuf` 与生成 descriptor。
- `.proto` 是唯一协议源；框架自带 `tools/generate_gateway_registry.py` 在构建阶段生成 Lua registry，业务仓库不复制也不手工维护生成器。
- Gateway 只负责接入、协议、资源上限和跨 Service 调用；不包含 Battle、SLG、玩家或地图业务。

## Service 合同

宿主工程提供标准默认配置 `config/gateway.lua`。它负责监听地址、transport、协议产物位置和资源上限；Gateway 启动时只读加载一次。

composition root 通常只注入业务 handler：

```lua
local gateway = skynet.newservice("flywow_gateway")
skynet.call(gateway, "lua", "start", {
    handler_service = query_service,
})
```

测试或多实例部署可以覆盖少量顶层配置；未覆盖字段继续使用 `config.gateway`：

```lua
skynet.call(gateway, "lua", "start", {
    handler_service = query_service,
    transport = "websocket",
    port = 19002,
})
```

`handler_service` 必须显式传入，因为它是业务 Service handle，不能通过全局名字或协议文件推导。

`handler_service` 必须实现：

```lua
skynet.dispatch("lua", function(_, _, command, payload)
    assert(command == "gateway_dispatch")
    -- payload.command、payload.request、payload.request_id、payload.connection_id
    -- 已经通过 registry 和 Protobuf 校验。
    skynet.retpack({ ok = true, response = business_response })
end)
```

业务拒绝使用：

```lua
skynet.retpack({
    ok = false,
    error = { code = "AUTH_REQUIRED", message = "authentication required" },
})
```

Gateway 不把 `fd` 传给业务。业务看到的是 `connection_id`、`peer`、`transport`、`request_id`、`command_id`、`command` 和已解码 `request`。

## 多实例与端口

每个 flywow_gateway Service 都拥有独立 Lua State、监听 fd、连接表、协议 codec 和生命周期。需要监听多个端口时，宿主只需创建多个 Gateway Service，并为每个实例传入不同的 port；可以让它们共享同一个业务 handler，也可以注入不同的 handler。

多实例启动时，分别调用 start 并保存每个 Service handle。每个实例的 config.gateway 仍提供默认值，start 只覆盖当前实例的顶层字段。停服时分别调用 stop。不能让多个实例共享连接表、监听 fd 或可变配置，也不能使用全局服务名隐藏这些依赖。

## 协议生成

RPC 前的注释声明 command id：

```proto
service NavigationService {
  // command_id=1001
  rpc QueryCell(QueryCellRequest) returns (QueryCellResponse);
}
```

构建阶段由宿主的 Server build 调用 FlyWow 生成器：

```bash
python3 "$FLYWOW_ROOT/tools/generate_gateway_registry.py" \
  --proto shared/protocol/navigation_query.proto \
  --output server/lualib/protocol/navigation_registry.lua
```

业务开发者只维护 `.proto`。重复 command、缺少 command_id、没有 RPC 或类型关系不完整时构建失败；`navigation_registry.lua` 是生成物，不应手工编辑。运行时只加载生成物，不读取 `.proto`。

## Transport

### TCP

TCP framing 固定为：

```text
uint16 big-endian payload length
Envelope protobuf bytes
```

每条连接顺序处理请求，跨连接可以并行；单连接不会无限积压业务调用。frame、Socket buffer、在线连接和写缓冲均有上限。

### WebSocket

WebSocket 使用 Skynet 固定版本的：

```lua
require "http.websocket"
```

Skynet 负责 Upgrade、mask、fragment、ping/pong 和 close frame。FlyWow 只接收 binary message，并复用同一套 Envelope/registry/handler。文本消息拒绝，协议错误关闭连接并产生 error 事件。

## error 与 warning

Gateway 统一记录并可选投递 `observer_service`：

```text
open
close
error: ENVELOPE_DECODE / PROTOCOL_VERSION / UNKNOWN_COMMAND / REQUEST_DECODE /
       HANDLER_CALL / HANDLER_RESULT / RESPONSE_ENCODE / WRITE_FAILED / WEBSOCKET_ERROR
warning: MAX_CONNECTIONS / WRITE_BACKPRESSURE
```

事件包含 `kind`、`code`、`message`、`connection_id`、`transport`、`peer`、`command` 等字段。Observer 使用 `skynet.send`，观察系统故障不能阻塞业务请求。

## 验证和运维

必须验证：

- TCP 和 WebSocket 成功请求；
- 半包/粘包或 WebSocket fragment；
- 未知 command、错误 descriptor、错误版本和非法 Protobuf；
- 文本 WebSocket、错误 mask、超长 frame；
- 连接上限、写缓冲 warning、关闭和重复 close；
- handler 抛错、业务拒绝、Server stop 后资源释放。

升级时必须同时检查 Skynet 版本、`http.websocket` 行为、descriptor、registry 和协议版本；不能静默替换任一运行时依赖。
