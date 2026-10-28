--- 职责：校验并索引构建阶段生成的 FlyWow Gateway 协议 registry。
--- 边界：FlyWow Gateway Contract；不读取 .proto、不执行 I/O、不持有业务 handler。
--- 输入/输出：生成 registry table -> 按 numeric command 查询的只读索引。
--- 生命周期：Gateway Service 启动时加载一次；校验成功后不再修改。
--- 不负责：不决定 command 的业务归属、不调用 Service、不编码或解码 Protobuf。
local M = {}

--- 校验一个来自生成文件的 Envelope command id。
--- 执行边界：只读；不执行 I/O、yield 或分配资源。
--- 失败行为：不是 1..0xffffffff 的整数时抛出异常。
---@param value integer Protobuf uint32 command id。
---@return nil 成功时无返回值；非法值直接抛出异常。
local function assert_command_id(value)
    assert(type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 0xffffffff,
           "gateway command id must be an integer in [1, 0xffffffff]")
end

--- 校验构建期生成的 registry 并建立索引；拒绝缺失类型名和非法 Envelope 配置。
--- definitions.envelope_type 是完整 Protobuf 类型名；commands 以 uint32 command id 为键，值含 name/request_type/可选 response_type；输入归调用方且只读。
--- request_type/response_type 可分别为空；两者都存在是请求-响应，只有 request_type 是单向请求，只有 response_type 是主动下发。
--- 返回独立索引，调用方拥有并应视为只读；空 commands、字段缺失或格式错误时抛异常。
--- commands 以命令号为唯一键；源协议的重复命令号由生成工具拒绝，运行时不重复检查。
--- 仅分配与 command 数量成正比的 Lua table；不执行 I/O、yield 或外部资源分配。
---@param definitions table 构建阶段生成的 registry；调用方拥有且只读。
---@return table 经过校验的只读 numeric command 索引；函数分配与 command 数量成正比的 table。
function M.build_index(definitions)
    assert(type(definitions) == "table", "gateway registry must be a table")
    assert(type(definitions.envelope_type) == "string" and definitions.envelope_type ~= "",
           "gateway registry envelope_type is required")
    assert(type(definitions.commands) == "table", "gateway registry commands are required")

    -- 校验每项定义后建立独立索引，不修改构建产物。
    local by_id = {} -- command id 到只读协议定义的索引，供解码和路由查询。
    local count = 0  -- 已登记 command 数量；构建结束时用于拒绝空 registry。
    for command_id, definition in pairs(definitions.commands) do -- 命令号与生成器提供的类型定义，逐项校验后复制。
        assert_command_id(command_id)
        assert(type(definition) == "table", "gateway command definition must be a table")
        assert(type(definition.name) == "string" and definition.name ~= "",
               "gateway command name is required")
        if definition.request_type ~= nil then
            assert(type(definition.request_type) == "string" and
                definition.request_type ~= "",
                "gateway request_type must be a non-empty string for " .. definition.name)
        end
        if definition.response_type ~= nil then
            assert(type(definition.response_type) == "string" and definition.response_type ~= "",
                   "gateway response_type must be a non-empty string for " .. definition.name)
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

    -- 完整索引校验通过后才交给调用者。
    assert(count > 0, "gateway registry must contain at least one command")

    return
    {
        envelope_type = definitions.envelope_type, -- codec 共用的完整 Envelope Protobuf 类型名。
        by_id         = by_id, -- Gateway 按入站或出站命令号查询的独立索引。
        count         = count, -- 启动时报告的有效命令数量。
    }
end

--- 根据 Envelope 中的 uint32 command 查找 request/response 类型定义。
--- registry 是 M.build_index 返回且由调用方持有的只读索引；command_id 合法范围为 1..0xffffffff。
--- 返回只读定义；未知 id 返回 nil。O(1) table 查询，不执行 I/O、yield 或修改 registry。
---@param registry table M.build_index 返回的只读 registry。
---@param command_id integer Envelope 中的 uint32 command id。
---@return table|nil 对应 command 定义；未知 id 返回 nil。
function M.find_command(registry, command_id)
    return registry.by_id[command_id]
end

return M
