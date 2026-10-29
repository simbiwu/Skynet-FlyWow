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
---@param hello string Gateway 输入的完整 HELLO 字节；替身只用它创建密码对象。
---@return userdata, string 测试用 userdata 与固定 SERVER_CHALLENGE 字节。
function crypto.new(hello)
    -- 使用独占文件 userdata 模拟 Native 类型；替身只验证状态机，不执行密码运算。
    local native = assert(io.tmpfile())
    local close_file = native.close
    local file_metatable = debug.getmetatable(native)
    debug.setmetatable(native, { __index = { -- 为测试 userdata 提供与 Native 相同的 verify/close 方法。
        verify = function(_, bytes) -- 接收测试 proof，返回固定的服务端证明。
            assert(bytes == string.char(3) .. string.rep("p", 32))
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
