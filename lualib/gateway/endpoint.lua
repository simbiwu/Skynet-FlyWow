--- 职责：为业务 Service 提供薄的异步响应上下文，避免重复拼接网络返回元数据。
--- 边界：FlyWow Runtime Library；只依赖 skynet，不包含 Cluster、协议 codec 或业务路由。
--- 输入/输出：request + 显式 gateway_service/可选 send 函数 -> context:reply(response) / context:close()。
--- 生命周期：上下文由调用方拥有，可保存到业务异步完成；每个上下文最多回复一次。
--- 不负责：不注册 dispatch、不 fork 业务协程、不保存全局请求表、不做超时或业务错误映射。
local skynet = require "skynet"
local M = {}

---@class GatewayEndpointOptions
---@field request GatewayDispatch 已解码的 Gateway request record。
---@field gateway_service ServiceHandle 当前本地 Gateway handle；使用 send 时可省略。
---@field send fun(message: GatewayResponseMessage): any|nil 可选的项目自定义响应投递函数。
---@field close fun(message: GatewayDisconnect): any|nil 可选的项目自定义关闭投递函数。

--- 构造一次请求的响应上下文；只快照路由字段，不保存 request body。
--- options.request 是已解码请求；gateway_service 是当前本地 Gateway handle。
--- options.send/close 可替换本地响应/关闭发送，接收对应 record；其 I/O/yield 与失败合同归项目适配器。
--- 返回调用方独占 context；参数非法抛错，构造不 yield；默认回复是本地 skynet.send，不等待业务结果。
---@param options GatewayEndpointOptions 请求路由和可选响应/关闭投递器。
---@return table 调用方独占的单次 reply/close context；不保存业务 body。
function M.new(options)
    assert(type(options) == "table" and type(options.request) == "table", "endpoint request is required")
    local request = options.request
    assert(type(request.gateway_epoch) == "string" and math.type(request.connection_id) == "integer" and
           math.type(request.command_id) == "integer" and math.type(request.request_id) == "integer",
           "endpoint route metadata is required")
    local gateway = options.gateway_service
    local close = options.close -- 可选项目关闭函数，不由框架选择 Cluster。
    local send = options.send -- 快照返回函数；调用方修改 options 不改变已构造的上下文。
    assert(send ~= nil or (math.type(gateway) == "integer" and gateway > 0), "gateway_service is required")
    assert(send == nil or type(send) == "function", "send must be a function")
    assert(close == nil or type(close) == "function", "close must be a function")
    local route =
    {
        gateway_epoch = request.gateway_epoch, -- Gateway 启动身份；原样返回。
        connection_id = request.connection_id, -- 当前连接身份，不是 fd。
        command_id    = request.command_id, -- registry 定义的响应类型。
        request_id    = request.request_id, -- 客户端请求编号；0 用于主动推送。
    }
    local closing = false -- 只保护本上下文的关闭投递；不是 Gateway 连接状态。
    local replied = false -- 调用方拥有的单次回复保护，不是 Gateway 等待状态。
    local context = {}

    --- 发送本次请求的业务响应；response 为协议定义对应的 table，调用方拥有。
    --- 成功返回 true；关闭投递后返回 false/CONNECTION_CLOSING，重复回复返回 false/DUPLICATE_REPLY；发送失败返回 false/SEND_FAILED，可由调用方决定重试。
    --- 默认 skynet.send 不 yield；自定义 send 可 yield，但保护位在调用前设置，避免并发重复回复。
    ---@param response GatewayResponseMessage|table 当前 command 对应的业务响应。
    ---@return boolean, string|nil 是否成功投递；失败返回稳定错误码。
    function context:reply(response)
        assert(type(response) == "table", "response must be a table")
        if closing then return false, "CONNECTION_CLOSING" end
        if replied then return false, "DUPLICATE_REPLY" end
        replied = true
        local message =
        {
            gateway_epoch = route.gateway_epoch,
            connection_id = route.connection_id,
            command_id    = route.command_id,
            request_id    = route.request_id,
            response      = response,
        }
        local ok, result
        if send then ok, result = pcall(send, message)
        else ok, result = pcall(skynet.send, gateway, "lua", "gateway_response", message) end
        if not ok or result == false or (not send and result == nil) then
            replied = false
            return false, "SEND_FAILED"
        end
        return true
    end
    --- 请求断开该上下文对应的连接；可在 reply 前或后使用，不需要尚在等待的请求。
    --- 无参数；成功 true 仅表示投递成功，实际断开由 gateway_disconnect 通知，重复 false/DUPLICATE_CLOSE。
    --- 自定义响应路径若没有 close 或本地 Gateway handle，返回 false/CLOSE_UNAVAILABLE。
    --- 默认 send 不 yield；自定义 close 可 yield。失败 false/SEND_FAILED，允许调用方显式重试。
    ---@return boolean, string|nil 是否成功投递关闭请求；失败返回稳定错误码。
    function context:close()
        if closing then return false, "DUPLICATE_CLOSE" end
        if not close and not (math.type(gateway) == "integer" and gateway > 0) then
            return false, "CLOSE_UNAVAILABLE"
        end
        closing = true
        local message =
        {
            gateway_epoch = route.gateway_epoch, -- 原始 Gateway 实例身份；不使用 fd。
            connection_id = route.connection_id, -- 要关闭的当前连接编号。
        }
        local ok, result
        if close then
            ok, result = pcall(close, message)
        else
            ok, result = pcall(skynet.send, gateway, "lua", "gateway_close", message)
        end
        if not ok or result == false or (not close and result == nil) then
            closing = false
            return false, "SEND_FAILED"
        end
        return true
    end
    return context
end

return M
