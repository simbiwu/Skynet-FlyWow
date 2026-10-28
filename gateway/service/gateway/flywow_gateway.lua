--- 职责：提供与业务无关的 Skynet Gateway Service，统一接入 TCP 与 WebSocket。
--- 边界：FlyWow Runtime Service；拥有监听 fd、连接生命周期、frame、背压和协议编解码。
--- 输入/输出：宿主传入的完整课程配置 + handler Service -> 已解码 command/request 与编码后的 response。
--- 生命周期：由宿主通过 newservice 创建；start 后监听，stop 后释放监听 fd 和所有连接。
--- 不负责：不注册业务 command、不理解 Battle/SLG DTO、不加载 .proto 源码、不保存业务状态。
local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local registry_api = require "registry"
local codec_module = require "codec"
local handshake_module = require "handshake"

---@alias GatewayTransport "tcp"|"websocket"

---@class GatewayConnection
---@field handshake HandshakeContext 当前连接独占的握手状态。
---@field id integer Gateway 单调递增逻辑连接编号。
---@field fd integer Gateway 独占的底层 Socket fd；不传给业务。
---@field peer string 对端地址诊断字符串。
---@field transport GatewayTransport 当前传输类型。
---@field close_requested boolean 是否已经提交底层关闭，避免并发关闭重复操作。
---@field closed boolean 是否已从连接表摘除。
---@field read_started integer|nil 当前 TCP 定长读取或 WebSocket Upgrade 的起始 tick；nil 表示没有等待中的读取。
---@field last_message integer 最近一次成功处理完整消息的 tick；作为空闲超时起点。
---@field rate_started integer 本连接当前一秒接纳窗口的起点 tick。
---@field rate_count integer 本连接当前窗口已接纳的业务请求数；用于判断单连接速率上限。
local module_state =
{
    phase              = "created", -- Service 生命周期；created/starting/running/stopping/stopped。
    gateway_config     = nil,       -- 通过 start 校验后的只读配置；由 start 一次写入，后续运行阶段读取。
    registry           = nil,       -- 生成 registry 的只读索引；生命周期覆盖整个运行期。
    handshake          = nil,       -- 独立握手manager；Gateway只调用，不解析密码协议。
    codec              = nil,       -- 当前 Lua State 独占的 descriptor codec。
    listen_fd          = nil,       -- 监听 Socket fd；关闭后清空。
    connections        = {},        -- connection_id -> connection context；只由 Gateway 修改。
    connections_by_fd  = {},        -- fd -> connection context；仅用于 WebSocket 回调反查。
    next_connection_id = 0,         -- 单调递增连接标识；不复用为业务持久 ID。
    rate_started       = 0,         -- 实例一秒接纳窗口起点，单位 10ms tick。
    rate_count         = 0,         -- 当前窗口已接纳的请求数；只用于实例级限流。
    epoch              = nil,       -- 每次 Service 启动的新身份，隔离旧进程迟到响应。
    client_count       = 0,         -- 当前登记的连接数，包含握手中连接；用于 O(1) 判断 max_clients。
}
local ws_handler = {} -- Skynet WebSocket 回调表；启动时注册，运行期间不替换。

--- 把配置项校验为有界整数，避免字符串数字、小数或 NaN 进入端口和资源上限。
--- config_value 是候选数值，config_name 仅用于错误诊断，min_value/max_value 是含端点的合法范围；参数只读。
--- 返回 Lua integer；类型不符或越界时抛错。不执行 I/O、分配外部资源或 yield。
---@param config_value number 待校验的配置数值。
---@param config_name string 错误消息中标识该配置的名称。
---@param min_value integer 允许的最小值，含端点。
---@param max_value integer 允许的最大值，含端点。
---@return integer 校验通过的原值；类型错误或越界时抛错。
local function require_integer(config_value, config_name, min_value, max_value)
    assert(type(config_value) == "number" and math.type(config_value) == "integer",
           config_name .. " must be an integer")
    assert(config_value >= min_value and config_value <= max_value,
           config_name .. " must be in [" .. min_value .. ", " .. max_value .. "]")
    return config_value
end

