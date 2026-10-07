--- 当前调用方的代际绑定；release 先向目标发送屏障，确保先前 send 已排空。
local skynet = require "skynet"
local rpc = require "flywow_hotupgrade_rpc"
local result = require "flywow_hotupgrade_error"
local native = require "flywow_hotupgrade_native"
local native_error = require "flywow_hotupgrade_native_error"
local M = {}
local Ref = {}
Ref.__index = Ref

---@param options table controller/target/can_switch/timeout_ms
---@return flywow_hotupgrade_result
function M.new(options)
    local ref_id, code = native.nonce()
    if not ref_id then return result.failure(native_error.code(code), "引用身份生成失败") end
    local resolved = rpc.call(options.controller, "resolve",
        {target = options.target, ref_id = ref_id}, options.timeout_ms or 10000)
    if not resolved.ok then return resolved end
    return result.success({ref = setmetatable(
    {
        controller = options.controller, target = options.target,
        address = resolved.record.address, generation = resolved.record.generation,
        instance_id = resolved.record.instance_id,
        ref_id = ref_id,
        can_switch = options.can_switch, timeout_ms = options.timeout_ms or 10000,
    }, Ref)})
end

--- 同步 call 可 yield；不将超时解释为取消业务。
---@param command string 宿主命令
---@param payload any 可序列化业务 record
---@return flywow_hotupgrade_result
function Ref:call(command, payload)
    if self.closed or self.switching then return result.failure("HU_REFERENCE_CLOSED", self.target) end
    return rpc.call(self.address, "invoke",
        {generation = self.generation, instance_id = self.instance_id, command = command, payload = payload}, self.timeout_ms)
end

--- 单向发送沿用 send；不宣称业务送达或成功。
---@param command string 命令
---@param payload any 可序列化数据
---@return flywow_hotupgrade_result
function Ref:send(command, payload)
    if self.closed or self.switching then return result.failure("HU_REFERENCE_CLOSED", self.target) end
    skynet.send(self.address, "hotupgrade", "invoke",
        {generation = self.generation, instance_id = self.instance_id, command = command, payload = payload})
    return result.success()
end

---@return flywow_hotupgrade_result
function Ref:switch()
    if self.closed or self.switching then return result.failure("HU_REFERENCE_CLOSED", self.target) end
    local safe = not self.can_switch or self.can_switch()
    if not safe then return result.failure("HU_SWITCH_BLOCKED", self.target) end
    self.switching = true
    local drained = rpc.call(self.address, "visitor_barrier",
        {generation = self.generation, instance_id = self.instance_id}, self.timeout_ms)
    if not drained.ok then self.switching = false; return drained end
    local switched = rpc.call(self.controller, "switch", {target = self.target, can_switch = safe}, self.timeout_ms)
    if switched.ok then
        self.address, self.generation = switched.record.address, switched.record.generation
        self.instance_id = switched.record.instance_id
    end
    self.switching = false
    return switched
end

--- 可能 yield；先关闭本引用，再以同源协议屏障排空之前投递。
--- 最后一个引用释放后撤销依赖资格；此后需重新声明，而不是自动访问新代。
---@return flywow_hotupgrade_result
function Ref:release()
    if self.released then return result.success() end
    self.closed = true
    local drained = rpc.call(self.address, "visitor_barrier",
        {generation = self.generation, instance_id = self.instance_id}, self.timeout_ms)
    if not drained.ok then return drained end
    local released = rpc.call(self.controller, "release_ref",
        {target = self.target, ref_id = self.ref_id}, self.timeout_ms)
    if released.ok then self.released = true end
    return released
end

return M
