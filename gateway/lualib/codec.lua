--- 职责：使用宿主提供的 lua-protobuf 完成 Gateway Envelope 和 command body 编解码。
--- 边界：FlyWow Gateway Runtime Library；不读取 Socket、不调用业务 Service、不保存连接状态。
--- 输入/输出：descriptor path + registry -> FlyWowResult<Lua table / Protobuf bytes>。
--- 生命周期：每个 Gateway Lua State 启动时加载一次 descriptor；codec 对象由当前 Service 独占。
--- 不负责：不决定路由、不处理 TCP/WebSocket framing。
local pb = require "pb"
local flywow_result = require "flywow_result"

local M = {}
local registry -- 当前 Service 已验证的协议表；init 成功后发布，编解码函数只读使用。

--- 从构建产物读取 FileDescriptorSet；文件句柄由本函数独占并在所有路径关闭。
---@param descriptor_path string Server 工作目录下 descriptor 文件的路径。
---@return FlyWowResult<string> 完整 descriptor bytes；I/O 失败返回 GATEWAY_DESCRIPTOR_READ_FAILED。
local function read_descriptor(descriptor_path)
    local open_succeeded, descriptor_file, open_error = pcall(io.open, descriptor_path, "rb")
    if not open_succeeded or descriptor_file == nil then
        return flywow_result.failure(
            "GATEWAY_DESCRIPTOR_READ_FAILED",
            tostring(open_succeeded and open_error or descriptor_file),
            { descriptor_path = descriptor_path }
        )
    end

    -- 文件已成功打开，读取完整 bytes 后不论结果如何都关闭本函数独占的句柄。
    local read_succeeded, descriptor_bytes, read_error =
        pcall(descriptor_file.read, descriptor_file, "*a")
    local close_succeeded, close_result, close_error =
        pcall(descriptor_file.close, descriptor_file)
    if not read_succeeded or descriptor_bytes == nil then
        return flywow_result.failure(
            "GATEWAY_DESCRIPTOR_READ_FAILED",
            tostring(read_succeeded and read_error or descriptor_bytes),
            { descriptor_path = descriptor_path }
        )
    end
    if not close_succeeded or close_result == nil then
        return flywow_result.failure(
            "GATEWAY_DESCRIPTOR_READ_FAILED",
            tostring(close_succeeded and close_error or close_result),
            { descriptor_path = descriptor_path }
        )
    end

    return flywow_result.success(descriptor_bytes)
end

--- 初始化当前 Gateway Service 的协议表与 descriptor；只在 start 接受连接前调用。
--- codec_config.descriptor_path 指向构建产物；codec_config.registry 是构建生成的 registry。
---@param codec_config table Gateway start 提供的 descriptor_path 与 registry。
---@return FlyWowResult<integer> 成功 value 为命令数量；配置、文件、descriptor 无效时返回稳定错误。
function M.init(codec_config)
    if type(codec_config) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_CODEC_CONFIG_INVALID",
            "gateway codec config must be a table"
        )
    end
    if type(codec_config.descriptor_path) ~= "string" or codec_config.descriptor_path == "" then
        return flywow_result.failure(
            "GATEWAY_CODEC_CONFIG_INVALID",
            "gateway descriptor_path is required"
        )
    end
    if type(codec_config.registry) ~= "table" then
        return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway registry structure is invalid")
    end

    -- codec 独占校验生成表；无效结构在 descriptor I/O 前返回原有 Registry 错误。
    local candidate_registry = codec_config.registry -- 构建生成的协议表；后续只由 codec 查找命令。
    if type(candidate_registry.envelope_type) ~= "string" or candidate_registry.envelope_type == "" or
        type(candidate_registry.commands) ~= "table" then
        return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway registry structure is invalid")
    end

    -- Registry 骨架通过后逐项核对命令号与消息类型，并统计数量供后续 descriptor 校验使用。
    local command_count = 0 -- 启动结果使用的已验证命令数。
    for command_id, definition in pairs(candidate_registry.commands) do
        if type(command_id) ~= "number" or command_id % 1 ~= 0 or
            command_id < 1 or command_id > 0xffffffff or type(definition) ~= "table" or
            (definition.request_type ~= nil and
                (type(definition.request_type) ~= "string" or definition.request_type == "")) or
            (definition.response_type ~= nil and
                (type(definition.response_type) ~= "string" or definition.response_type == "")) then
            return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway command definition is invalid",
                { command_id = command_id })
        end
        command_count = command_count + 1
    end
    if command_count == 0 then
        return flywow_result.failure("GATEWAY_REGISTRY_INVALID", "gateway registry must contain at least one command")
    end

    -- 校验通过后读取 descriptor；文件错误直接沿 Result 返回给启动入口。
    local descriptor_result = read_descriptor(codec_config.descriptor_path)
    if not descriptor_result.ok then
        return descriptor_result
    end

    -- 只有 descriptor bytes 读取成功后才调用 lua-protobuf 注册类型。
    local load_succeeded, loaded_or_error = pcall(pb.load, descriptor_result.value)
    if not load_succeeded or loaded_or_error ~= true then
        return flywow_result.failure(
            "GATEWAY_DESCRIPTOR_INVALID",
            tostring(load_succeeded and loaded_or_error or loaded_or_error),
            { descriptor_path = codec_config.descriptor_path }
        )
    end

    -- 在监听前核对 Registry 所引用的消息类型，拒绝不匹配的 descriptor。
    local required_types = { candidate_registry.envelope_type }
    for _, definition in pairs(candidate_registry.commands) do
        if definition.request_type then
            required_types[#required_types + 1] = definition.request_type
        end
        if definition.response_type then
            required_types[#required_types + 1] = definition.response_type
        end
    end

    -- 类型清单已由 Registry 收集，逐项确认已加载的 descriptor 能解析对应消息。
    for _, type_name in ipairs(required_types) do
        if pb.type(type_name) == nil then
            return flywow_result.failure(
                "GATEWAY_DESCRIPTOR_INVALID",
                "descriptor is missing a registry message type",
                { descriptor_path = codec_config.descriptor_path, message_type = type_name }
            )
        end
    end

    -- 校验完成后才发布 Registry，失败初始化不会覆盖模块已有协议表。
    registry = candidate_registry
    return flywow_result.success(command_count)
end

--- 判断命令是否出现在已验证的生成表中。
---@param command_id integer Envelope 中的命令号。
---@return boolean found 命令存在时为 true。
function M.has_command(command_id)
    return registry.commands[command_id] ~= nil
end

--- 判断命令是否可用于业务出站消息。
---@param command_id integer 宿主提供的命令号。
---@return boolean supported 声明响应类型时为 true。
function M.has_response(command_id)
    local definition = registry.commands[command_id]
    return definition ~= nil and definition.response_type ~= nil
end

--- 解码一条完整 Envelope；payload 是 framing 后的 Protobuf bytes，由调用方借用且本函数不保留。
---@param payload string 一条完整 Envelope 的 Protobuf bytes。
---@return FlyWowResult<table> 成功 value 为 Envelope；格式错误或类型不匹配时返回 GATEWAY_ENVELOPE_DECODE_FAILED。
function M.decode_envelope(payload)
    if type(payload) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_ENVELOPE_DECODE_FAILED",
            "Envelope payload must be a byte string"
        )
    end

    -- 类型通过后调用 lua-protobuf；坏帧在这里转换为稳定错误码。
    local decoded, envelope_or_error = pcall(
        pb.decode,
        registry.envelope_type,
        payload
    )
    if not decoded or type(envelope_or_error) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_ENVELOPE_DECODE_FAILED",
            tostring(envelope_or_error),
            { envelope_type = registry.envelope_type }
        )
    end

    -- 外层结构成功后交给调用方检查版本和 command。
    return flywow_result.success(envelope_or_error)
