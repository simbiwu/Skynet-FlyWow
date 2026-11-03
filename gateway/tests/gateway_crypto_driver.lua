-- 职责：为Python独立参考实现提供真实OpenSSL握手入口。
-- 边界：Test Driver；stdin仅含测试HELLO/PROOF，stdout仅输出公开challenge/ready。
-- 生命周期：一个Native对象，验证后显式关闭并确认不能复用。
-- 不负责：不输出secret，不启动Socket，不替代SDK验收。
package.cpath = assert(arg[1]) .. "/?.so;" .. package.cpath
local crypto = require "flywow_gateway_crypto"
-- 将测试参考实现输入的 hex 转为完整握手字节，不用于 Runtime 网络输入。
---@param hex string Python 参考实现写入 stdin 的十六进制 HELLO/PROOF。
---@return string 解码后的完整握手消息。
local function decode(hex)
    return (hex:gsub("..", function(pair) return string.char(assert(tonumber(pair, 16))) end))
end
-- 将 Native 的公开挑战或服务端证明输出给 Python 参考实现。
---@param bytes string Native 返回的完整 CHALLENGE/READY，不包含密钥。
---@return string 公开消息的十六进制表示。
local function encode(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local context, challenge = crypto.create_context(decode(assert(io.read())))
io.write(encode(challenge), "\n"); io.flush()
local proof = decode(assert(io.read())) -- 独立参考实现产生的有效证明，用于验证不可复用。
-- close-before-verify 模式使用参考实现为此挑战算出的有效证明，单独验证 close 对活动对象的失效作用。
if arg[2] == "close_before_verify" then
    context:close()
    local rejected, close_error = context:verify(proof) -- 原本有效的证明现在也不得通过。
    assert(rejected == nil and close_error.code == "HANDSHAKE_PROOF")
    context:close()
    print("NATIVE_CLOSE_BEFORE_VERIFY_OK")
    return
end
local ready = context:verify(proof)
io.write(encode(ready), "\n"); io.flush()
local rejected, proof_error = context:verify(proof)
assert(rejected == nil and proof_error.code == "HANDSHAKE_PROOF")
context:close(); context:close()
local after_close, close_error = context:verify(proof) -- 关闭后连原先有效证明也必须被拒绝。
assert(after_close == nil and close_error.code == "HANDSHAKE_PROOF")
local invalid, key_error = crypto.create_context(string.char(1, 1, 4) .. string.rep("\0", 64))
assert(invalid == nil and key_error.code == "INVALID_PUBLIC_KEY")
print("NATIVE_LIFECYCLE_OK")
