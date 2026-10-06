--- 稳定 Router 的调用入口；排队记录保留在 Router Service，目标实例替换不迁移协程。
local rpc = require "flywow_hotupgrade_rpc"
local M = {}
local Ref = {}
Ref.__index = Ref

---@param options table handle/key/policy/timeout_ms
---@return table 路由引用
function M.new(options)
    return setmetatable({options = options}, Ref)
end

---@param command string 宿主命令
---@param payload any 宿主 record
---@return flywow_hotupgrade_result 调用可 yield
function Ref:call(command, payload)
    return rpc.call(self.options.handle, "request",
        {key = self.options.key, command = command, payload = payload,
            policy = self.options.policy}, self.options.timeout_ms or 10000)
end

return M
