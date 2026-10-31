--- 职责：提供与业务无关的 Skynet Gateway Service，统一接入 TCP 与 WebSocket。
--- 边界：FlyWow Runtime Service；拥有监听 fd、连接生命周期、frame、背压和协议编解码。
--- 输入/输出：宿主传入的完整课程配置 + handler Service -> 已解码 command/request 与编码后的 response。
--- 生命周期：由宿主通过 newservice 创建；start 后监听，stop 后释放监听 fd 和所有连接。
--- 不负责：不注册业务 command、不理解 Battle/SLG DTO、不加载 .proto 源码、不保存业务状态。
local skynet = require "skynet"
local flywow_result = require "flywow_result"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
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
---@field last_message integer idle_timeout_ticks 的计时点；客户端完整业务消息会刷新，WebSocket ping/pong 和服务端 Push 不刷新。
---@field rate_started integer 本连接当前一秒接纳窗口的起点 tick。
---@field rate_count integer 本连接当前窗口已接纳的业务请求数；用于判断单连接速率上限。
local module_state =
{
    phase              = "created", -- Service 生命周期；created/starting/running/stopping/stopped。
    gateway_config     = nil,       -- 通过 start 校验后的只读配置；由 start 一次写入，后续运行阶段读取。
    registry           = nil,       -- 构建期生成的协议表；启动校验后由 Gateway 与 codec 只读共享。
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

--- 校验有界整数配置；调用方需要区分成功值与配置错误。
---@param config_value number|string|nil 宿主传入的候选配置值。
---@param config_name string 错误详情中指出的配置字段。
---@param min_value integer 合法范围下界，含端点。
---@param max_value integer 合法范围上界，含端点。
---@return FlyWowResult<integer> 成功 value 为整数；类型或范围错误返回 GATEWAY_CONFIG_INVALID。
local function validate_integer_config(config_value, config_name, min_value, max_value)
    if type(config_value) ~= "number" or math.type(config_value) ~= "integer" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            config_name .. " must be an integer",
            { field = config_name }
        )
    end
    if config_value < min_value or config_value > max_value then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            config_name .. " is outside the allowed range",
            { field = config_name, minimum = min_value, maximum = max_value }
        )
    end

    return flywow_result.success(config_value)
end

