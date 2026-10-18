--- 统一热更结果和受限执行；无 I/O，异常不作为跨模块控制协议。
local M = {}

---@class FlyWowHotUpgradeResult
---@field ok boolean 成功标记
---@field code? string 稳定 HU_ 错误码
---@field message? string 诊断文本
---@field step? string 失败步骤
---@field txn_id? string 事务身份

---@param code string 稳定错误码
---@param message string 诊断文本
---@param step? string 步骤
---@return FlyWowHotUpgradeResult
function M.failure(code, message, step)
    return {ok = false, code = code, message = message, step = step}
end

---@param data? table 调用者持有的结果
---@return FlyWowHotUpgradeResult
function M.success(data)
    data = data or {}
    data.ok = true
    return data
end

--- 仅用于无法访问 Skynet API 的纯 Lua 隔离文本执行，捕获异常并限制指令预算。
--- 不得包装业务或 Skynet 回调：拒绝 yield 不能撤销调用前已产生的外部注册。
---@param fn function 待执行函数
---@param budget? integer Lua 指令预算
---@param ... any 基础设施转发的固定参数
---@return FlyWowHotUpgradeResult
function M.execute(fn, budget, ...)
    -- 固定参数数量以保留中间 nil；独立协程让同步 hook 的 yield 可被检测。
    local args = table.pack(...)
    local co = coroutine.create(function()
        return fn(table.unpack(args, 1, args.n))
    end)
    local remaining = budget or 1000000
    debug.sethook(co, function()
        remaining = remaining - 1000
        if remaining <= 0 then
            error("instruction budget exhausted", 0)
        end
    end, "", 1000)

    -- 无论成功、异常还是预算超限都先卸载本次 hook，再判断协程是否试图 yield。
    local values = table.pack(coroutine.resume(co))
    debug.sethook(co)
    if not values[1] then
        return M.failure("HU_HOOK_FAILED", tostring(values[2]))
    end
    if coroutine.status(co) ~= "dead" then
        coroutine.close(co)
        return M.failure("HU_YIELD_FORBIDDEN", "同步阶段不能 yield")
    end
    return M.success({values = table.pack(table.unpack(values, 2, values.n))})
end

--- 候选初始化允许 Skynet yield，但限制当前协程的 Lua CPU 指令；不抢占 Native。
--- 保存并恢复已有 hook；预算耗尽先卸载自身，避免异常处理再次触发预算错误。
---@param fn function 初始化入口
---@param budget integer 整段初始化的指令上限
---@return FlyWowHotUpgradeResult
function M.initialize(fn, budget)
    local previous, mask, count = debug.gethook()
    local remaining = budget
    debug.sethook(function()
        remaining = remaining - 1000
        if remaining <= 0 then
            debug.sethook()
            error("candidate instruction budget exhausted", 0)
        end
    end, "", 1000)

    -- 初始化允许 yield；pcall 结束后立即恢复宿主原有 hook，避免泄漏预算状态。
    local ok, message = pcall(fn)
    debug.sethook(previous, mask, count)
    if not ok then
        return M.failure("HU_CREATE_FAILED", tostring(message))
    end
    return M.success()
end

return M
