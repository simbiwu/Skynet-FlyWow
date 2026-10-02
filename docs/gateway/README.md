# FlyWow Gateway

## 文档入口

- 第一次接入：[完整接入指南](接入指南.md)，按依赖、协议、配置、启动、Unity/H5、关闭和验收逐步操作。
- 配置复制起点：[Gateway 配置示例](flywow_gateway_config.example.lua)，说明每个字段的用途、读取时机、生成依赖和调用方式。
- 当前文件：模块边界、Service/endpoint公开合同、资源限制与运维。
- [握手详细合同](握手合同.md)：四条消息的字节布局、动态secret派生、状态机和SDK接口。


## 接入握手

连接必须先完成框架内置P-256随机挑战握手，业务只收到ready后的请求。无需登录、宿主会话表或Watchdog；握手状态机在独立模块，详见[合同与SDK](握手合同.md)。宿主构建OpenSSL 3 EVP绑定并配置lua_cpath，客户端与Server同步升级。没有旧客户端绕过开关，不增加CRC或包头加密。

## 解决的问题

`flywow_gateway` 是业务无关的 Skynet 接入 Service。它把 TCP 或 Skynet 内置 `http.websocket` transport 统一转换成：

```text
Envelope bytes
-> descriptor/registry 校验
-> command + 已解码 request
-> send(handler Service)，立即继续读取

handler完成 -> send(gateway_response) -> response Envelope bytes
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
skynet.call(gateway, "lua", "start",
{
    handler_service = query_service,
}
)
```

测试或多实例部署可以覆盖少量顶层配置；未覆盖字段继续使用 `config.gateway`：

```lua
skynet.call(gateway, "lua", "start",
{
    handler_service = query_service,
    transport       = "websocket",
    port            = 19002,
}
)
```

`handler_service` 必须显式传入，因为它是业务 Service handle，不能通过全局名字或协议文件推导。

`handler_service` 接收单向 `gateway_dispatch` 和 `gateway_disconnect`。处理完成后单向发送 `gateway_response`；数据平面不使用 `retpack`，业务可通过 `context:close()` 主动断开连接。这是相对于旧同步 handler 的不兼容 API 变更，宿主必须同时迁移。

业务可以在自己已有的 dispatch 中使用薄接入模块：

```lua
local endpoint = require "flywow.gateway.endpoint"

-- 接收本地 Gateway 解码请求；query(request) 是宿主实际业务函数。
-- source 是 Gateway handle；query 可以 yield，Gateway 的读取不会等待它。
skynet.dispatch("lua", function(session, source, command, payload)
    if command == "gateway_disconnect" then return end
    assert(command == "gateway_dispatch" and session == 0)
    local context = endpoint.new(
    {
        gateway_service = source,
        request         = payload,
    }
    )
    local response = query(payload.request)
    assert(context:reply(response))
end)
```

真实可运行例子见宿主的 `service/battle/navigation_query.lua` 和 `service/tests/gateway_async_smoke.lua`。`endpoint.new` 不保存业务 body，只快照路由字段；context 归调用方，可保留到业务异步完成。每个 context 最多回复一次，重复回复返回 `false, "DUPLICATE_REPLY"`，发送失败返回 `false, "SEND_FAILED"`。默认本地 send 不 yield；自定义 `send(message)` 是否 yield 由宿主负责，返回 false/抛错视为失败、其他返回视为成功。调用方修改 options 不改变已构造的上下文。

辅助模块不接管 dispatch、不创建业务协程、不包含 Cluster、不保存全局请求表。业务拒绝应形成宿主 `.proto` 定义的 response table；Gateway 不解释业务错误码。处理异常也由宿主 handler 收敛为其响应类型。

### 内部消息合同

`gateway_dispatch` 携带 `gateway_epoch`、`connection_id`、`peer`、`transport`、`request_id`、`command_id`、`command`、`request`。`source` 是实际本地 Gateway handle；跨进程路由由宿主适配器显式保存/传递，不由框架发现。

`gateway_response` 的参数为：

