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

-- 校验并复制 start 配置，避免运行过程中读取宿主可能修改的 table。
-- 参数 input：可省略的启动覆盖 table；业务通常只传 handler_service，其他字段来自 config.gateway。
-- 返回值：当前 Service 私有的不可再变更配置；失败抛错，不执行 I/O、yield 或启动资源。
local function normalize_config(input)
    local merged = merge_config(load_default_config(), input)
    local transport = merged.transport or "tcp"
    assert(transport == "tcp" or transport == "websocket", "unsupported gateway transport: " .. tostring(transport))
    if transport == "websocket" then
        assert(merged.websocket_protocol == nil or merged.websocket_protocol == "ws" or merged.websocket_protocol == "wss",
               "websocket_protocol must be ws or wss")
    end
    local max_frame_bytes = merged.max_frame_bytes or 65535
    assert(max_frame_bytes >= 1 and max_frame_bytes <= 0xffff, "max_frame_bytes must fit the TCP Envelope uint16")
    assert(max_frame_bytes <= 256 * 1024, "WebSocket transport is limited by pinned Skynet http.websocket")
    local max_clients = merged.max_clients or 1024
    local warning_kb = merged.write_warning_close_kb or 1024
    assert(max_clients >= 1 and warning_kb >= 1, "gateway resource limits must be positive")
    assert(tonumber(merged.port) and merged.port >= 1 and merged.port <= 65535, "port must be in [1, 65535]")
    assert(merged.backlog == nil or (merged.backlog >= 1 and merged.backlog <= 65535), "backlog must be positive")
    assert(merged.handler_service and merged.handler_service > 0, "handler_service is required")
    assert(type(merged.descriptor_path) == "string" and merged.descriptor_path ~= "", "descriptor_path is required")
    assert(type(merged.registry_module) == "string" and merged.registry_module ~= "", "registry_module is required")
    return {
        host = merged.host or "127.0.0.1", -- 监听地址；只影响当前 Gateway。
        port = assert(tonumber(merged.port), "port is required"), -- TCP/WS 监听端口，1..65535。
        backlog = merged.backlog or 128, -- OS accept backlog，不等于 max_clients。
        transport = transport, -- tcp 或 websocket；运行期不可切换。
        websocket_protocol = merged.websocket_protocol or "ws", -- websocket 时为 ws/wss。
        handler_service = merged.handler_service, -- 已创建的业务 Service handle；不通过全局名字发现。
        observer_service = merged.observer_service, -- 可选观测 Service handle；只接收异步事件。
        descriptor_path = merged.descriptor_path, -- 运行目录下的 descriptor 文件路径。
        registry_module = merged.registry_module, -- 生成 registry 的 require 名称。
        protocol_version = assert(tonumber(merged.protocol_version), "protocol_version is required"), -- Envelope 版本。
        max_frame_bytes = max_frame_bytes, -- 单个 Envelope body 上限，单位 byte。
        max_clients = max_clients, -- 当前 Gateway 最大在线连接数。
        write_warning_close_kb = warning_kb, -- 写缓冲 warning 达到此 KB 时关闭连接。
    }
end

-- 向可选 observer Service 投递结构化 Gateway 事件；observer 故障不能影响业务请求。
-- 参数 event：包含 kind、connection_id、transport、peer、request_id、command 等字段的普通 table。
-- 返回值：无；使用 skynet.send，不 yield，不等待 observer 响应，不持有 event 的外部引用。
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
-- 参数 fd/peer/transport：当前连接的底层标识、对端地址和协议类型；fd 仅由 Gateway 自己保存。
-- 返回值：连接上下文；调用方拥有并负责在关闭时从 state.connections 移除。
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
-- 参数 connection：当前 Gateway 拥有的 connection context；reason 为不含敏感数据的关闭原因。
-- 返回值：首次关闭 true，重复关闭 false；不执行网络 close，避免递归和 yield。
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

-- 将业务 handler 的结果标准化为 response table。
-- 参数 result：handler Service 返回的 `{ ok=true, response=<table> }` record；禁止返回 nil/字符串状态。
-- 返回值：业务 response table；失败抛错，由上层转换为 handler_error 并关闭连接。
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

-- 解码、调用业务 Service、编码并发送一条完整 Envelope。
-- 参数 connection：当前连接；payload：已由 TCP/WebSocket transport 完成 framing 的 bytes；send：发送函数。
-- 返回值：成功 true；失败 false。函数执行 Protobuf、跨 Service skynet.call 并可能 yield。
-- yield 后会重新检查 connection.closed；不保存 payload 的 borrowed 引用。
local function dispatch_payload(connection, payload, send)
    if connection.closed or #payload == 0 or #payload > state.config.max_frame_bytes then
        emit({ kind = "error", code = "FRAME_LIMIT", message = "payload exceeds configured limit", connection_id = connection.id })
        return false
    end
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

