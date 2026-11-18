--- Gateway 的 Listener Service。接收宿主的启动配置，创建 Worker 池并持有监听 fd。
--- 所有 Worker 初始化成功后才开始监听；停止时先关闭监听 fd，再通知 Worker 退出。
local skynet = require "skynet"
local flywow_result = require "flywow_result"
local flywow_common = require "flywow_common"
local gateway_common = require "flywow_gateway_common"
local gateway_config = require "flywow_gateway_config"
local socket = require "skynet.socket"
local websocket = require "http.websocket"

local module_state =
{
    phase              = "created",  -- Service 生命周期；created/starting/running/stopping/stopped。
    gateway_config     = nil,        -- 通过 start 校验后的只读配置；由 start 一次写入，后续运行阶段读取。
    listen_fd          = nil,        -- 监听 Socket fd；关闭后清空。
    next_connection_id = 0,          -- 单调递增连接标识；不复用为业务持久 ID。
    epoch              = nil,        -- 每次 Service 启动的新身份，隔离旧进程迟到响应。
    connection_count   = 0,          -- 当前登记的连接数，包含握手中连接；用于 O(1) 判断 max_clients。
    gateway_workers    = {}          -- 已就绪的 Worker handle；start 完成监听后交付，stop 取出并清空。
}

local module_handler = {}

--- 停止调用方交给本函数清理的 Worker；等待停止 RPC 时可能 yield。
---@param workers integer[] 待停止的 Worker handle，按创建顺序排列。
---@return FlyWowResult<GatewayStopResult> 汇总各 Worker 的摘除数，失败时同时返回关闭错误数。
local function stop_workers(workers)
    local closed_connections = 0 -- 各 Worker 在本次停机中摘除并提交关闭的连接总数。
    local error_count = 0 -- 统计连接关闭异常，以及无法取得停止 RPC 结果的 Worker。
    local first_error -- 首条错误诊断，供宿主排查。

    for worker_index = #workers, 1, -1 do
        local worker_handle = workers[worker_index] -- 本次等待完成清理的 Worker。
        local call_ok, stop_result = pcall(skynet.call, worker_handle, "lua", "stop") -- 停止回复或 RPC 异常。
        local worker_error -- 当前 Worker 的 RPC 异常或关闭错误摘要。

        if not call_ok then
            error_count = error_count + 1
            worker_error = tostring(stop_result)
        elseif not stop_result.ok then
            closed_connections = closed_connections + stop_result.details.closed_connections
            error_count = error_count + stop_result.details.close_error_count
            worker_error = stop_result.message
        else
            closed_connections = closed_connections + stop_result.value.closed_connections
        end

        -- 每个失败都记录索引和 handle，返回结果保留失败总数和首条诊断。
        if worker_error then
            first_error = first_error or worker_error

            skynet.error(
                "GATEWAY_WORKER_STOP_FAILED worker_index=", worker_index,
                " worker_handle=", worker_handle,
                " error=", worker_error
            )
        end
    end

    if error_count > 0 then
        return flywow_result.failure(
            "GATEWAY_STOP_CLOSE_FAILED",
            first_error,
            {
                closed_connections = closed_connections, -- 有回复的 Worker 已摘除并提交关闭的总数。
                close_error_count = error_count, -- 连接关闭异常和停止 RPC 异常的合计。
            }
        )
    end

    return flywow_result.success(
    {
        closed_connections = closed_connections, -- 所有 Worker 已摘除并提交关闭的总数。
    })
end

--- 为 accepted fd 分配连接编号和全局配额，再异步交给所属 Worker。
---@param fd integer Skynet 监听回调传入的连接 fd，尚未由 Lua Socket 层接管。
---@param peer string Skynet 提供的对端地址，供 Worker 接入传输时使用。
---@return nil 允许接入时由 Worker 接管 fd；阶段、配额或连接编号检查拒绝时由 Listener 关闭。
local function on_accept(fd, peer)
    if module_state.phase ~= "running"
        or module_state.connection_count >= module_state.gateway_config.max_clients
        or module_state.next_connection_id == math.maxinteger then
        socket.close_fd(fd)
        return
    end

    local worker_index = fd % module_state.gateway_config.worker_count + 1
    local worker_handle = module_state.gateway_workers[worker_index]

    -- 连接编号由 Listener 分配，所有 Worker 使用同一套编号。
    module_state.next_connection_id = module_state.next_connection_id + 1
    local connection_id = module_state.next_connection_id

    -- 投递前占用配额，等待 Worker 接管的连接也计入全局上限。
    module_state.connection_count = module_state.connection_count + 1
    skynet.send(worker_handle, "lua", "accept_client", fd, peer, connection_id)
   