```lua
{
    gateway_epoch = payload.gateway_epoch, -- 必须匹配当前 Gateway 启动身份。
    connection_id = payload.connection_id, -- 当前连接；fd 从不暴露。
    command_id    = payload.command_id, -- 使用 registry 的 response_type。
    request_id    = payload.request_id, -- 不在 Gateway 查询或保存等待记录。
    response      = response, -- 业务产生的 Protobuf table。
}
```

Gateway 只接受配置的 handler 发来的结果。实例身份不同、连接已关闭或 Service 已停止的响应丢弃；编码错误只产生事件，不关闭健康连接；写失败摘除并关闭连接。`gateway_disconnect` 携带实例身份与连接编号，用于宿主释放自己的会话/路由，不等于取消已接纳业务。

请求编号保留 .proto 的 uint64 位模式，0保留给主动消息；高位在 pinned Lua 中表现为负整数，也必须原样回复，不能按正负过滤。主动消息可以复用已登记的 response_type：构造请求上下文时把 `request_id` 设为0，再使用相同回复入口。当前不支持未登记的独立推送类型，不新增 Envelope kind/endpoint/Cluster 等字段。

### 入站与出站互不等待

```text
客户端 A -> 完整帧 -> 解码 -> skynet.send(handler) -> 继续读取 B
handler 完成 A -> skynet.send(gateway_response) -> 编码 -> 写当前连接
```

响应允许 B、A 顺序，客户端按请求编号匹配；业务顺序归业务 Service。send 只表示本地投递/写队列接纳，不表示远端执行或客户端收到；可靠性、重试与去重不属于 Gateway。

## 多实例与端口

每个 flywow_gateway Service 都拥有独立 Lua State、监听 fd、连接表、协议 codec 和生命周期。需要监听多个端口时，宿主只需创建多个 Gateway Service，并为每个实例传入不同的 port；可以让它们共享同一个业务 handler，也可以注入不同的 handler。

多实例启动时，分别调用 start 并保存每个 Service handle。每个实例的 config.gateway 仍提供默认值，start 只覆盖当前实例的顶层字段。停服时分别调用 stop。不能让多个实例共享连接表、监听 fd 或可变配置，也不能使用全局服务名隐藏这些依赖。

## 协议生成

RPC 前的注释声明 command id：

```proto
service NavigationService
{
  // command_id=1001
  rpc QueryCell(QueryCellRequest) returns (QueryCellResponse);
}
```

构建阶段由宿主的 Server build 调用 FlyWow 生成器：

```bash
python3 server/third_party/skynet-flywow/tools/generate_gateway_registry.py \
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

每条连接顺序读取和投递，立即继续读下一帧，不等待 handler 或业务结果。frame、Socket buffer、在线连接和入站速率受配置限制；超限关闭来源连接。

### WebSocket

WebSocket 使用 Skynet 固定版本的：

```lua
require "http.websocket"
```

Skynet 负责 Upgrade、mask、fragment、ping/pong 和 close frame。FlyWow 只接收 binary message，并复用同一套 Envelope/registry/handler。文本消息拒绝，协议错误关闭连接并产生 error 事件。

当前公开合同只提供 `ws`。TLS 由宿主前置终止；Gateway 不使用 Skynet `wss` 的默认证书路径，也不把未实现的证书注入、轮换和失败回滚包装成已交付能力。

## error 与 warning

Gateway 统一记录并可选投递 `observer_service`：

```text
open
close
error: ENVELOPE_DECODE / PROTOCOL_VERSION / UNKNOWN_COMMAND / REQUEST_DECODE /
       REQUEST_ID / HANDLER_SEND / RESPONSE_ARGUMENT / RESPONSE_ENCODE / WRITE_FAILED / WEBSOCKET_ERROR
warning: MAX_CONNECTIONS / WRITE_BACKPRESSURE / INGRESS_RATE_LIMIT
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

## 配置、容量与退出

