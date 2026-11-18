--- Gateway 的 Worker Service。在自己的 Lua State 中初始化协议和握手依赖，并处理分配给它的连接。
local skynet = require "skynet"
local flywow_result = require "flywow_result"
local flywow_common = require "flywow_common"
local gateway_common = require "flywow_gateway_common"
local gateway_tcp      = require "flywow_gateway_tcp"
local socket           = require "skynet.socket"
local websocket        = require "http.websocket"
local ws_handler       = require "flywow_ws_handler"
local index_min_heap = require "flywow_indexminheap"

local module_state =
{
    phase              = "created",  -- Worker 生命周期；created/running/stopping/stopped。
    gateway_config     = nil,        -- 通过 start 校验后的只读配置；由 start 一次写入，后续运行阶段读取。

    listener_handle   = nil,          -- 本 Worker 的 Listener，接收配额归还通知。
  
    handshake_module = require "flywow_gateway_handshake", -- 本 Worker 的握手模块；start 设置密码实现和超时，接入时创建连接握手状态。
    codec_module     = require "flywow_gateway_codec",     -- 本 Worker 的编解码模块；start 加载协议定义，收发业务帧时复用。
   
    connections        = {},         -- connection_id -> 本 Worker 独占的连接上下文。
    connections_by_fd  = {},         -- fd -> 本 Worker 的连接上下文；供传输回调反查。
    connection_count  = 0,           -- 本 Worker 当前已登记的连接数。
    epoch              = nil,        -- Listener 分配的 Gateway 实例身份，隔离旧实例消息。

    timeout_heap = nil, -- 文件加载时创建，保存各连接最早生效的绝对截止毫秒。
}

local module_handler = {}

--- 让截止时间更早的连接排在超时堆顶部。
---@param first_deadline_ms integer 第一个连接的绝对截止毫秒。
---@param second_deadline_ms integer 第二个连接的绝对截止毫秒。
---@return boolean 第一个截止时间更早时返回 true。
local function is_deadline_earlier(first_deadline_ms, second_deadline_ms)
    return first_deadline_ms < second_deadline_ms
end

module_state.timeout_heap = index_min_heap.new(is_deadline_earlier)

--- 将单调时钟起点与配置时长合成堆使用的绝对截止时间。
---@param started_ms integer 接纳、读取开始或业务活动的单调毫秒读数。
---@param timeout_ms integer 对应阶段的配置时长。
---@return integer 截止毫秒，最大为 Lua 可表示的整数。
local function calculate_deadline_ms(started_ms, timeout_ms)
    -- 配置允许 math.maxinteger，避免极长时限溢出成已到期。
    return started_ms + math.min(timeout_ms, math.maxinteger - started_ms)
end

--- 接入、读取状态变化或业务活动后，更新连接最早到期的时间。
---@param connection GatewayConnection 已登记的连接，提供握手、读取和业务活动状态。
---@return nil 以连接对象为键更新堆项，不 yield。
local function refresh_connection_deadline(connection)
    local gateway_config = module_state.gateway_config -- 本 Worker 的超时配置来源。
    local deadline_ms -- 握手未完成时使用握手时限，完成后使用业务空闲时限。
    if module_state.handshake_module.ready(connection.handshake) then
        deadline_ms = calculate_deadline_ms(connection.last_message_at_ms, gateway_config.idle_timeout_ms)
    else
        deadline_ms = calculate_deadline_ms(connection.handshake.started_ms, gateway_config.handshake_timeout_ms)
    end

    -- 定长读取或 Upgrade 正在等待时，也纳入独立的读取时限。
    if connection.read_started_ms then
        local read_deadline_ms = calculate_deadline_ms(connection.read_started_ms, gateway_config.read_timeout_ms)
        deadline_ms = math.min(deadline_ms, read_deadline_ms)
    end

    if not module_state.timeout_heap:update(connection, deadline_ms) then
        module_state.timeout_heap:insert(connection, deadline_ms)
    end
end

--- TCP 定长读取或 WebSocket Upgrade 改变等待状态时调用。
---@param connection GatewayConnection 已登记的连接，用于更新读取时钟和堆项。
---@param read_started_ms? integer 单调毫秒起点，nil 表示读取结束。
---@return nil 同步更新读取状态和期限。
local function set_read_started(connection, read_started_ms)
    connection.read_started_ms = read_started_ms
    refresh_connection_deadline(connection)