--- 校验并复制宿主完整传入的课程配置，避免运行期间读取可变配置 table。
--- 参数 startup_config：必需的 Gateway 配置，包含 handler、descriptor、registry 和监听参数；本函数只读取输入。
--- 返回值：新建的 Service 私有规范化配置；校验失败抛错，不执行 I/O、yield 或启动资源。
---@param startup_config GatewayStartConfig 宿主传入的 Gateway 启动配置；本函数读取传输、监听、协议和资源上限字段。
---@return GatewayStartConfig 持有已校验标量的新配置表；缺少必需字段或字段越界时抛错。
local function normalize_config(startup_config)
    assert(type(startup_config) == "table", "gateway start config must be a table")
    -- Gateway 不 require 宿主业务配置；默认值只用于可选的通用传输参数。

    -- 先确认传输类型受支持，再校验端口、帧长和各项连接上限。
    local host = startup_config.host or "127.0.0.1" -- 宿主配置的监听地址；缺省只绑定回环接口。
    assert(type(host) == "string" and host ~= "", "host must be a non-empty address")
    local transport = startup_config.transport or "tcp" -- 本实例固定使用的传输类型，后续选择监听路径。
    assert(
        transport == "tcp" or transport == "websocket",
        "unsupported gateway transport: " .. tostring(transport)
    )
    if transport == "websocket" then
        -- Gateway 固定提供明文 ws；wss 必须由宿主在外部终止 TLS，不能静默降级。
        assert(
            startup_config.websocket_protocol == nil or
            startup_config.websocket_protocol == "ws",
            "websocket_protocol currently supports ws only; terminate TLS outside Gateway"
        )
    end

    -- 传输选项通过后，校验帧长、连接数、写缓冲阈值、端口和协议版本的整数范围。
    local max_frame_bytes = require_integer( -- 入站与出站 Envelope 的共同字节上限。
        startup_config.max_frame_bytes or 65535,
        "max_frame_bytes",
        1,
        0xffff
    )
    local max_clients = require_integer( -- 当前 Gateway 可登记的连接容量。
        startup_config.max_clients or 1024,
        "max_clients",
        1,
        1000000
    )
    local write_warning_close_kb = require_integer( -- Skynet 写缓冲告警触发摘除连接的 KB 阈值。
        startup_config.write_warning_close_kb or 1024,
        "write_warning_close_kb",
        1,
        0x7fffffff
    )

    local port = require_integer(startup_config.port, "port", 1, 65535) -- 宿主要求绑定的 TCP/WS 端口。
    local backlog = require_integer( -- 操作系统尚未 accept 的连接队列容量。
        startup_config.backlog or 128,
        "backlog",
        1,
        65535
    )
    local protocol_version = require_integer( -- 本实例接受和发送的 Envelope 协议版本。
        startup_config.protocol_version,
        "protocol_version",
        1,
        0xffffffff
    )

    -- handler_service 是宿主注册的本地 Skynet 服务名，发送时由 Skynet 解析当前注册者。
    local handler_service = startup_config.handler_service -- 宿主已注册的请求接收 Service 名。
    assert(type(handler_service) == "string" and handler_service ~= "",
        "handler_service must be a non-empty Skynet service name")
    -- 在返回配置副本前，确认后续启动要读取的 descriptor 文件和生成 registry 模块都已指定。
    assert(
        type(startup_config.descriptor_path) == "string" and
        startup_config.descriptor_path ~= "",
        "descriptor_path is required"
    )
    assert(
        type(startup_config.registry_module) == "string" and
        startup_config.registry_module ~= "",
        "registry_module is required"
    )

    -- 返回只包含已校验值的配置副本；运行期不再读取宿主传入的可变 table。
    return
    {
        host                          = host, -- 监听地址；只影响当前 Gateway。
        port                          = port, -- TCP/WS 监听端口，1..65535。
        backlog                       = backlog, -- OS accept backlog，不等于 max_clients。
        transport                     = transport, -- tcp 或 websocket；运行期不可切换。
        handler_service               = handler_service, -- 宿主注册的本地服务名；发送时解析当前服务。
        descriptor_path               = startup_config.descriptor_path, -- 运行目录下的 descriptor 文件路径。
        registry_module               = startup_config.registry_module, -- 生成 registry 的 require 名称。
        protocol_version              = protocol_version, -- Envelope uint32 兼容版本。
        max_frame_bytes               = max_frame_bytes, -- 单个 Envelope bytes 上限，TCP 长度前缀不计，单位 byte。
        -- TCP 分段读取和 WebSocket HTTP Upgrade 都受单次等待期限限制，避免连接长期占用槽位。
        read_timeout_ticks            = require_integer(
            startup_config.read_timeout_ticks or 3000,
            "read_timeout_ticks",
            1,
            360000
        ), -- TCP 每次定长读取/WS 握手上限，单位 10 ms。
        idle_timeout_ticks            = require_integer(
            startup_config.idle_timeout_ticks or 30000,
            "idle_timeout_ticks",
            1,
            360000
        ), -- WS 完整消息空闲上限，单位 10 ms。
        max_requests_per_second       = require_integer(
            startup_config.max_requests_per_second or 200,
            "max_requests_per_second",
            1,
            100000
        ), -- 单连接一秒窗口的最大业务请求数。
        -- 实例级上限独立保护 handler 总投递预算。
        max_total_requests_per_second = require_integer(
            startup_config.max_total_requests_per_second or 10000,
            "max_total_requests_per_second",
            1,
            1000000
        ), -- 本 Gateway 实例一秒窗口的最大业务请求数。
        -- 限制同时持有密码学握手上下文的连接数；该上限独立于全部在线连接数。
        max_pending_handshakes        = require_integer(
            startup_config.max_pending_handshakes or math.min(128, max_clients),
            "max_pending_handshakes",
            1,
            max_clients
        ), -- 含TCP与WS的应用握手并发上限。
        handshake_timeout_ticks       = require_integer(
            startup_config.handshake_timeout_ticks or 1000,
            "handshake_timeout_ticks",
            1,
            360000
        ), -- 总握手期限，10ms tick。
        max_clients                   = max_clients, -- 当前 Gateway 最大在线连接数。
        write_warning_close_kb        = write_warning_close_kb, -- 写缓冲 warning 达到此 KB 时关闭连接。
    }
end


---@alias GatewayEventKind "open"|"ready"|"close"|"error"|"warning"

---@class GatewayEvent
---@field kind GatewayEventKind 连接生命周期、协议或资源边界事件类型。
---@field code? string 稳定诊断类别；不携带业务错误合同。
---@field message? string 面向运维的诊断文本，不作为业务响应。
---@field connection_id? integer 当前 Gateway 实例内的逻辑连接编号。

--- 把连接、协议和传输边界事件写入 Skynet 日志；不向其它 Service 转发诊断消息。
--- event 只含诊断文本和连接编号，不包含业务 payload；日志输出不 yield。
---@param event GatewayEvent 本次事件的只读记录；日志写入后不保留。
---@return nil 写入 Skynet 日志。
local function log_event(event)
    skynet.error("FLYWOW_GATEWAY_" .. string.upper(event.kind),
                 " connection_id=", tostring(event.connection_id or "-"),
                 " code=", tostring(event.code or "-"),
                 " message=", tostring(event.message or "-"))
end

--- 为新连接创建唯一上下文；上下文不暴露底层 fd 给业务 Service。
--- fd 是 Skynet 接受的连接句柄，peer 是诊断用地址，transport 为 tcp/websocket；fd 始终由本 Service 独占。
--- 容量达到 max_clients 时返回 nil 且不接管连接关闭责任；成功时返回由 Gateway 状态表持有的 context。
--- connection_id 单调递增，避免 fd 被 OS 复用后旧连接身份与新连接混淆。
---@param fd integer 新接入的底层 fd；成功后由 Gateway 接管。
---@param peer string 对端地址诊断字符串。
---@param transport GatewayTransport 当前 TCP/WebSocket 传输。
---@return GatewayConnection|nil connection，或容量/身份/握手资源不足。
local function create_connection(fd, peer, transport)
    -- 连接数达到上限、连接编号耗尽或无法取得握手名额时，不接管 fd。
    if module_state.client_count >= module_state.gateway_config.max_clients then
        log_event(
        {
            kind      = "warning",
            code      = "MAX_CONNECTIONS",
            message   = "connection limit reached", -- 超出 max_clients 时拒绝新连接。
        }
        )

        return nil
    end

    -- 连接编号只增不复用；达到 Lua 整数上限时拒绝接入，避免身份与旧连接冲突。
    if module_state.next_connection_id == math.maxinteger then
        log_event(
        {
            kind    = "error",
            code    = "CONNECTION_ID_EXHAUSTED",
            message = "connection identity exhausted",
        }
        )

        return nil
    end

    -- 每个连接在登记前先占用握手名额；容量不足时不会把 fd 加入连接索引。
    local handshake, handshake_error = module_state.handshake.accept() -- 连接独占的握手状态；无名额时返回稳定错误码。
    if not handshake then
        log_event(
        {
            kind    = "error",
            code    = handshake_error,
            message = "handshake capacity reached",
        }
        )

        return nil
    end

    -- 为新连接建立私有上下文，并把刚取得的握手名额交给它持有。
    module_state.next_connection_id = module_state.next_connection_id + 1

    local connection = -- 新连接的唯一状态记录，登记到 id/fd 两个索引后由 Gateway 持有。
    {
        handshake       = handshake, -- 握手模块拥有内部状态；连接关闭时释放。
        id              = module_state.next_connection_id, -- Gateway 内部连接标识，不暴露底层 fd。
        fd              = fd, -- Gateway 私有底层 fd；业务 Service 不接收。
        peer            = peer, -- 对端地址字符串；只用于日志和业务上下文。
        transport       = transport, -- tcp 或 websocket。
        close_requested = false, -- transport 关闭只提交一次，避免两个协程同时 close/wait。
        closed          = false, -- close race 保护位；只允许从 false 到 true。
        read_started    = nil, -- 当前定长读取的开始 tick；nil 表示没有读取等待。
        last_message    = skynet.now(), -- 最近完整消息 tick；只用于网络空闲超时。
        rate_started    = skynet.now(), -- 本连接一秒接纳窗口起点，单位 10ms tick。
        rate_count      = 0,             -- 本连接当前窗口已接纳的业务请求数。
    }

    -- 两个索引都登记成功后再增加在线计数，确保按 id 和 fd 都能找到该连接。
    module_state.connections[connection.id] = connection
    module_state.connections_by_fd[fd] = connection
    module_state.client_count = module_state.client_count + 1

    -- 连接进入索引后记录 open 事件；日志输出不改变接入结果。
    log_event(
    {
        kind          = "open",
        connection_id = connection.id, -- 供宿主清理此前按此连接登记的临时数据。
    }
    )

    return connection
