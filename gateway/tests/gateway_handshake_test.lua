-- 职责：独立验证握手状态机的阶段、容量、期限与幂等释放。
-- 边界：Unit Test；Native以具名替身注入，不启动Socket或登录。
-- 生命周期：测试独占握手模块与连接记录；计数证明资源释放，不冒充密码算法验证。
-- 不负责：真实Native互通由另一个测试执行。
local root = assert(arg[1])
package.path = root .. "/common/lualib/?.lua;" ..
    root .. "/gateway/lualib/?.lua;" .. package.path
local handshake_module = require "handshake"
local flywow_result = require "flywow_result"
local now, closed = 0, 0
local crypto = {}
-- 替身保持Native对象合同，失败可控；不执行I/O。
---@param hello string Gateway 输入的完整 HELLO 字节；替身只用它创建密码对象。
---@return userdata, string 测试用 userdata 与固定 SERVER_CHALLENGE 字节。
function crypto.create_context(hello)
    -- 使用独占文件 userdata 模拟 Native 类型；替身只验证状态机，不执行密码运算。
    local native = assert(io.tmpfile())
    local close_file = native.close
    local file_metatable = debug.getmetatable(native)
    debug.setmetatable(native, { __index = { -- 为测试 userdata 提供与 Native 相同的 verify/close 方法。
        verify = function(_, bytes) -- 接收测试 proof，返回固定的服务端证明。
            if bytes ~= string.char(3) .. string.rep("p", 32) then
                return nil, { code = "HANDSHAKE_PROOF", message = "test proof mismatch" }
            end
            return string.char(4) .. string.rep("r", 32)
        end,
        close = function(self) -- 关闭本测试持有的文件 userdata 并记录释放次数。
            closed = closed + 1
            debug.setmetatable(self, file_metatable)
            close_file(self)
        end,
    } })
    return native, string.char(2, 1) .. string.rep("c", 97)
end
local init_result = handshake_module.init(
{
    crypto        = crypto,
    now           = function() return now end,
    max_pending   = 2,
    timeout_ms    = 1000, -- 测试期限为 1000ms，now 每前进一步代表 10ms。
}
)
assert(init_result.ok, init_result.message)
local hello = string.char(1, 1, 4) .. string.rep("a", 64)
local proof = string.char(3) .. string.rep("p", 32)
local a_result = handshake_module.accept()
local b_result = handshake_module.accept()
assert(a_result.ok and b_result.ok)
local a, b = a_result.value, b_result.value
assert(not handshake_module.accept().ok)
assert(not handshake_module.ready(a) and handshake_module.expected_size(a) == 67)
local challenge_result = handshake_module.receive(a, hello)
assert(challenge_result.ok, challenge_result.message)
assert(#challenge_result.value.response_bytes == 99)
assert(not challenge_result.value.needs_confirmation)
assert(handshake_module.expected_size(a) == 33)
local ready_result = handshake_module.receive(a, proof)
assert(ready_result.ok, ready_result.message)
assert(#ready_result.value.response_bytes == 33 and ready_result.value.needs_confirmation)
assert(not handshake_module.ready(a), "must wait for successful transport write")
assert(handshake_module.confirm(a).ok and handshake_module.ready(a))
handshake_module.close(a)
assert(closed == 1, "double close must not free twice")
local c_result = handshake_module.accept()
assert(c_result.ok, "confirm must release exactly one pending slot")
assert(not handshake_module.accept().ok, "ready and active contexts must not exceed pending capacity")
local c = c_result.value
assert(not handshake_module.receive(c, hello:sub(1, 66)).ok)
handshake_module.close(c)
handshake_module.close(c)
local replacement = handshake_module.accept()
assert(replacement.ok, "repeated close must release exactly one pending slot")
handshake_module.close(replacement.value)
assert(not handshake_module.receive(b, string.char(1, 2) .. string.rep("a", 65)).ok)
local d = handshake_module.accept().value
assert(handshake_module.receive(d, hello).ok)
assert(not handshake_module.receive(d, string.char(3) .. string.rep("x", 32)).ok)
assert(closed == 2)
local e = handshake_module.accept().value
assert(handshake_module.receive(e, hello).ok)
now = 100
assert(handshake_module.expired(e))
assert(not handshake_module.receive(e, proof).ok)
assert(closed == 3)
-- tick回绕也按绝对期限，不随HELLO刷新。
now = 0xfffffff0
local f = handshake_module.accept().value
now = 0x20
assert(not handshake_module.expired(f))
now = 0x60
assert(handshake_module.expired(f))
handshake_module.close(f)
-- READY 已生成但尚未写出时到达绝对期限，confirm 仍须拒绝并归还名额。
now = 0
local confirming = handshake_module.accept().value -- 本场景持有的最后确认前连接。
assert(handshake_module.receive(confirming, hello).ok)
assert(handshake_module.receive(confirming, proof).ok)
now = 100
local timeout_result = handshake_module.confirm(confirming) -- 写后确认观察到的期限失败。
assert(not timeout_result.ok and timeout_result.code == "HANDSHAKE_TIMEOUT")
assert(not handshake_module.ready(confirming))
handshake_module.close(confirming)
local available_one = handshake_module.accept() -- 期限失败后应归还第一个名额。
local available_two = handshake_module.accept() -- 第二个名额用于证明没有泄漏或重复归还。
assert(available_one.ok and available_two.ok and not handshake_module.accept().ok)
handshake_module.close(available_one.value)
handshake_module.close(available_two.value)
print("GATEWAY_HANDSHAKE_UNIT_OK")