| 配置 | 默认值 | 边界 |
| --- | --- | --- |
| max_pending_handshakes | min(128,max_clients) | 应用握手并发上限，包含TCP/WS，不能大于max_clients |
| handshake_timeout_ticks | 1000 | 总握手10秒，从连接登记开始，包含WS Upgrade |
| max_clients | 1024 | 包含尚未完成 WS 握手的连接 |
| max_frame_bytes | 65535 | 完整 Envelope 编解码上限；WS 底层另有 pinned 库的256KiB帧限制 |
| read_timeout_ticks | 3000 | 每次 TCP 定长读取和 WS 握手最多30秒，单位10ms |
| idle_timeout_ticks | 30000 | WS 完整消息空闲最多300秒 |
| max_requests_per_second | 200 | 每连接一秒窗口接纳帧数 |
| max_total_requests_per_second | 10000 | 当前 Gateway 一秒窗口总接纳帧数 |
| write_warning_close_kb | 1024 | pinned Socket 写缓冲 warning 达到该KB阈值后关闭 |

读超时由一个有界扫描协程检查，扫描间隔100ms；不是业务请求超时。入站采用固定一秒窗口，边界处可能形成突发，不把它宣称为平滑限流。限流不能保证任意下游 Skynet mailbox 有硬容量；宿主 handler 应快速消费消息，并限制业务在途和自建队列，避免无限 fork 或重试。Observer 也必须快速消费，框架不保证任意观察服务的队列容量。

连接编号单调递增且不复用，耗尽后拒绝接入；Gateway 启动身份隔离重启前的响应。TCP 完整 frame 一次 socket.write；pinned `ws` 写入由同一 Service 无 yield 调用保证帧之间不交叉，不能把这个假设迁移到未经验证的 TLS/其他 transport。

## 开发验证与升级

```bash
SKYNET_LUA=/path/to/pinned-skynet/3rd/lua/lua \
  python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/ci/check_repository.py
```

Lua 合同测试加载真实 Gateway/endpoint 源码，但 transport/codec 是替身；没有显式 SKYNET_LUA 时会明确跳过。宿主真实集成测试负责 pinned Skynet、真实 Protobuf、TCP、WS、单进程和 Cluster 路径。测试覆盖 A 延迟期间 B 完成、乱序结果、编码失败不关连接、主动消息、断线迟到回包、协议失败和网络上限。

升级必须同时迁移旧 handler 的 call/retpack 合同为双向 send，并让 handler 接受 disconnect 通知。Envelope 和协议版本不变。正常发布固定已验证的 submodule 提交；开发阶段直接使用仓库内固定的 FlyWow submodule。回滚时同步回滚框架与 handler，不能混用同步/异步 API。

## 业务主动断开

业务可在处理请求时或响应后调用 `context:close()`，默认本地 send `gateway_close`。关闭 record 只包含原 `gateway_epoch` 和 `connection_id`，不需要 request_id/token/fd，也不要求请求尚在等待。

Gateway 只接纳配置 handler 的命令；核对当前实例和连接后先 detach，向 handler 发送一次 gateway_disconnect，再异步关闭 TCP/WS。WS 使用1008和固定有限文案。重复、旧实例、已断开或未授权关闭不影响新连接。disconnect 表示 Gateway 已移除连接路由，不承诺对端收到关闭帧。

context:close 成功 true 只表示发送接纳；重复 false/DUPLICATE_CLOSE；失败 false/SEND_FAILED，可显式重试。自定义响应 sender 且未注入本地 Gateway handle 或 options.close 时返回 false/CLOSE_UNAVAILABLE。close 投递后 reply 返回 false/CONNECTION_CLOSING；reply 后 close 允许，但发送队列接纳不等于客户端已收到最后响应。

跨进程由宿主注入 options.close(message) 转发到项目 Proxy；框架不加载 Cluster。Proxy 再发送本地 gateway_close，并负责自己的返回路由清理。框架不自动向独立 Battle 进程传播 disconnect。测试覆盖 TCP/WS 关闭、重复/旧实例/来源保护、发送失败重试和独立业务进程 Cluster 路径。
