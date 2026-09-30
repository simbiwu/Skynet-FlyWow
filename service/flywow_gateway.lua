-- 职责：提供与业务无关的 Skynet Gateway Service，统一接入 TCP 与 WebSocket。
-- 边界：FlyWow Runtime Service；拥有监听 fd、连接生命周期、frame、背压和协议编解码。
-- 输入/输出：config.gateway 默认配置 + 可选 start 覆盖项 + handler Service -> 已解码 command/request 与编码后的 response。
-- 生命周期：由宿主通过 newservice 创建；start 后监听，stop 后释放所有 fd、连接和队列状态。
-- 不负责：不注册业务 command、不理解 Battle/SLG DTO、不加载 .proto 源码、不保存业务状态。
local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local registry_loader = require "flywow.gateway.registry"
local codec_factory = require "flywow.gateway.codec"

local state = {
    phase = "created",              -- Service 生命周期；created/starting/running/stopping/stopped。
    config = nil,                    -- 通过 start 校验后的只读配置；owner 是当前 Lua State。
    registry = nil,                  -- 生成 registry 的只读索引；生命周期覆盖整个运行期。
    codec = nil,                     -- 当前 Lua State 独占的 descriptor codec。
    listen_fd = nil,                 -- 监听 Socket fd；关闭后清空。
    connections = {},                -- connection_id -> connection context；只由 Gateway 修改。
    connections_by_fd = {},          -- fd -> connection context；仅用于 WebSocket 回调反查。
    next_connection_id = 0,          -- 单调递增连接标识；不复用为业务持久 ID。
    client_count = 0,                -- 当前已完成接入的连接数。
}

-- 读取宿主工程的标准 Gateway 默认配置；配置文件归宿主维护，框架只读取不修改。
-- 参数：无；固定 require 名称为 config.gateway，必须返回普通 Lua table。
-- 返回值：默认配置 table；失败抛出配置加载异常，不执行 Socket I/O、不 yield。
local function load_default_config()
    local defaults = require "config.gateway"
    assert(type(defaults) == "table", "config.gateway must return a table")
    return defaults
end

-- 将启动时覆盖项浅合并到默认配置；handler_service 等运行期 handle 不写入静态配置。
-- 参数 defaults/overrides：默认配置和可选覆盖 table；调用方拥有输入，函数不修改它们。
-- 返回值：Gateway 私有候选配置；不执行 I/O、不 yield；同名顶层字段由 overrides 覆盖。
local function merge_config(defaults, overrides)
    assert(overrides == nil or type(overrides) == "table", "gateway start overrides must be a table")
    local merged = {}
    for key, value in pairs(defaults) do
        merged[key] = value
    end
    for key, value in pairs(overrides or {}) do
        merged[key] = value
    end
    return merged
end

-- 把配置项校验为有界整数，避免字符串数字、小数或 NaN 进入端口和资源上限。
-- value 是候选数值，name 仅用于错误诊断，minimum/maximum 是含端点的合法范围；参数只读。
-- 返回 Lua integer；类型不符或越界时抛错。不执行 I/O、分配外部资源或 yield。
local function require_integer(value, name, minimum, maximum)
    assert(type(value) == "number" and math.type(value) == "integer",
           name .. " must be an integer")
    assert(value >= minimum and value <= maximum,
           name .. " must be in [" .. minimum .. ", " .. maximum .. "]")
    return value
end

