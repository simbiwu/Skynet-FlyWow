-- 职责：为Python独立参考实现提供真实OpenSSL握手入口。
-- 边界：Test Driver；stdin仅含测试HELLO/PROOF，stdout仅输出公开challenge/ready。
-- 生命周期：一个Native对象，验证后显式关闭并确认不能复用。
-- 不负责：不输出secret，不启动Socket，不替代SDK验收。
package.cpath = assert(arg[1]) .. "/?.so;" .. package.cpath
local crypto = require "flywow_gateway_crypto"
-- 测试专用hex解码，不用于Runtime不可信消息。
local function decode(hex)
    return (hex:gsub("..", function(pair) return string.char(assert(tonumber(pair, 16))) end))
end
-- 输出公开字节，便于与独立实现对比。
local function encode(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local context, challenge = crypto.new(decode(assert(io.read())))
io.write(encode(challenge), "\n"); io.flush()
local ready = context:verify(decode(assert(io.read())))
io.write(encode(ready), "\n"); io.flush()
assert(not pcall(context.verify, context, string.rep("x", 33)))
context:close(); context:close()
assert(not pcall(crypto.new, string.char(1, 1, 4) .. string.rep("\0", 64)))
print("NATIVE_LIFECYCLE_OK")