--- 校验并复制宿主配置；运行期间 Gateway 不再读取调用方可变 table。
---@param startup_config GatewayStartConfig 宿主传入的完整启动配置；本函数只读取配置字段。
---@return FlyWowResult<GatewayStartConfig> 成功 value 为已验证副本；字段无效时返回 GATEWAY_CONFIG_INVALID。
local function normalize_config(startup_config)
    if type(startup_config) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "gateway start config must be a table"
        )
    end

    -- 校验传输选择和监听地址；默认地址只接受本机连接，外部绑定须由宿主显式指定。
    local host = startup_config.host == nil and "127.0.0.1" or startup_config.host -- 缺省只绑定回环接口；显式 false 保留给类型检查拒绝。
    if type(host) ~= "string" or host == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "host must be a non-empty address",
            { field = "host" }
        )
    end

    -- 监听地址通过后选择本实例固定的传输协议。
    local transport = startup_config.transport == nil and "tcp" or startup_config.transport -- 仅 nil 使用 tcp 默认值；显式 false 由传输类型校验拒绝。
    if transport ~= "tcp" and transport ~= "websocket" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "unsupported gateway transport",
            { field = "transport", value = tostring(transport) }
        )
    end
    if transport == "websocket" and startup_config.websocket_protocol ~= nil and
        startup_config.websocket_protocol ~= "ws" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "websocket_protocol supports ws only; terminate TLS outside Gateway",
            { field = "websocket_protocol" }
        )
    end

    -- 每项数值配置分别通过公共 integer 检查；首个错误作为本次启动结果返回。
    -- 传输协议与 WebSocket 选项通过后校验帧长和各资源上限。
    local max_frame_result = validate_integer_config(
        startup_config.max_frame_bytes == nil and 65535 or startup_config.max_frame_bytes,
        "max_frame_bytes",
        1,
        0xffff
    )
    if not max_frame_result.ok then
        return max_frame_result
    end

    -- 帧长通过后保存其余连接容量与写缓冲参数。
    local max_frame_bytes = max_frame_result.value -- 入站与出站 Envelope 的共同字节上限。

    local max_clients_result = validate_integer_config(
        startup_config.max_clients == nil and 1024 or startup_config.max_clients,
        "max_clients",
        1,
        1000000
    )
    if not max_clients_result.ok then
        return max_clients_result
    end
    -- 连接容量通过后保存配置副本，随后检查写缓冲阈值。

    local max_clients = max_clients_result.value -- 当前 Gateway 可登记的连接容量。

    -- 连接容量通过后校验写缓冲关闭阈值。
    local write_warning_result = validate_integer_config(
        startup_config.write_warning_close_kb == nil and 1024 or startup_config.write_warning_close_kb,
        "write_warning_close_kb",
        1,
        0x7fffffff
    )
    if not write_warning_result.ok then
        return write_warning_result
    end
    -- 写缓冲阈值通过后保存配置副本，随后检查监听端口。

    local write_warning_close_kb = write_warning_result.value -- Skynet 写缓冲告警触发摘除连接的 KB 阈值。

    -- 缓冲阈值通过后校验监听端口和 backlog。
    local port_result = validate_integer_config(startup_config.port, "port", 1, 65535)
    if not port_result.ok then
        return port_result
    end
    -- 端口校验成功后保存监听端口。

    local port = port_result.value -- 宿主要求绑定的 TCP/WS 端口。

    local backlog_result = validate_integer_config(startup_config.backlog == nil and 128 or startup_config.backlog, "backlog", 1, 65535)
    if not backlog_result.ok then
        return backlog_result
    end
    -- backlog 校验成功后保存 OS accept 队列上限。

    local backlog = backlog_result.value -- 操作系统尚未 accept 的连接队列容量。

    -- 端口和 backlog 通过后校验 Envelope 版本与时限。
    local protocol_version_result =
        validate_integer_config(startup_config.protocol_version, "protocol_version", 1, 0xffffffff)
    if not protocol_version_result.ok then
        return protocol_version_result
    end
    -- 协议版本通过后保存版本号，再校验网络时限。

    local protocol_version = protocol_version_result.value -- 本实例接受和发送的 Envelope 协议版本。

    -- Envelope 版本通过后校验读取、空闲和请求速率限制。
    local read_timeout_result = validate_integer_config(
        startup_config.read_timeout_ticks == nil and 3000 or startup_config.read_timeout_ticks,
        "read_timeout_ticks",
        1,
        360000
    )
    if not read_timeout_result.ok then
        return read_timeout_result
    end
    -- 读取期限通过后保存配置，再校验空闲期限。

    local read_timeout_ticks = read_timeout_result.value -- TCP 定长读取与 WebSocket Upgrade 的单次等待期限，单位 10ms tick。

    -- 单次读取期限通过后校验 WebSocket 空闲期限。
    local idle_timeout_result = validate_integer_config(
        startup_config.idle_timeout_ticks == nil and 30000 or startup_config.idle_timeout_ticks,
        "idle_timeout_ticks",
        1,
        360000
    )
    if not idle_timeout_result.ok then
        return idle_timeout_result
    end
    -- 空闲期限通过后保存配置，再校验入站速率上限。

    local idle_timeout_ticks = idle_timeout_result.value -- 客户端完整业务消息空闲期限，单位 10ms tick；不由 ping/pong 或服务端 Push 刷新。

    -- 空闲期限通过后分别限制连接级与实例级入站速率。
    local requests_per_second_result = validate_integer_config(
        startup_config.max_requests_per_second == nil and 200 or startup_config.max_requests_per_second,
        "max_requests_per_second",
        1,
        100000
    )
    if not requests_per_second_result.ok then
        return requests_per_second_result
    end
    -- 连接级速率通过后保存配置，再校验实例总速率。

    local max_requests_per_second = requests_per_second_result.value -- 单连接一秒窗口的最大业务请求数。

    -- 连接级速率通过后限制整个实例的总接纳速率。
    local total_requests_per_second_result = validate_integer_config(
        startup_config.max_total_requests_per_second == nil and 10000 or startup_config.max_total_requests_per_second,
        "max_total_requests_per_second",
        1,
        1000000
    )
    if not total_requests_per_second_result.ok then
        return total_requests_per_second_result
    end
    -- 实例速率通过后保存配置，再限制 Native 握手上下文容量。

    local max_total_requests_per_second = total_requests_per_second_result.value -- 本 Gateway 实例一秒窗口的最大业务请求数。

    -- 实例请求预算通过后限制同时持有 Native 握手上下文的连接。
    local max_pending_result = validate_integer_config(
        startup_config.max_pending_handshakes == nil and math.min(128, max_clients) or startup_config.max_pending_handshakes,
        "max_pending_handshakes",
        1,
        max_clients
    )
    if not max_pending_result.ok then
        return max_pending_result
    end
    -- 握手容量通过后保存上限，再校验握手绝对期限。

    local max_pending_handshakes = max_pending_result.value -- 含 TCP 与 WS 的应用握手并发上限。

    -- 握手名额通过后校验绝对握手期限。
    local handshake_timeout_result = validate_integer_config(
        startup_config.handshake_timeout_ticks == nil and 1000 or startup_config.handshake_timeout_ticks,
        "handshake_timeout_ticks",
        1,
        360000
    )
    if not handshake_timeout_result.ok then
        return handshake_timeout_result
    end
    -- 握手期限通过后保存配置，最后校验 handler 和协议产物。

    local handshake_timeout_ticks = handshake_timeout_result.value -- 从连接登记起算的握手总期限，单位 10ms tick。

    -- 数值范围全部通过后校验 handler 与协议产物路径。
    -- handler 与协议产物由宿主显式提供；运行期间不会再 require 固定业务配置。
    local handler_service = startup_config.handler_service -- 宿主已注册的请求接收 Service 名。
    if type(handler_service) ~= "string" or handler_service == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "handler_service must be a non-empty Skynet service name",
            { field = "handler_service" }
        )
    end
    if type(startup_config.descriptor_path) ~= "string" or
        startup_config.descriptor_path == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "descriptor_path is required",
            { field = "descriptor_path" }
        )
    end
    if type(startup_config.registry_module) ~= "string" or
        startup_config.registry_module == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "registry_module is required",
            { field = "registry_module" }
        )
    end

    return flywow_result.success(
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
        read_timeout_ticks            = read_timeout_ticks, -- 单次 TCP 读取或 WS Upgrade 上限，单位 10ms tick。
        idle_timeout_ticks            = idle_timeout_ticks, -- 客户端完整业务消息空闲上限，单位 10ms tick。
        max_requests_per_second       = max_requests_per_second, -- 单连接一秒窗口的业务请求上限。
        max_total_requests_per_second = max_total_requests_per_second, -- 本 Gateway 一秒窗口的业务请求上限。
        max_pending_handshakes        = max_pending_handshakes, -- 尚未完成应用握手的连接上限。
        handshake_timeout_ticks       = handshake_timeout_ticks, -- 应用握手总期限，单位 10ms tick。
        max_clients                   = max_clients, -- 当前 Gateway 最大在线连接数。
        write_warning_close_kb        = write_warning_close_kb, -- Skynet warning 回调大小达到此 KB 时关闭连接。
    })
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
    local handshake_result = module_state.handshake.accept() -- 为新连接申请握手名额；容量不足时返回稳定错误结果。
    if not handshake_result.ok then
        log_event(
        {
            kind    = "error",
            code    = handshake_result.code, -- 把握手管理器的稳定拒绝码带入 Gateway 事件。
            message = handshake_result.message, -- 原始诊断只供日志定位，不能作为流程判断。
        }
        )

        return nil
    end

    -- 所有协议对象都已创建，下面一次性提交到 Service 状态。

    local handshake = handshake_result.value -- 新连接持有的独占握手 context。

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
---@param force_shutdown boolean|nil true 时先强制释放底层发送队列，再清理 Socket/WS 对象。
---@return nil 关闭提交完成或无需重复关闭。
local function close_transport(connection, code, reason, force_shutdown)
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

    -- 调用方仅在背压超限时要求丢弃底层发送队列；其他关闭继续按原合同排空。
    if force_shutdown and not socket.invalid(connection.fd) then
        socket.shutdown(connection.fd)
    end

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
--- connection/payload 由 Gateway 持有，失败时返回 FlyWowResult 并由传输层关闭违规连接。
---@param connection GatewayConnection 当前已登记连接。
---@param payload string 一条完整业务 Envelope bytes；当前调用借用，不跨 yield 保存。
---@return FlyWowResult<nil> 投递成功时为 success；帧、协议、速率或 handler 投递失败时返回稳定错误。
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
        return flywow_result.failure("FRAME_LIMIT", "payload exceeds configured limit")
    end

    -- 先把不可信 Protobuf bytes 解为 Envelope；codec 失败以结果返回，不用 pcall 包内部模块。
    local envelope_result = module_state.codec.decode_envelope(payload) -- 解码结果；失败时含 codec 错误码与诊断。
    if not envelope_result.ok then
        log_event(
        {
            kind          = "error",
            code          = "ENVELOPE_DECODE", -- Gateway 对外记录的帧解码失败类别。
            message       = envelope_result.message, -- codec 诊断仅用于日志。
            connection_id = connection.id, -- 标识导致本次拒绝的逻辑连接。
        }
        )
        return flywow_result.failure(
            "ENVELOPE_DECODE",
            envelope_result.message,
            { cause_code = envelope_result.code }
        )
    end

    -- Envelope 解码成功后才检查协议版本并解析 command。
    local envelope = envelope_result.value -- 已解码外层记录，接下来检查版本和命令号。

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
        return flywow_result.failure("PROTOCOL_VERSION", "unsupported protocol version")
    end

    -- 用 wire 字段 Envelope.command 查 registry；跨 Service 记录再使用 command_id。
    -- 只按生成 registry 中的 command 定义解释 body，不从客户端输入推导消息类型。
    local definition = module_state.registry.commands[envelope.command] -- 当前命令对应的已验证请求/响应类型定义。
    if definition == nil then
        log_event(
        {
            kind          = "error",
            code          = "UNKNOWN_COMMAND",
            message       = "command is not in generated registry",
            connection_id = connection.id,
        }
        )
        return flywow_result.failure(
            "UNKNOWN_COMMAND",
            "command is not in generated registry",
            { command_id = envelope.command }
        )
    end

    -- 已找到命令后才解码其 request body；Protobuf 错误在当前网络消息边界转换为稳定结果。
    local request_result =
        module_state.codec.decode_request(envelope.command, definition, envelope.body) -- 解码后的业务 record 或 codec 错误。
    if not request_result.ok then
        log_event(
        {
            kind          = "error",
            code          = "REQUEST_DECODE", -- Gateway 对外记录的业务 body 解码失败类别。
            message       = request_result.message, -- codec 诊断仅用于日志。
            connection_id = connection.id, -- 标识导致本次拒绝的逻辑连接。
        }
        )
        return flywow_result.failure(
            "REQUEST_DECODE",
            request_result.message,
            { cause_code = request_result.code, command_id = envelope.command }
        )
    end

    -- request 解码成功后才计算速率预算并异步发送给 handler。
    local request = request_result.value -- 按 registry request_type 解码的业务请求，后续交给 handler。

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
        return flywow_result.failure("INGRESS_RATE_LIMIT", "ingress rate exceeded")
    end

    -- 两项上限都通过后才占用本帧的接纳额度。
    connection.rate_count = connection.rate_count + 1
    module_state.rate_count = module_state.rate_count + 1

    -- 完整 request 已获准投递；刷新空闲计时后异步交给宿主处理。
    connection.last_message = now

    -- 将 request、command 和连接身份异步发送给宿主指定的 handler Service；发送失败时由传输层关闭连接。
    local inbound_request = -- 本帧交给 handler 的连接上下文与业务请求；send 后 Gateway 不保存。
    {
        gateway_epoch = module_state.epoch, -- 让 handler 忽略旧 Gateway 实例的迟到消息。
        connection_id = connection.id, -- 使用逻辑连接号，不暴露底层 fd。
        peer          = connection.peer, -- 连接建立时记录的对端地址，仅供宿主诊断。
        transport     = connection.transport, -- 标明该连接使用 TCP 还是 WebSocket。
        command_id    = envelope.command, -- 由 registry 验证过的业务命令号。
        data          = request, -- 已按 registry 请求类型解码的业务内容。
    }
    local call_succeeded, send_result_or_error = pcall( -- 捕获 Skynet send 异常；正常返回值 0 表示成功，nil/false 表示失败。
        skynet.send,
        module_state.gateway_config.handler_service,
        "lua",
        "send_data",
        inbound_request
    )

    -- pinned Skynet 普通 send 成功返回 0；nil 或 false 表示投递失败。
    if not call_succeeded or send_result_or_error == false or send_result_or_error == nil then
        log_event(
        {
            kind          = "error",
            code          = "HANDLER_SEND", -- handler mailbox 未接收本条请求。
            message       = tostring(send_result_or_error), -- Skynet send 的拒绝或异常诊断。
            connection_id = connection.id, -- 标识投递失败的逻辑连接。
        }
        )
        return flywow_result.failure("HANDLER_SEND", tostring(send_result_or_error))
    end

    return flywow_result.success()