end

--- 解码并按读取顺序异步投递完整帧；本入口不等待任何业务响应。
--- connection/payload 由 Gateway 持有，失败时返回 FlyWowResult 并由传输层关闭违规连接。
---@param connection GatewayConnection 当前已登记连接。
---@param payload string 一条完整业务 Envelope bytes；当前调用借用，不跨 yield 保存。
---@return FlyWowResult<nil> 成功表示已投递给 Handler，帧、协议或投递失败时返回稳定错误。
local function dispatch_payload(connection, payload)
    -- 帧为空或超过配置上限时停止解码；连接由传输入口验证。
    if #payload == 0 or #payload > gateway_common.MAX_FRAME_BYTES then
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "FRAME_LIMIT",
            message       = "payload exceeds configured limit",
            connection_id = connection.connection_id, -- 当前连接的逻辑编号，用于关联诊断。
        }
        )
        return flywow_result.failure("FRAME_LIMIT", "payload exceeds configured limit")
    end

    -- 先把不可信 Protobuf bytes 解为 Envelope；codec 失败以结果返回，不用 pcall 包内部模块。
    local envelope_result = module_state.codec_module.decode_envelope(payload) -- 解码结果；失败时含 codec 错误码与诊断。
    if not envelope_result.ok then
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "ENVELOPE_DECODE", -- Gateway 对外记录的帧解码失败类别。
            message       = envelope_result.message, -- codec 诊断仅用于日志。
            connection_id = connection.connection_id, -- 标识导致本次拒绝的逻辑连接。
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
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "PROTOCOL_VERSION",
            message       = "unsupported protocol version",
            connection_id = connection.connection_id, -- 当前连接的逻辑编号，用于关联诊断。
        }
        )
        return flywow_result.failure("PROTOCOL_VERSION", "unsupported protocol version")
    end

    -- 用 wire 字段 Envelope.command 查 registry；跨 Service 记录再使用 command_id。
    -- 只按生成 registry 中的 command 定义解释 body，不从客户端输入推导消息类型。
    if not module_state.codec_module.has_command(envelope.command) then
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "UNKNOWN_COMMAND",
            message       = "command is not in generated registry",
            connection_id = connection.connection_id, -- 当前连接的逻辑编号，用于关联诊断。
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
        module_state.codec_module.decode_request(envelope.command, envelope.body) -- 解码后的业务 record 或 codec 错误。
    if not request_result.ok then
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "REQUEST_DECODE", -- Gateway 对外记录的业务 body 解码失败类别。
            message       = request_result.message, -- codec 诊断仅用于日志。
            connection_id = connection.connection_id, -- 标识导致本次拒绝的逻辑连接。
        }
        )
        return flywow_result.failure(
            "REQUEST_DECODE",
            request_result.message,
            { cause_code = request_result.code, command_id = envelope.command }
        )
    end

    -- 两层解码通过后，刷新完整业务消息活动时间，再异步投递给 handler。
    local request = request_result.value -- 按 registry 请求类型解码的业务 record。
    connection.last_message_at_ms = flywow_common.now_ms()
    refresh_connection_deadline(connection)

    -- 将 request、command 和连接身份异步发送给宿主指定的 handler Service；发送失败时由传输层关闭连接。
    local inbound_request = -- 本帧交给 handler 的连接身份与业务请求；send 后 Gateway 不保存。
    {
        gateway_epoch = module_state.epoch, -- 让 handler 忽略旧 Gateway 实例的迟到消息。
        connection_id = connection.connection_id, -- 使用逻辑连接号，不暴露底层 fd。
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
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "HANDLER_SEND", -- handler mailbox 未接收本条请求。
            message       = tostring(send_result_or_error), -- Skynet send 的拒绝或异常诊断。
            connection_id = connection.connection_id, -- 标识投递失败的逻辑连接。
        }
        )
        return flywow_result.failure("HANDLER_SEND", tostring(send_result_or_error))
    end

    return flywow_result.success()
end

