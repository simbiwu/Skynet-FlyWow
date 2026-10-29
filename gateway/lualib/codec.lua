--- 职责：使用宿主提供的 lua-protobuf 完成 Gateway Envelope 和 command body 编解码。
--- 边界：FlyWow Gateway Runtime Library；不读取 Socket、不调用业务 Service、不保存连接状态。
--- 输入/输出：descriptor path + registry -> FlyWowResult<Lua table / Protobuf bytes>。
--- 生命周期：每个 Gateway Lua State 启动时加载一次 descriptor；codec 对象由当前 Service 独占。
--- 不负责：不决定路由、不处理 TCP/WebSocket framing。
local pb = require "pb"
local flywow_result = require "flywow_result"

local M = {}

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

--- 创建当前 Gateway Lua State 独占的 codec，并加载已生成 descriptor。
--- codec_config.descriptor_path 指向构建产物；codec_config.registry 是已验证 registry 索引。
---@param codec_config table Gateway start 提供的 descriptor_path 与 registry。
---@return FlyWowResult<table> 成功 value 为 codec；配置、文件、descriptor 无效时返回稳定错误。
function M.new(codec_config)
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
    if type(codec_config.registry) ~= "table" or
        type(codec_config.registry.envelope_type) ~= "string" then
        return flywow_result.failure(
            "GATEWAY_CODEC_CONFIG_INVALID",
            "gateway registry envelope_type is required"
        )
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

    -- descriptor 已注册，下面创建只捕获已验证配置的本地 codec。
    local codec = {} -- 当前 Gateway Service 独占的编解码入口，闭包读取本次配置。

    --- 解码一条完整 Envelope；payload 是 framing 后的 Protobuf bytes，由调用方借用且本函数不保留。
    ---@param payload string 一条完整 Envelope 的 Protobuf bytes。
    ---@return FlyWowResult<table> 成功 value 为 Envelope；格式错误或类型不匹配时返回 GATEWAY_ENVELOPE_DECODE_FAILED。
    function codec.decode_envelope(payload)
        if type(payload) ~= "string" then
            return flywow_result.failure(
                "GATEWAY_ENVELOPE_DECODE_FAILED",
                "Envelope payload must be a byte string"
            )
        end

        -- 类型通过后调用 lua-protobuf；坏帧在这里转换为稳定错误码。
        local decoded, envelope_or_error = pcall(
            pb.decode,
            codec_config.registry.envelope_type,
            payload
        )
        if not decoded or type(envelope_or_error) ~= "table" then
            return flywow_result.failure(
                "GATEWAY_ENVELOPE_DECODE_FAILED",
                tostring(envelope_or_error),
                { envelope_type = codec_config.registry.envelope_type }
            )
        end

        -- 外层结构成功后交给调用方检查版本和 command。
        return flywow_result.success(envelope_or_error)
    end

    --- 按已验证 registry 的 request_type 解码 Envelope.body。
    ---@param definition table registry 中由 command id 找到的只读命令定义。
    ---@param body string Envelope 中的 request Protobuf bytes。
    ---@return FlyWowResult<table> 成功 value 为业务 request；schema 或 body 错误返回 GATEWAY_REQUEST_DECODE_FAILED。
    function codec.decode_request(definition, body)
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
                { command_id = definition.id }
            )
        end

        -- registry 已给出可信消息类型，解码异常只拒绝当前请求。
        local decoded, request_or_error = pcall(pb.decode, definition.request_type, body)
        if not decoded or type(request_or_error) ~= "table" then
            return flywow_result.failure(
                "GATEWAY_REQUEST_DECODE_FAILED",
                tostring(request_or_error),
                { command_id = definition.id, request_type = definition.request_type }
            )
        end

        -- body 解码成功后交给 Gateway 投递，不在 codec 缓存业务数据。
        return flywow_result.success(request_or_error)
    end

    --- 按 registry response_type 编码业务 response，再封装共享 Envelope。
    ---@param definition table registry 中由 command id 找到的只读命令定义。
    ---@param version integer 当前 Gateway 配置的 Envelope 协议版本。
    ---@param response table handler 返回的业务响应；本函数只读。
    ---@return FlyWowResult<string> 成功 value 为完整 Envelope bytes；类型、schema 或编码错误返回 GATEWAY_RESPONSE_ENCODE_FAILED。
    function codec.encode_response(definition, version, response)
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
                { command_id = definition.id }
            )
        end

        -- 先编码业务 body；成功后再构造共享 Envelope。
        local body_encoded, body_or_error =
            pcall(pb.encode, definition.response_type, response)
        if not body_encoded or type(body_or_error) ~= "string" then
            return flywow_result.failure(
                "GATEWAY_RESPONSE_ENCODE_FAILED",
                tostring(body_or_error),
                { command_id = definition.id, response_type = definition.response_type }
            )
        end

        -- body 编码成功后封装版本、command 和不透明 body bytes。
        local envelope =
        {
            protocol_version = version, -- 宿主指定的 Envelope 兼容版本。
            command          = definition.id, -- 与业务响应类型对应的 registry 命令号。
            body             = body_or_error, -- 编码后的业务消息，作为 Envelope 的不透明载荷。
        }
        -- Envelope 编码失败时保留错误结果，不返回半成品 bytes。
        local envelope_encoded, envelope_or_error =
            pcall(pb.encode, codec_config.registry.envelope_type, envelope)
        if not envelope_encoded or type(envelope_or_error) ~= "string" then
            return flywow_result.failure(
                "GATEWAY_RESPONSE_ENCODE_FAILED",
                tostring(envelope_or_error),
                { envelope_type = codec_config.registry.envelope_type }
            )
        end

        -- 外层结构成功后交给调用方检查版本和 command。
        return flywow_result.success(envelope_or_error)
    end

    return flywow_result.success(codec)
end

return M
