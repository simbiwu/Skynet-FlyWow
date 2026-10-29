-- 职责：独立验证握手状态机的阶段、容量、期限与幂等释放。
-- 边界：Unit Test；Native以具名替身注入，不启动Socket或登录。
-- 生命周期：测试独占manager/context；计数证明资源释放，不冒充密码算法验证。
-- 不负责：真实Native互通由另一个测试执行。
local root = assert(arg[1])
package.path = root .. "/common/lualib/?.lua;" ..
    root .. "/gateway/lualib/?.lua;" .. package.path
local factory = require "handshake"
local flywow_result = require "flywow_result"
local now, closed = 0, 0
local crypto = {}
-- 替身保持Native对象合同，失败可控；不执行I/O。
function crypto.new(hello)
    local native = {}
    -- 仅一个固定证明通过；验证失败抛错交给状态机关闭。
    function native:verify(bytes)
        assert(bytes == string.char(3) .. string.rep("p", 32))
        return string.char(4) .. string.rep("r", 32)
    end
    -- 记录释放次数，manager必须只调用一次。
    function native:close() closed = closed + 1 end
    return native, string.char(2, 1) .. string.rep("c", 97)
end
local manager_result = factory.new(
{
    crypto        = crypto,
    now           = function() return now end,
    max_pending   = 2,
    timeout_ticks = 100,
}
)
assert(manager_result.ok, manager_result.message)
local manager = manager_result.value
local hello = string.char(1, 1, 4) .. string.rep("a", 64)
local proof = string.char(3) .. string.rep("p", 32)
local a_result = manager.accept()
local b_result = manager.accept()
assert(a_result.ok and b_result.ok)
local a, b = a_result.value, b_result.value
assert(not manager.accept().ok)
assert(not manager.ready(a) and manager.expected_size(a) == 67)
local challenge_result = manager.receive({ context = a, bytes = hello })
assert(challenge_result.ok, challenge_result.message)
assert(#challenge_result.value.response_bytes == 99)
assert(not challenge_result.value.needs_confirmation)
assert(manager.expected_size(a) == 33)
local ready_result = manager.receive({ context = a, bytes = proof })
assert(ready_result.ok, ready_result.message)
assert(#ready_result.value.response_bytes == 33 and ready_result.value.needs_confirmation)
assert(not manager.ready(a), "must wait for successful transport write")
assert(manager.confirm(a).ok and manager.ready(a))
manager.close(a)
assert(closed == 1, "double close must not free twice")
local c = manager.accept().value
assert(not manager.receive({ context = c, bytes = hello:sub(1, 66) }).ok)
manager.close(c)
assert(not manager.receive({ context = b, bytes = string.char(1, 2) .. string.rep("a", 65) }).ok)
local d = manager.accept().value
assert(manager.receive({ context = d, bytes = hello }).ok)
assert(not manager.receive({ context = d, bytes = string.char(3) .. string.rep("x", 32) }).ok)
assert(closed == 2)
local e = manager.accept().value
assert(manager.receive({ context = e, bytes = hello }).ok)
now = 100
assert(manager.expired(e))
assert(not manager.receive({ context = e, bytes = proof }).ok)
assert(closed == 3)
-- tick回绕也按绝对期限，不随HELLO刷新。
now = 0xfffffff0
local f = manager.accept().value
now = 0x20
assert(not manager.expired(f))
now = 0x60
assert(manager.expired(f))
manager.close(f)
print("GATEWAY_HANDSHAKE_UNIT_OK")