--- 将握手帧交给状态机并发送它生成的响应；只有 SERVER_READY 写成功后才提交 ready。
--- Native/握手错误和传输写错误返回 FlyWowResult；调用方据此摘除连接。Socket 写不 yield。
---@param connection GatewayConnection 当前未 ready 的连接。
---@param bytes string 一条完整握手消息；不跨调用保存。
---@return FlyWowResult<nil> 成功表示响应已写出且所需 ready 状态已提交；失败返回握手或传输错误。
local function process_handshake(connection, bytes)
    local handshake_result = module_state.handshake_module.receive(connection.handshake, bytes) -- 响应生成结果；写入与确认成功之前不能视为本次处理完成。
    local completion_result = handshake_result -- 先保留状态机失败；成功后由实际的写入或确认结果替换。
    if handshake_result.ok then
        -- 状态机只生成响应，先提交本地写入；固定 Socket/WS 写接口不 yield。
        local handshake_output = handshake_result.value -- 完整响应及是否需要在写成功后确认 ready。
        local write_succeeded, write_result_or_error = gateway_common.write_frame(connection, handshake_output.response_bytes) -- 原生写是否返回及其拒绝值或异常。
        if not write_succeeded or write_result_or_error == false then
            completion_result = flywow_result.failure(
                "HANDSHAKE_WRITE_FAILED",
                tostring(write_succeeded and "transport rejected handshake response" or write_result_or_error)
            )
        else
            -- 最终响应写入成功后仍须检查握手期限，确认成功后释放 Native 对象。
            if handshake_output.needs_confirmation then
                completion_result = module_state.handshake_module.confirm(connection.handshake)
                if completion_result.ok then
                    -- 握手确认后从当前时间开始计业务空闲，替换原握手期限。
                    connection.last_message_at_ms = flywow_common.now_ms()
                    refresh_connection_deadline(connection)

                    gateway_common.log_event(
                    {
                        kind = "ready", -- READY 已被本地传输接受且绝对期限检查通过。
                        connection_id = connection.connection_id, -- 现已允许业务收发的逻辑连接。
                        message = "handshake complete", -- 不表示客户端已经收到或验证服务端证明。
                    })
                end
            else
                completion_result = flywow_result.success()
            end
        end
    end

    -- 握手生成、传输或确认的失败都在这里记录一次；Native 的细分原因不能在通用错误码中丢失。
    if not completion_result.ok then
        local native_details = completion_result.details -- Native 失败的安全诊断；帧、期限与写失败可能没有此字段。
        local failure_message = completion_result.message -- 顶层失败文本；只为日志附加 Native 操作码与原因。
        if native_details then
            failure_message = failure_message .. " native_code=" .. tostring(native_details.native_code) ..
                " native_message=" .. tostring(native_details.native_message)
        end
        gateway_common.log_event(
        {
            kind = "error", -- 当前握手步骤失败，由 TCP/WS 调用方摘除并关闭连接。
            code = completion_result.code, -- 保留可程序化判断的握手错误类别。
            message = failure_message, -- 不包含帧、证明或密钥的诊断。
            connection_id = connection.connection_id, -- 产生本次失败的逻辑连接。
        })
    end
    return completion_result
end

--- WebSocket 回调收到完整 binary 消息后调用；由 Worker 决定按握手还是业务 Envelope 处理。
---@param connection GatewayConnection WebSocket 回调从 fd 索引找到的活动连接，用于读取握手状态。
---@param payload string Skynet 已拼好的完整 binary 消息。
---@return FlyWowResult<nil> 握手响应或业务投递的结果；失败时由 WebSocket 回调关闭连接。
local function on_websocket_message(connection, payload)
    if module_state.handshake_module.ready(connection.handshake) then
        return dispatch_payload(connection, payload)
    end

    return process_handshake(connection, payload)
end

--- Worker 运行期间每 100ms 检查超时堆，关闭已到握手、读取或空闲期限的连接。
---@return nil Worker 停止后退出。关闭底层 Socket 可能 yield。
local function run_timeout_loop()
    while module_state.phase == "running" do
        skynet.sleep(10) -- Skynet 的 sleep 接收 tick，10 tick 对应 100ms。

        -- 等待或关闭 Socket 期间 Worker 可能停止，取下一条连接前确认仍在运行。
        while module_state.phase == "running" do
            -- 堆顶保存最早到期的连接及其绝对截止毫秒。
            local connection, deadline_ms = module_state.timeout_heap:peek()
            if not connection or flywow_common.now_ms() < deadline_ms then
                break
            end

            -- 关闭入口先摘除连接和堆项，再关闭底层 Socket。
            gateway_common.close_connection(module_state, connection, "connection timeout")
        end
    end
