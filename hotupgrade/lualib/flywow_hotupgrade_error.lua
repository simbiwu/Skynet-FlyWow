--- 统一热更结果和受限执行；无 I/O，异常不作为跨模块控制协议。
local M = {}

---@class flywow_hotupgrade_result
---@field ok boolean 成功标记
---@field code? string 稳定 HU_ 错误码
---@field message? string 诊断文本
---@field step? string 失败步骤
---@field txn_id? string 事务身份

---@param code string 稳定错误码
---@param message string 诊断文本
---@param step? string 步骤
---@return flywow_hotupgrade_result
function M.failure(code, message, step)
    return {ok = false, code = code, message = message, step = step}
end

---@param data? table 调用者持有的结果
---@return flywow_hotupgrade_result
function M.success(data)
    data = data or {}
    data.ok = true
    return data
end

--- 同步执行不允许 yield 的 hook；捕获异常，并限制纯 Lua 指令预算。
--- 不支持抢占阻塞 C 调用；hook 必须遵守无外部副作用合同。
---@param fn function 待执行函数
---@param budget? integer Lua 指令预算
---@param ... any 基础设施转发的固定参数
---@return flywow_hotupgrade_result
function M.execute(fn, budget, ...)
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
---@return flywow_hotupgrade_result
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

    local ok, message = pcall(fn)
    debug.sethook(previous, mask, count)
    if not ok then return M.failure("HU_CREATE_FAILED", tostring(message)) end
    return M.success()
end

return M
