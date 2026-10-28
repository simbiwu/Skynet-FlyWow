--- 职责：使用宿主提供的 lua-protobuf 完成 Gateway Envelope 和 command body 编解码。
--- 边界：FlyWow Gateway Runtime Library；不读取 Socket、不调用业务 Service、不保存连接状态。
--- 输入/输出：descriptor path + registry -> Lua table 与 Protobuf bytes。
--- 生命周期：每个 Gateway Lua State 启动时加载一次 descriptor；codec 对象由当前 Service 独占。
--- 不负责：不决定路由、不处理 TCP/WebSocket framing、不把错误转换成业务结果。
local pb = require "pb"

local M = {}

--- 读取构建产物 descriptor；文件句柄只在本函数内拥有，返回值由调用方拥有。
--- 参数 descriptor_path：Server 运行目录下的 descriptor 文件路径；必须可读且内容为 FileDescriptorSet。
--- 返回值：完整 descriptor bytes；失败抛出文件 I/O 异常，不 yield、不保留句柄。
---@param descriptor_path string Server 运行目录中的 descriptor 文件路径。
---@return string 完整 descriptor bytes；文件打开失败时抛出 I/O 异常。
local function read_descriptor(descriptor_path)
    local descriptor_file = assert(io.open(descriptor_path, "rb")) -- 本次读取独占的文件句柄，读完即关闭。
    local descriptor_bytes = descriptor_file:read("*a") -- 完整 FileDescriptorSet 字节，交给 pb.load。
    descriptor_file:close()

    return descriptor_bytes
end

--- 创建一个已加载 descriptor 的 codec。
--- 参数 codec_config.descriptor_path：Server 运行目录下的 descriptor 文件；codec_config.registry：registry 索引。
--- 返回值：独立 codec 对象；对象只在当前 Lua State 使用，不跨 Service 传递。
--- 失败：文件不存在、descriptor 损坏或 protobuf 类型不存在时抛错；执行文件 I/O，不 yield。
---@param codec_config table descriptor_path 与已验证的 registry 索引。
---@return table 持有已加载 descriptor 的 codec；文件或 Protobuf 校验失败时抛错。
function M.new(codec_config)
    assert(type(codec_config) == "table", "gateway codec config is required")
    assert(type(codec_config.descriptor_path) == "string" and codec_config.descriptor_path ~= "",
           "gateway descriptor_path is required")
    assert(type(codec_config.registry) == "table", "gateway registry is required")

    --- descriptor 整体加载到当前 State 后，再创建共用 registry 的编解码入口。
    local descriptor_bytes = read_descriptor(codec_config.descriptor_path)
    assert(pb.load(descriptor_bytes),
           "cannot load protobuf descriptor: " .. codec_config.descriptor_path)

    local codec = {}

    --- 解码一条完整 Envelope；payload 是 framing 后的 Protobuf bytes，由调用方借用且本函数不保留。
    --- 返回新 Lua table，由当前 Service 拥有；payload 格式错误或类型不匹配时抛错。
    --- 不执行 I/O、yield 或跨 Service 调用。
    ---@param payload string 一条完整 Envelope 的 Protobuf bytes。
    ---@return table 解码后的 Envelope；格式错误时抛错。
    function codec.decode_envelope(payload)
        return assert(pb.decode(codec_config.registry.envelope_type, payload))
    end

    --- 根据已校验 registry definition 解码 Envelope.body；body 是单条 request 的 Protobuf bytes。
    --- definition 由同一 codec 的 registry 提供且只读；body 由调用方借用，本函数不保存 borrowed buffer。
    --- 返回当前 Service 拥有的新 request table；消息类型缺失或 body 非法时抛错，不执行 I/O/yield。
    ---@param definition table 已验证 registry 中的请求定义。
    ---@param body string Envelope 中的 request bytes。
    ---@return table 解码后的业务 request；类型缺失或格式错误时抛错。
    function codec.decode_request(definition, body)
        assert(definition.request_type ~= nil,
               "gateway command does not define a request: " .. definition.name)
        return assert(pb.decode(definition.request_type, body))
    end

    --- 将业务 response 编码为 registry 指定的 response message，再封装为完整 Envelope。
    --- 单向命令的 response_type 为 nil；调用此函数会立即失败，防止伪造业务响应。
    --- definition 是只读 command 定义；version 是已协商的协议版本整数。
    --- response 是 handler 返回的业务 table，调用方拥有且本函数只读。返回新 Lua bytes string；
    --- Protobuf 编码失败时抛错；不执行 I/O、yield 或修改业务 response。
    ---@param definition table 已验证 registry 中的响应定义。
    ---@param version integer 当前连接协商的协议版本。
    ---@param response table handler 返回的业务响应。
    ---@return string 编码后的完整 Envelope；响应定义无效或编码失败时抛错。
    function codec.encode_response(definition, version, response)
        assert(definition.response_type ~= nil,
               "gateway command does not define a response: " .. definition.name)

        local body = assert(pb.encode(definition.response_type, response))
        local envelope =
        {
            protocol_version = version, -- 宿主指定的 Envelope 兼容版本。
            command          = definition.id, -- 与业务响应类型对应的 registry 命令号。
            body             = body, -- 编码后的业务消息，作为 Envelope 的不透明载荷。
        }

        return assert(pb.encode(codec_config.registry.envelope_type, envelope))
    end

    return codec
end

return M