end

--- 响应广播消息，将同一条业务消息异步转发给本 Gateway 的所有 Worker。
---@param message GatewayOutboundMessage Handler 提交的广播，connection_id 为 0。
---@return nil 提交转发；实例已停止或消息属于旧实例时结束。
function module_handler.on_send_data(message)
    if module_state.phase ~= "running" or message.gateway_epoch ~= module_state.epoch then
        return
    end

     -- 定向消息由持有连接的 Worker 处理，Listener 只接收全局广播。
     if message.connection_id ~= 0 then
        return
     end

     for _, worker_handle in ipairs(module_state.gateway_workers) do
        skynet.send(worker_handle, "lua", "send_data", message)
     end

end

--- 校验宿主配置，逐个创建并初始化 Worker，再绑定和启动监听 Socket。
--- 仅 created 状态可启动；创建 Service、等待 Worker RPC 和启动监听均可能 yield。
---@param startup_config GatewayStartConfig 宿主提交的启动配置；Listener 使用监听地址和 Worker 数，Worker 使用同一份规范化配置初始化依赖。
---@return FlyWowResult<GatewayStartResult> 成功时返回实际监听信息；失败时回收本次创建的 Worker 并返回启动错误。
function module_handler.on_start(startup_config)
    if module_state.phase ~= "created" then
        return flywow_result.failure("GATEWAY_START_STATE_INVALID", "gateway can only start once")
    end

    -- 在创建 Worker 或绑定端口前校验宿主配置。
    local config_result = gateway_config.normalize_config(startup_config) -- 宿主配置的完整校验结果。
    if not config_result.ok then
        return config_result
    end

    local gateway_config = config_result.value -- 已验证副本；后续不再读取宿主可变 table。

    -- 在首次创建 Worker 前进入 starting，等待期间收到的重复 start 会被拒绝。
    module_state.gateway_config = gateway_config
    module_state.epoch = tostring(skynet.self()) .. ":" .. tostring(skynet.hpc())
    module_state.phase = "starting"

    local workers = {} -- 本次启动创建的 Worker；监听就绪前由 start 负责回收。

    --- 回收本次启动创建的 Worker，并将原失败结果交给宿主。清理可能 yield。
    ---@param failure FlyWowResult<nil> 导致本次启动失败的结果。
    ---@return FlyWowResult<nil> 原失败结果。
    local function fail_start(failure)
        stop_workers(workers)

        -- 若 stop 已接手生命周期，由它更新最终阶段。
        if module_state.phase == "starting" then
         module_state.phase = "stopped"
        end
        return failure
    end

    for worker_index = 1 , gateway_config.worker_count do
        local create_ok, worker_handle = pcall(skynet.newservice, "flywow_gateway_worker")
        if not create_ok  then
            return fail_start(flywow_result.failure(
                 "GATEWAY_WORKER_CREATE_FAILED",
                tostring(worker_handle),
                { worker_index = worker_index } -- 标识启动循环中失败的 Worker。
            ))
        end
        -- 先保存 handle，Worker 初始化失败时也能通知这个 Service 退出。
        workers[worker_index] = worker_handle
        local call_ok, start_result = pcall(skynet.call, worker_handle, "lua", "start", gateway_config, module_state.epoch)
        
        if not call_ok then
            return fail_start(flywow_result.failure(
                "GATEWAY_WORKER_START_FAILED",
                tostring(start_result),
                { worker_index = worker_index } -- 标识启动循环中失败的 Worker。
            ))
        end
        if not start_result.ok then
            return fail_start(start_result)
        end
    end
   
    -- 所有 Worker 就绪后才绑定端口；绑定抛错时回收本次创建的 Worker。
    local listen_ok, listen_fd, address, port = pcall( -- 绑定结果或原生异常；失败时保留诊断而不泄漏异常合同。
        socket.listen,
        gateway_config.host,
        gateway_config.port
    )
    if not listen_ok then
        return fail_start(flywow_result.failure("GATEWAY_LISTEN_FAILED", tostring(listen_fd)))
    end

    -- listener 创建可能 yield；如果 stop 已改变阶段，释放本协程仍拥有的 fd。
    if module_state.phase ~= "starting" then
        pcall(socket.close, listen_fd)
         return fail_start(flywow_result.failure(
        "GATEWAY_START_INTERRUPTED",
        "gateway stopped while binding"
    ))
    end

    -- bind 完成后把 fd 所有权交给 Service 状态，供 stop 与启动失败路径清理。
    module_state.listen_fd = listen_fd

    -- 启动监听失败时，只有仍持有监听 fd 的路径才负责关闭它。
    local start_ok, started_fd, start_error = pcall( -- 驱动启动状态、成功 fd 或错误值。
        socket.start,
        listen_fd,
        on_accept
    )
    if not start_ok or started_fd ~= listen_fd then
        if module_state.listen_fd == listen_fd then
            module_state.listen_fd = nil
            pcall(socket.close, listen_fd)
        end

        local failure = start_ok and start_error or started_fd
        return fail_start(flywow_result.failure("GATEWAY_LISTENER_START_FAILED", tostring(failure)))
    end

    -- socket.start 也可能 yield；只有本协程仍拥有 listener 且阶段未变化时才能发布 ready。
    if module_state.phase ~= "starting" then
        if module_state.listen_fd == listen_fd then
            module_state.listen_fd = nil
            pcall(socket.close, listen_fd)
        end
        return fail_start(flywow_result.failure(
        "GATEWAY_START_INTERRUPTED",
        "gateway stopped while starting listener"
    ))
    end

    -- 监听就绪后交付 Worker 池，后续由 stop 统一回收。
    module_state.gateway_workers = workers
    module_state.phase = "running"
    skynet.error(
        "FLYWOW_GATEWAY_READY transport=",
        gateway_config.transport,
        " address=",
        address,
        ":",
        port)

    return flywow_result.success(
        {
            address       = address, -- Socket Driver 实际绑定的监听地址。
            port          = port, -- Socket Driver 实际绑定的端口。
            transport     = gateway_config.transport, -- 启动配置选择的 TCP 或 WebSocket。
        }
    )
