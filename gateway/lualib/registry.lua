--- 职责：校验构建期生成的 Gateway registry，并提供只读 command 查询。
--- 边界：Gateway Runtime Library；不读取 .proto、不执行 I/O、不调用业务 Service。
--- 输入/输出：生成 registry table -> FlyWowResult<索引>；查找未知 command 时返回 nil。
--- 生命周期：Gateway 启动时构建一次，校验失败由 start 入口转换为 Skynet RPC 启动错误。
--- 不负责：不决定 command 的业务归属，也不编码或解码 Protobuf。
local flywow_result = require "flywow_result"

local M = {}

--- 检查生成文件提供的 command id 是否符合 Protobuf uint32 的非零命令范围。
---@param command_id integer 生成 registry 的 command key；后续作为 Envelope.command 路由键。
---@return FlyWowResult<nil> 合法时为 success；非整数或超出 1..0xffffffff 时返回 GATEWAY_REGISTRY_INVALID。
local function validate_command_id(command_id)
    if type(command_id) ~= "number" or command_id % 1 ~= 0 or
        command_id < 1 or command_id > 0xffffffff then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_INVALID",
            "command id must be an integer in [1, 0xffffffff]",
            { command_id = command_id }
        )
    end

    return flywow_result.success()
end

--- 校验构建期生成的 registry 并建立 Gateway 私有索引。
--- definitions.envelope_type 是 Envelope 全名；commands 按命令号索引，并含 name/request_type/可选 response_type。
---@param definitions table 协议构建工具生成的只读 registry；本函数复制需要的字段。
---@return FlyWowResult<table> 成功 value 为独立只读索引；结构无效时返回 GATEWAY_REGISTRY_INVALID。
function M.build_index(definitions)
    if type(definitions) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_INVALID",
            "gateway registry must be a table"
        )
    end
    if type(definitions.envelope_type) ~= "string" or definitions.envelope_type == "" then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_INVALID",
            "gateway registry envelope_type is required"
        )
    end
    if type(definitions.commands) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_INVALID",
            "gateway registry commands are required"
        )
    end

    -- 逐项验证生成定义后建立独立索引；不修改构建产物。
    local by_id = {} -- command id 到只读协议定义的索引，供解码和路由查询。
    local count = 0  -- 已登记 command 数量；构建结束时用于拒绝空 registry。
    for command_id, definition in pairs(definitions.commands) do -- 命令号与生成器提供的类型定义，逐项校验后复制。
        local command_id_result = validate_command_id(command_id)
        if not command_id_result.ok then
            return command_id_result
        end
        if type(definition) ~= "table" then
            return flywow_result.failure(
                "GATEWAY_REGISTRY_INVALID",
                "gateway command definition must be a table",
                { command_id = command_id }
            )
        end
        if type(definition.name) ~= "string" or definition.name == "" then
            return flywow_result.failure(
                "GATEWAY_REGISTRY_INVALID",
                "gateway command name is required",
                { command_id = command_id }
            )
        end
        if definition.request_type ~= nil and
            (type(definition.request_type) ~= "string" or definition.request_type == "") then
            return flywow_result.failure(
                "GATEWAY_REGISTRY_INVALID",
                "gateway request_type must be a non-empty string",
                { command_id = command_id, name = definition.name }
            )
        end
        if definition.response_type ~= nil and
            (type(definition.response_type) ~= "string" or definition.response_type == "") then
            return flywow_result.failure(
                "GATEWAY_REGISTRY_INVALID",
                "gateway response_type must be a non-empty string",
                { command_id = command_id, name = definition.name }
            )
        end

        by_id[command_id] =
        {
            id              = command_id, -- 用于 Envelope 路由的唯一命令号。
            name            = definition.name, -- 生成工具保留的命令名称，供错误诊断使用。
            request_type    = definition.request_type, -- 入站解码类型；nil 表示仅允许服务端下发。
            response_type   = definition.response_type, -- 出站编码类型；nil 表示单向客户端请求。
        }
        count = count + 1
    end

    if count == 0 then
        return flywow_result.failure(
            "GATEWAY_REGISTRY_INVALID",
            "gateway registry must contain at least one command"
        )
    end

    return flywow_result.success(
    {
        envelope_type = definitions.envelope_type, -- codec 共用的完整 Envelope Protobuf 类型名。
        by_id         = by_id, -- Gateway 按入站或出站命令号查询的独立索引。
        count         = count, -- 启动时报告的有效命令数量。
    })
end

--- 根据 Envelope 中的 uint32 command 查找 request/response 类型定义。
---@param registry table M.build_index 返回且由 Gateway 持有的只读索引。
---@param command_id integer Envelope 中的 command id；未知 id 是正常查询结果。
---@return table|nil 对应 command 定义；registry 不含该 id 时返回 nil。
function M.find_command(registry, command_id)
    return registry.by_id[command_id]
end

return M
