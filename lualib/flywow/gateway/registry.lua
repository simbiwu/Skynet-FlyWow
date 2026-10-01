-- 职责：校验并索引构建阶段生成的 FlyWow Gateway 协议 registry。
-- 边界：FlyWow Gateway Contract；不读取 .proto、不执行 I/O、不持有业务 handler。
-- 输入/输出：生成 registry table -> 按 numeric command 查询的只读索引。
-- 生命周期：Gateway Service 启动时加载一次；校验成功后不再修改。
-- 不负责：不决定 command 的业务归属、不调用 Service、不编码或解码 Protobuf。
local M = {}

-- 校验一个来自生成文件的 Envelope command id。
-- 参数 value：Protobuf uint32 command；只读，不执行 I/O、yield 或分配资源。
-- 失败：不是 1..0xffffffff 的整数时抛出异常。
local function assert_command_id(value)
    assert(type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 0xffffffff,
           "gateway command id must be an integer in [1, 0xffffffff]")
end

-- 加载构建期生成的 registry，并拒绝重复 command、缺失类型名和非法 Envelope 配置。
-- definitions.envelope_type 是完整 Protobuf 类型名；commands 以 uint32 command id 为键，值含 name/request_type/response_type；输入归调用方且只读。
-- 返回独立索引，调用方拥有并应视为只读；空 commands、重复 id、字段缺失或格式错误时抛异常。
-- 仅分配与 command 数量成正比的 Lua table；不执行 I/O、yield 或外部资源分配。
function M.load(definitions)
    assert(type(definitions) == "table", "gateway registry must be a table")
    assert(type(definitions.envelope_type) == "string" and definitions.envelope_type ~= "",
           "gateway registry envelope_type is required")
    assert(type(definitions.commands) == "table", "gateway registry commands are required")

    local by_id = {}
    local count = 0
    for command_id, definition in pairs(definitions.commands) do
        assert_command_id(command_id)
        assert(type(definition) == "table", "gateway command definition must be a table")
        assert(type(definition.name) == "string" and definition.name ~= "",
               "gateway command name is required")
        assert(type(definition.request_type) == "string" and definition.request_type ~= "",
               "gateway request_type is required for " .. definition.name)
        assert(type(definition.response_type) == "string" and definition.response_type ~= "",
               "gateway response_type is required for " .. definition.name)
        assert(by_id[command_id] == nil, "duplicate gateway command id: " .. command_id)
        by_id[command_id] =
        {
            id              = command_id,
            name            = definition.name,
            request_type    = definition.request_type,
            response_type   = definition.response_type,
        }
        count = count + 1
    end
    assert(count > 0, "gateway registry must contain at least one command")

    return
    {
        envelope_type = definitions.envelope_type,
        by_id         = by_id,
        count         = count,
    }
end

-- 根据 Envelope 中的 uint32 command 查找 request/response 类型定义。
-- registry 是 M.load 返回且由调用方持有的只读索引；command_id 合法范围为 1..0xffffffff。
-- 返回只读定义；未知 id 返回 nil。O(1) table 查询，不执行 I/O、yield 或修改 registry。
function M.find(registry, command_id)
    return registry.by_id[command_id]
end

return M
