--- 当前 Service 的事务安全点；暂停阻止新任务，已进入任务自然排空。
local result = require "flywow_hotupgrade_error"
local M = {}
local Guard = {}
Guard.__index = Guard

---@param clock table now/sleep 适配器；now 返回毫秒，sleep 接收毫秒且可能 yield。
---@return table 当前 Lua State 独占的 Guard
function M.new(clock)
    return setmetatable({clock = clock, active = 0, owner = nil}, Guard)
end

---@return flywow_hotupgrade_result
function Guard:enter()
    if self.owner then
        return result.failure("HU_UPGRADING", "入口已暂停")
    end
    self.active = self.active + 1
    return result.success()
end

---@return flywow_hotupgrade_result
function Guard:leave()
    if self.active == 0 then
        return result.failure("HU_GUARD_UNBALANCED", "没有已进入事务")
    end
    self.active = self.active - 1
    return result.success()
end

--- handler 可 yield；异常也释放计数。转发未知签名时固定参数与 nil 数量。
---@param fn function 业务处理函数；可 yield，异常会转成 HU_HANDLER_FAILED。
---@param ... any 仅在本 Service 调用栈内转发的参数，保留中间 nil。
---@return flywow_hotupgrade_result values 保留函数返回值数量；每个成功 enter 都在返回前 leave。
function Guard:run(fn, ...)
    local entered = self:enter()
    if not entered.ok then
        return entered
    end

    local values = table.pack(pcall(fn, ...))
    self:leave()
    if not values[1] then
        return result.failure("HU_HANDLER_FAILED", tostring(values[2]))
    end
    return result.success({values = table.pack(table.unpack(values, 2, values.n))})
end

---@param txn_id string 当前升级身份
---@return flywow_hotupgrade_result
function Guard:prepare_upgrade(txn_id)
    if self.owner and self.owner ~= txn_id then
        return result.failure("HU_UPGRADE_BUSY", "另一个事务占有安全点")
    end
    self.owner = txn_id
    return result.success()
end

--- 可 yield；每次醒来重新核对 owner，超时不放行新请求。
---@param txn_id string 已通过 prepare_upgrade 获取的唯一安全点 owner。
---@param timeout_ms integer 最大等待毫秒数；到期时仍保持入口暂停，不自动释放 owner。
---@param can_upgrade? function 宿主附加同步安全条件；不得 yield，执行预算由 result.execute 限制。
---@return flywow_hotupgrade_result
function Guard:wait_idle(txn_id, timeout_ms, can_upgrade)
    local deadline = self.clock.now() + timeout_ms
    while self.owner == txn_id do
        if self.active == 0 then
            if not can_upgrade then
                return result.success()
            end
            local checked = result.execute(can_upgrade)
            if not checked.ok then
                return checked
            end
            local verdict = checked.values[1]
            if verdict == true or (type(verdict) == "table" and verdict.ok == true) then
                return result.success()
            end
        end
        if self.clock.now() >= deadline then
            return result.failure("HU_SAFEPOINT_TIMEOUT", "事务未排空")
        end
        self.clock.sleep(10)
    end
    return result.failure("HU_STALE_TRANSACTION", "安全点 owner 已变化")
end

---@param txn_id string owner
---@return flywow_hotupgrade_result
function Guard:resume(txn_id)
    if self.owner and self.owner ~= txn_id then
        return result.failure("HU_STALE_TRANSACTION", "不能释放其它事务安全点")
    end
    self.owner = nil
    return result.success()
end

return M
