--- 职责：提供与业务无关的 Skynet Gateway Service，统一接入 TCP 与 WebSocket。
--- 边界：FlyWow Runtime Service；拥有监听 fd、连接生命周期、frame、背压和协议编解码。
--- 输入/输出：宿主传入的完整课程配置 + handler Service -> 已解码 command/request 与编码后的 response。
--- 生命周期：由宿主通过 newservice 创建；start 后监听，stop 后释放所有 fd、连接和队列状态。
--- 不负责：不注册业务 command、不理解 Battle/SLG DTO、不加载 .proto 源码、不保存业务状态。
local skynet = require "skynet"
local luapanda_debug = require "shared.debug.luapanda_debug"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local registry_loader = require "registry"
local codec_factory = require "codec"
local handshake_factory = require "handshake"

---@alias GatewayTransport "tcp"|"websocket"

---@class GatewayConnection
---@field handshake HandshakeContext 当前连接独占的握手状态。
---@field id integer Gateway 单调递增逻辑连接编号。
---@field fd integer Gateway 独占的底层 Socket fd；不传给业务。
---@field peer string 对端地址诊断字符串。
---@field transport GatewayTransport 当前传输类型。
---@field closed boolean 是否已从连接表摘除。
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
    rate_started       = 0,         -- 实例当前一秒限流窗口起点，单位10ms tick。
    rate_count         = 0,         -- 实例当前窗口接纳帧数，不是业务等待数。
    responses_sent     = 0,         -- 已由 transport 接纳的响应/推送数，不表示客户端收到。
    responses_dropped  = 0,         -- 旧实例/已关闭连接/无效消息等丢弃数。
    epoch              = nil,       -- 每次 Service 启动的新身份，隔离旧进程迟到响应。
    client_count       = 0,         -- 当前已完成接入的连接数。
}
local ws_handler = {} -- Skynet WebSocket 回调表；启动时注册，运行期间不替换。

--- 将启动时覆盖项浅合并到默认配置；handler_service 是运行期提供的本地服务名。
--- 参数 base_config/config_overrides：默认配置和可选覆盖 table；调用方拥有输入，函数不修改它们。
--- 返回值：Gateway 私有候选配置；不执行 I/O、不 yield；config_overrides 中的同名顶层字段覆盖默认值。
local function merge_config(base_config, config_overrides)
    assert(config_overrides == nil or type(config_overrides) == "table", "gateway start overrides must be a table")
    local merged_config = {}
    for key, value in pairs(base_config) do
        merged_config[key] = value
    end
    for key, value in pairs(config_overrides or {}) do
        merged_config[key] = value
    end
    return merged_config
end

--- 把配置项校验为有界整数，避免字符串数字、小数或 NaN 进入端口和资源上限。
--- value 是候选数值，name 仅用于错误诊断，minimum/maximum 是含端点的合法范围；参数只读。
--- 返回 Lua integer；类型不符或越界时抛错。不执行 I/O、分配外部资源或 yield。
local function require_integer(value, name, minimum, maximum)
    assert(type(value) == "number" and math.type(value) == "integer",
           name .. " must be an integer")
    assert(value >= minimum and value <= maximum,
           name .. " must be in [" .. minimum .. ", " .. maximum .. "]")
    return value
end