end

--- 幂等地停止监听并关闭所有 Gateway 拥有的连接。
--- 首个调用负责清理；stopping/stopped 时重复调用直接返回零，不表示首次清理已经完成。
--- 关闭监听和等待 Worker 清理可能 yield。连接关闭由各 Worker 执行。
---@return FlyWowResult<GatewayStopResult> 首次调用返回清理结果；重复调用立即成功且关闭数为零。
function module_handler.on_stop()
    -- 已停止或正在停止的实例直接返回，避免重复清理；不等待首次调用。
    if module_state.phase == "stopping" or module_state.phase == "stopped" then
        return flywow_result.success(
            {
                closed_connections = 0, -- 本次重复调用不拥有清理责任，因此计数为零。
            }
        )
    end

    -- 首次调用独占清理；重复调用立即返回，不等待其完成。
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

    -- 等待 Worker 的停止回复前先取出池；关闭失败计入宿主收到的停止结果。
    local workers = module_state.gateway_workers
    module_state.gateway_workers = {}
    local worker_stop_result = stop_workers(workers) -- 本轮 Worker 清理汇总，包含摘除数及可能的异常。
    local detached_count -- 各 Worker 本次摘除的连接总数，失败结果也携带已清理数量。
    if worker_stop_result.ok then
        detached_count = worker_stop_result.value.closed_connections
    else
        detached_count = worker_stop_result.details.closed_connections
        close_error_count = close_error_count + worker_stop_result.details.close_error_count
        first_close_error = first_close_error or worker_stop_result.message
    end
    
   
    -- 停止阶段会尽力关闭全部 fd；底层任一关闭失败都通过单一稳定错误返回。
    module_state.phase = "stopped"
    if close_error_count > 0 then
        return flywow_result.failure(
            "GATEWAY_STOP_CLOSE_FAILED",
            first_close_error,
            { close_error_count = close_error_count, closed_connections = detached_count }
        )
    else
        return flywow_result.success(
            {
                closed_connections = detached_count, -- 本次首次摘除并提交关闭的连接总数。
            }
        )
    end

end


--- Worker 归还配额时更新 Listener 持有的接纳计数。
---@return nil 同步递减已占用的连接配额。
function module_handler.on_connection_released()
    module_state.connection_count = module_state.connection_count - 1
end

skynet.start(function()
    --- 服务命令合同：start 接收 GatewayStartConfig，send_data 接收出站消息 record，stop 不接收参数。
    skynet.dispatch("lua", function(session, _source, command, argument)
        if command == "send_data" then
            module_handler.on_send_data(argument)
            return
        end

        if command == "start" then
            local start_result = module_handler.on_start(argument) -- 本次启动的稳定结果，包含监听信息或错误码。
            if session ~= 0 then
                skynet.retpack(start_result)
            elseif not start_result.ok then
                skynet.error("GATEWAY_START_FAILED ", start_result.code, " ", start_result.message)
            end
            return
        end

        if command == "connection_released" then
            module_handler.on_connection_released()
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

            local stop_result = module_handler.on_stop() -- 本次关闭的连接数或底层资源释放失败。
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
