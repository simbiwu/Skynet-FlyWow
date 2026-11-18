--- Gateway TCP 字节收发。使用 Worker 持有的连接记录，读写两字节大端长度头的帧。
local flywow_common = require "flywow_common"
local socket = require "skynet.socket"
local flywow_result = require "flywow_result"

local M = {}

--- 等待指定数量的 TCP 字节，并维护当前读取的起始时间。
---@param connection GatewayConnection Worker 持有的 TCP 连接，本函数读取 fd。
---@param size integer 本次需要读取的字节数，由 Worker 当前的帧处理阶段决定。
---@param set_read_started fun(connection: GatewayConnection, read_started_ms: integer|nil) Worker 提供的读取期限更新入口。
---@return string|nil 完整字节；EOF 或等待期间连接已关闭时返回 nil。Socket 读取可能 yield。
local function read_exact(connection, size, set_read_started)
    set_read_started(connection, flywow_common.now_ms())
    local received_bytes = socket.read(connection.fd, size) -- 本次定长读取的完整字节，断开时可能返回 false。

    -- 超时或 stop 可能在读取期间摘除连接，恢复后不能重新登记期限。
    if connection.closed then
        return nil
    end
    set_read_started(connection, nil)
    return received_bytes or nil
end

--- 读取完整 TCP 帧；先检查长度头，再按已接受的长度等待帧体。读取可能 yield。
---@param connection GatewayConnection Worker 持有的 TCP 连接，提供 fd 和读取恢复时的关闭状态。
---@param max_frame_bytes integer Gateway 允许的最大帧体字节数，由现有公共帧长上限提供。
---@param expected_size? integer Worker 在握手阶段给出的固定帧体长度；业务阶段省略。
---@param set_read_started fun(connection: GatewayConnection, read_started_ms: integer|nil) Worker 提供的期限更新入口，帧头和帧体分别计时。
---@return FlyWowResult<string|nil> 成功 value 为帧体；EOF 或连接已关闭时成功 value 为 nil；非法长度返回 FRAME_LIMIT。
function M.read_frame(connection, max_frame_bytes, expected_size, set_read_started)
    local header = read_exact(connection, 2, set_read_started)
    if not header then
        return flywow_result.success()
    end

    -- >I2 按网络大端序读取两字节无符号长度，长度不含头部自身。
    -- 握手期必须匹配当前阶段的固定长度，检查在读取帧体前完成。
    local size = string.unpack(">I2", header)
    if size < 1 or size > max_frame_bytes or (expected_size and size ~= expected_size) then
        return flywow_result.failure("FRAME_LIMIT", "invalid TCP frame length")
    end

    return flywow_result.success(read_exact(connection, size, set_read_started))
end

--- 添加 TCP 长度头并提交写入，沿用 Socket 写入的返回约定。
---@param connection GatewayConnection Worker 持有的 TCP 连接，本函数读取 fd。
---@param bytes string 已由调用方检查长度的完整帧体。
---@return boolean call_succeeded 底层写入是否正常返回。
---@return any write_result_or_error 原生返回值或异常诊断；false 表示写入被拒绝。
function M.write_frame(connection, bytes)
    return pcall(socket.write, connection.fd, string.pack(">I2", #bytes) .. bytes)
end

return M
