local skynet = require "skynet"
local socket = require "skynet.socket"
local gateway_tcp = require "flywow_gateway_tcp"
local websocket = require "http.websocket"

-- WebSocket Close 帧状态码见 RFC 6455 §7.4.1 和 IANA WebSocket Close Code Registry。
local WEBSOCKET_GOING_AWAY = 1001
local M = {}
M.MAX_FRAME_BYTES = 0xffff -- TCP uint16 长度头决定的业务 Envelope 上限；TCP/WS


--- 把连接、协议和传输边界事件写入 Skynet 日志；不向其它 Service 转发诊断消息。
--- event 只含诊断文本和连接编号，不包含业务 payload；日志输出不 yield。
---@param event GatewayEvent 本次事件的只读记录；日志写入后不保留。
---@return nil 写入 Skynet 日志。
function M.log_event(event)
    skynet.error("FLYWOW_GATEWAY_" .. string.upper(event.kind),
                 " connection_id=", tostring(event.connection_id or "-"),
                 " code=", tostring(event.code or "-"),
                 " message=", tostring(event.message or "-"))
end

--- 从连接表中移除连接并发出一次 close 事件；重复调用不会重复递减计数。
--- connection 是本 Gateway 状态表中的 context，reason 是不含敏感数据的诊断原因。
--- 设置 closed 后同步摘除堆项和索引，归还配额并通知业务断开。本函数不 yield。
--- 返回首次 detach 为 true，nil 或重复关闭为 false。
--- 供主动关闭流程与 Skynet WebSocket 结束回调复用；由 Skynet 收尾的回调在此归还配额。
---@param module_state table 持有连接索引、超时堆、握手模块和通知目标的 Worker 状态。
---@param connection GatewayConnection|nil Gateway 连接上下文。
---@param reason string|nil 不含敏感数据的关闭原因。
---@return boolean 是否首次摘除连接。
function M.detach_connection(module_state, connection, reason)
    if connection == nil or connection.closed then
        return false
    end

    -- 在底层关闭之前移除超时项、释放握手资源并摘除连接索引。
    connection.closed = true
    module_state.timeout_heap:remove(connection)
    module_state.handshake_module.close(connection.handshake)
    module_state.connections[connection.connection_id] = nil
    module_state.connections_by_fd[connection.fd] = nil
    module_state.connection_count = module_state.connection_count - 1

    skynet.send(module_state.listener_handle, "lua", "connection_released")

    -- 连接身份已从 Gateway 索引移除后通知 handler，避免它继续把数据关联到已关闭连接。
    skynet.send(module_state.gateway_config.handler_service, "lua", "gateway_disconnect",
    {
        gateway_epoch = module_state.epoch, -- handler 用实例身份忽略旧 Gateway 的迟到清理。
        connection_id = connection.connection_id, -- 与此前 send_data 使用同一个逻辑连接编号。
    }
    )

    -- 日志只记录关闭原因和逻辑连接编号，不携带对端地址或业务 payload。
    M.log_event(
        {
            kind          = "close", -- 连接生命周期结束事件。
            connection_id = connection.connection_id, -- 对应 handler 收到的断开通知。
            message       = reason or "closed", -- 关闭来源只用于诊断。
        }
    )
    return true
end

--- Gateway 主动结束连接的入口。首次摘除时归还配额，再按传输方式关闭 Socket，关闭可能 yield。
---@param module_state table Worker 持有的状态，用于摘除连接和检查 fd 的当前归属。
---@param connection GatewayConnection|nil Worker 登记的连接，已摘除时直接返回。
---@param reason? string 可选的关闭日志说明。
---@return nil 完成关闭或连接已摘除。
function M.close_connection(module_state, connection, reason)
    if not M.detach_connection(module_state, connection, reason) then
        return
    end

    -- close 可能 yield；若 fd 已被新连接复用，旧上下文不能再关闭这个 fd。
    local current_connection = module_state.connections_by_fd[connection.fd] -- 当前占用 fd 的连接，用于阻止旧上下文关闭复用后的 fd。
    if current_connection and current_connection ~= connection then
        return
    end

    -- 按连接接管状态选择 WebSocket close、已登记 Socket close 或未登记 fd 的 close_fd。
    if connection.transport == "websocket" and not websocket.is_close(connection.fd) then
        websocket.close(connection.fd, WEBSOCKET_GOING_AWAY, "closed")
    elseif socket.invalid(connection.fd) then
        socket.close_fd(connection.fd)
    else
        socket.close(connection.fd)
    end
end

--- 按连接的传输类型提交完整帧；TCP 模块添加长度头，WebSocket 使用二进制消息。
---@param connection GatewayConnection Worker 持有的连接，本函数读取 transport 和 fd。
---@param bytes string 完整握手消息或业务 Envelope 字节。
---@return boolean call_succeeded 底层写入是否正常返回。
---@return any write_result_or_error 原生返回值或异常诊断；false 表示写入被拒绝。
function M.write_frame(connection, bytes)
    if connection.transport == "tcp" then
        return gateway_tcp.write_frame(connection, bytes)
    end

    return pcall(websocket.write, connection.fd, bytes, "binary")
end
return M