end


--- 从连接表中移除连接并发出一次 close 事件；重复调用不会重复递减计数。
--- connection 是本 Gateway 状态表中的 context，reason 是不含敏感数据的诊断原因。
--- 先设置 closed 再摘除两个索引，使重入/迟到回调只能观察到已关闭状态；不关闭 fd、不执行 I/O/yield。
--- 返回首次 detach 为 true，nil 或重复关闭为 false。
---@param connection GatewayConnection|nil Gateway 连接上下文。
---@param reason string|nil 不含敏感数据的关闭原因。
---@return boolean 是否首次摘除连接。
local function detach_connection(connection, reason)
    if connection == nil or connection.closed then
        return false
    end

    -- 先标记并释放本连接握手资源，再移除两个索引和在线计数；重复回调此后会直接返回。
    connection.closed = true
    module_state.handshake.close(connection.handshake)
    module_state.connections[connection.id] = nil
    module_state.connections_by_fd[connection.fd] = nil
    module_state.client_count = module_state.client_count - 1

    -- 连接身份已从 Gateway 索引移除后通知 handler，避免它继续把数据关联到已关闭连接。
    skynet.send(module_state.gateway_config.handler_service, "lua", "gateway_disconnect",
    {
        gateway_epoch = module_state.epoch, -- handler 用实例身份忽略旧 Gateway 的迟到清理。
        connection_id = connection.id, -- 与此前 send_data 使用同一个逻辑连接编号。
    }
    )

    -- 日志只记录关闭原因和逻辑连接编号，不携带对端地址或业务 payload。
    log_event(
        {
            kind          = "close", -- 连接生命周期结束事件。
            connection_id = connection.id, -- 对应 handler 收到的断开通知。
            message       = reason or "closed", -- 关闭来源只用于诊断。
        }
    )
    return true
end

--- 幂等关闭本连接的 transport；接管前用 close_fd，接管后使用 Socket/WS 关闭。
--- connection 由 Gateway 拥有；code 为 WS 状态码，reason 为有限诊断文本，不含业务数据。
--- 已提交关闭或 fd 已被新连接占用时直接结束；Socket/WS close 可能 yield。
---@param connection GatewayConnection 由 Gateway 持有的连接上下文。
---@param code integer|nil WebSocket close code；TCP 路径忽略。
---@param reason string|nil 不含业务数据的关闭原因。
---@return nil 关闭提交完成或无需重复关闭。
local function close_transport(connection, code, reason)
    if connection.close_requested then
        return
    end

    -- close 可能 yield；若 fd 已被新连接复用，旧上下文不能再关闭这个 fd。
    local current = module_state.connections_by_fd[connection.fd] -- 当前占用 fd 的连接，用于阻止旧上下文关闭复用后的 fd。
    if current and current ~= connection then
        return
    end

    -- 在任何底层 close/yield 前记录已提交，其他关闭协程看到它后不会重复操作 fd。
    connection.close_requested = true

    -- 按连接接管状态选择 WebSocket close、已登记 Socket close 或未登记 fd 的 close_fd。
    if connection.transport == "websocket" and not websocket.is_close(connection.fd) then
        websocket.close(connection.fd, code or 1001, reason or "closed")
    elseif socket.invalid(connection.fd) then
        socket.close_fd(connection.fd)
    else
        socket.close(connection.fd)
    end
end

---@class GatewayInboundRequest
---@field gateway_epoch string 当前 Gateway 实例身份；handler 用它忽略旧实例的迟到消息。
---@field connection_id integer 当前实例内的逻辑连接编号；不是底层 fd。
---@field peer string transport 提供的对端地址；仅供宿主诊断使用。
---@field transport GatewayTransport 接入该连接的 TCP 或 WebSocket 类型。
---@field command_id integer registry 中已验证的业务 command id。
---@field data table 按 command request_type 解码后的业务请求；Gateway 不再修改。

