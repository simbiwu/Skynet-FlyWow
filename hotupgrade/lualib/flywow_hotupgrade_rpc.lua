--- 专用控制协议的有界超时调用；超时不取消远端，也不强杀等待响应的协程。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local M = {}
local active = 0
local maximum = 128
local defined = false

local function define_protocol()
    if defined then return end
    skynet.register_protocol(
    {
        name = "hotupgrade", id = 20,
        pack = skynet.pack, unpack = skynet.unpack,
    })
    defined = true
end

---@alias flywow_hotupgrade_control_command 'register'|'resolve'|'switch'|'release_ref'|'bootstrap'|'validate'|'apply'|'dry_run'|'history'|'metrics'|'rollback'|'prepare'|'stage'|'export'|'import'|'activate'|'resume'|'abort'|'finish'|'retire'|'status'|'health'|'prepare_retire'|'cancel_retire'|'can_retire'|'begin_drain'|'grant'|'invoke'|'visitor_barrier'
---@class flywow_hotupgrade_control_request
---@field txn_id string 控制面生成的事务身份
---@field generation integer 目标实例代际，防止地址复用
---@field instance_id string 注册时生成的随机实例身份；生命周期内不变，防止 handle 复用
---@field sequence integer 控制面持久化的单调事务序号；拒绝迟到控制消息
---@field timeout_ms? integer 毫秒
---@field patch? table 已校验且冻结的 Patch 数据

--- 可 yield；在途协程仍占容量直到真正完成，避免超时导致无限泄漏。
---@param address integer 目标 Service handle
---@param command flywow_hotupgrade_control_command 控制消息命令
---@param request table request record，不含函数
---@param timeout_ms integer 毫秒
---@return flywow_hotupgrade_result
function M.call(address, command, request, timeout_ms)
    define_protocol()
    if active >= maximum then return result.failure("HU_RPC_LIMIT", "控制请求在途超限") end
    active = active + 1
    local caller = coroutine.running()
    local pending = true
    local answer
    skynet.fork(function()
        local ok, value = pcall(skynet.call, address, "hotupgrade", command, request)
        active = active - 1
        if pending then
            answer = ok and value or result.failure("HU_RPC_FAILED", tostring(value))
            pending = false
            skynet.wakeup(caller)
        end
    end)
    skynet.timeout(math.max(1, math.ceil(timeout_ms / 10)), function()
        if pending then
            pending = false
            answer = result.failure("HU_RPC_TIMEOUT", "目标操作可能仍在执行")
            skynet.wakeup(caller)
        end
    end)
    if pending then skynet.wait(caller) end
    return answer
end

--- 每个 State 注册一次独立协议，不覆盖业务 lua dispatch；source 由调用者验证。
---@param handler function command/request/source -> result，可能 yield
function M.install(handler)
    define_protocol()
    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local ok, answer = pcall(handler, command, request, source)
        if not ok then answer = result.failure("HU_CONTROL_FAILED", tostring(answer)) end
        if session ~= 0 then skynet.retpack(answer) end
    end)
end

return M
