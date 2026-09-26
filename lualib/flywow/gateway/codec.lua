-- 职责：使用宿主提供的 lua-protobuf 完成 Gateway Envelope 和 command body 编解码。
-- 边界：FlyWow Gateway Runtime Library；不读取 Socket、不调用业务 Service、不保存连接状态。
-- 输入/输出：descriptor path + registry -> Lua table 与 Protobuf bytes。
-- 生命周期：每个 Gateway Lua State 启动时加载一次 descriptor；codec 对象由当前 Service 独占。
-- 不负责：不决定路由、不处理 TCP/WebSocket framing、不把错误转换成业务结果。
local pb = require "pb"

local M = {}

-- 读取构建产物 descriptor；文件句柄只在本函数内拥有，返回值由调用方拥有。
-- 参数 path：Server 运行目录下的 descriptor 文件路径；必须可读且内容为 FileDescriptorSet。
-- 返回值：完整 descriptor bytes；失败抛出文件 I/O 异常，不 yield、不保留句柄。
local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("*a")
    file:close()
    return bytes
end

-- 创建一个已加载 descriptor 的 codec。
-- 参数 options.descriptor_path：Server 运行目录下的 descriptor 文件；options.registry：registry 索引。
-- 返回值：独立 codec 对象；对象只在当前 Lua State 使用，不跨 Service 传递。
-- 失败：文件不存在、descriptor 损坏或 protobuf 类型不存在时抛错；执行文件 I/O，不 yield。
function M.new(options)
    assert(type(options) == "table", "gateway codec options are required")
    assert(type(options.descriptor_path) == "string" and options.descriptor_path ~= "",
           "gateway descriptor_path is required")
    assert(type(options.registry) == "table", "gateway registry is required")
    local bytes = read_file(options.descriptor_path)
    assert(pb.load(bytes), "cannot load protobuf descriptor: " .. options.descriptor_path)

    local codec = {}

    -- 解码一条完整 Envelope；bytes 所有权属于本次调用，返回 table 由当前 Service 拥有。
    -- 失败：Protobuf bytes 非法时抛错；不执行 I/O、yield 或跨 Service 调用。
    function codec.decode_envelope(payload)
        return assert(pb.decode(options.registry.envelope_type, payload))
    end

    -- 根据 command definition 解码 body；body 是 Envelope 内部 bytes，不保存 borrowed buffer。
    -- 失败：command 类型缺失或 body 非法时抛错。
    function codec.decode_request(definition, body)
        return assert(pb.decode(definition.request_type, body))
    end

    -- 将业务 response 编码为 registry 指定的 response message，再封装为 Envelope。
    -- 参数 definition：M.registry.find 返回的只读定义；request_id/version：Envelope 元数据。
    -- 返回值：新 Lua string；失败时抛错；不执行 I/O、yield 或修改业务 response。
    function codec.encode_response(definition, request_id, version, response)
        local body = assert(pb.encode(definition.response_type, response))
        return assert(pb.encode(options.registry.envelope_type, {
            protocol_version = version,
            command = definition.id,
            request_id = request_id,
            body = body,
        }))
    end

    return codec
end

return M