end

--- 从 Listener 下发的配置初始化本 Worker 的协议编解码和握手依赖；加载模块和描述文件可能执行 I/O。
---@return FlyWowResult<nil> 依赖全部就绪时成功；加载或初始化失败时返回原始错误。
local function initialize_worker()
    local gateway_config = module_state.gateway_config
    local generated_ok, generated = pcall(require, gateway_config.registry_module) -- 按宿主指定名称加载生成 registry。
    if not generated_ok then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_LOAD_FAILED",
            tostring(generated),
            { module = gateway_config.registry_module }
        )
    end

    -- 命令表加载成功后验证其字段和命令 ID，防止无效协议索引进入运行状态。
    -- 生成表由 codec 独占校验与查询；Gateway 只传递构建产物。
    local codec_result = module_state.codec_module.init(
        {
            descriptor_path = gateway_config.descriptor_path, -- 宿主生成的 Protobuf descriptor 文件。
            registry        = generated, -- 构建生成的协议表，由 codec 校验并持有。
        }
    )
    if not codec_result.ok then
        return codec_result
    end

    -- 协议定义就绪后再加载 Native 密码模块，供后续连接握手使用。
    local crypto_ok, crypto = pcall(require, "flywow_gateway_crypto") -- 本 Gateway 使用的 Native 握手实现。
    if not crypto_ok then
        return flywow_result.failure("GATEWAY_CRYPTO_LOAD_FAILED", tostring(crypto))
    end

    -- 握手模块和超时堆使用同一张配置表及同一个毫秒时钟。
    local handshake_result = module_state.handshake_module.init(gateway_config, crypto, flywow_common.now_ms)
    if not handshake_result.ok then
        return handshake_result
    end

    return flywow_result.success()
end

--- 运行一个已登记 TCP 连接；本协程串行读取和投递，直到 EOF、错误或 Service 停止。
--- connection 由 Gateway 状态表持有并提供 fd；frame 为 2 byte uint16 big-endian 长度头 + Envelope bytes，长度不含头。
--- TCP 模块检查长度头并返回帧体；本函数选择业务握手或 Envelope 处理路径。
--- 读取 Socket 时 yield；投递不等待业务。退出后由 on_accept_client 外层协程统一关闭连接。
---@param connection GatewayConnection Gateway 独占的 TCP 连接。
---@return string 实际退出原因；外层协程负责摘除并关闭连接。
local function run_tcp(connection)
    -- 已 detach 的连接不能再启动读取协程，避免关闭后重新使用 fd。
    if connection.closed then
        return "tcp session ended"
    end

    -- 启动 TCP fd；业务帧长度在读取完整 body 前校验，写队列积压另由 warning 回调处理。
    local fd = connection.fd -- 当前协程操作的连接 fd；由连接记录持有。
    local opened, open_error = socket.start(fd) -- Skynet 原生接口的返回值；成功为原 fd，失败为 nil 和诊断文本。

    if connection.closed then
        return "tcp session ended"
    end

    -- pinned socket.start 成功返回原 fd；运行时失败按连接错误清理，不用 assert 表达。
    if opened ~= fd then
        gateway_common.log_event(
        {
            kind          = "error", -- accepted TCP fd 未能进入 Skynet Socket 管理。
            code          = "TCP_SOCKET_START", -- pinned Socket 未能接管 accepted fd。
            message       = tostring(open_error or opened), -- Skynet 原生返回的失败诊断。
            connection_id = connection.connection_id, -- 标识本次启动失败的逻辑连接。
        }
        )
        return "socket start failed"
    end

    -- Socket 接管 fd 后仅注册写队列告警；帧大小由长度头和业务 Envelope 上限校验。
    socket.warning(fd, function(_, size)
        if size == 0 then
            return
        end

        gateway_common.log_event(
        {
            kind          = "warning",
            code          = "WRITE_BACKPRESSURE",
            message       = "TCP write buffer is large",
            connection_id = connection.connection_id, -- 便于把写缓冲告警与连接日志对应。
        }
        )

        gateway_common.close_connection(module_state, connection, "write backpressure")
    end)

    -- Worker 决定握手或业务阶段，TCP 模块负责读取并验证完整帧。
    while not connection.closed and module_state.phase == "running" do
        local ready = module_state.handshake_module.ready(connection.handshake)
        local expected_size
        if not ready then
            expected_size = module_state.handshake_module.expected_size(connection.handshake)
        end

        local read_result = gateway_tcp.read_frame(connection, gateway_common.MAX_FRAME_BYTES, expected_size, set_read_started) -- 帧读取结果，等待期间由 TCP 回调维护读取期限。
        if not read_result.ok then
            gateway_common.log_event(
            {
                kind          = "error", -- TCP 长度头不符合当前阶段要求。
                code          = read_result.code, -- 保留帧读取返回的稳定错误码。
                message       = read_result.message, -- 记录长度诊断，不包含客户端帧内容。
                connection_id = connection.connection_id, -- 当前帧所属的逻辑连接。
            })
            break
        end

        local payload = read_result.value
        -- read_frame 会等待 Socket 数据；恢复时 stop 可能已结束本 Worker 的运行阶段。
        if not payload or module_state.phase ~= "running" then
            break
        end

        local frame_result
        if ready then
            frame_result = dispatch_payload(connection, payload)
        else
            frame_result = process_handshake(connection, payload)
        end
        if not frame_result.ok then
            break
        end
    end
    return "tcp session ended"
