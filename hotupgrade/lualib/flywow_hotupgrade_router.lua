--- origin_service_handle 到当前 Service 实例的稳定路由表；暂停期间拒绝新请求，不缓存业务 payload。
local result = require "flywow_hotupgrade_error"
local skynet = require "skynet"
local M = {}
local Router = {}
Router.__index = Router

---@return table 由 Router Service 单独持有的路由表。
function M.new()
    return setmetatable(
    {
        -- Router Service 独占；每项保存当前目标、暂停 owner 和 Router 侧在途计数。
        routes = {},
    }, Router)
end

---@param origin_service_handle integer 初代 Service handle 的稳定路由键，不是当前 RPC 目标。
---@param record table 当前或候选实例记录。
---@return FlyWowHotUpgradeResult
function Router:bind(origin_service_handle, record)
    local route = self.routes[origin_service_handle]
    if route and route.record.instance_handle ~= record.instance_handle then
        return result.failure("HU_ROUTE_CONFLICT", origin_service_handle)
    end

    -- Router Service 持有到 RPC 返回前的计数，pause 用它排空已转发但尚未返回的调用。
    self.routes[origin_service_handle] =
    {
        record = record, -- 当前转发目标；切换时整体替换此字段。
        paused = false,  -- true 时拒绝新业务请求。
        txn_id = nil,    -- 暂停状态 owner；resume/abort 必须匹配。
        active = 0,      -- 已接纳且尚未收到目标 RPC 返回的请求数。
    }

    return result.success()
end

---@param origin_service_handle integer 初代 Service handle 的稳定路由键，不是当前 RPC 目标。
---@param txn_id string 当前控制事务身份。
---@return FlyWowHotUpgradeResult 暂停后不接收新请求。
function Router:pause(origin_service_handle, txn_id)
    local route = self.routes[origin_service_handle]
    if not route or (route.paused and route.txn_id ~= txn_id) then
        return result.failure("HU_ROUTE_BUSY", origin_service_handle)
    end

    route.paused, route.txn_id = true, txn_id

    return result.success()
end

---@param origin_service_handle integer 初代 Service handle 的稳定路由键，不是当前 RPC 目标。
---@param txn_id string 当前控制事务身份。
---@param expected integer 预期旧实例的 instance_handle。
---@param record table 已完成初始化和健康检查的候选实例。
---@return FlyWowHotUpgradeResult 以旧实例身份比较结果切换当前实例。
function Router:switch(origin_service_handle, txn_id, expected, record)
    local route = self.routes[origin_service_handle]
    if not route or not route.paused or route.txn_id ~= txn_id
        or route.record.instance_handle ~= expected or record.instance_handle == expected then
        return result.failure("HU_ROUTE_SWITCH_FAILED", origin_service_handle)
    end

    route.record = record

    return result.success()
end

---@param origin_service_handle integer 初代 Service handle 的稳定路由键，不是当前 RPC 目标。
---@param txn_id string 当前控制事务身份。
---@return FlyWowHotUpgradeResult 恢复该 origin_service_handle 对应请求的转发。
function Router:resume(origin_service_handle, txn_id)
    local route = self.routes[origin_service_handle]
    if not route or not route.paused or route.txn_id ~= txn_id then
        return result.failure("HU_ROUTE_RESUME_FAILED", origin_service_handle)
    end

    route.paused, route.txn_id = false, nil

    return result.success()
end

---@param origin_service_handle integer 初代 Service handle 的稳定路由键，不是当前 RPC 目标。
---@param txn_id string 当前控制事务身份。
---@return FlyWowHotUpgradeResult 取消未提交切换并恢复原路由。
function Router:abort(origin_service_handle, txn_id)
    local route = self.routes[origin_service_handle]
    if not route or not route.paused or route.txn_id ~= txn_id then
        return result.failure("HU_ROUTE_ABORT_FAILED", origin_service_handle)
    end

    route.paused, route.txn_id = false, nil

    return result.success()
end

---@param origin_service_handle integer 初代 Service handle 的稳定路由键，不是当前 RPC 目标。
---@param command string 业务命令。
---@param payload any 业务 record。
---@param source integer Router 调用方；保留为诊断字段。
---@return FlyWowHotUpgradeResult 目标忙、失效或目标 Service 返回的业务结果。
function Router:request(origin_service_handle, command, payload, source)
    local route = self.routes[origin_service_handle]
    if not route then
        return result.failure("HU_TARGET_MISSING", origin_service_handle)
    end
    if route.paused then
        return result.failure("HU_ROUTE_PAUSED", origin_service_handle)
    end

    -- 内层转发不设本地超时，否则远端仍执行时会提前递减计数并误报排空。
    route.active = route.active + 1
    local ok, called = pcall(skynet.call, route.record.instance_handle, "hotupgrade", "invoke",
        {instance_handle = route.record.instance_handle,
            command = command, payload = payload})
    route.active = route.active - 1
    if not ok then
        return result.failure("HU_RPC_FAILED", tostring(called))
    end
    if not called.ok then
        called.source = source
    end

    return called
end

return M
