---@meta

--- Gateway 跨文件使用的数据合同，供 LuaLS 分析。

---@alias GatewayTransport "tcp"|"websocket"

---@class GatewayConnection
---@field handshake HandshakeContext 当前连接独占的握手状态。
---@field connection_id integer Gateway 单调递增逻辑连接编号。
---@field fd integer Gateway 独占的底层 Socket fd；不传给业务。
---@field peer string Listener 收到的对端地址，供 Worker 接入 WebSocket 使用。
---@field transport GatewayTransport 当前传输类型。
---@field closed boolean 是否已从连接表摘除。
---@field read_started_ms? integer TCP 定长读取或 WebSocket Upgrade 的单调毫秒起点，nil 表示没有等待中的读取。
---@field last_message_at_ms? integer 握手确认或最近一条完整客户端业务消息的单调毫秒读数，用于判断业务空闲。

---@alias GatewayEventKind "open"|"ready"|"close"|"error"|"warning"

---@class GatewayEvent
---@field kind GatewayEventKind 连接生命周期、协议或资源边界事件类型。
---@field code? string 稳定诊断类别；不携带业务错误合同。
---@field message? string 面向运维的诊断文本，不作为业务响应。
---@field connection_id? integer 当前 Gateway 实例内的逻辑连接编号。

---@class GatewayStartConfig
---@field host? string 监听地址；缺省绑定 127.0.0.1。
---@field port integer 必需监听端口，范围 1..65535。
---@field transport? GatewayTransport 缺省 tcp；实例运行期间不切换。
---@field handler_service string 已注册的本地 Skynet Service 名，用于投递业务请求。
---@field descriptor_path string 宿主构建生成的 Protobuf descriptor 文件路径。
---@field registry_module string 已生成的协议 registry 模块名。
---@field protocol_version integer Envelope 使用的协议版本。
---@field read_timeout_ms? integer TCP 定长读取或 WebSocket Upgrade 的读取上限，单位毫秒；默认 30000。
---@field idle_timeout_ms? integer 客户端完整业务消息空闲上限，单位毫秒；默认 300000；WebSocket ping/pong 和服务端 Push 不重置。
---@field handshake_timeout_ms? integer 从连接登记起算的握手总期限，单位毫秒；默认 10000。
---@field max_clients integer 宿主显式提供的实例接纳配额，正整数；包含尚未完成握手的连接。
---@field worker_count? integer Worker 数；缺省取当前 Node 的 thread，范围为 1 到 thread。

---@class GatewayStartResult
---@field address string 实际监听地址。
---@field port integer 实际监听端口。
---@field transport GatewayTransport 实例使用的传输协议。

---@class GatewayStopResult
---@field closed_connections integer 本次 stop 由各 Worker 首次摘除并提交关闭的连接总数。

---@class GatewayOutboundMessage
---@field gateway_epoch string Gateway 启动时生成的身份，拒绝前一实例迟到的响应。
---@field connection_id integer 当前实例的连接编号；0 表示广播给所有已就绪连接。
---@field command_id integer registry 中声明 response_type 的正整数命令 ID。
---@field data table 已构造的业务 response 或主动 Push message；Gateway 只负责编码。

---@class GatewayCloseRequest
---@field gateway_epoch string Gateway 启动时生成的身份，用于拒绝旧实例的迟到关闭命令。
---@field connection_id integer 当前实例的逻辑连接编号；不是底层 fd。