--- 校验并复制宿主完整传入的课程配置，避免运行期间读取可变配置 table。
--- 参数 startup_config：必需的完整 Gateway 配置，包含 handler、descriptor、registry 和监听参数。
--- 返回值：当前 Service 私有的规范化配置；失败抛错，不执行 I/O、yield 或启动资源。
local function normalize_config(startup_config)
    assert(type(startup_config) == "table", "gateway start config must be a table")
    -- Gateway 不 require 宿主业务配置；默认值只用于可选的通用传输参数。
    local merged_config = merge_config({}, startup_config)

    -- 参数/状态检查：先校验传输类型，再校验网络和资源上限。
    local transport = merged_config.transport or "tcp"
    assert(
        transport == "tcp" or transport == "websocket",
        "unsupported gateway transport: " .. tostring(transport)
    )

    if transport == "websocket" then
        --- pinned Skynet 的 wss server 会从进程环境/当前目录隐式读证书。
        --- 当前合同没有 TLS 证书注入和轮换能力，因此明确只允许 ws。
        assert(
            merged_config.websocket_protocol == nil or
            merged_config.websocket_protocol == "ws",
            "websocket_protocol currently supports ws only; " ..
            "terminate TLS outside Gateway"
        )
    end

    local max_frame_bytes = require_integer(
        merged_config.max_frame_bytes or 65535,
        "max_frame_bytes",
        1,
        0xffff
    )
    local max_clients = require_integer(
        merged_config.max_clients or 1024,
        "max_clients",
        1,
        1000000
    )
    local warning_kb = require_integer(
        merged_config.write_warning_close_kb or 1024,
        "write_warning_close_kb",
        1,
        0x7fffffff
    )

    local port = require_integer(merged_config.port, "port", 1, 65535)
    local backlog = require_integer(
        merged_config.backlog or 128,
        "backlog",
        1,
        65535
    )
    local protocol_version = require_integer(
        merged_config.protocol_version,
        "protocol_version",
        1,
        0xffffffff
    )

    -- handler_service 是宿主注册的本地 Skynet 服务名，发送时由 Skynet 解析当前注册者。
    local handler_service = merged_config.handler_service
    assert(type(handler_service) == "string" and handler_service ~= "",
        "handler_service must be a non-empty Skynet service name")
    local observer_service = merged_config.observer_service
    if observer_service ~= nil then
        observer_service = require_integer(
            observer_service,
            "observer_service",
            1,
            math.maxinteger
        )
    end

    assert(
        type(merged_config.descriptor_path) == "string" and
        merged_config.descriptor_path ~= "",
        "descriptor_path is required"
    )
    assert(
        type(merged_config.registry_module) == "string" and
        merged_config.registry_module ~= "",
        "registry_module is required"
    )

    -- 收尾：返回当前 Gateway Lua State 独占的规范化配置。
    return
    {
        host                          = merged_config.host or "127.0.0.1", -- 监听地址；只影响当前 Gateway。
        port                          = port, -- TCP/WS 监听端口，1..65535。
        backlog                       = backlog, -- OS accept backlog，不等于 max_clients。
        transport                     = transport, -- tcp 或 websocket；运行期不可切换。
        websocket_protocol            = "ws", -- TLS 由宿主前置终止；Gateway 不隐式读取证书。
        handler_service               = handler_service, -- 宿主注册的本地服务名；发送时解析当前服务。
        observer_service              = observer_service, -- 可选观测 Service handle；只接收异步事件。
        descriptor_path               = merged_config.descriptor_path, -- 运行目录下的 descriptor 文件路径。
        registry_module               = merged_config.registry_module, -- 生成 registry 的 require 名称。
        protocol_version              = protocol_version, -- Envelope uint32 兼容版本。
        max_frame_bytes               = max_frame_bytes, -- 单个 Envelope body 上限，单位 byte。
        read_timeout_ticks            = require_integer(
            merged_config.read_timeout_ticks or 3000,
            "read_timeout_ticks",
            1,
            360000
        ), -- TCP 每次定长读取/WS 握手上限，单位 10 ms。
        idle_timeout_ticks            = require_integer(
            merged_config.idle_timeout_ticks or 30000,
            "idle_timeout_ticks",
            1,
            360000
        ), -- WS 完整消息空闲上限，单位 10 ms。
        max_requests_per_second       = require_integer(
            merged_config.max_requests_per_second or 200,
            "max_requests_per_second",
            1,
            100000
        ), -- 每连接每秒入站上限；超限关闭。
        max_total_requests_per_second = require_integer(
            merged_config.max_total_requests_per_second or 10000,
            "max_total_requests_per_second",
            1,
            1000000
        ), -- 当前实例每秒投递上限；超限关闭来源连接。
        max_pending_handshakes        = require_integer(
            merged_config.max_pending_handshakes or math.min(128, max_clients),
            "max_pending_handshakes",
            1,
            max_clients
        ), -- 含TCP与WS的应用握手并发上限。
        handshake_timeout_ticks       = require_integer(
            merged_config.handshake_timeout_ticks or 1000,
            "handshake_timeout_ticks",
            1,
            360000
        ), -- 总握手期限，10ms tick。
        max_clients                   = max_clients, -- 当前 Gateway 最大在线连接数。
        write_warning_close_kb        = warning_kb, -- 写缓冲 warning 达到此 KB 时关闭连接。
    }
end


---@alias GatewayEventKind "open"|"ready"|"close"|"error"|"warning"

---@class GatewayEvent
---@field kind GatewayEventKind 连接生命周期、协议或资源边界事件类型。
---@field code? string 稳定诊断类别；不携带业务错误合同。
---@field message? string 面向运维的诊断文本，不作为业务响应。
---@field connection_id? integer 当前 Gateway 实例内的逻辑连接编号。
---@field peer? string 对端地址诊断信息。
---@field transport? GatewayTransport 当前连接使用的传输方式。
---@field command? integer|"-" 已解码的协议命令 ID，仅在事件关联到该命令时出现。

