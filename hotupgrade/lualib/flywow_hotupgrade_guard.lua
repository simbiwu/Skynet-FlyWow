--- 当前 Service 的事务安全点；暂停阻止新任务，已进入任务自然排空。
local hotupgrade_result = require "flywow_hotupgrade_error"
local M = {}
local Guard = {}
Guard.__index = Guard

---@param clock table now/sleep 适配器；now 返回毫秒，sleep 接收毫秒且可能 yield。
---@return table 当前 Lua State 独占的 Guard
function M.new(clock)
    return setmetatable({
        clock = clock, -- 当前 Service 的毫秒时钟适配器；sleep 可 yield。
        active = 0,    -- 已通过 enter 且尚未 leave 的业务调用数。
        owner = nil,   -- 暂停入口的事务身份；非 nil 时拒绝新调用。
    }, Guard)
end

---@return FlyWowHotUpgradeResult
function Guard:enter()
    if self.owner then
        return hotupgrade_result.failure("HU_UPGRADING", "入口已暂停")
    end

    self.active = self.active + 1
    return hotupgrade_result.success()
end

---@return FlyWowHotUpgradeResult
function Guard:leave()
    if self.active == 0 then
        return hotupgrade_result.failure("HU_GUARD_UNBALANCED", "没有已进入事务")
    end

    self.active = self.active - 1
    return hotupgrade_result.success()
end

--- handler 可 yield；异常也释放计数。转发未知签名时固定参数与 nil 数量。
---@param fn function 业务处理函数；可 yield，异常会转成 HU_HANDLER_FAILED。
---@param ... any 仅在本 Service 调用栈内转发的参数，保留中间 nil。
---@return FlyWowHotUpgradeResult protected_call_results 保留函数返回值数量；每个成功 enter 都在返回前 leave。
function Guard:run(fn, ...)
    local entered = self:enter()
    if not entered.ok then
        return entered
    end

    local protected_call_results = table.pack(pcall(fn, ...))
    self:leave()
    if not protected_call_results[1] then
        return hotupgrade_result.failure("HU_HANDLER_FAILED", tostring(protected_call_results[2]))
    end

    return hotupgrade_result.success({values = table.pack(table.unpack(protected_call_results, 2, protected_call_results.n))})
end

---@param batch_id string|table 当前批次身份
---@return FlyWowHotUpgradeResult
function Guard:prepare_upgrade(batch_id)
    if self.owner and self.owner ~= batch_id then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "另一个批次占有安全点")
    end

    self.owner = batch_id
    return hotupgrade_result.success()
end

--- 可 yield；每次醒来重新核对 owner，超时不放行新请求。
---@param batch_id string|table 已通过 prepare_upgrade 获取的唯一安全点 owner。
---@param timeout_ms integer 最大等待毫秒数；到期时仍保持入口暂停，不自动释放 owner。
---@param before_upgrade? function Guard 暂停新业务且在途调用归零后检查；未放行会继续等待至超时，异常返回 HU_HOOK_FAILED。必须同步只读，不得 yield。
---@return FlyWowHotUpgradeResult
function Guard:wait_idle(batch_id, timeout_ms, before_upgrade)
    local deadline = self.clock.now() + timeout_ms
    while self.owner == batch_id do
        if self.active == 0 then
            if not before_upgrade then
                return hotupgrade_result.success()
            end

            local ok, verdict = pcall(before_upgrade)
            if not ok then
                return hotupgrade_result.failure("HU_HOOK_FAILED", tostring(verdict))
            end

            if verdict == true or (type(verdict) == "table" and verdict.ok == true) then
                return hotupgrade_result.success()
            end
        end

        if self.clock.now() >= deadline then
            return hotupgrade_result.failure("HU_SAFEPOINT_TIMEOUT", "业务未在批次期限内排空")
        end

        self.clock.sleep(10)
    end

    return hotupgrade_result.failure("HU_STALE_TRANSACTION", "批次安全点 owner 已变化")
end

---@param batch_id string|table owner
---@return FlyWowHotUpgradeResult
function Guard:resume(batch_id)
    if self.owner and self.owner ~= batch_id then
        return hotupgrade_result.failure("HU_STALE_TRANSACTION", "不能释放其它批次的安全点")
    end

    self.owner = nil
    return hotupgrade_result.success()
end

return M