end

--- 按已验证 registry 的 request_type 解码 Envelope.body。
---@param command_id integer 当前命令号，来自生成表的 key。
---@param body string Envelope 中的 request Protobuf bytes。
---@return FlyWowResult<table> 成功 value 为业务 request；schema 或 body 错误返回 GATEWAY_REQUEST_DECODE_FAILED。
function M.decode_request(command_id, body)
    local definition = registry.commands[command_id] -- 已验证命令对应的请求类型。
    if type(definition) ~= "table" or type(definition.request_type) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_REQUEST_DECODE_FAILED",
            "gateway command does not define a request"
        )
    end
    if type(body) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_REQUEST_DECODE_FAILED",
            "request body must be a byte string",
            { command_id = command_id }
        )
    end

    -- registry 已给出可信消息类型，解码异常只拒绝当前请求。
    local decoded, request_or_error = pcall(pb.decode, definition.request_type, body)
    if not decoded or type(request_or_error) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_REQUEST_DECODE_FAILED",
            tostring(request_or_error),
            { command_id = command_id, request_type = definition.request_type }
        )
    end

    -- body 解码成功后交给 Gateway 投递，不在 codec 缓存业务数据。
    return flywow_result.success(request_or_error)
end

--- 按 registry response_type 编码业务 response，再封装共享 Envelope。
---@param command_id integer 当前命令号，来自生成表的 key。
---@param version integer 当前 Gateway 配置的 Envelope 协议版本。
---@param response table handler 返回的业务响应；本函数只读。
---@return FlyWowResult<string> 成功 value 为完整 Envelope bytes；类型、schema 或编码错误返回 GATEWAY_RESPONSE_ENCODE_FAILED。
function M.encode_response(command_id, version, response)
    local definition = registry.commands[command_id] -- 已验证命令对应的响应类型。
    if type(definition) ~= "table" or type(definition.response_type) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_RESPONSE_ENCODE_FAILED",
            "gateway command does not define a response"
        )
    end
    if math.type(version) ~= "integer" or type(response) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_RESPONSE_ENCODE_FAILED",
            "protocol version and response table are required",
            { command_id = command_id }
        )
    end

    -- 先编码业务 body；成功后再构造共享 Envelope。
    local body_encoded, body_or_error =
        pcall(pb.encode, definition.response_type, response)
    if not body_encoded or type(body_or_error) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_RESPONSE_ENCODE_FAILED",
            tostring(body_or_error),
            { command_id = command_id, response_type = definition.response_type }
        )
    end

    -- body 编码成功后封装版本、command 和不透明 body bytes。
    local envelope =
    {
        protocol_version = version, -- 宿主指定的 Envelope 兼容版本。
        command          = command_id, -- 与业务响应类型对应的 registry 命令号。
        body             = body_or_error, -- 编码后的业务消息，作为 Envelope 的不透明载荷。
    }
    -- Envelope 编码失败时保留错误结果，不返回半成品 bytes。
    local envelope_encoded, envelope_or_error =
        pcall(pb.encode, registry.envelope_type, envelope)
    if not envelope_encoded or type(envelope_or_error) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_RESPONSE_ENCODE_FAILED",
            tostring(envelope_or_error),
            { envelope_type = registry.envelope_type }
        )
    end

    -- 外层结构成功后交给调用方检查版本和 command。
    return flywow_result.success(envelope_or_error)
end

return M