-- 校验并复制 start 配置，避免运行过程中读取宿主可能修改的 table。
-- 参数 input：可省略的启动覆盖 table；业务通常只传 handler_service，其他字段来自 config.gateway。
-- 返回值：当前 Service 私有的不可再变更配置；失败抛错，不执行 I/O、yield 或启动资源。
local function normalize_config(input)
    local merged = merge_config(load_default_config(), input)
    local transport = merged.transport or "tcp"
    assert(transport == "tcp" or transport == "websocket", "unsupported gateway transport: " .. tostring(transport))
    if transport == "websocket" then
        -- pinned Skynet 的 wss server 会从进程环境/当前目录隐式读证书。
        -- 当前合同没有 TLS 证书注入和轮换能力，因此明确只允许 ws。
        assert(merged.websocket_protocol == nil or merged.websocket_protocol == "ws",
               "websocket_protocol currently supports ws only; terminate TLS outside Gateway")
    end
    local max_frame_bytes = require_integer(merged.max_frame_bytes or 65535,
                                            "max_frame_bytes", 1, 0xffff)
    local max_clients = require_integer(merged.max_clients or 1024,
                                        "max_clients", 1, 1000000)
    local warning_kb = require_integer(merged.write_warning_close_kb or 1024,
                                       "write_warning_close_kb", 1, 0x7fffffff)
    local port = require_integer(merged.port, "port", 1, 65535)
    local backlog = require_integer(merged.backlog or 128, "backlog", 1, 65535)
    local protocol_version = require_integer(merged.protocol_version,
                                             "protocol_version", 1, 0xffffffff)
    local handler_service = require_integer(merged.handler_service,
                                            "handler_service", 1, math.maxinteger)
    local observer_service = merged.observer_service
    if observer_service ~= nil then
        observer_service = require_integer(observer_service, "observer_service", 1, math.maxinteger)
    end
    assert(type(merged.descriptor_path) == "string" and merged.descriptor_path ~= "", "descriptor_path is required")
    assert(type(merged.registry_module) == "string" and merged.registry_module ~= "", "registry_module is required")
    return {
        host = merged.host or "127.0.0.1", -- 监听地址；只影响当前 Gateway。
        port = port, -- TCP/WS 监听端口，1..65535。
        backlog = backlog, -- OS accept backlog，不等于 max_clients。
        transport = transport, -- tcp 或 websocket；运行期不可切换。
        websocket_protocol = "ws", -- TLS 由宿主前置终止；Gateway 不隐式读取证书。
        handler_service = handler_service, -- 已创建的业务 Service handle；不通过全局名字发现。
        observer_service = observer_service, -- 可选观测 Service handle；只接收异步事件。
        descriptor_path = merged.descriptor_path, -- 运行目录下的 descriptor 文件路径。
        registry_module = merged.registry_module, -- 生成 registry 的 require 名称。
        protocol_version = protocol_version, -- Envelope uint32 兼容版本。
        max_frame_bytes = max_frame_bytes, -- 单个 Envelope body 上限，单位 byte。
        max_clients = max_clients, -- 当前 Gateway 最大在线连接数。
        write_warning_close_kb = warning_kb, -- 写缓冲 warning 达到此 KB 时关闭连接。
    }
end

-- 记录并向可选 observer Service 投递结构化 Gateway 事件；observer 故障不能影响业务请求。
-- event 是本次事件的只读普通 table，常见字段为 kind/code/message 和连接、请求上下文；敏感 payload 不得放入。
-- 返回值：无。skynet.send 异步投递且不 yield；日志只写标识和诊断字段，不保留 event 引用。
local function emit(event)
    skynet.error("FLYWOW_GATEWAY_" .. string.upper(event.kind),
                 " connection_id=", tostring(event.connection_id or "-"),
                 " command=", tostring(event.command or "-"),
                 " code=", tostring(event.code or "-"),
                 " message=", tostring(event.message or "-"))
    if state.config.observer_service then
        skynet.send(state.config.observer_service, "lua", "gateway_event", event)
    end
end

