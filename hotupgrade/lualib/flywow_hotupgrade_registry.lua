--- 控制面独占的稳定 origin_service_handle 到当前实例索引；候选仅属于其启动窗口和事务。
local result = require "flywow_hotupgrade_error"
local M = {}
local Registry = {}
Registry.__index = Registry

---@return table 由唯一控制 Service 持有的当前实例索引。
function M.new()
    return setmetatable(
    {
        -- 以逻辑 origin_service_handle 索引当前实例 record；record 由唯一 Controller 持有。
        targets = {},
    }, Registry)
end

---@param record table 已完成初代 Router 绑定的实例元数据。
---@return FlyWowHotUpgradeResult 同一逻辑实例只能初次登记一次。
function Registry:register(record)
    if self.targets[record.origin_service_handle] or record.candidate then
        return result.failure("HU_DUPLICATE_SERVICE", record.origin_service_handle)
    end
    self.targets[record.origin_service_handle] = record
    return result.success()
end

---@param origin_service_handle integer 初代 Service handle 的稳定身份键，不是当前 RPC 目标。
---@param expected integer 切换前旧实例的 instance_handle。
---@param record table 已就绪且已切换 Router 的候选元数据。
---@return FlyWowHotUpgradeResult 发布后仅保留新当前实例，旧实例由事务持有至退休。
function Registry:publish(origin_service_handle, expected, record)
    local current = self.targets[origin_service_handle]
    if not current or current.instance_handle ~= expected or record.origin_service_handle ~= origin_service_handle
        or record.instance_handle == expected or not record.candidate then
        return result.failure("HU_ROUTE_SWITCH_FAILED", "当前实例比较失败")
    end
    record.candidate = false
    self.targets[origin_service_handle] = record
    return result.success()
end

return M
