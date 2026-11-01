-- 职责：直接验证 Codec 对生成 Registry 的校验、唯一查询和错误类别。
-- 边界：Unit Test；lua-protobuf 以可控替身注入，descriptor 读取使用 Linux /dev/null。
-- 输入/输出：FlyWow 根路径 -> Codec合同断言或 GATEWAY_CODEC_UNIT_OK。
-- 生命周期：单一 Lua State；不启动 Gateway、Socket 或 Skynet。
-- 不负责：不验证真实 protobuf wire 编码，真实 descriptor 由集成验证覆盖。
local root = assert(arg[1])
package.path = root .. "/common/lualib/?.lua;" ..
    root .. "/gateway/lualib/?.lua;" .. package.path
local available_types = {}
local encoded_calls = {} -- 依调用顺序记录业务 body 与 Envelope 的编码输入，供成功路径核对。
local pb = {}
-- 替身接受任意 descriptor bytes；真实 descriptor 由集成测试验证。
---@param bytes string Codec 从 descriptor 文件读取的字节。
---@return boolean 注册成功标记。
function pb.load(bytes)
    assert(type(bytes) == "string")
    return true
end
-- 替身按测试预先登记的全名报告 descriptor 类型。
---@param name string Codec 查询的 protobuf 消息全名。
---@return boolean|nil 类型存在时为 true，不存在时为 nil。
function pb.type(name)
    return available_types[name]
end
-- 对指定类型返回可辨认的消息 record；bad 输入用于触发 Codec 的错误转换分支。
---@param name string Codec 请求解码的 protobuf 消息全名。
---@param bytes string 测试传入的消息字节。
---@return table 仅包含解码类型名的替身消息。
function pb.decode(name, bytes)
    assert(available_types[name])
    if bytes == "bad" then
        error("decode failure")
    end
    return { decoded_as = name }
end
-- 记录 Codec 传给 protobuf 的类型和消息内容，不验证实际 wire bytes。
---@param name string Codec 请求编码的 protobuf 消息全名。
---@param value table Codec 交给 protobuf 的消息 record。
---@return string 本测试用类型名代替编码后的字节。
function pb.encode(name, value)
    assert(available_types[name] and type(value) == "table")
    encoded_calls[#encoded_calls + 1] =
    {
        name = name, -- 本次编码使用的 protobuf 消息全名。
        value = value, -- 本次借用的业务消息或 Codec 新建的 Envelope。
    }
    return name
end
package.loaded.pb = pb
local codec_module = require "codec"
-- 为每个构造测试创建 Codec 可消费的 Registry record。
---@param commands table 按 command_id 索引、包含消息类型名的测试命令表。
---@return table envelope_type 与 commands 字段完整的测试 Registry。
local function registry(commands)
    return
    {
        envelope_type = ".demo.Envelope", -- Codec 解码外层 Envelope 时查找的消息全名。
        commands = commands, -- Codec 验证和查询的测试命令定义集合。
    }
end
-- 断言 Codec 返回指定错误码，覆盖稳定失败合同。
---@param result FlyWowResult Codec 操作返回的成功或失败结果。
---@param code string 当前测试要求的机器可读失败码。
---@return nil 结果不是指定失败码时立即让测试失败。
local function failed(result, code)
    assert(not result.ok and result.code == code, result.code)
end
failed(codec_module.init({ descriptor_path = "/dev/null", registry = false }), "GATEWAY_REGISTRY_INVALID")
failed(codec_module.init({ descriptor_path = "/dev/null", registry = { envelope_type = "", commands = {} } }),
    "GATEWAY_REGISTRY_INVALID")
failed(codec_module.init({ descriptor_path = "/dev/null", registry = registry({}) }),
    "GATEWAY_REGISTRY_INVALID")
failed(codec_module.init({ descriptor_path = "/dev/null", registry = registry({ [0] = {} }) }),
    "GATEWAY_REGISTRY_INVALID")
failed(codec_module.init({ descriptor_path = "/dev/null", registry = registry({ [7] = { request_type = "" } }) }),
    "GATEWAY_REGISTRY_INVALID")
local commands =
{
    [7] = { request_type = ".demo.Request", response_type = ".demo.Response" }, -- 双向命令覆盖请求解码与响应编码。
    [8] = { response_type = ".demo.Push" }, -- 服务端推送只需要响应消息类型。
    [9] = { request_type = ".demo.Request" }, -- 单向请求没有可编码的响应类型。
}
available_types[".demo.Envelope"] = true
available_types[".demo.Request"] = true
available_types[".demo.Response"] = true
available_types[".demo.Push"] = true
local result = codec_module.init({ descriptor_path = "/dev/null", registry = registry(commands) })
assert(result.ok, result.message)
local codec = codec_module
assert(result.value == 3)
assert(codec.has_command(7) and codec.has_command(8) and not codec.has_command(10))
assert(codec.has_response(7) and codec.has_response(8) and not codec.has_response(9))
assert(codec.decode_envelope("envelope").ok)
failed(codec.decode_envelope("bad"), "GATEWAY_ENVELOPE_DECODE_FAILED")
assert(codec.decode_request(7, "request").value.decoded_as == ".demo.Request")
failed(codec.decode_request(8, "request"), "GATEWAY_REQUEST_DECODE_FAILED")
failed(codec.decode_request(7, false), "GATEWAY_REQUEST_DECODE_FAILED")
failed(codec.decode_request(7, "bad"), "GATEWAY_REQUEST_DECODE_FAILED")
-- 普通响应必须先按响应类型编码原业务数据，再把对应命令、版本和 body 装进 Envelope。
local response = { result_id = 17 } -- 宿主提供的普通响应；Codec 应原样交给 body encoder。
assert(codec.encode_response(7, 4, response).value == ".demo.Envelope")
assert(#encoded_calls == 2)
assert(encoded_calls[1].name == ".demo.Response" and encoded_calls[1].value == response)
assert(encoded_calls[2].name == ".demo.Envelope")
assert(encoded_calls[2].value.command == 7 and encoded_calls[2].value.protocol_version == 4)
assert(encoded_calls[2].value.body == ".demo.Response")

-- Push 没有 request_type，仍应使用自身响应类型和本次命令、版本，不能沿用上次响应字段。
local push = { notice_id = 23 } -- 宿主主动下发的数据，与普通响应使用不同字段以便识别。
assert(codec.encode_response(8, 5, push).value == ".demo.Envelope")
assert(#encoded_calls == 4)
assert(encoded_calls[3].name == ".demo.Push" and encoded_calls[3].value == push)
assert(encoded_calls[4].name == ".demo.Envelope")
assert(encoded_calls[4].value.command == 8 and encoded_calls[4].value.protocol_version == 5)
assert(encoded_calls[4].value.body == ".demo.Push")
failed(codec.encode_response(9, 4, {}), "GATEWAY_RESPONSE_ENCODE_FAILED")
failed(codec.encode_response(7, 4.5, {}), "GATEWAY_RESPONSE_ENCODE_FAILED")
local missing = registry({ [7] = { request_type = ".demo.Missing" } })
failed(codec_module.init({ descriptor_path = "/dev/null", registry = missing }), "GATEWAY_DESCRIPTOR_INVALID")
print("GATEWAY_CODEC_UNIT_OK")