end

--- 将已编码的业务帧写入连接；写入失败时记录原因并关闭连接。
---@param connection GatewayConnection 本 Worker 持有且已经就绪的连接。
---@param encoded string Codec 生成并通过长度检查的 Envelope 字节。
---@return nil 提交写入；失败时关闭连接，关闭可能 yield。
local function write_connection(connection, encoded)
    local write_ok, write_result = gateway_common.write_frame(connection, encoded)
    if not write_ok or write_result == false then
        local reason = write_ok and "transport rejected response" or tostring(write_result)
        skynet.error(
              "GATEWAY_RESPONSE_WRITE_FAILED connection_id=", connection.connection_id,
            " error=", reason
        )
        gateway_common.close_connection(module_state, connection, reason)
    end
end

--- Listener 启动 Worker 时初始化依赖、注册传输回调并启动超时协程。
---@param source integer Listener 的 Service handle，用于归还连接配额。
---@param gateway_config GatewayStartConfig Listener 传入的规范化配置。
---@param epoch string Listener 分配的 Gateway 实例身份。
---@return FlyWowResult<nil> Worker 成功就绪或初始化失败的结果。
function module_handler.on_start(source, gateway_config, epoch)
    -- Listener 已规范化启动配置；此处保存 RPC 收到的本地副本供依赖初始化使用。
    module_state.gateway_config, module_state.epoch = gateway_config, epoch
    module_state.listener_handle = source

    -- 协议和握手依赖就绪后再配置 WebSocket 回调并发布运行状态。
    local start_result = initialize_worker()
    if start_result.ok then
        ws_handler.init(module_state, on_websocket_message, set_read_started)
        module_state.phase = "running"
        skynet.fork(run_timeout_loop)
    else  
        skynet.error(flywow_result.to_string(start_result))
    end

    return start_result
end