--- 记录并向可选 observer Service 投递结构化 Gateway 事件；observer 故障不能影响业务请求。
--- event 只含诊断和连接上下文，不能包含业务 payload；skynet.send 异步投递且不 yield。
---@param event GatewayEvent 本次事件的只读记录；发送后不由 Gateway 保存。
local function emit_event(event)
    skynet.error("FLYWOW_GATEWAY_" .. string.upper(event.kind),
                 " connection_id=", tostring(event.connection_id or "-"),
                 " command=", tostring(event.command or "-"),
                 " code=", tostring(event.code or "-"),
                 " message=", tostring(event.message or "-"))

    if module_state.gateway_config.observer_service then
        skynet.send(module_state.gateway_config.observer_service, "lua", "gateway_event", event)
    end
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
    -- 参数/状态检查：容量、连接身份和握手名额必须可用。
    if module_state.client_count >= module_state.gateway_config.max_clients then
        emit_event(
        {
            kind      = "warning",
            code      = "MAX_CONNECTIONS",
            message   = "connection limit reached",
            peer      = peer,
            transport = transport,
        }
        )

        return nil
    end

    if module_state.next_connection_id == math.maxinteger then
        emit_event(
        {
            kind    = "error",
            code    = "CONNECTION_ID_EXHAUSTED",
            message = "connection identity exhausted",
        }
        )

        return nil
    end

    local handshake, handshake_error = module_state.handshake.accept()
    if not handshake then
        emit_event(
        {
            kind    = "error",
            code    = handshake_error,
            message = "handshake capacity reached",
        }
        )

        return nil
    end

    -- 数据准备：创建当前连接独占的上下文。
    module_state.next_connection_id = module_state.next_connection_id + 1

    local connection =
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
        rate_started    = skynet.now(), -- 当前一秒计数窗口起点；tick 回绕用模运算。
        rate_count      = 0, -- 当前一秒已接纳帧数；不是业务 in-flight。
        request_count   = 0, -- 已完成 dispatch 次数；诊断统计字段。
    }

    -- 状态修改：连接同时登记到两个索引，再增加在线计数。
    module_state.connections[connection.id] = connection
    module_state.connections_by_fd[fd] = connection
    module_state.client_count = module_state.client_count + 1

    -- 持久化/消息发送：通知观测方连接已建立。
    emit_event(
    {
        kind          = "open",
        connection_id = connection.id,
        peer          = peer,
        transport     = transport,
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

    connection.closed = true
    module_state.handshake.close(connection.handshake)
    module_state.connections[connection.id] = nil
    module_state.connections_by_fd[connection.fd] = nil
    module_state.client_count = module_state.client_count - 1

    skynet.send(module_state.gateway_config.handler_service, "lua", "gateway_disconnect",
    {
        gateway_epoch = module_state.epoch,
        connection_id = connection.id,
    }
    )

    emit_event(
        {
            kind          = "close",
            connection_id = connection.id,
            peer          = connection.peer,
            transport     = connection.transport,
            message       = reason or "closed",
        }
    )
    return true
end

--- 幂等关闭本连接的 transport；接管前用 close_fd，接管后使用 Socket/WS 关闭。
--- connection 由 Gateway 拥有；code 为 WS 状态码，reason 为有限诊断文本，不含业务数据。
--- 返回是否首次提交关闭；Socket/WS close 可能 yield。先标记 close_requested，并拒绝已被新连接占用的 fd。
local function close_transport(connection, code, reason)
    if connection.close_requested then
        return false
    end

    local current = module_state.connections_by_fd[connection.fd]
    if current and current ~= connection then
        return false
    end

    connection.close_requested = true

    if connection.transport == "websocket" and not websocket.is_close(connection.fd) then
        websocket.close(connection.fd, code or 1001, reason or "closed")
    elseif socket.invalid(connection.fd) then
        socket.close_fd(connection.fd)
    else
        socket.close(connection.fd)
    end
    return true
end

--- 解码并按读取顺序异步投递完整帧；本入口不等待任何业务响应。
--- connection/payload 由 Gateway 拥有，payload 长度单位 byte；返回 false 时调用方关闭违规连接。
--- 解码和 send 不 yield；只有连接/协议/网络资源错误影响后续读取，业务结果走独立入口。
---@param connection GatewayConnection 当前已登记连接。
---@param payload string 一条完整业务 Envelope bytes；当前调用借用，不跨 yield 保存。
---@return boolean 是否成功投递给 handler；失败由 transport 层关闭连接。
local function dispatch_payload(connection, payload)
    -- 参数/状态检查：拒绝关闭连接、空帧和超限帧。
    if connection.closed or #payload == 0 or #payload > module_state.gateway_config.max_frame_bytes then
        emit_event(
        {
            kind          = "error",
            code          = "FRAME_LIMIT",
            message       = "payload exceeds configured limit",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 核心计算：解码 Envelope、校验协议版本；业务关联由消息 body 定义。
    --- pcall 把不可信网络字节导致的解码异常限制在当前请求，便于统一发事件并关闭连接。
    local envelope_ok, envelope = pcall(module_state.codec.decode_envelope, payload)
    if not envelope_ok then
        emit_event(
        {
            kind          = "error",
            code          = "ENVELOPE_DECODE",
            message       = tostring(envelope),
            connection_id = connection.id,
        }
        )

        return false
    end

    if envelope.protocol_version ~= module_state.gateway_config.protocol_version then
        emit_event(
        {
            kind          = "error",
            code          = "PROTOCOL_VERSION",
            message       = "unsupported protocol version",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 核心计算：根据 CommandId 查找定义并解码 Request。
    local definition = registry_loader.find_command(module_state.registry, envelope.command)
    if definition == nil then
        emit_event(
        {
            kind          = "error",
            code          = "UNKNOWN_COMMAND",
            message       = "command is not in generated registry",
            connection_id = connection.id,
        }
        )

        return false
    end

    local request_ok, request = pcall(
        module_state.codec.decode_request,
        definition,
        envelope.body
    )
    if not request_ok then
        emit_event(
        {
            kind          = "error",
            code          = "REQUEST_DECODE",
            message       = tostring(request),
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 参数/状态检查：更新并检查当前连接和实例的限流窗口。
    local now = skynet.now()

    if (now - connection.rate_started) % 0x100000000 >= 100 then
        connection.rate_started, connection.rate_count = now, 0
    end

    if (now - module_state.rate_started) % 0x100000000 >= 100 then
        module_state.rate_started, module_state.rate_count = now, 0
    end

    if connection.rate_count >= module_state.gateway_config.max_requests_per_second or
        module_state.rate_count >= module_state.gateway_config.max_total_requests_per_second then
        emit_event(
        {
            kind          = "warning",
            code          = "INGRESS_RATE_LIMIT",
            message       = "ingress rate exceeded",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 状态修改：记录本次已接纳的请求。
    connection.rate_count = connection.rate_count + 1
    module_state.rate_count = module_state.rate_count + 1
    connection.request_count = connection.request_count + 1
    connection.last_message = now

    -- 持久化/消息发送：把已解码请求和路由元数据投递给业务层。
    --- 只传递连接身份、command_id 和已解码数据；Gateway 不缓存业务请求。
    local sent, err = pcall(
        skynet.send,
        module_state.gateway_config.handler_service,
        "lua",
        "send_data",
        {
            gateway_epoch    = module_state.epoch,
            connection_id    = connection.id,
            peer             = connection.peer,
            transport        = connection.transport,
            command_id       = definition.id,

            data             = request,
        }
    )

    if not sent or err == nil then
        emit_event(
        {
            kind          = "error",
            code          = "HANDLER_SEND",
            message       = tostring(err),
            connection_id = connection.id,
        }
        )

        return false
    end

    return true
end


--- 发送入口：编码后发送给指定连接，或发送给当前所有已握手连接。
--- source 必须是配置的 handler；message 包含 epoch/connection_id/command_id/data。
--- connection_id=0 表示广播；Gateway 不保存业务请求状态，也不判断业务结果。
---@param source ServiceHandle 发送 data 的已配置 handler handle。
---@param message GatewayDataMessage 带有目标连接和响应数据。
---@return boolean 是否至少接纳了一次传输写入。
local function write_connection(connection, encoded)
    local sent, err

    if connection.transport == "tcp" then
        sent, err = pcall(
            socket.write,
            connection.fd,
            string.pack(">I2", #encoded) .. encoded
        )
        sent = sent and err ~= false
    else
        sent, err = pcall(
            websocket.write,
            connection.fd,
            encoded,
            "binary"
        )
    end

    if not sent then
        emit_event(
        {
            kind          = "error",
            code          = "WRITE_FAILED",
            message       = tostring(err),
            connection_id = connection.id,
        }
        )

        detach_connection(connection, "write failed")
        skynet.fork(function()
            close_transport(connection, 1011, "write failed")
        end)
        return false
    end

    module_state.responses_sent = module_state.responses_sent + 1
    return true
end

---@class GatewayOutboundMessage
---@field gateway_epoch string Gateway 启动时生成的身份，拒绝前一实例迟到的响应。
---@field connection_id integer 当前实例的连接编号；0 表示广播给所有已就绪连接。
---@field command_id integer registry 中声明 response_type 的正整数命令 ID。
---@field data table 已构造的业务 response 或主动 Push message；Gateway 只负责编码。
---@param outbound_message GatewayOutboundMessage 当前 handler 发来的业务响应或 Push。
local function deliver_outbound_message(outbound_message)
    -- 参数/状态检查：只接受当前 Gateway 实例的有效消息；发送方由宿主信任边界管理。
    if not module_state.gateway_config or type(outbound_message) ~= "table" or
        outbound_message.gateway_epoch ~= module_state.epoch or
        module_state.phase ~= "running" then
        module_state.responses_dropped = module_state.responses_dropped + 1
        return false
    end

    if math.type(outbound_message.connection_id) ~= "integer" or
        outbound_message.connection_id < 0 or
        math.type(outbound_message.command_id) ~= "integer" or
        outbound_message.command_id <= 0 or
        type(outbound_message.data) ~= "table" then
        module_state.responses_dropped = module_state.responses_dropped + 1
        return false
    end

    -- 数据准备：根据 command_id 找到 response 类型并完成一次编码。
    local definition = registry_loader.find_command(module_state.registry, outbound_message.command_id)
    if not definition or definition.response_type == nil then
        module_state.responses_dropped = module_state.responses_dropped + 1
        return false
    end

    local ok, encoded = pcall(
        module_state.codec.encode_response,
        definition,
        module_state.gateway_config.protocol_version,
        outbound_message.data
    )
    if not ok or #encoded > module_state.gateway_config.max_frame_bytes then
        emit_event(
        {
            kind          = "error",
            code          = "RESPONSE_ENCODE",
            message       = ok and "response exceeds frame limit" or tostring(encoded),
            connection_id = outbound_message.connection_id,
        }
        )

        return false
    end

    -- 持久化/消息发送：指定连接或广播到当前已握手连接。
    if outbound_message.connection_id == 0 then
        local sent_any = false

        for _, connection in pairs(module_state.connections) do
            if not connection.closed and
                module_state.handshake.ready(connection.handshake) then
                sent_any = write_connection(connection, encoded) or sent_any
            end
        end

        return sent_any
    end

    local connection = module_state.connections[outbound_message.connection_id]
    if not connection or connection.closed or
        not module_state.handshake.ready(connection.handshake) then
        module_state.responses_dropped = module_state.responses_dropped + 1
        return false
    end

    return write_connection(connection, encoded)
end

---@class GatewayCloseRequest
---@field gateway_epoch string Gateway 启动时生成的身份，用于拒绝旧实例的迟到关闭命令。
---@field connection_id integer 当前实例的逻辑连接编号；不是底层 fd。

--- 接收 handler 的主动断开命令；只按当前实例与连接身份关闭，不查业务请求记录。
--- close_request.gateway_epoch/connection_id 来自原请求或项目会话；发送方由宿主信任边界管理。
--- 返回是否首次接纳；旧实例、失效连接或重复关闭返回 false，不影响新连接。
--- 先摘除连接，再 fork transport 关闭；消息入口不 yield，关闭任务可能 yield。
---@param close_request GatewayCloseRequest 当前 handler 请求关闭的连接身份。
---@return boolean 首次成功接纳关闭时为 true；旧实例、失效连接或重复请求为 false。
local function request_close(close_request)
    -- 参数/状态检查：只接受当前 Gateway 实例和有效连接的关闭请求。
    if not module_state.gateway_config or module_state.phase ~= "running" or
        type(close_request) ~= "table" or close_request.gateway_epoch ~= module_state.epoch or
        math.type(close_request.connection_id) ~= "integer" then
        return false
    end

    local connection = module_state.connections[close_request.connection_id]
    if not connection or not detach_connection(connection, "closed by handler") then
        return false
    end

    --- 关闭前已摘除索引，随后到达的 response/close 不会再使用该连接；fd 不暴露给业务。
    skynet.fork(function()
        close_transport(connection, 1008, "closed by server")
    end)

    return true
end


--- 从 TCP 字节流读取指定数量的字节；TCP 不保留消息边界，因此 header/body 必须分别读满。
--- connection 是当前 Gateway 持有的 TCP 上下文；size 是正整数 byte 数。成功返回新 bytes string，失败返回 nil 与原因。
--- socket.read 执行 I/O 并可能 yield；调用方在返回后需检查连接状态，不得依赖 fd 未被关闭。
---@param connection GatewayConnection 当前 TCP 连接；读取可能 yield。
---@param size integer 必须读取的 byte 数；由当前握手/业务阶段决定。
---@return string|nil, string|nil 完整 bytes，或失败原因；返回后需重新检查 connection.closed。
local function read_exact(connection, size)
    connection.read_started = skynet.now()

    local data, remainder = socket.read(connection.fd, size)

    connection.read_started = nil

    if connection.closed then
        return nil, "connection closed"
    end

    if not data then
        return nil, remainder or "socket closed"
    end

    if #data ~= size then
        return nil, "short read"
    end

    return data
end


--- 将当前握手消息交给独立模块并发送其输出；Gateway不解析握手字段。
--- connection/bytes只在本调用借用；返回boolean，失败由调用方关闭；写失败不提交ready。
--- pinned TCP/WS写不yield；完成后只保留ready标记，不持有secret。
---@param connection GatewayConnection 当前未 ready 的连接。
---@param bytes string 一条完整握手消息；不跨调用保存。
---@return boolean 是否成功写出 response 并在最后阶段提交 ready。
local function process_handshake(connection, bytes)
    -- 核心计算：把完整握手帧交给握手模块。
    local response, code, confirm = module_state.handshake.receive(
    {
        context = connection.handshake, -- 本连接独占的握手状态。
        bytes   = bytes, -- 当前完整网络帧，只读借用。
    }
    )

    if not response then
        emit_event(
        {
            kind          = "error",
            code          = code,
            message       = "handshake rejected",
            connection_id = connection.id,
        }
        )

        return false
    end

    -- 持久化/消息发送：把握手响应写回 TCP 或 WebSocket。
    local ok, result
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

    if confirm then
        if not module_state.handshake.confirm(connection.handshake) then
            return false
        end

        emit_event(
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
    -- 参数/状态检查：关闭中的连接不再启动 Socket。
    if connection.closed then
        return
    end

    -- 数据准备：启动 Socket 并配置帧上限和背压回调。
    local fd = connection.fd
    local opened, open_error = socket.start(fd)

    if connection.closed then
        return
    end

    --- pinned socket.start 成功无返回值；错误返回 false，不能依赖它返回 true。
    assert(opened ~= false, tostring(open_error))

    socket.limit(fd, module_state.gateway_config.max_frame_bytes + 2)
    socket.warning(fd, function(_, size)
        emit_event(
        {
            kind          = "warning",
            code          = "WRITE_BACKPRESSURE",
            message       = "TCP write buffer is large",
            connection_id = connection.id,
            pending_kb    = size,
        }
        )

        if size >= module_state.gateway_config.write_warning_close_kb then
            detach_connection(connection, "write backpressure")
            close_transport(connection, 1013, "write backpressure")
        end
    end)

    -- 核心计算：循环读取帧头、读取帧体，再按握手状态分发。
    while not connection.closed and module_state.phase == "running" do
        local header, err = read_exact(connection, 2)
        if not header then
            break
        end

        --- >I2 表示网络字节序 uint16；先拒绝 0 或超限长度，再按该值读取 body。
        local size = string.unpack(">I2", header)
        local ready = module_state.handshake.ready(connection.handshake)

        if (not ready and size ~= module_state.handshake.expected_size(connection.handshake)) or
            (ready and (size < 1 or size > module_state.gateway_config.max_frame_bytes)) then
            emit_event(
            {
                kind          = "error",
                code          = "FRAME_LIMIT",
                message       = "invalid TCP frame length",
                connection_id = connection.id,
            }
            )

            break
        end

        local payload = read_exact(connection, size)
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

    -- 收尾：所有退出路径统一摘除连接并关闭传输。
    detach_connection(connection, "tcp session ended")
    close_transport(connection, 1001, "tcp session ended")
end


--- 处理已由 Skynet 完成拼帧的 WebSocket message；底层库负责 Upgrade、mask、fragment 与 ping/pong。
--- id 是 Skynet connection id，payload 是单条完整消息 bytes，opcode 标识文本或 binary；payload 不跨回调保存。
--- 仅接受 binary 且受 max_frame_bytes 限制；函数无返回值，失败时发事件并关闭当前连接。
function ws_handler.message(id, payload, opcode)
    local connection = module_state.connections_by_fd[id]
    if not connection or connection.closed then
        return
    end

    if opcode ~= "binary" then
        emit_event(
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

    local ok
    if module_state.handshake.ready(connection.handshake) then
        ok = dispatch_payload(connection, payload)
    else
        ok = process_handshake(connection, payload)
    end

    if not ok then
        detach_connection(connection, "protocol rejected")
        close_transport(connection, 1008, "gateway request rejected")
    end
end

--- WebSocket 握手完成后清除握手计时；连接在 accept 时已登记，HTTP Upgrade 由 Skynet 完成。
--- id 是 Skynet connection id；header/url 由底层拥有且本函数不保存；peer 使用 accept 的实际对端地址。
--- 无返回值，不执行跨 Service 调用或 yield；超过 max_clients 的连接在握手前拒绝。
function ws_handler.handshake(id, header, url)
    local connection = module_state.connections_by_fd[id]
    if not connection or connection.closed then
        return
    end

    connection.read_started = nil
    connection.last_message = skynet.now()
end

--- WebSocket 关闭回调中移除连接；底层库负责释放 Socket，本函数只清理 Gateway 索引。
--- id 是 Skynet WebSocket connection id；迟到或重复回调由 detach 的幂等性处理。无返回值，不执行 I/O/yield。
function ws_handler.close(id)
    detach_connection(module_state.connections_by_fd[id], "websocket closed")
end

--- 将 WebSocket 底层传输错误转为统一 Gateway error 事件并摘除连接。
--- id 是 Skynet connection id，message 是底层诊断文本；不包含业务 payload。无返回值，只修改本 Service 的连接索引。
function ws_handler.error(id, message)
    local connection = module_state.connections_by_fd[id]

    emit_event(
    {
        kind          = "error",
        code          = "WEBSOCKET_ERROR",
        message       = tostring(message),
        connection_id = connection and connection.id or id,
    }
    )

    detach_connection(connection, "websocket error")
end

--- 处理 WebSocket 写队列增长通知；size 是待写字节数，按 Skynet warning 回调的单位比较关闭阈值（KB）。
--- ws_object 提供底层 connection id；只对仍登记的连接发事件，达到 write_warning_close_kb 时关闭以限制队列增长。无返回值。
function ws_handler.warning(ws_object, size)
    local connection = module_state.connections_by_fd[ws_object.id]
    if connection then
        emit_event(
        {
            kind          = "warning",
            code          = "WRITE_BACKPRESSURE",
            message       = "WebSocket write buffer is large",
            connection_id = connection.id,
            pending_kb    = size,
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
    -- 参数/状态检查：按配置选择 WebSocket 或 TCP 接入路径。
    if module_state.gateway_config.transport == "websocket" then
        local accepted = create_connection(fd, peer, "websocket")
        if not accepted then
            socket.close_fd(fd)
            return
        end

        accepted.read_started = skynet.now()
        skynet.fork(function()
            if accepted.closed then
                return
            end

            local ok, err = websocket.accept(
                fd,
                ws_handler,
                module_state.gateway_config.websocket_protocol,
                peer
            )
            local connection = module_state.connections_by_fd[fd]

            if not ok and err then
                emit_event(
                {
                    kind          = "error",
                    code          = "WEBSOCKET_ACCEPT",
                    message       = tostring(err),
                    connection_id = connection and connection.id or fd,
                }
                )
            end

            detach_connection(connection, "websocket session ended")
        end)

        return
    end

    local connection = create_connection(fd, peer, "tcp")
    if not connection then
        --- accepted fd 尚未进入 Lua socket_pool，必须用 close_fd 关闭。
        socket.close_fd(fd)
        return
    end

    --- 捕获 start/read/driver 异常，保证异常退出也释放连接；清理不向业务发送错误响应。
    skynet.fork(function()
        local ok, err = pcall(run_tcp, connection)
        if not ok then
            emit_event(
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
local function timeout_loop()
    -- 核心计算：周期扫描正在握手或正在读数据的连接。
    while module_state.phase == "running" do
        skynet.sleep(10)

        local now = skynet.now()
        local expired = {}

        for _, connection in pairs(module_state.connections) do
            local since = connection.read_started or connection.last_message
            local limit = connection.read_started
                and module_state.gateway_config.read_timeout_ticks
                or module_state.gateway_config.idle_timeout_ticks

            if module_state.handshake.expired(connection.handshake) or
                (now - since) % 0x100000000 >= limit then
                expired[#expired + 1] = connection
            end
        end

        -- 状态修改：摘除并关闭本轮发现的超时连接。
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
---@field websocket_protocol? "ws" 仅接受 ws；TLS 必须由宿主前置终止。
---@field handler_service string 已注册的本地 Skynet Service 名，用于投递业务请求。
---@field observer_service? integer 可选观测 Service handle，只接收异步诊断事件。
---@field descriptor_path string 宿主构建生成的 Protobuf descriptor 文件路径。
---@field registry_module string 已生成的协议 registry 模块名。
---@field protocol_version integer Envelope 使用的协议版本。
---@field max_frame_bytes? integer 单帧 body 字节上限。
---@field read_timeout_ticks? integer 读取超时，单位 10 ms tick。
---@field idle_timeout_ticks? integer WebSocket 空闲超时，单位 10 ms tick。
---@field max_requests_per_second? integer 单连接每秒入站请求上限。
---@field max_total_requests_per_second? integer 当前实例每秒总投递上限。
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
    -- 参数/状态检查：Gateway 只能从 created 状态启动一次。
    assert(module_state.phase == "created", "gateway can only start once")

    -- 数据准备：读取配置并加载生成的协议 registry。
    local gateway_config = normalize_config(startup_config)
    local generated = assert(
        require(gateway_config.registry_module),
        "cannot load gateway registry module"
    )
    local registry = registry_loader.build_index(generated)

    -- 状态修改：安装当前 Lua State 独占的运行时对象。
    module_state.gateway_config = gateway_config
    module_state.registry = registry
    module_state.codec = codec_factory.new(
        {
            descriptor_path = gateway_config.descriptor_path,
            registry        = registry,
        }
    )

    module_state.epoch = tostring(skynet.self()) .. ":" .. tostring(skynet.hpc())
    module_state.handshake = handshake_factory.new(
    {
        crypto        = require "flywow_gateway_crypto", -- 固定native绑定，缺少时启动失败。
        now           = skynet.now, -- 显式时钟，不创建额外协程。
        max_pending   = gateway_config.max_pending_handshakes, -- 待握手连接数量。
        timeout_ticks = gateway_config.handshake_timeout_ticks, -- 绝对期限。
    }
    )

    -- 状态修改：进入 starting，随后绑定监听 Socket。
    module_state.rate_started = skynet.now()
    module_state.rate_count = 0
    module_state.phase = "starting"

    local listen_fd, address, port = socket.listen(
        gateway_config.host,
        gateway_config.port,
        gateway_config.backlog
    )
    module_state.listen_fd = listen_fd

    -- 持久化/消息发送：注册监听回调并发布 ready 日志。
    socket.start(listen_fd, accept_client)
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
    -- 参数/状态检查：重复停止直接返回，不重复触碰监听和连接。
    if module_state.phase == "stopped" then
        return
        {
            closed_connections = 0,
        }
    end

    -- 状态修改：先进入 stopping，阻止新的业务读取。
    module_state.phase = "stopping"

    -- 持久化/消息发送：关闭监听 Socket，不再接受新连接。
    if module_state.listen_fd then
        socket.close(module_state.listen_fd)
        module_state.listen_fd = nil
    end

    -- 数据准备：先复制连接快照，避免遍历时删除连接表。
    local closed = 0
    local snapshot = {}

    for _, connection in pairs(module_state.connections) do
        snapshot[#snapshot + 1] = connection
    end

    -- 状态修改：逐个摘除连接并关闭底层传输。
    for index = 1, #snapshot do
        local connection = snapshot[index]
        if not connection.closed then
            closed = closed + 1
            detach_connection(connection, "server shutdown")
            close_transport(connection, 1001, "server shutdown")
        end
    end

    -- 收尾：所有连接处理完成后发布 stopped 状态。
    module_state.phase = "stopped"

    return
    {
        closed_connections = closed,
    }
end


skynet.start(function()
    skynet.info_func(function()
        local handshaking_connections = 0
        local reading_connections = 0

        for _, connection in pairs(module_state.connections) do
            if module_state.handshake and not module_state.handshake.ready(connection.handshake) then
                handshaking_connections = handshaking_connections + 1
            end
            if connection.read_started then
                reading_connections = reading_connections + 1
            end
        end

        local gateway_config = module_state.gateway_config
        return
        {
            phase                   = module_state.phase,
            transport               = gateway_config and gateway_config.transport or "unconfigured",
            listen_host             = gateway_config and gateway_config.host or "unbound",
            listen_port             = gateway_config and gateway_config.port or 0,
            connections             = module_state.client_count,
            ready_clients           = module_state.client_count - handshaking_connections,
            handshaking_connections = handshaking_connections,
            reading_connections     = reading_connections,
            responses_sent          = module_state.responses_sent,
            responses_dropped       = module_state.responses_dropped,
            protocol_commands       = module_state.registry and module_state.registry.count or 0,
        }
    end)

    --- LuaPanda 只连接当前 FlyWow Lua State；8820 不与 Proxy/Query/Battle Service 复用。
    luapanda_debug.start(8820)

    --- 服务命令合同：start 接收 GatewayStartConfig，send_data/close 接收对应消息 record；stop/stats 不接收参数。
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

        if command == "stats" then
            skynet.retpack(
                {
                    phase             = module_state.phase,
                    clients           = module_state.client_count,
                    responses_sent    = module_state.responses_sent,
                    responses_dropped = module_state.responses_dropped,
                    command_count     = module_state.registry and module_state.registry.count or 0,
                }
            )
            return
        end

        error("unknown flywow.gateway command: " .. tostring(command))
    end)
end)