-- 为新连接创建唯一上下文；上下文不暴露底层 fd 给业务 Service。
-- fd 是 Skynet 接受的连接句柄，peer 是诊断用地址，transport 为 tcp/websocket；fd 始终由本 Service 独占。
-- 容量达到 max_clients 时返回 nil 且不接管连接关闭责任；成功时返回由 Gateway 状态表持有的 context。
-- connection_id 单调递增，避免 fd 被 OS 复用后旧连接身份与新连接混淆。
local function create_connection(fd, peer, transport)
    if state.client_count >= state.config.max_clients then
        emit({ kind = "warning", code = "MAX_CONNECTIONS", message = "connection limit reached", peer = peer, transport = transport })
        return nil
    end
    state.next_connection_id = state.next_connection_id + 1
    local connection = {
        id = state.next_connection_id, -- Gateway 内部连接标识，不暴露底层 fd。
        fd = fd,                        -- Gateway 私有底层 fd；业务 Service 不接收。
        peer = peer,                    -- 对端地址字符串；只用于日志和业务上下文。
        transport = transport,          -- tcp 或 websocket。
        closed = false,                 -- close race 保护位；只允许从 false 到 true。
        request_count = 0,              -- 已完成 dispatch 次数；诊断统计字段。
    }
    state.connections[connection.id] = connection
    state.connections_by_fd[fd] = connection
    state.client_count = state.client_count + 1
    emit({ kind = "open", connection_id = connection.id, peer = peer, transport = transport })
    return connection
end

-- 从连接表中移除连接并发出一次 close 事件；重复调用不会重复递减计数。
-- connection 是本 Gateway 状态表中的 context，reason 是不含敏感数据的诊断原因。
-- 先设置 closed 再摘除两个索引，使重入/迟到回调只能观察到已关闭状态；不关闭 fd、不执行 I/O/yield。
-- 返回首次 detach 为 true，nil 或重复关闭为 false。
local function detach(connection, reason)
    if connection == nil or connection.closed then
        return false
    end
    connection.closed = true
    state.connections[connection.id] = nil
    state.connections_by_fd[connection.fd] = nil
    state.client_count = state.client_count - 1
    emit({ kind = "close", connection_id = connection.id, peer = connection.peer,
           transport = connection.transport, message = reason or "closed" })
    return true
end

-- 将业务 handler 的返回合同校验为 response table。
-- result 由注入的 handler Service 返回，必须是 `{ ok=true, response=<table> }`；错误时可用 `{ ok=false, error={code,message} }`。
-- 返回 handler 拥有的 response table，供编码器只读使用；nil、未知状态或拒绝结果转为异常，由调用方映射成显式事件。
local function require_response(result)
    assert(type(result) == "table", "handler must return a result table")
    if result.ok == false then
        local error_info = result.error or {}
        error((error_info.code or "HANDLER_REJECTED") .. ": " .. (error_info.message or "handler rejected request"))
    end
    assert(result.ok == true, "handler result.ok must be true")
    assert(result.response ~= nil, "handler result.response is required")
    return result.response
end