--- 响应 Listener 的 accept_client 消息，登记其已分配编号和配额的连接，再启动对应传输。
---@param fd integer Listener 交来的 Socket ID，由本 Worker 接管。
---@param peer string 监听回调提供的对端地址，用于 WebSocket 接入。
---@param connection_id integer Listener 分配的实例内连接编号，用于本地登记和业务消息。
---@return nil 无 RPC 结果；TCP 会话由独立协程推进，WebSocket 接入可能 yield。
function module_handler.on_accept_client(fd, peer, connection_id)
    -- Listener 停止接纳前已投递的 fd 仍归这个 Worker 处理。
    if module_state.phase ~= "running" then
        socket.close_fd(fd)
        skynet.send(module_state.listener_handle, "lua", "connection_released")
        return
    end

    local handshake = module_state.handshake_module.accept() -- 新连接的握手状态及接纳起点。
    ---@type GatewayConnection
    local accepted_connection =
    {
        fd            = fd,                                     -- Listener 交来的 fd，由本 Worker 接管。
        peer          = peer,                                   -- 对端地址，供 WebSocket 接入使用。
        connection_id = connection_id,                          -- Listener 分配的实例内连接编号。
        transport     = module_state.gateway_config.transport,  -- 启动时选定的传输方式。
        handshake     = handshake, -- 本连接独占的握手状态。
        closed        = false,                                  -- 首次摘除连接时置为 true。
        read_started_ms = nil, -- 定长读取或 WebSocket Upgrade 开始时填写。
        last_message_at_ms = nil, -- 握手确认时设初值，之后由完整业务消息刷新。
    }

    module_state.connections[accepted_connection.connection_id] = accepted_connection
    module_state.connections_by_fd[accepted_connection.fd] = accepted_connection
    module_state.connection_count = module_state.connection_count + 1
    
    if accepted_connection.transport == "websocket" then
        -- Upgrade 从接纳开始等待，应用握手总期限同时生效。
        set_read_started(accepted_connection, handshake.started_ms)
        local call_succeeded, accepted_by_websocket, failure = pcall(
            websocket.accept,
            accepted_connection.fd,
            ws_handler,
            "ws",
            accepted_connection.peer
        )

        if not call_succeeded or not accepted_by_websocket then
            gateway_common.log_event(
            {
                kind          = "error", -- 原生 accept 失败事件。
                code          = "WEBSOCKET_ACCEPT", -- 固定分类，区分 Upgrade 与应用握手失败。
                message       = tostring(call_succeeded and failure or accepted_by_websocket), -- pcall 异常或 accept 返回的错误。
                connection_id  = accepted_connection.connection_id, -- 尚有登记时记录逻辑 id，否则记录原生 fd。
            }
            )

            gateway_common.close_connection(module_state, accepted_connection, "websocket accept failed")
            return
        end
    elseif accepted_connection.transport == "tcp" then
        refresh_connection_deadline(accepted_connection)
        -- 捕获 start/read/driver 异常，保证异常退出也释放连接；清理不向业务发送错误响应。
        skynet.fork(function()
            local ok, err = pcall(run_tcp, accepted_connection) -- 捕获 TCP 协程异常，保证后续摘除并关闭连接。
            if not ok then
                gateway_common.log_event(
                {
                    kind          = "error",
                    code          = "TCP_SESSION",
                    message       = tostring(err),
                    connection_id = accepted_connection.connection_id, -- 当前连接的逻辑编号，用于关联诊断。
                }
                )
            end

            -- 正常和异常退出共享关闭所有权；已被超时或 stop 摘除时不重复关闭。
            gateway_common.close_connection(module_state, accepted_connection)
        end)
    else
      --暂不支持其它
    end
end

--- 响应 Handler 的 close 消息，按连接身份执行关闭，关闭传输时可能 yield。
---@param request GatewayCloseRequest Handler 沿用入站消息的实例身份和连接编号。
---@return nil 结束本 Worker 持有的目标连接；旧实例或已结束的连接直接忽略。
function module_handler.on_close(request)
    if module_state.phase ~= "running" or request.gateway_epoch ~= module_state.epoch then
        return
    end

    gateway_common.close_connection(module_state, module_state.connections[request.connection_id])
end