-- 从 TCP 流读取指定字节数；Socket 关闭、短读或底层错误返回 nil 和原因。
-- 参数 fd：当前 TCP fd；size：正整数 byte 数；返回值由 skynet.socket.read 所有。
-- 函数执行 I/O 并 yield；返回后调用方不能假设连接仍然有效。
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

-- 运行一个 TCP 连接。协议 framing 是 uint16 big-endian length + Envelope bytes。
-- 参数 connection：已登记连接；函数拥有当前读取协程直到 close，顺序处理同一连接请求。
-- 失败：frame、协议或业务错误后关闭连接；执行 Socket I/O、跨 Service call 和 yield。
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

-- 处理 WebSocket binary message；Skynet 的 http.websocket 已负责 Upgrade、mask、fragment 和 ping/pong。
-- 参数 id/payload/opcode：Skynet WebSocket connection id、完整 payload、文本或 binary opcode。
-- 返回值：无；业务失败会关闭当前连接并发出结构化 error 事件。
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

-- WebSocket 握手完成后登记连接；Skynet 已在 accept 内完成 HTTP Upgrade 校验。
-- 参数 id/header/url：Skynet connection id、握手 header 和请求路径；当前 Gateway 只记录生命周期。
-- 返回值：无；连接容量不足时关闭当前 WebSocket，不执行跨 Service 调用。
function ws_handler.handshake(id, header, url)
    local connection = create_connection(id, header["x-real-ip"] or "unknown", "websocket")
    if not connection then websocket.close(id, 1013, "server busy") end
end

-- WebSocket 关闭时移除连接；底层库已经负责释放 Socket。
-- 参数 id：Skynet WebSocket connection id；返回值：无；不执行 I/O 或 yield。
function ws_handler.close(id)
    detach(state.connections_by_fd[id], "websocket closed")
end

-- WebSocket 传输错误转成统一 Gateway error 事件。
-- 参数 id/message：连接 id 和底层错误文字；返回值：无；只修改本 Service 的连接表。
function ws_handler.error(id, message)
    local connection = state.connections_by_fd[id]
    emit({ kind = "error", code = "WEBSOCKET_ERROR", message = tostring(message), connection_id = connection and connection.id or id })
    detach(connection, "websocket error")
end

-- WebSocket 写缓冲达到 Skynet warning 阈值时发出 warning，并在配置阈值处主动关闭。
-- 参数 ws_object/size：Skynet websocket 对象和待写 byte 数；返回值：无；必要时执行一次 WebSocket close。
function ws_handler.warning(ws_object, size)
    local connection = state.connections_by_fd[ws_object.id]
    if connection then
        emit({ kind = "warning", code = "WRITE_BACKPRESSURE", message = "WebSocket write buffer is large", connection_id = connection.id, pending_kb = size })
        if size >= state.config.write_warning_close_kb then websocket.close(ws_object.id, 1013, "server backpressure") end
    end
end

-- 新 TCP/WebSocket 客户端进入监听回调；只创建有限连接，不让业务 Service 接触 fd。
-- 参数 fd/peer：Skynet accepted fd 和对端地址；函数在 Gateway Service 内执行并 fork 会话。
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

-- 启动监听、加载 descriptor/registry 并发布可用状态。
-- 参数 input：可选启动覆盖 table；通常只包含 handler_service，网络和协议配置来自 config.gateway。
-- 返回值：{ address, port, transport, command_count }；函数执行 I/O、加载文件并在 socket.listen yield。
-- 失败：配置、descriptor、registry 或 bind 失败时抛错，Service 不进入 running。
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

-- 停止监听、关闭所有连接并释放 Service 私有状态。
-- 返回值：{ closed_connections = number }；函数执行 Socket I/O 并可能 yield，不能在业务 handler 内调用。
local function stop()
    if state.phase == "stopped" then return { closed_connections = 0 } end
    state.phase = "stopping"
    if state.listen_fd then socket.close(state.listen_fd); state.listen_fd = nil end
    local closed = 0
    for _, connection in pairs(state.connections) do
        if not connection.closed then
            closed = closed + 1
            if connection.transport == "websocket" then websocket.close(connection.fd, 1001, "server shutdown") else socket.close(connection.fd) end
            detach(connection, "server shutdown")
        end
    end
    state.phase = "stopped"
    return { closed_connections = closed }
end

-- 暴露 Service 命令；配置和 handler handle 通过 skynet.call 显式传入，不使用全局服务名。
-- 参数 command/start：start 的参数是启动合同；stop 不接受额外参数。
skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, argument)
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
            skynet.retpack({ phase = state.phase, clients = state.client_count, command_count = state.registry and state.registry.count or 0 })
            return
        end
        error("unknown flywow.gateway command: " .. tostring(command))
    end)
end)