-- 校验并处理一条已完成 framing 的 Envelope：解码、调用业务 handler、编码 response 并交给 transport 发送。
-- connection 是本 Service 持有的连接 context；payload 是单帧 Protobuf bytes，长度单位 byte；send(encoded) 由当前 transport 提供。
-- 返回 true 表示发送函数接受了完整响应，false 表示调用方应关闭连接；协议、业务和写入失败均发出结构化事件。
-- Protobuf 会分配临时 Lua 对象，skynet.call 会跨 Service 且可能 yield；yield 后先检查 closed，payload 不跨调用保存。
local function dispatch_payload(connection, payload, send)
    if connection.closed or #payload == 0 or #payload > state.config.max_frame_bytes then
        emit({ kind = "error", code = "FRAME_LIMIT", message = "payload exceeds configured limit", connection_id = connection.id })
        return false
    end
    -- pcall 把不可信网络字节导致的解码异常限制在当前请求，便于统一发事件并关闭连接。
    local envelope_ok, envelope = pcall(state.codec.decode_envelope, payload)
    if not envelope_ok then
        emit({ kind = "error", code = "ENVELOPE_DECODE", message = tostring(envelope), connection_id = connection.id })
        return false
    end
    if envelope.protocol_version ~= state.config.protocol_version then
        emit({ kind = "error", code = "PROTOCOL_VERSION", message = "unsupported protocol version", connection_id = connection.id })
        return false
    end
    local definition = registry_loader.find(state.registry, envelope.command)
    if definition == nil then
        emit({ kind = "error", code = "UNKNOWN_COMMAND", message = "command is not in generated registry", connection_id = connection.id })
        return false
    end
    local request_ok, request = pcall(state.codec.decode_request, definition, envelope.body)
    if not request_ok then
        emit({ kind = "error", code = "REQUEST_DECODE", message = tostring(request), connection_id = connection.id, command = definition.name })
        return false
    end

    connection.request_count = connection.request_count + 1
    -- handler 调用是唯一可能 yield 的请求步骤；下面必须再次检查连接身份/生命周期。
    local call_ok, result = pcall(skynet.call, state.config.handler_service, "lua", "gateway_dispatch", {
        connection_id = connection.id,
        peer = connection.peer,
        transport = connection.transport,
        request_id = envelope.request_id,
        command_id = definition.id,
        command = definition.name,
        request = request,
    })
    if connection.closed then
        return false
    end
    if not call_ok then
        emit({ kind = "error", code = "HANDLER_CALL", message = tostring(result), connection_id = connection.id, command = definition.name })
        return false
    end
    local response_ok, response = pcall(require_response, result)
    if not response_ok then
        emit({ kind = "error", code = "HANDLER_RESULT", message = tostring(response), connection_id = connection.id, command = definition.name })
        return false
    end
    -- 在交给 transport 前再次限制完整 Envelope 大小，防止合法请求触发无界响应写入。
    local encode_ok, encoded = pcall(state.codec.encode_response, definition, envelope.request_id,
                                     state.config.protocol_version, response)
    if not encode_ok or #encoded > state.config.max_frame_bytes then
        emit({ kind = "error", code = "RESPONSE_ENCODE", message = encode_ok and "response exceeds frame limit" or tostring(encoded), connection_id = connection.id, command = definition.name })
        return false
    end
    local sent_ok, sent_error = pcall(send, encoded)
    if not sent_ok then
        emit({ kind = "error", code = "WRITE_FAILED", message = tostring(sent_error), connection_id = connection.id, command = definition.name })
        return false
    end
    return true
end

-- 从 TCP 字节流读取指定数量的字节；TCP 不保留消息边界，因此 header/body 必须分别读满。
-- fd 是当前 Gateway 持有的 TCP fd；size 是正整数 byte 数。成功返回新 bytes string，失败返回 nil 与原因。
-- socket.read 执行 I/O 并可能 yield；调用方在返回后需检查连接状态，不得依赖 fd 未被关闭。
local function read_exact(fd, size)
    local data, remainder = socket.read(fd, size)
    if not data then
        return nil, remainder or "socket closed"
    end
    if #data ~= size then
        return nil, "short read"
    end
    return data
end