--- 响应 Handler 的 send_data 消息，编码后单播给指定连接或广播给本 Worker 的就绪连接。
---@param message GatewayOutboundMessage 正连接编号用于单播，0 用于本 Worker 内广播。
---@return nil 提交发送；旧实例、无效目标或编码失败时结束，写入失败的关闭可能 yield。
function module_handler.on_send_data(message)
    if module_state.phase ~= "running"
        or message.gateway_epoch ~= module_state.epoch then
        return
    end

    local connection
    if message.connection_id ~= 0 then
        connection = module_state.connections[message.connection_id]
        if not connection or not module_state.handshake_module.ready(connection.handshake) then
            return
        end
    end

    -- 每条消息在本 Worker 编码一次，广播时复用同一份字节。
    local encode_result = module_state.codec_module.encode_response(
        message.command_id,
        module_state.gateway_config.protocol_version,
        message.data
    )
    if not encode_result.ok then
        skynet.error(flywow_result.to_string(encode_result))
        return
    end

    local encoded = encode_result.value
    if #encoded > gateway_common.MAX_FRAME_BYTES then
        skynet.error(
            "GATEWAY_RESPONSE_FRAME_TOO_LARGE connection_id=", message.connection_id
        )
        return
    end

    if connection then
        write_connection(connection, encoded)
        return
    end

    -- 写入失败后的关闭可能 yield；先固定目标，避免等待期间连接索引变化影响遍历。
    local connections = {}
    for _, current_connection in pairs(module_state.connections) do
        if module_state.handshake_module.ready(current_connection.handshake) then
            connections[#connections + 1] = current_connection
        end
    end

    for _, current_connection in ipairs(connections) do
        if module_state.phase ~= "running" then
            return
        end

        -- 前一条连接关闭期间，这个目标也可能已由其他路径关闭。
        if not current_connection.closed then
            write_connection(current_connection, encoded)
        end
    end
end

--- Listener 停机时逐条关闭本 Worker 登记的连接，清理期间拒绝新接入。
---@return FlyWowResult<GatewayStopResult> 返回本次摘除数，任一关闭失败时附上失败数。
function module_handler.on_stop()
    module_state.phase = "stopping"
    local closed_connections = 0 -- 本次 stop 接手摘除并提交关闭的连接数。
    local close_error_count = 0 -- 本次关闭入口抛出的异常数。
    local first_close_error -- 首条关闭诊断，供 Listener 汇总返回。

    -- 底层关闭可能 yield，每次从当前索引取一条，避开已由回调清理的连接。
    while true do
        local _, connection = next(module_state.connections)
        if not connection then
            break
        end

        -- 单个 Socket 关闭异常时继续清理其他连接，并把失败交给 Listener 汇总。
        local close_ok, close_error = pcall(gateway_common.close_connection, module_state, connection, "gateway stopped")
        closed_connections = closed_connections + 1
        if not close_ok then
            close_error_count = close_error_count + 1
            first_close_error = first_close_error or tostring(close_error)
            skynet.error("GATEWAY_CONNECTION_STOP_FAILED connection_id=", connection.connection_id, " error=", tostring(close_error))
        end
    end

    module_state.phase = "stopped"
    if close_error_count > 0 then
        return flywow_result.failure("GATEWAY_STOP_CLOSE_FAILED", first_close_error,
        {
            closed_connections = closed_connections, -- 本次已摘除并提交关闭的连接数。
            close_error_count = close_error_count, -- 底层关闭异常的连接数。
        })
    end

    return flywow_result.success(
    {
        closed_connections = closed_connections, -- 本次已摘除并提交关闭的连接数。
    })
end

skynet.start(function ()
    skynet.dispatch("lua", function(session, source, command, ...) 
        if command == "start" then
            local start_result = module_handler.on_start(source, ...)
            if session ~= 0 then
                skynet.retpack(start_result)
            end
            return
        elseif command == "stop" then
            if module_state.phase == "stopping" then
                if session ~= 0 then
                    skynet.retpack(flywow_result.success(
                    {
                        closed_connections = 0, -- 首次 stop 正在清理，重复请求不取得连接关闭所有权。
                    }))
                end
                return
            end

            local stop_result = module_handler.on_stop() -- 汇总本 Worker 的摘除数和关闭错误后再回复 Listener。
            if session ~= 0 then
                skynet.retpack(stop_result)
            end
            skynet.exit()
            return
        elseif command == "send_data" then
            module_handler.on_send_data(...)
            return
        elseif command == "close" then
            module_handler.on_close(...)
            return
        elseif command == "accept_client" then
            module_handler.on_accept_client(...)
            return
        end

        local failure = flywow_result.failure(
            "GATEWAY_WORKER_COMMAND_UNKNOWN",
            "unknown Gateway Worker command: " .. tostring(command)
        )
        if session ~= 0 then
            skynet.retpack(failure)
        end
    end)
end  
)