--- 解码并按读取顺序异步投递完整帧；本入口不等待任何业务响应。
--- connection/payload 由 Gateway 拥有，payload 长度单位 byte；返回 false 时调用方关闭违规连接。
--- 解码和 send 不 yield；只有连接/协议/网络资源错误影响后续读取，业务结果走独立入口。
---@param connection GatewayConnection 当前已登记连接。
---@param payload string 一条完整业务 Envelope bytes；当前调用借用，不跨 yield 保存。
---@return boolean 是否成功投递给 handler；失败由 transport 层关闭连接。
local function dispatch_payload(connection, payload)
    -- 连接已关闭、帧为空或超过配置上限时停止解码。
    if connection.closed or #payload == 0 or #payload > module_state.gateway_config.max_frame_bytes then
        log_event(
        {
            kind          = "error",
            code          = "FRAME_LIMIT",
            message       = "payload exceeds configured limit",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 将完整帧解码成 Envelope，并拒绝与本 Gateway 协议版本不符的消息。
    --- pcall 把不可信网络字节导致的解码异常限制在当前请求，便于统一发事件并关闭连接。
    local envelope_ok, envelope = pcall(module_state.codec.decode_envelope, payload) -- 捕获不可信帧解码结果；失败值用于诊断。
    if not envelope_ok then
        log_event(
        {
            kind          = "error",
            code          = "ENVELOPE_DECODE",
            message       = tostring(envelope),
            connection_id = connection.id,
        }
        )

        return false
    end

    -- Envelope 已能解码后再比较协议版本；不匹配时不查命令表或调用业务 Service。
    if envelope.protocol_version ~= module_state.gateway_config.protocol_version then
        log_event(
        {
            kind          = "error",
            code          = "PROTOCOL_VERSION",
            message       = "unsupported protocol version",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 用 wire 字段 Envelope.command 查 registry；跨 Service 记录再使用 command_id。
    -- 只按生成 registry 中的 command 定义解释 body，不从客户端输入推导消息类型。
    local definition = registry_api.find_command(module_state.registry, envelope.command) -- 当前命令对应的已验证请求/响应类型定义。
    if definition == nil then
        log_event(
        {
            kind          = "error",
            code          = "UNKNOWN_COMMAND",
            message       = "command is not in generated registry",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 已找到命令后才解码其 request body；Protobuf 错误在当前网络消息边界转成拒绝投递。
    local request_ok, request = pcall( -- 请求体解码状态及生成的业务 record。
        module_state.codec.decode_request,
        definition,
        envelope.body
    )
    if not request_ok then
        log_event(
        {
            kind          = "error",
            code          = "REQUEST_DECODE",
            message       = tostring(request),
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 分别按连接和 Gateway 实例统计一秒窗口，避免单个连接占满实例总预算。
    local now = skynet.now() -- 当前 10ms tick，用于推进连接与实例的一秒速率窗口。
    if (now - connection.rate_started) % 0x100000000 >= 100 then
        connection.rate_started = now
        connection.rate_count = 0
    end

    -- 连接窗口之外，独立重置实例总量窗口。
    if (now - module_state.rate_started) % 0x100000000 >= 100 then
        module_state.rate_started = now
        module_state.rate_count = 0
    end

    -- 任一上限已满就拒绝当前来源连接；超限帧不计入已接纳请求数。
    if connection.rate_count >= module_state.gateway_config.max_requests_per_second or
        module_state.rate_count >= module_state.gateway_config.max_total_requests_per_second then
        log_event(
        {
            kind          = "warning",
            code          = "INGRESS_RATE_LIMIT",
            message       = "ingress rate exceeded",
            connection_id = connection.id,
        }
        )
        return false
    end

    -- 两项上限都通过后才占用本帧的接纳额度。
    connection.rate_count = connection.rate_count + 1
    module_state.rate_count = module_state.rate_count + 1

    -- 完整 request 已获准投递；刷新空闲计时后异步交给宿主处理。
    connection.last_message = now

    -- 将 request、command 和连接身份异步发送给宿主指定的 handler Service；发送失败时由传输层关闭连接。
    --- 只传递连接身份、command_id 和已解码数据；Gateway 不缓存业务请求。
    local inbound_request = -- 本帧交给 handler 的连接上下文与业务请求；send 后 Gateway 不保存。
    {
        gateway_epoch = module_state.epoch, -- 让 handler 忽略旧 Gateway 实例的迟到消息。
        connection_id = connection.id, -- 使用逻辑连接号，不暴露底层 fd。
        peer          = connection.peer, -- 连接建立时记录的对端地址，仅供宿主诊断。
        transport     = connection.transport, -- 标明该连接使用 TCP 还是 WebSocket。
        command_id    = definition.id, -- 由 registry 验证过的业务命令号。
        data          = request, -- 已按 registry 请求类型解码的业务内容。
    }
    local call_succeeded, send_result_or_error = pcall( -- 投递调用是否抛错，以及 send 返回值或异常文本。
        skynet.send,
        module_state.gateway_config.handler_service,
        "lua",
        "send_data",
        inbound_request
    )

    -- pinned Skynet 的 send 成功返回 true、失败返回 false；pcall 的首值只表示是否抛错。
    if not call_succeeded or send_result_or_error ~= true then
        log_event(
        {
            kind          = "error",
            code          = "HANDLER_SEND",
            message       = tostring(send_result_or_error), -- send 异常或 false 返回值，用于定位 handler 投递失败。
            connection_id = connection.id, -- 对应触发投递失败的连接。
        }
        )

        return false
    end

    return true
end


--- 将完整 Envelope 写入一个连接；TCP 前置 uint16 长度头，WebSocket 发送 binary message。
--- 写入异常或底层明确拒绝时会摘除连接并异步关闭；成功只表示本地传输接受写入。
---@param connection GatewayConnection Gateway 独占的目标连接；本函数读取 transport、fd 和 id。
---@param encoded string 已编码的完整 Envelope bytes；由调用方创建，本函数不保存。
---@return boolean 是否被底层传输接受；失败时连接已安排关闭。
local function write_connection(connection, encoded)
    local call_succeeded, write_result_or_error -- pcall 是否抛错，以及 transport 返回值或异常文本。

    if connection.transport == "tcp" then
        call_succeeded, write_result_or_error = pcall(
            socket.write,
            connection.fd,
            string.pack(">I2", #encoded) .. encoded
        )
        call_succeeded = call_succeeded and write_result_or_error ~= false
    else
        call_succeeded, write_result_or_error = pcall(
            websocket.write,
            connection.fd,
            encoded,
            "binary"
        )
    end

    -- 底层写失败时先报告并摘除连接，再异步关闭可能仍在写缓冲中的传输。
    if not call_succeeded then
        log_event(
        {
            kind          = "error",
            code          = "WRITE_FAILED",
            message       = tostring(write_result_or_error), -- 底层异常或拒绝结果，用于定位传输写失败。
            connection_id = connection.id, -- 对应被摘除的连接。
        }
        )

        detach_connection(connection, "write failed")
        skynet.fork(function()
            close_transport(connection, 1011, "write failed")
        end)
        return false
    end

    -- 本地传输接受写入即成功；该结果只供单播/广播调用决定是否继续处理。
    return true
end

---@class GatewayOutboundMessage
---@field gateway_epoch string Gateway 启动时生成的身份，拒绝前一实例迟到的响应。
---@field connection_id integer 当前实例的连接编号；0 表示广播给所有已就绪连接。
---@field command_id integer registry 中声明 response_type 的正整数命令 ID。
---@field data table 已构造的业务 response 或主动 Push message；Gateway 只负责编码。
--- 处理 handler 发来的业务响应或主动 Push；校验实例/连接身份后编码并写入传输。
--- 无效消息、未知命令、编码失败或目标连接已关闭时丢弃；本函数只产生传输副作用。
---@param outbound_message GatewayOutboundMessage handler 发来的记录；读取 gateway_epoch、connection_id、command_id 和 data。
---@return nil 本入口没有业务返回值；没有可写目标时结束当前消息处理。
local function deliver_outbound_message(outbound_message)
    -- 校验响应记录和 connection_id；发送方身份由宿主 Service 注册边界保证。
    if not module_state.gateway_config or type(outbound_message) ~= "table" or
        outbound_message.gateway_epoch ~= module_state.epoch or
        module_state.phase ~= "running" then
        return
    end

    -- 实例身份通过后再校验目标、命令和业务响应类型，避免访问不完整记录。
    if math.type(outbound_message.connection_id) ~= "integer" or
        outbound_message.connection_id < 0 or
        math.type(outbound_message.command_id) ~= "integer" or
        outbound_message.command_id <= 0 or
        type(outbound_message.data) ~= "table" then
        return
    end

    -- 从 registry 取得该命令的 response 类型，并把业务 table 编码成完整 Envelope。
    -- 消息字段有效后查找响应类型；单向命令没有 response_type，不能用于此入口。
    local definition = registry_api.find_command(module_state.registry, outbound_message.command_id) -- 出站消息声明的响应类型。
    if not definition or definition.response_type == nil then
        return
    end

    -- 编码器可能因业务 table 不符合 Protobuf schema 而抛错；在消息入口转换为失败并记录事件。
    local ok, encoded = pcall( -- 编码调用状态及 Envelope bytes 或错误值。
        module_state.codec.encode_response,
        definition,
        module_state.gateway_config.protocol_version,
        outbound_message.data
    )
    if not ok or #encoded > module_state.gateway_config.max_frame_bytes then
        log_event(
        {
            kind          = "error",
            code          = "RESPONSE_ENCODE",
            message       = ok and "response exceeds frame limit" or tostring(encoded),
            connection_id = outbound_message.connection_id,
        }
        )
        return
    end

    -- 把编码后的响应写给指定 ready 连接，或写给当前全部 ready 连接。
    if outbound_message.connection_id == 0 then
        for _, connection in pairs(module_state.connections) do
            if not connection.closed and
                module_state.handshake.ready(connection.handshake) then
                write_connection(connection, encoded)
            end
        end

        return
    end

    -- 单播只查当前连接索引；连接已关闭或握手未完成时不能写入。
    local connection = module_state.connections[outbound_message.connection_id] -- 当前实例拥有的目标连接；广播已在前一分支处理。
    if not connection or connection.closed or
        not module_state.handshake.ready(connection.handshake) then
        return
    end

    -- 单播目标已经验证为当前 ready 连接；写入失败由 write_connection 摘除并关闭它。
    write_connection(connection, encoded)
end

---@class GatewayCloseRequest
---@field gateway_epoch string Gateway 启动时生成的身份，用于拒绝旧实例的迟到关闭命令。
---@field connection_id integer 当前实例的逻辑连接编号；不是底层 fd。

--- 接收 handler 的主动断开命令；只按当前实例与连接身份关闭，不查业务请求记录。
--- close_request.gateway_epoch/connection_id 来自原请求或项目会话；发送方由宿主信任边界管理。
--- 旧实例、失效连接或重复关闭请求直接忽略，不影响新连接。
--- 先摘除连接，再 fork transport 关闭；消息入口不 yield，关闭任务可能 yield。
---@param close_request GatewayCloseRequest 当前 handler 请求关闭的连接身份。
---@return nil 关闭请求处理完成；无效或重复请求直接结束。
local function request_close(close_request)
    -- 校验关闭请求属于当前实例，并确认目标连接仍在连接索引中。
    if not module_state.gateway_config or module_state.phase ~= "running" or
        type(close_request) ~= "table" or close_request.gateway_epoch ~= module_state.epoch or
        math.type(close_request.connection_id) ~= "integer" then
        return
    end

    -- 请求身份有效后再查当前连接索引，迟到命令不会按复用的 fd 关闭新连接。
    local connection = module_state.connections[close_request.connection_id] -- close 请求指定的本实例连接。
    if not connection or not detach_connection(connection, "closed by handler") then
        return
    end

    --- 关闭前已摘除索引，随后到达的 response/close 不会再使用该连接；fd 不暴露给业务。
    skynet.fork(function()
        close_transport(connection, 1008, "closed by server")
    end)
        return
end


--- 从 TCP 字节流读取指定数量的字节；TCP 不保留消息边界，因此 header/body 必须分别读满。
--- connection 是当前 Gateway 持有的 TCP 上下文；size 是正整数 byte 数。成功返回新 bytes string，失败返回 nil。
--- socket.read 执行 I/O 并可能 yield；返回后检查 connection.closed，防止继续使用已摘除的 fd。
---@param connection GatewayConnection 当前 TCP 连接；读取可能 yield。
---@param size integer 必须读取的 byte 数；由当前握手/业务阶段决定。
---@return string|nil 完整 bytes；失败返回 nil，调用方据此结束当前 TCP 会话。
local function read_exact(connection, size)
    connection.read_started = skynet.now()

    local received_bytes = socket.read(connection.fd, size) -- 本次定长读取的结果；恢复后先检查连接身份。

    connection.read_started = nil

    if connection.closed then
        return nil
    end

    if not received_bytes then
        return nil
    end

    if #received_bytes ~= size then
        return nil
    end

    return received_bytes
end


--- 将当前握手消息交给独立模块并发送其输出；Gateway不解析握手字段。
--- connection/bytes只在本调用借用；返回boolean，失败由调用方关闭；写失败不提交ready。
--- pinned TCP/WS写不yield；完成后只保留ready标记，不持有secret。
---@param connection GatewayConnection 当前未 ready 的连接。
---@param bytes string 一条完整握手消息；不跨调用保存。
---@return boolean 是否成功写出 response 并在最后阶段提交 ready。
local function process_handshake(connection, bytes)
    -- 由握手模块校验当前阶段的消息并生成响应；Gateway 不读取握手字段。
    local response, code, confirm = module_state.handshake.receive( -- 握手响应、稳定错误码及是否需写后确认 ready。
    {
        context = connection.handshake, -- 本连接独占的握手状态；receive 只改这个 context。
        bytes   = bytes, -- 当前完整网络帧；借用到本次同步解码结束，不保存。
    }
    )

    if not response then
        log_event(
        {
            kind          = "error",
            code          = code,
            message       = "handshake rejected",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 将握手模块生成的响应写回原传输；只有发送成功后才提交 ready。
    local ok, result -- pcall 执行状态及底层 write 返回值或异常。
    if connection.transport == "tcp" then
        ok, result = pcall(
            socket.write,
            connection.fd,
            string.pack(">I2", #response) .. response
        )
    else
        ok, result = pcall(
            websocket.write,
            connection.fd,
            response,
            "binary"
        )
    end

    if not ok or result == false or connection.closed then
        return false
    end

    -- 完整握手消息已成功往返，刷新活动时间；握手总期限仍由独立绝对期限限制。
    connection.last_message = skynet.now()

    -- 最后一条握手响应已成功写出后才提交 ready；失败时连接仍不能收发业务消息。
    if confirm then
        if not module_state.handshake.confirm(connection.handshake) then
            return false
        end

        log_event(
        {
            kind          = "ready",
            connection_id = connection.id,
            message       = "handshake complete",
        }
        )
    end

    return true
end


--- 运行一个已登记 TCP 连接；本协程串行读取和投递，直到 EOF、错误或 Service 停止。
--- connection 由 Gateway 状态表持有并提供 fd；frame 为 2 byte uint16 big-endian 长度头 + Envelope bytes，长度不含头。
--- 先检查长度再读取 body，防止按不可信长度分配/缓存过量数据；限制 socket 缓冲区以施加背压。
--- 读取 Socket 时 yield；投递不等待业务。所有退出路径都 detach 并关闭 fd。
---@param connection GatewayConnection Gateway 独占的 TCP 连接。
---@return nil 直到 EOF、协议错误、超时或 Server 停止后退出并清理连接。
local function run_tcp(connection)
    -- 已 detach 的连接不能再启动读取协程，避免关闭后重新使用 fd。
    if connection.closed then
        return
    end

    -- 启动 TCP fd，限制接收缓冲；另用 warning 回调处理写缓冲积压。
    local fd = connection.fd -- 当前协程操作的连接 fd；由连接记录持有。
    local opened, open_error = socket.start(fd) -- 启动结果必须是原 fd；失败值用于异常诊断。

    if connection.closed then
        return
    end

    --- pinned socket.start 成功返回原 fd；失败返回 nil 和错误文本，不能按布尔 true 判断。
    assert(opened == fd, tostring(open_error))

    socket.limit(fd, module_state.gateway_config.max_frame_bytes + 2)
    socket.warning(fd, function(_, size)
        log_event(
        {
            kind          = "warning",
            code          = "WRITE_BACKPRESSURE",
            message       = "TCP write buffer is large",
            connection_id = connection.id, -- 便于把写缓冲告警与连接日志对应。
        }
        )

        if size >= module_state.gateway_config.write_warning_close_kb then
            detach_connection(connection, "write backpressure")
            close_transport(connection, 1013, "write backpressure")
        end
    end)

    -- 每轮先读满长度头并校验上限，再读完整帧体；未完成握手的帧交给握手流程，其余帧进入业务解码。
    while not connection.closed and module_state.phase == "running" do
        local header = read_exact(connection, 2) -- TCP 的两字节长度前缀，不属于 Envelope。
        if not header then
            break
        end

        --- >I2 表示网络字节序 uint16；先拒绝 0 或超限长度，再按该值读取 body。
        local size = string.unpack(">I2", header) -- 网络序长度前缀给出的帧体字节数，先校验再读取。
        local ready = module_state.handshake.ready(connection.handshake) -- 决定使用握手固定长度还是业务帧上限校验。

        if (not ready and size ~= module_state.handshake.expected_size(connection.handshake)) or
            (ready and (size < 1 or size > module_state.gateway_config.max_frame_bytes)) then
            log_event(
            {
                kind          = "error",
                code          = "FRAME_LIMIT",
                message       = "invalid TCP frame length",
                connection_id = connection.id,
            }
            )

            break
        end

        -- 长度已通过握手阶段或业务帧上限检查，现在才读取完整帧体。
        local payload = read_exact(connection, size) -- 长度已验证的完整握手或 Envelope 字节。
        if not payload then
            break
        end

        if ready then
            if not dispatch_payload(connection, payload) then
                break
            end
        elseif not process_handshake(connection, payload) then
            break
        end
    end

    -- 无论 EOF、协议错误还是 Service 停止，都从索引摘除连接并关闭 TCP fd。
    detach_connection(connection, "tcp session ended")
    close_transport(connection, 1001, "tcp session ended")
end


--- 处理已由 Skynet 完成拼帧的 WebSocket message；底层库负责 Upgrade、mask、fragment 与 ping/pong。
--- id 是 Skynet connection id，payload 是单条完整消息 bytes，opcode 标识文本或 binary；payload 不跨回调保存。
--- 仅接受 binary 且受 max_frame_bytes 限制；函数无返回值，失败时发事件并关闭当前连接。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@param payload string 一条完整 WebSocket 消息的字节内容。
---@param opcode string 底层解析出的 text/binary 消息类型。
---@return nil 无业务返回值；不支持的消息或协议失败时关闭该连接。
function ws_handler.message(id, payload, opcode)
    local connection = module_state.connections_by_fd[id] -- 当前 WebSocket 回调对应的连接；关闭或迟到回调时可能不存在。
    if not connection or connection.closed then
        return
    end

    -- 先拒绝 WebSocket text；协议只定义 binary message 与握手/Envelope 字节。
    if opcode ~= "binary" then
        log_event(
        {
            kind          = "error",
            code          = "TEXT_MESSAGE_REJECTED",
            message       = "only binary WebSocket messages are accepted",
            connection_id = connection.id,
        }
        )
        detach_connection(connection, "text message rejected")
        close_transport(connection, 1003, "binary messages required")
        return
    end

    -- ready 前的 binary message 属于握手；ready 后才按业务 Envelope 解码并投递。
    local ok -- 当前握手帧或业务帧是否接受；false 时摘除该连接。
    if module_state.handshake.ready(connection.handshake) then
        ok = dispatch_payload(connection, payload)
    else
        ok = process_handshake(connection, payload)
    end

    -- 只有当前握手或业务帧处理失败才关闭连接；成功路径保持 Socket 打开。
    if not ok then
        detach_connection(connection, "protocol rejected")
        close_transport(connection, 1008, "gateway request rejected")
    end
end

--- WebSocket 握手完成后清除握手计时；连接在 accept 时已登记，HTTP Upgrade 由 Skynet 完成。
--- id 是 Skynet connection id；header/url 由底层拥有且本函数不保存；peer 使用 accept 的实际对端地址。
--- 无返回值，不执行跨 Service 调用或 yield；超过 max_clients 的连接在握手前拒绝。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@param header table HTTP Upgrade 请求头；只读且不保存。
---@param url string 客户端请求路径；只读且不保存。
---@return nil 记录握手完成时间，不返回业务数据。
function ws_handler.handshake(id, header, url)
    local connection = module_state.connections_by_fd[id] -- 当前 WebSocket 回调对应的连接；关闭或迟到回调时可能不存在。
    if not connection or connection.closed then
        return
    end

    -- HTTP Upgrade 成功后应用握手期限开始；从此按完整消息活动时间检查空闲连接。
    connection.read_started = nil
    connection.last_message = skynet.now()
end

--- WebSocket 关闭回调中移除连接；底层库负责释放 Socket，本函数只清理 Gateway 索引。
--- id 是 Skynet WebSocket connection id；迟到或重复回调由 detach 的幂等性处理。无返回值，不执行 I/O/yield。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@return nil 从 Gateway 连接索引摘除连接；重复回调不重复处理。
function ws_handler.close(id)
    detach_connection(module_state.connections_by_fd[id], "websocket closed")
end

--- 将 WebSocket 底层传输错误转为统一 Gateway error 事件并摘除连接。
--- id 是 Skynet connection id，message 是底层诊断文本；不包含业务 payload。无返回值，只修改本 Service 的连接索引。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@param message string Skynet 提供的传输错误文本；不含业务消息。
---@return nil 记录错误并摘除连接。
function ws_handler.error(id, message)
    local connection = module_state.connections_by_fd[id] -- 当前 WebSocket 回调对应的连接；关闭或迟到回调时可能不存在。

    log_event(
    {
        kind          = "error",
        code          = "WEBSOCKET_ERROR",
        message       = tostring(message),
        connection_id = connection and connection.id or id,
    }
    )

    detach_connection(connection, "websocket error")
end

--- 处理 WebSocket 写队列增长通知；Skynet 的 size 单位是 KB，达到阈值时关闭慢连接。
--- ws_object 提供底层 connection id；只对仍登记的连接发事件，达到 write_warning_close_kb 时关闭以限制队列增长。无返回值。
---@param ws_object table Skynet WebSocket 对象；id 用于找到 Gateway 连接。
---@param size integer Skynet write buffer 大小，单位 KB。
---@return nil 记录缓冲告警；达到配置上限时关闭连接。
function ws_handler.warning(ws_object, size)
    local connection = module_state.connections_by_fd[ws_object.id] -- warning 所属的 Gateway 连接；已摘除时忽略。
    if connection then
        log_event(
        {
            kind          = "warning", -- 当前连接的本地写队列过大。
            code          = "WRITE_BACKPRESSURE", -- 触发 Gateway 写缓冲上限的稳定诊断类别。
            message       = "WebSocket write buffer is large", -- 说明该事件来自 WebSocket 写队列。
            connection_id = connection.id, -- 便于从日志定位连接生命周期。
        }
        )

        if size >= module_state.gateway_config.write_warning_close_kb then
            detach_connection(connection, "write backpressure")
            close_transport(connection, 1013, "server backpressure")
        end
    end
end

--- 新 TCP/WebSocket 客户端进入监听回调；只登记有界连接，不把 fd 交给业务 Service。
--- fd 是 Skynet accept 的句柄且由 Gateway 接管关闭，peer 是对端地址诊断字符串。
--- WebSocket accept 与 TCP 会话分别由 Gateway fork 协程驱动；超限时立即关闭 fd，不入表。
---@param fd integer Skynet accept 回调提供的新 fd。
---@param peer string 对端地址诊断字符串。
---@return nil 连接由 Gateway 协程接管或立即关闭。
local function accept_client(fd, peer)
    -- stop 可能在关闭监听 Socket 时 yield；迟到的 accept 仍须在接管前释放 fd。
    if module_state.phase ~= "running" then
        socket.close_fd(fd)
        return
    end

    -- 根据 transport 配置选择 WebSocket 监听回调或 TCP 连接协程。
    if module_state.gateway_config.transport == "websocket" then
        local accepted = create_connection(fd, peer, "websocket") -- 已登记且持有握手名额的 WebSocket 连接。
        if not accepted then
            socket.close_fd(fd)
            return
        end

        accepted.read_started = skynet.now()
        skynet.fork(function()
            if accepted.closed then
                return
            end

            local call_succeeded, accepted_by_websocket, failure = pcall(
                websocket.accept,
                fd,
                ws_handler,
                "ws",
                peer
            )
            local connection = module_state.connections_by_fd[fd] -- accept 返回后重新读取索引，确认该 fd 仍对应活动连接。

            if not call_succeeded or not accepted_by_websocket then
                log_event(
                {
                    kind          = "error", -- 原生 accept 失败事件。
                    code          = "WEBSOCKET_ACCEPT", -- 固定分类，区分 Upgrade 与应用握手失败。
                    message       = tostring(call_succeeded and failure or accepted_by_websocket), -- pcall 异常或 accept 返回的错误。
                    connection_id = connection and connection.id or fd, -- 尚有登记时记录逻辑 id，否则记录原生 fd。
                }
                )

                if connection then
                    detach_connection(connection, "websocket accept failed")
                    close_transport(connection, 1011, "websocket accept failed")
                end
                return
            end

            detach_connection(connection, "websocket session ended")
        end)

        return
    end

    -- TCP 路径在接管 fd 后启动独立读取协程；创建失败的 fd 仍由 accept 回调关闭。
    local connection = create_connection(fd, peer, "tcp") -- 接管 TCP fd 后交给单独读取协程的连接记录。
    if not connection then
        --- accepted fd 尚未进入 Lua socket_pool，必须用 close_fd 关闭。
        socket.close_fd(fd)
        return
    end

    --- 捕获 start/read/driver 异常，保证异常退出也释放连接；清理不向业务发送错误响应。
    skynet.fork(function()
        local ok, err = pcall(run_tcp, connection) -- 捕获 TCP 协程异常，保证后续摘除并关闭连接。
        if not ok then
            log_event(
            {
                kind          = "error",
                code          = "TCP_SESSION",
                message       = tostring(err),
                connection_id = connection.id,
            }
            )

            detach_connection(connection, "tcp session failed")
            pcall(close_transport, connection, 1011, "tcp session failed")
        end
    end)
end


--- 一个扫描协程限制 TCP 半包/空闲读与 WS 握手/空闲占用；不按请求创建 timer。
--- 无参数；最多扫描 max_clients 个连接，tick 回绕用模运算；detach 后关闭会 yield。
---@return nil Service 停止后退出；运行期间每 100 ms 扫描并关闭超时连接。
local function timeout_loop()
    -- 定时检查握手期限、TCP 读超时和 WebSocket 空闲期限。
    while module_state.phase == "running" do
        skynet.sleep(10)

        local now = skynet.now() -- 当前 10ms tick，用于判断握手总期限与连接空闲期限。
        local expired = {} -- 本轮扫描判定超时的连接快照；关闭可能 yield，因此先完成扫描。

        for _, connection in pairs(module_state.connections) do
            local since = connection.read_started or connection.last_message -- 空闲计时起点：正在读取时取 read_started，否则取最近完整消息时间。
            local limit = connection.read_started -- 正在等待定长数据时使用读取期限，否则使用连接空闲期限。
                and module_state.gateway_config.read_timeout_ticks
                or module_state.gateway_config.idle_timeout_ticks

            if module_state.handshake.expired(connection.handshake) or
                (now - since) % 0x100000000 >= limit then
                expired[#expired + 1] = connection
            end
        end

        -- 对本轮判定超时的连接先摘除索引，再关闭底层传输。
        for _, connection in ipairs(expired) do
            if detach_connection(connection, "network read timeout") then
                close_transport(connection, 1001, "network timeout")
            end
        end
    end
end


---@class GatewayStartConfig
---@field host? string 监听地址；缺省绑定 127.0.0.1。
---@field port integer 必需监听端口，范围 1..65535。
---@field backlog? integer OS accept backlog；缺省 128，不等于 max_clients。
---@field transport? GatewayTransport 缺省 tcp；实例运行期间不切换。
---@field websocket_protocol? "ws" 仅兼容明文 WebSocket；TLS/WSS 必须由宿主前置终止。
---@field handler_service string 已注册的本地 Skynet Service 名，用于投递业务请求。
---@field descriptor_path string 宿主构建生成的 Protobuf descriptor 文件路径。
---@field registry_module string 已生成的协议 registry 模块名。
---@field protocol_version integer Envelope 使用的协议版本。
---@field max_frame_bytes? integer 单条 Envelope bytes 上限；TCP 的 uint16 长度前缀不计。
---@field read_timeout_ticks? integer 读取超时，单位 10 ms tick。
---@field idle_timeout_ticks? integer WebSocket 空闲超时，单位 10 ms tick。
---@field max_requests_per_second? integer 单连接每秒接纳的业务请求上限。
---@field max_total_requests_per_second? integer 当前实例每秒接纳的业务请求上限。
---@field max_pending_handshakes? integer 尚未完成握手的连接上限。
---@field handshake_timeout_ticks? integer 握手总期限，单位 10 ms tick。
---@field max_clients? integer 当前实例最大在线连接数。
---@field write_warning_close_kb? integer 写缓冲达到此 KB 后关闭连接。

---@class GatewayStartResult
---@field address string 实际监听地址。
---@field port integer 实际监听端口。
---@field transport GatewayTransport 实例使用的传输协议。
---@field command_count integer 已加载 registry 中的命令数。

--- 校验启动配置、加载协议 descriptor/registry 并开始监听，最后才发布 running 状态。
--- handler_service 必须是已注册的本地 Skynet 服务名。配置、文件或 bind 失败时抛错，不宣告就绪。
--- 执行文件 I/O、创建 codec 和监听 Socket，socket.listen 可能 yield；只允许从 created 启动一次。
---@param startup_config GatewayStartConfig 宿主提交的完整启动配置。
---@return GatewayStartResult 实际监听信息；失败抛错，可能 yield。
local function start(startup_config)
    -- 拒绝重复 start；只有 created 实例可以进入配置加载和监听流程。
    assert(module_state.phase == "created", "gateway can only start once")

    -- 从宿主输入构造已校验配置，读取 descriptor，再加载并校验生成的 registry。
    -- normalize_config 不访问外部资源；后续文件加载失败由 start 按 Skynet RPC 合同抛错。
    local gateway_config = normalize_config(startup_config) -- 已校验的本地配置副本，启动后不再读宿主输入表。
    local generated = assert( -- 宿主构建生成的 Registry 定义，下一步验证并建立本地索引。
        require(gateway_config.registry_module),
        "cannot load gateway registry module"
    )
    local registry = registry_api.build_index(generated) -- 当前实例独占的已验证命令索引，供 codec 与路由读取。

    -- 将校验后的配置、registry、codec 和握手管理器保存到本 Service 状态。
    module_state.gateway_config = gateway_config
    module_state.registry = registry
    module_state.codec = codec_module.new(
        {
            descriptor_path = gateway_config.descriptor_path,
            registry        = registry,
        }
    )

    module_state.epoch = tostring(skynet.self()) .. ":" .. tostring(skynet.hpc())
    module_state.handshake = handshake_module.new(
    {
        crypto        = require "flywow_gateway_crypto", -- 固定native绑定，缺少时启动失败。
        now           = skynet.now, -- 显式时钟，不创建额外协程。
        max_pending   = gateway_config.max_pending_handshakes, -- 待握手连接数量。
        timeout_ticks = gateway_config.handshake_timeout_ticks, -- 绝对期限。
    }
    )

    -- 新实例从当前 tick 开始统计全局接纳请求窗口。
    module_state.rate_started = skynet.now()
    module_state.rate_count = 0

    -- 先记录 starting，再创建监听 fd；bind/listen 失败由启动调用报告。
    module_state.phase = "starting"

    -- 配置与运行时对象准备完成后才绑定端口；listen 可能 yield，返回信息用于发布就绪结果。
    local listen_fd, address, port = socket.listen( -- 绑定产生的 listener 及 driver 返回的实际地址和端口。
        gateway_config.host,
        gateway_config.port,
        gateway_config.backlog
    )

    -- listen 可能 yield；若 stop 已在等待期间完成，不能重新发布已停止的实例。
    if module_state.phase ~= "starting" then
        socket.close(listen_fd)
        error("gateway start was stopped while binding")
    end

    -- bind 完成后由 Service 状态接管 listener fd，供 stop 关闭。
    module_state.listen_fd = listen_fd

    -- 注册 accept 回调可能等待 Skynet socket driver；失败时释放监听 fd 并终结启动状态。
    local start_call_succeeded, started_fd, start_error = -- 启动调用状态、成功 fd 或底层失败文本。
        pcall(socket.start, listen_fd, accept_client)
    if not start_call_succeeded or started_fd ~= listen_fd then
        if module_state.listen_fd == listen_fd then
            module_state.listen_fd = nil
            pcall(socket.close, listen_fd)
        end
        module_state.phase = "stopped"
        local failure = start_call_succeeded and start_error or started_fd -- 从 pcall 返回值中取 socket.start 的错误原因。
        error("cannot start gateway listener: " .. tostring(failure))
    end

    -- stop 可在 socket.start 等待期间运行；检查后才允许进入 running。
    if module_state.phase ~= "starting" then
        if module_state.listen_fd == listen_fd then
            module_state.listen_fd = nil
        end
        error("gateway start was stopped while starting listener")
    end

    -- 两个可 yield 的监听步骤都完成且实例仍在 starting 后才发布 running。
    module_state.phase = "running"
    skynet.fork(timeout_loop)

    skynet.error(
        "FLYWOW_GATEWAY_READY transport=",
        gateway_config.transport,
        " address=",
        address,
        ":",
        port,
        " commands=",
        registry.count
    )

    return
    {
        address       = address,
        port          = port,
        transport     = gateway_config.transport,
        command_count = registry.count,
    }
end


---@class GatewayStopResult
---@field closed_connections integer 本次停止时由 Gateway 关闭的连接数量。


--- 幂等地停止监听并关闭所有 Gateway 拥有的连接。
--- 返回本次主动关闭的连接数；执行 Socket I/O，关闭操作可能 yield，不应在业务请求 handler 中同步调用。
--- 连接数受 max_clients 限制；先快照索引再 detach，避免遍历期间删 key 漏关或重复关闭。
---@return GatewayStopResult 停止结果；重复停止返回 0。
local function stop()
    -- 已 stopped 的实例直接返回，避免重复关闭已经释放的 fd。
    if module_state.phase == "stopped" then
        return
        {
            closed_connections = 0,
        }
    end

    -- 进入 stopping 后，读取循环会在下一次检查时退出。
    module_state.phase = "stopping"

    -- 关闭监听 fd，阻止 Skynet 再把新连接交给本实例。
    local listen_fd = module_state.listen_fd -- 先转成本地 owner，再从共享状态清空以防重复关闭。
    module_state.listen_fd = nil
    if listen_fd then
        socket.close(listen_fd)
    end

    -- 复制当前连接列表；后续 detach 会修改原索引，不能直接遍历它。
    local closed = 0 -- 本次 stop 首次摘除的连接数，不累计此前已关闭连接。
    local snapshot = {} -- stop 开始时仍登记的连接快照；detach 会修改原索引表。

    for _, connection in pairs(module_state.connections) do
        snapshot[#snapshot + 1] = connection
    end

    -- 逐个从两个连接索引摘除并关闭 fd；单个关闭会 yield。
    for index = 1, #snapshot do
        local connection = snapshot[index] -- 本轮停止要摘除并关闭的连接。
        if not connection.closed then
            closed = closed + 1
            detach_connection(connection, "server shutdown")
            close_transport(connection, 1001, "server shutdown")
        end
    end

    -- 所有连接关闭后标记 stopped；后续 stop 调用只返回零个本次关闭连接。
    module_state.phase = "stopped"

    return
    {
        closed_connections = closed,
    }
end


skynet.start(function()
    --- 服务命令合同：start 接收 GatewayStartConfig，send_data/close 接收对应消息 record，stop 不接收参数。
    skynet.dispatch("lua", function(_session, _source, command, argument)
        if command == "close" then
            request_close(argument)
            return
        end

        if command == "send_data" then
            deliver_outbound_message(argument)
            return
        end

        if command == "start" then
            skynet.retpack(start(argument))
            return
        end

        if command == "stop" then
            assert(argument == nil, "stop does not accept an argument")
            skynet.retpack(stop())
            return
        end

        error("unknown flywow.gateway command: " .. tostring(command))
    end)
end)