-- 运行一个已登记 TCP 连接；本协程串行处理该连接上的请求直到 EOF、错误或 Service 停止。
-- connection 由 Gateway 状态表持有并提供 fd；frame 为 2 byte uint16 big-endian 长度头 + Envelope bytes，长度不含头。
-- 先检查长度再读取 body，防止按不可信长度分配/缓存过量数据；限制 socket 缓冲区以施加背压。
-- 执行 Socket I/O、跨 Service call 和 yield；所有退出路径都 detach 并关闭 fd。
local function run_tcp(connection)
    local fd = connection.fd
    socket.start(fd)
    socket.limit(fd, state.config.max_frame_bytes + 2)
    socket.warning(fd, function(_, size)
        emit({ kind = "warning", code = "WRITE_BACKPRESSURE", message = "TCP write buffer is large", connection_id = connection.id, pending_kb = size })
        if size >= state.config.write_warning_close_kb then
            socket.close(fd)
        end
    end)
    while not connection.closed and state.phase == "running" do
        local header, err = read_exact(fd, 2)
        if not header then break end
        -- >I2 表示网络字节序 uint16；先拒绝 0 或超限长度，再按该值读取 body。
        local size = string.unpack(">I2", header)
        if size < 1 or size > state.config.max_frame_bytes then
            emit({ kind = "error", code = "FRAME_LIMIT", message = "invalid TCP frame length", connection_id = connection.id })
            break
        end
        local payload
        payload, err = read_exact(fd, size)
        if not payload then break end
        if not dispatch_payload(connection, payload, function(encoded)
            assert(#encoded <= 0xffff, "encoded response exceeds TCP framing limit")
            assert(socket.write(fd, string.pack(">I2", #encoded) .. encoded))
        end) then break end
    end
    detach(connection, "tcp session ended")
    socket.close(fd)
end

local ws_handler = {}

-- 处理已由 Skynet 完成拼帧的 WebSocket message；底层库负责 Upgrade、mask、fragment 与 ping/pong。
-- id 是 Skynet connection id，payload 是单条完整消息 bytes，opcode 标识文本或 binary；payload 不跨回调保存。
-- 仅接受 binary 且受 max_frame_bytes 限制；函数无返回值，失败时发事件并关闭当前连接。
function ws_handler.message(id, payload, opcode)
    local connection = state.connections_by_fd[id]
    if not connection or connection.closed then return end
    if opcode ~= "binary" then
        emit({ kind = "error", code = "TEXT_MESSAGE_REJECTED", message = "only binary WebSocket messages are accepted", connection_id = connection.id })
        websocket.close(id, 1003, "binary messages required")
        return
    end
    if not dispatch_payload(connection, payload, function(encoded)
        assert(#encoded <= state.config.max_frame_bytes, "encoded response exceeds frame limit")
        websocket.write(id, encoded, "binary")
    end) then
        websocket.close(id, 1008, "gateway request rejected")
    end
end

-- WebSocket 握手完成后登记连接；HTTP Upgrade 和握手校验由 Skynet 完成。
-- id 是 Skynet connection id，header 是只读握手字段，url 是请求路径；仅使用 x-real-ip 作为诊断 peer，不据此授权。
-- 无返回值；超过 max_clients 时关闭该连接，不执行跨 Service 调用或 yield。
function ws_handler.handshake(id, header, url)
    local connection = create_connection(id, header["x-real-ip"] or "unknown", "websocket")
    if not connection then websocket.close(id, 1013, "server busy") end
end

-- WebSocket 关闭回调中移除连接；底层库负责释放 Socket，本函数只清理 Gateway 索引。
-- id 是 Skynet WebSocket connection id；迟到或重复回调由 detach 的幂等性处理。无返回值，不执行 I/O/yield。
function ws_handler.close(id)
    detach(state.connections_by_fd[id], "websocket closed")
end

-- 将 WebSocket 底层传输错误转为统一 Gateway error 事件并摘除连接。
-- id 是 Skynet connection id，message 是底层诊断文本；不包含业务 payload。无返回值，只修改本 Service 的连接索引。
function ws_handler.error(id, message)
    local connection = state.connections_by_fd[id]
    emit({ kind = "error", code = "WEBSOCKET_ERROR", message = tostring(message), connection_id = connection and connection.id or id })
    detach(connection, "websocket error")
end

-- 处理 WebSocket 写队列增长通知；size 是待写字节数，按 Skynet warning 回调的单位比较关闭阈值（KB）。
-- ws_object 提供底层 connection id；只对仍登记的连接发事件，达到 write_warning_close_kb 时关闭以限制队列增长。无返回值。
function ws_handler.warning(ws_object, size)
    local connection = state.connections_by_fd[ws_object.id]
    if connection then
        emit({ kind = "warning", code = "WRITE_BACKPRESSURE", message = "WebSocket write buffer is large", connection_id = connection.id, pending_kb = size })
        if size >= state.config.write_warning_close_kb then websocket.close(ws_object.id, 1013, "server backpressure") end
    end
end

-- 新 TCP/WebSocket 客户端进入监听回调；只登记有界连接，不把 fd 交给业务 Service。
-- fd 是 Skynet accept 的句柄且由 Gateway 接管关闭，peer 是对端地址诊断字符串。
-- WebSocket accept 与 TCP 会话分别由 Gateway fork 协程驱动；超限时立即关闭 fd，不入表。
local function accept_client(fd, peer)
    if state.config.transport == "websocket" then
        if state.client_count >= state.config.max_clients then
            emit({ kind = "warning", code = "MAX_CONNECTIONS", message = "connection limit reached", peer = peer, transport = "websocket" })
            socket.close(fd)
            return
        end
        skynet.fork(function()
            local ok, err = websocket.accept(fd, ws_handler, state.config.websocket_protocol, peer)
            local connection = state.connections_by_fd[fd]
            if not ok and err then emit({ kind = "error", code = "WEBSOCKET_ACCEPT", message = tostring(err), connection_id = connection and connection.id or fd }) end
            detach(connection, "websocket session ended")
        end)
    else
        local connection = create_connection(fd, peer, "tcp")
        if not connection then
            socket.close(fd)
            return
        end
        skynet.fork(function() run_tcp(connection) end)
    end
end

-- 校验启动配置、加载协议 descriptor/registry 并开始监听，最后才发布 running 状态。
-- input 是宿主传入的可选覆盖 table；handler_service 必须是已启动 handler 的显式 Service handle。
-- 成功返回实际 address/port、transport 与 command_count；配置、文件、协议或 bind 失败时抛错，不宣告就绪。
-- 执行文件 I/O、创建 codec 和监听 Socket，socket.listen 可能 yield；只允许从 created 启动一次。
local function start(input)
    assert(state.phase == "created", "gateway can only start once")
    local config = normalize_config(input)
    local generated = assert(require(config.registry_module), "cannot load gateway registry module")
    local registry = registry_loader.load(generated)
    state.config, state.registry = config, registry
    state.codec = codec_factory.new({ descriptor_path = config.descriptor_path, registry = registry })
    state.phase = "starting"
    local listen_fd, address, port = socket.listen(config.host, config.port, config.backlog)
    state.listen_fd = listen_fd
    socket.start(listen_fd, accept_client)
    state.phase = "running"
    skynet.error("FLYWOW_GATEWAY_READY transport=", config.transport,
                 " address=", address, ":", port, " commands=", registry.count)
    return { address = address, port = port, transport = config.transport, command_count = registry.count }
end

-- 幂等地停止监听并关闭所有 Gateway 拥有的连接。
-- 返回本次主动关闭的连接数；执行 Socket I/O，关闭操作可能 yield，不应在业务请求 handler 中同步调用。
-- 连接数受 max_clients 限制；先快照索引再 detach，避免遍历期间删 key 漏关或重复关闭。
local function stop()
    if state.phase == "stopped" then return { closed_connections = 0 } end
    state.phase = "stopping"
    if state.listen_fd then socket.close(state.listen_fd); state.listen_fd = nil end
    local closed = 0
    local snapshot = {}
    for _, connection in pairs(state.connections) do
        snapshot[#snapshot + 1] = connection
    end
    for index = 1, #snapshot do
        local connection = snapshot[index]
        if not connection.closed then
            closed = closed + 1
            if connection.transport == "websocket" then websocket.close(connection.fd, 1001, "server shutdown") else socket.close(connection.fd) end
            detach(connection, "server shutdown")
        end
    end
    state.phase = "stopped"
    return { closed_connections = closed }
end

-- 分发 Gateway Service 的固定 Lua 命令；启动配置和业务 handler handle 通过调用参数显式传入。
-- session/source 是 Skynet 消息头字段，command/argument 是消息体固定位置参数；argument 仅 start 可使用。
-- start、stop、stats 通过 retpack 返回各自 record；未知命令或非法参数抛错，交由 skynet.call 报给调用方。
-- start/stop 的 Socket 操作可能 yield；消息头和参数只在本次 dispatch 使用，不跨调用保存。
local function dispatch_command(_session, _source, command, argument)
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
        skynet.retpack({ phase = state.phase, clients = state.client_count,
                         command_count = state.registry and state.registry.count or 0 })
        return
    end
    error("unknown flywow.gateway command: " .. tostring(command))
end

-- 在 Service 初始化协程中注册固定 Lua dispatch；不创建第二个 Service。
-- 无参数和返回值；skynet.start 控制 Service 就绪时机。
local function initialize_service()
    skynet.dispatch("lua", dispatch_command)
end

skynet.start(initialize_service)
