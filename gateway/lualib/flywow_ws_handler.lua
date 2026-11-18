local gateway_common = require "flywow_gateway_common"

local M = {}
local module_state =
{
    worker_state = nil, -- 当前 Worker 的状态引用，供回调定位和关闭连接。
    message_handler = nil, -- Worker 登记的应用帧处理回调。
    read_deadline_handler = nil, -- Worker 登记的读取期限回调。
}

--- Worker 启动时登记状态引用和消息回调，供 Skynet 的 WebSocket 回调使用。
---@param state table Worker 的运行状态；传输回调读取 phase、按 fd 查找连接，并用它清理连接。
---@param message_handler fun(connection: GatewayConnection, payload: string): FlyWowResult<nil> Worker 提供的握手和业务消息处理入口。
---@param read_deadline_handler fun(connection: GatewayConnection, read_started_ms: integer|nil) Worker 提供的读取期限更新入口。
---@return nil 保存引用，供当前 Worker 的 WebSocket 会话复用。
function M.init(state, message_handler, read_deadline_handler)
    module_state.worker_state = state
    module_state.message_handler = message_handler
    module_state.read_deadline_handler = read_deadline_handler
end

--- 处理已由 Skynet 完成拼帧的 WebSocket message；底层库负责 Upgrade、mask、fragment 与 ping/pong。
--- id 是 Skynet connection id，payload 是单条完整消息 bytes，opcode 标识文本或 binary；payload 不跨回调保存。
--- 只交付 binary 消息，Worker 拒绝消息时关闭当前连接。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@param payload string 一条完整 WebSocket 消息的字节内容。
---@param opcode string 底层解析出的 text/binary 消息类型。
---@return nil 无业务返回值；不支持的消息或协议失败时关闭该连接。
function M.message(id, payload, opcode)
    if module_state.worker_state.phase ~= "running" then
        return
    end

    -- 仅从活动索引取得来源连接；停止阶段已在入口拒绝消息。
    local connection = module_state.worker_state.connections_by_fd[id] -- 当前 WebSocket 回调对应的连接；关闭或迟到回调时可能不存在。
    if not connection then
        return
    end

    -- 先拒绝 WebSocket text；协议只定义 binary message 与握手/Envelope 字节。
    if opcode ~= "binary" then
        gateway_common.log_event(
        {
            kind          = "error",
            code          = "TEXT_MESSAGE_REJECTED",
            message       = "only binary WebSocket messages are accepted", -- 客户端使用了未支持的文本帧。
            connection_id = connection.connection_id, -- 当前连接的逻辑编号，用于关联诊断。
        }
        )
       gateway_common.close_connection(module_state.worker_state, connection, "binary messages required")
        return
    end

    -- Skynet 已交付完整 binary 消息；由 Worker 解释消息并返回是否接受。
    local frame_result = module_state.message_handler(connection, payload)

    -- 当前握手或业务帧失败后关闭连接，成功帧保持可读写。
    if not frame_result.ok then
        gateway_common.close_connection(module_state.worker_state, connection, "gateway request rejected")
    end
end

--- Skynet 完成 HTTP Upgrade 后结束读取计时；应用握手的绝对期限仍从 accept 登记连接起算。
--- id 对应 accept 登记的连接；header/url 由底层拥有且本函数不保存。
--- 同步更新 Worker 超时堆，不跨 Service 调用或 yield。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@param header table HTTP Upgrade 请求头；只读且不保存。
---@param url string 客户端请求路径；只读且不保存。
---@return nil 清除 Upgrade 读取期限，保留应用握手的接纳起点。
function M.handshake(id, header, url)
    local connection = module_state.worker_state.connections_by_fd[id] -- 当前 WebSocket 回调对应的连接；关闭或迟到回调时可能不存在。
    if not connection then
        return
    end

    -- 只结束 Upgrade 读取期限，应用握手仍从接入时记录的 started_ms 起算。
    module_state.read_deadline_handler(connection, nil)
end

--- 底层 WebSocket 关闭时摘除 Gateway 连接，移除其期限并归还配额。
--- id 是 Skynet WebSocket connection id；迟到或重复回调由 detach 的幂等性处理。无返回值，不执行 I/O/yield。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@return nil 从 Gateway 连接索引摘除连接；重复回调不重复处理。
function M.close(id)
    gateway_common.detach_connection(module_state.worker_state, module_state.worker_state.connections_by_fd[id], "websocket closed")
end

--- 将 WebSocket 底层传输错误转为统一 Gateway error 事件并摘除连接。
--- id 是 Skynet connection id，message 是底层诊断文本；不包含业务 payload。无返回值，只修改本 Service 的连接索引。
---@param id integer Skynet 分配的 WebSocket 连接编号。
---@param message string Skynet 提供的传输错误文本；不含业务消息。
---@return nil 记录错误并摘除连接。
function M.error(id, message)
    local connection = module_state.worker_state.connections_by_fd[id] -- 当前 WebSocket 回调对应的连接；关闭或迟到回调时可能不存在。

    gateway_common.log_event(
    {
        kind          = "error",
        code          = "WEBSOCKET_ERROR",
        message       = tostring(message),
        connection_id = connection and connection.connection_id or id, -- 当前连接的逻辑编号，用于关联诊断。
    }
    )

    gateway_common.detach_connection(module_state.worker_state, connection, "websocket error")
end

--- 处理 Skynet WebSocket 写队列告警；size 单位是 KB，清空通知为 0 并直接忽略。
--- 非零告警记录并关闭该连接；0 为缓冲恢复通知，直接忽略。无返回值。
---@param ws_object table Skynet WebSocket 对象；id 用于找到 Gateway 连接。
---@param size integer Skynet write buffer 告警大小，单位 KB；0 表示发送缓冲已清空并被忽略。
---@return nil 记录非零缓冲告警；收到非零积压告警即关闭连接。
function M.warning(ws_object, size)
    if size == 0 then
        return
    end

    -- 恢复通知不属于积压事件；非零回调才查找仍登记的连接并记录告警。
    local connection = module_state.worker_state.connections_by_fd[ws_object.id] -- warning 所属的 Gateway 连接；已摘除时忽略。
    if connection then
        gateway_common.log_event(
        {
            kind          = "warning", -- 当前连接的本地写队列过大。
            code          = "WRITE_BACKPRESSURE", -- 触发 Gateway 写缓冲上限的稳定诊断类别。
            message       = "WebSocket write buffer is large", -- 说明该事件来自 WebSocket 写队列。
            connection_id = connection.connection_id, -- 便于从日志定位连接生命周期。
        }
        )

        gateway_common.close_connection(module_state.worker_state, connection, "server backpressure")
    end
end

return M
