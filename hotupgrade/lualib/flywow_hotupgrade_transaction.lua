--- 显式事务跳转，生产开放与清理分开记录；每个对象仅由控制面 owner 修改。
local result = require "flywow_hotupgrade_error"
local M = {}
local Transaction = {}
Transaction.__index = Transaction

local edges =
{
    CREATED = {VALIDATING = true, ABORTING = true},
    VALIDATING = {PREPARING = true, ABORTING = true},
    PREPARING = {STAGING = true, ABORTING = true},
    STAGING = {READY = true, ABORTING = true},
    READY = {ACTIVATING = true, ABORTING = true},
    ACTIVATING = {PUBLISHED = true, ABORTING = true, RECOVERY_REQUIRED = true},
    PUBLISHED = {DRAINING = true, COMPLETED = true, RECOVERY_REQUIRED = true},
    DRAINING = {COMPLETED = true, COMMITTED_DRAIN_PENDING = true},
    COMMITTED_DRAIN_PENDING = {DRAINING = true, RECOVERY_REQUIRED = true},
    ABORTING = {ABORTED = true, RECOVERY_REQUIRED = true},
}

--- 不合法跳转拒绝，不修改原状态；COMPLETED/ABORTED 是终态。
---@param phase string 目标阶段
---@return flywow_hotupgrade_result
function Transaction:move(phase)
    if not (edges[self.phase] and edges[self.phase][phase]) then
        return result.failure("HU_INVALID_TRANSITION", self.phase .. " -> " .. tostring(phase))
    end
    self.phase = phase
    return result.success()
end

---@param id string 唯一事务身份
---@return table 独占事务对象
function M.new(id)
    return setmetatable({id = id, phase = "CREATED"}, Transaction)
end

return M