end


--- 将完整 Envelope 写入一个连接；TCP 前置 uint16 长度头，WebSocket 发送 binary message。
--- 写入失败时返回稳定错误并摘除连接、异步关闭；成功只表示本地传输接受写入。
---@param connection GatewayConnection Gateway 独占的目标连接；本函数读取 transport、fd 和 id。
---@param encoded string 已编码的完整 Envelope bytes；由调用方创建，本函数不保存。
---@return nil 写入失败由本函数记录、摘除连接并安排关闭；调用方无需处理传输结果。
local function write_connection(connection, encoded)
    local write_succeeded, write_result_or_error

    if connection.transport == "tcp" then
        write_succeeded, write_result_or_error = pcall(
            socket.write,
            connection.fd,
            string.pack(">I2", #encoded) .. encoded
        )
        write_succeeded = write_succeeded and write_result_or_error ~= false
    else
        write_succeeded, write_result_or_error = pcall(
            websocket.write,
            connection.fd,
            encoded,
            "binary"
        )
        write_succeeded = write_succeeded and write_result_or_error ~= false
    end

    -- 底层明确拒绝或抛错时，关闭该连接并记录原生诊断。
    if not write_succeeded then
        -- 写失败时先记录原因，再摘除连接并异步关闭 transport。
        local failure_message = tostring(write_result_or_error) -- 底层异常或拒绝结果，仅用于诊断。
        log_event(
        {
            kind          = "error",
            code          = "WRITE_FAILED", -- 底层传输拒绝或写入调用抛错。
            message       = failure_message, -- 原生诊断仅用于定位写入失败。
            connection_id = connection.id, -- 标识被摘除的逻辑连接。
        }
        )

        detach_connection(connection, "write failed")
        skynet.fork(function()
            close_transport(connection, 1011, "write failed")
        end)
        return
    end
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
    local definition = module_state.registry.commands[outbound_message.command_id] -- 出站消息声明的响应类型。
    if not definition or definition.response_type == nil then
        return
    end

    -- codec 将 schema 或业务记录错误作为结果返回；出站消息入口记录并丢弃失败响应。
    local encode_result = module_state.codec.encode_response(
        outbound_message.command_id,
        definition,
        module_state.gateway_config.protocol_version,
        outbound_message.data
    )
    if not encode_result.ok then
        log_event(
        {
            kind          = "error", -- 当前响应不能发送给客户端。
            code          = "RESPONSE_ENCODE", -- 业务响应无法编码为协议 Envelope。
            message       = encode_result.message, -- codec 诊断只用于日志。
            connection_id = outbound_message.connection_id, -- 记录目标连接或广播标记。
        }
        )
        return
    end

    -- 编码成功后限制出站帧长，再选择 ready 连接。
    local encoded = encode_result.value -- 已编码 Envelope；下面只处理帧长度和目标连接。
    if #encoded > module_state.gateway_config.max_frame_bytes then
        log_event(
        {
            kind          = "error",
            code          = "RESPONSE_ENCODE", -- 编码结果超过配置的单帧上限。
            message       = "response exceeds frame limit", -- 固定诊断不含业务数据。
            connection_id = outbound_message.connection_id, -- 记录目标连接或广播标记。
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


--- 将握手帧交给状态机并发送它生成的响应；只有 SERVER_READY 写成功后才提交 ready。
--- Native/握手错误和传输写错误返回 FlyWowResult；调用方据此摘除连接。Socket 写不 yield。
---@param connection GatewayConnection 当前未 ready 的连接。
---@param bytes string 一条完整握手消息；不跨调用保存。
---@return FlyWowResult<nil> 成功表示响应已写出且所需 ready 状态已提交；失败返回握手或传输错误。
local function process_handshake(connection, bytes)
    local handshake_result = module_state.handshake.receive(
    {
        context = connection.handshake, -- 本连接独占的握手状态；receive 只改这个 context。
        bytes   = bytes, -- 当前完整网络帧；借用到本次同步解码结束，不保存。
    }
    )
    if not handshake_result.ok then
        log_event(
        {
            kind          = "error",
            code          = handshake_result.code, -- 状态机为当前握手阶段返回的稳定错误码。
            message       = handshake_result.message, -- 握手失败诊断只进入事件日志。
            connection_id = connection.id, -- 标识被拒绝的逻辑连接。
        }
        )
        return flywow_result.failure(
            handshake_result.code,
            handshake_result.message,
            handshake_result.details
        )
    end

    -- 握手状态机通过后发送其响应；只有发送成功才提交需要的 ready。
    local handshake_output = handshake_result.value -- 握手响应字节和写成功后确认标记。
    local response_bytes = handshake_output.response_bytes
    local write_succeeded, write_result_or_error
    if connection.transport == "tcp" then
        write_succeeded, write_result_or_error = pcall(
            socket.write,
            connection.fd,
            string.pack(">I2", #response_bytes) .. response_bytes
        )
    else
        write_succeeded, write_result_or_error = pcall(
            websocket.write,
            connection.fd,
            response_bytes,
            "binary"
        )
    end

    if not write_succeeded or write_result_or_error == false or connection.closed then
        return flywow_result.failure(
            "HANDSHAKE_WRITE_FAILED",
            tostring(write_succeeded and "transport rejected handshake response" or write_result_or_error)
        )
    end

    -- 响应写入完成后刷新活动时间；最后阶段还需提交握手 ready。
    connection.last_message = skynet.now()

    if handshake_output.needs_confirmation then
        local confirm_result = module_state.handshake.confirm(connection.handshake)
        if not confirm_result.ok then
            return confirm_result
        end

        log_event(
        {
            kind          = "ready",
            connection_id = connection.id,
            message       = "handshake complete",
        }
        )
    end

    return flywow_result.success()
end

--- 运行一个已登记 TCP 连接；本协程串行读取和投递，直到 EOF、错误或 Service 停止。
--- connection 由 Gateway 状态表持有并提供 fd；frame 为 2 byte uint16 big-endian 长度头 + Envelope bytes，长度不含头。
--- 先校验长度再读取 body；max_frame_bytes 限制业务 Envelope，不是底层传输接收内存硬上限。
--- 读取 Socket 时 yield；投递不等待业务。所有退出路径都 detach 并关闭 fd。
---@param connection GatewayConnection Gateway 独占的 TCP 连接。
---@return nil 直到 EOF、协议错误、超时或 Server 停止后退出并清理连接。
local function run_tcp(connection)
    -- 已 detach 的连接不能再启动读取协程，避免关闭后重新使用 fd。
    if connection.closed then
        return
    end

    -- 启动 TCP fd；业务帧长度在读取完整 body 前校验，写队列积压另由 warning 回调处理。
    local fd = connection.fd -- 当前协程操作的连接 fd；由连接记录持有。
    local opened, open_error = socket.start(fd) -- Skynet 原生接口的返回值；成功为原 fd，失败为 nil 和诊断文本。

    if connection.closed then
        return
    end

    -- pinned socket.start 成功返回原 fd；运行时失败按连接错误清理，不用 assert 表达。
    if opened ~= fd then
        log_event(
        {
            kind          = "error", -- accepted TCP fd 未能进入 Skynet Socket 管理。
            code          = "TCP_SOCKET_START", -- pinned Socket 未能接管 accepted fd。
            message       = tostring(open_error or opened), -- Skynet 原生返回的失败诊断。
            connection_id = connection.id, -- 标识本次启动失败的逻辑连接。
        }
        )
        detach_connection(connection, "socket start failed")
        close_transport(connection, 1011, "socket start failed")
        return
    end

    -- Socket 接管 fd 后仅注册写队列告警；帧大小由长度头和业务 Envelope 上限校验。
    socket.warning(fd, function(_, size)
        if size == 0 then
            return
        end

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
            close_transport(connection, 1013, "write backpressure", true)
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

        local frame_result
        if ready then
            frame_result = dispatch_payload(connection, payload)
        else
            frame_result = process_handshake(connection, payload)
        end

        -- 当前帧处理失败时摘除连接并关闭底层 WebSocket。
    if not frame_result.ok then
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
    local frame_result -- 当前握手帧或业务帧的结果；失败时摘除该连接。
    if module_state.handshake.ready(connection.handshake) then
        frame_result = dispatch_payload(connection, payload)
    else
        frame_result = process_handshake(connection, payload)
    end

    -- 当前握手或业务帧失败后关闭连接，成功帧保持可读写。
    if not frame_result.ok then
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

--- 处理 Skynet WebSocket 写队列告警；size 单位是 KB，清空通知为 0 并直接忽略。
--- 非零告警先记录；只有回调 size 达到 write_warning_close_kb 才关闭，阈值受 Skynet 告警粒度影响。无返回值。
---@param ws_object table Skynet WebSocket 对象；id 用于找到 Gateway 连接。
---@param size integer Skynet write buffer 告警大小，单位 KB；0 表示发送缓冲已清空并被忽略。
---@return nil 记录非零缓冲告警；回调大小达到配置阈值时关闭连接。
function ws_handler.warning(ws_object, size)
    if size == 0 then
        return
    end

    -- 恢复通知不属于积压事件；非零回调才查找仍登记的连接并记录告警。
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
            close_transport(connection, 1013, "server backpressure", true)
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
    -- 定时检查握手期限、TCP 读超时和客户端完整业务消息空闲期限。
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
---@field max_frame_bytes? integer 单条业务 Envelope bytes 上限；TCP 长度头不计，不构成底层传输内存硬上限。
---@field read_timeout_ticks? integer 读取超时，单位 10 ms tick。
---@field idle_timeout_ticks? integer 客户端完整业务消息空闲超时，单位 10 ms tick；WebSocket ping/pong 和服务端 Push 不重置。
---@field max_requests_per_second? integer 单连接每秒接纳的业务请求上限。
---@field max_total_requests_per_second? integer 当前实例每秒接纳的业务请求上限。
---@field max_pending_handshakes? integer 尚未完成握手的连接上限。
---@field handshake_timeout_ticks? integer 握手总期限，单位 10 ms tick。
---@field max_clients? integer 当前实例最大在线连接数。
---@field write_warning_close_kb? integer Skynet warning 回调的 size 达到此 KB 时关闭；受底层告警粒度影响。

--- Gateway 启动时校验宿主指定的生成文件结构，不建立第二份命令索引。
---@param generated table require 返回的协议表；只读。
---@return FlyWowResult<integer> 成功值是命令数量，失败为 GATEWAY_REGISTRY_INVALID。
local function validate_generated_registry(generated)
    if type(generated) ~= "table" or
        type(generated.envelope_type) ~= "string" or generated.envelope_type == "" or
        type(generated.commands) ~= "table" then
        return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway registry structure is invalid")
    end

    local count = 0
    for command_id, definition in pairs(generated.commands) do
        if type(command_id) ~= "number" or command_id % 1 ~= 0 or
            command_id < 1 or command_id > 0xffffffff or type(definition) ~= "table" or
            (definition.request_type ~= nil and
                (type(definition.request_type) ~= "string" or definition.request_type == "")) or
            (definition.response_type ~= nil and
                (type(definition.response_type) ~= "string" or definition.response_type == "")) then
            return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway command definition is invalid",
                { command_id = command_id })
        end
        count = count + 1
    end

    if count == 0 then
        return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway registry must contain at least one command")
    end
    return flywow_result.success(count)
end

---@class GatewayStartResult
---@field address string 实际监听地址。
---@field port integer 实际监听端口。
---@field transport GatewayTransport 实例使用的传输协议。
---@field command_count integer 已加载 registry 中的命令数。

--- 校验启动配置、加载协议 descriptor/registry 并开始监听，最后才发布 running 状态。
--- handler_service 必须是已注册的本地 Skynet 服务名。配置、文件或 bind 失败返回稳定错误，不宣告就绪。
--- 执行文件 I/O、创建 codec 和监听 Socket，socket.listen 可能 yield；只允许从 created 启动一次。
---@param startup_config GatewayStartConfig 宿主提交的完整启动配置。
---@return FlyWowResult<GatewayStartResult> 成功 value 为实际监听信息；失败返回稳定错误，可能 yield。
local function start(startup_config)
    if module_state.phase ~= "created" then
        return flywow_result.failure("GATEWAY_START_STATE_INVALID", "gateway can only start once")
    end

    -- 配置、协议定义和 Native 握手依赖都通过后，才提交运行状态。
    local config_result = normalize_config(startup_config) -- 宿主配置的完整校验结果。
    if not config_result.ok then
        return config_result
    end

    -- 启动配置通过后加载课程构建生成的命令表；缺失模块会明确返回加载错误。
    local gateway_config = config_result.value -- 已验证副本；后续不再读取宿主可变 table。
    local generated_ok, generated = pcall(require, gateway_config.registry_module) -- 按宿主指定名称加载生成 registry。
    if not generated_ok then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_LOAD_FAILED",
            tostring(generated),
            { module = gateway_config.registry_module }
        )
    end

    -- 命令表加载成功后验证其字段和命令 ID，防止无效协议索引进入运行状态。
    local registry_result = validate_generated_registry(generated) -- 只读校验生成表并计算命令数。
    if not registry_result.ok then
        return registry_result
    end

    local registry = generated -- Gateway 与 codec 直接共用构建产物，不再复制索引。
    local command_count = registry_result.value -- 启动日志和统计使用的命令数量。
    local codec_result = codec_module.new(
        {
            descriptor_path = gateway_config.descriptor_path, -- 宿主生成的 Protobuf descriptor 文件。
            registry        = registry, -- 已通过结构校验的生成表。
        }
    )
    if not codec_result.ok then
        return codec_result
    end

    -- codec ready 后再加载 Native 握手实现；此时仍未创建 listener 或接受连接。
    local crypto_ok, crypto = pcall(require, "flywow_gateway_crypto") -- 本 Gateway 使用的 Native 握手实现。
    if not crypto_ok then
        return flywow_result.failure("GATEWAY_CRYPTO_LOAD_FAILED", tostring(crypto))
    end

    -- Native 模块加载成功后建立本 Service 独占的握手管理器和容量限制。
    local handshake_result = handshake_module.new(
        {
            crypto        = crypto, -- 执行本连接 ECDH/HMAC 的 Native 模块。
            now           = skynet.now, -- 握手期限使用的 10 ms 时钟。
            max_pending   = gateway_config.max_pending_handshakes, -- 同时持有 Native 上下文的连接上限。
            timeout_ticks = gateway_config.handshake_timeout_ticks, -- 从 accept 起算的绝对期限。
        }
    )
    if not handshake_result.ok then
        return handshake_result
    end

    -- 所有依赖都通过校验后一次性发布运行对象，再进入异步 listener 阶段。
    local codec = codec_result.value -- 当前 Lua State 独占的 Protobuf codec。
    local handshake = handshake_result.value -- 管理握手名额与每连接 Native userdata 的状态机。
    module_state.gateway_config = gateway_config
    module_state.registry = registry
    module_state.codec = codec
    module_state.handshake = handshake
    module_state.epoch = tostring(skynet.self()) .. ":" .. tostring(skynet.hpc())
    module_state.rate_started = skynet.now()
    module_state.rate_count = 0
    module_state.phase = "starting"

    -- Socket 绑定可能失败；把原生异常转换为此 RPC 的稳定错误结果。
    local listen_ok, listen_fd, address, port = pcall( -- 绑定结果或原生异常；失败时保留诊断而不泄漏异常合同。
        socket.listen,
        gateway_config.host,
        gateway_config.port,
        gateway_config.backlog
    )
    if not listen_ok then
        module_state.phase = "stopped"
        return flywow_result.failure("GATEWAY_LISTEN_FAILED", tostring(listen_fd))
    end

    -- listener 创建可能 yield；如果 stop 已改变阶段，释放本协程仍拥有的 fd。
    if module_state.phase ~= "starting" then
        pcall(socket.close, listen_fd)
        return flywow_result.failure("GATEWAY_START_INTERRUPTED", "gateway stopped while binding")
    end

    -- bind 完成后把 fd 所有权交给 Service 状态，供 stop 与启动失败路径清理。
    module_state.listen_fd = listen_fd

    -- socket.start 是 Native 驱动边界；失败时释放刚绑定的 listener。
    local start_ok, started_fd, start_error = pcall( -- 驱动启动状态、成功 fd 或错误值。
        socket.start,
        listen_fd,
        accept_client
    )
    if not start_ok or started_fd ~= listen_fd then
        if module_state.listen_fd == listen_fd then
            module_state.listen_fd = nil
            pcall(socket.close, listen_fd)
        end
        module_state.phase = "stopped"
        local failure = start_ok and start_error or started_fd -- pcall 返回的驱动错误或异常文本。
        return flywow_result.failure("GATEWAY_LISTENER_START_FAILED", tostring(failure))
    end

    -- socket.start 也可能 yield；只有本协程仍拥有 listener 且阶段未变化时才能发布 ready。
    if module_state.phase ~= "starting" then
        if module_state.listen_fd == listen_fd then
            module_state.listen_fd = nil
            pcall(socket.close, listen_fd)
        end
        return flywow_result.failure("GATEWAY_START_INTERRUPTED", "gateway stopped while starting listener")
    end

    -- 所有监听步骤成功且仍归本启动流程所有后才发布 running。
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
        command_count
    )

    return flywow_result.success(
        {
            address       = address, -- Socket Driver 实际绑定的监听地址。
            port          = port, -- Socket Driver 实际绑定的端口。
            transport     = gateway_config.transport, -- 启动配置选择的 TCP 或 WebSocket。
            command_count = command_count, -- 已验证协议 registry 中的命令数量。
        }
    )
end

---@class GatewayStopResult
---@field closed_connections integer 本次停止时由 Gateway 关闭的连接数量。


--- 幂等地停止监听并关闭所有 Gateway 拥有的连接。
--- 返回本次主动关闭的连接数；执行 Socket I/O，关闭操作可能 yield，不应在业务请求 handler 中同步调用。
--- 连接数受 max_clients 限制；先快照索引再 detach，避免遍历期间删 key 漏关或重复关闭。
---@return FlyWowResult<GatewayStopResult> 成功 value 含本次关闭数量；Socket 关闭异常返回稳定错误。
local function stop()
    -- 已 stopped 的实例直接返回，避免重复关闭已经释放的 fd。
    if module_state.phase == "stopped" then
        return flywow_result.success(
            {
                closed_connections = 0, -- 重复 stop 没有再次关闭的连接数。
            }
        )
    end

    -- 进入 stopping 后，读取循环会在下一次检查时退出。
    module_state.phase = "stopping"

    -- 关闭监听 fd，阻止 Skynet 再把新连接交给本实例。
    local listen_fd = module_state.listen_fd -- 先转成本地 owner，再从共享状态清空以防重复关闭。
    module_state.listen_fd = nil
    local close_error_count = 0 -- 本次停止时底层关闭失败的数量；用于让调用方识别未完成的资源释放。
    local first_close_error = nil -- 第一条关闭诊断；只保留一条以免失败信息随连接数增长。
    if listen_fd then
        local close_ok, close_error = pcall(socket.close, listen_fd) -- Listener 关闭状态及原生异常诊断。
        if not close_ok then
            close_error_count = close_error_count + 1
            first_close_error = tostring(close_error)
        end
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
            local close_ok, close_error = pcall( -- 当前连接的 transport 关闭状态及原生异常诊断。
                close_transport,
                connection,
                1001,
                "server shutdown"
            )
            if not close_ok then
                close_error_count = close_error_count + 1
                if first_close_error == nil then
                    first_close_error = tostring(close_error)
                end
            end
        end
    end

    -- 停止阶段会尽力关闭全部 fd；底层任一关闭失败都通过单一稳定错误返回。
    module_state.phase = "stopped"
    if close_error_count > 0 then
        return flywow_result.failure(
            "GATEWAY_STOP_CLOSE_FAILED",
            first_close_error,
            { close_error_count = close_error_count, closed_connections = closed }
        )
    end

    return flywow_result.success(
        {
            closed_connections = closed, -- 本次首次摘除并提交关闭的连接总数。
        }
    )
end


skynet.start(function()
    --- 服务命令合同：start 接收 GatewayStartConfig，send_data/close 接收对应消息 record，stop 不接收参数。
    skynet.dispatch("lua", function(session, _source, command, argument)
        if command == "close" then
            request_close(argument)
            return
        end

        if command == "send_data" then
            deliver_outbound_message(argument)
            return
        end

        if command == "start" then
            local start_result = start(argument) -- 本次启动的稳定结果，包含监听信息或错误码。
            if session ~= 0 then
                skynet.retpack(start_result)
            elseif not start_result.ok then
                skynet.error("GATEWAY_START_FAILED ", start_result.code, " ", start_result.message)
            end
            return
        end

        if command == "stop" then
            if argument ~= nil then
                local failure = flywow_result.failure(
                    "GATEWAY_STOP_ARGUMENT_INVALID",
                    "stop does not accept an argument"
                )
                if session ~= 0 then
                    skynet.retpack(failure)
                else
                    skynet.error("GATEWAY_STOP_ARGUMENT_INVALID")
                end
                return
            end

            local stop_result = stop() -- 本次关闭的连接数或底层资源释放失败。
            if session ~= 0 then
                skynet.retpack(stop_result)
            elseif not stop_result.ok then
                skynet.error("GATEWAY_STOP_FAILED ", stop_result.code, " ", stop_result.message)
            end
            return
        end

        local failure = flywow_result.failure(
            "GATEWAY_COMMAND_UNKNOWN",
            "unknown flywow.gateway command: " .. tostring(command),
            { command = tostring(command) }
        )
        if session ~= 0 then
            skynet.retpack(failure)
        else
            skynet.error("GATEWAY_COMMAND_UNKNOWN ", tostring(command))
        end
    end)
end)
