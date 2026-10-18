--- 注册 Service 的本地热更参与者；业务状态和 Adapter 永远留在本 Lua State。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local guard = require "flywow_hotupgrade_guard"
local modules = require "flywow_hotupgrade_module_patch"
local M = {}
local Runtime = {}
Runtime.__index = Runtime

-- 在本 Service State 同步执行 Adapter，并统一处理异常、拒绝和普通返回值。
local function hook(adapter, name, ...)
    if not adapter[name] then
        return result.success()
    end
    -- 回调是受信同步合同；不在裸 coroutine 中执行 Skynet API 后伪称已撤销其调度注册。
    local values = table.pack(pcall(adapter[name], ...))
    if not values[1] then
        return result.failure("HU_HOOK_FAILED", tostring(values[2]))
    end
    local value = values[2]
    if value == false or (name == "healthcheck" and value ~= true) then
        return result.failure("HU_HOOK_REJECTED", name)
    end
    -- export_state 返回业务数据而非 Hook 结果 record；状态可合法包含名为 ok 的字段。
    if name ~= "export_state" and type(value) == "table" and value.ok ~= nil then
        return value
    end
    return result.success({value = value})
end

--- 创建一个 Lua State 独占的 Runtime；Adapter 函数不进入控制面消息或审计记录。
---@param options table controller_handle、instance_handle、候选标记和本地 Adapter。
---@return table 当前 Service 独占 Runtime；内部 Guard、模块缓存和访客计数不跨 State 共享。
function M.new(options)
    -- Guard 统一用毫秒计时；Skynet 的 now/sleep 单位是 10 毫秒刻度。
    local clock =
    {
        now = function()
            return skynet.now() * 10
        end,
        sleep = function(ms)
            skynet.sleep(math.max(1, math.ceil(ms / 10)))
        end,
    }
    return setmetatable(
    {
        options = options,                                      -- 当前 instance_handle、controller_handle 与启动角色；创建后不变。
        adapter = options.adapter or {},                        -- 当前 Lua State 的业务回调，不跨 RPC 传递。
        guard = guard.new(clock),                               -- 本实例业务入口门禁与在途调用计数。
        modules = modules.new(),                                -- 本实例 package.loaded 上的可撤销模块 Stage。
        phase = options.candidate and "CANDIDATE" or "RUNNING", -- 本地热更状态机阶段。
        completed_sequence = 0,                                 -- 已完成 txn_id 尾号，拒绝该序号及更旧控制消息。
    }, Runtime)
end

--- 建立单个事务 owner 并拒绝已完成序号；candidate 首次加入事务时转交 Guard 所有权。
---@param request table 控制面请求，txn_id 后缀含单调序号。
---@return FlyWowHotUpgradeResult 重放、冲突事务或有效 owner 状态。
function Runtime:begin(request)
    local sequence = type(request.txn_id) == "string" and tonumber(request.txn_id:match(":(%d+)$"))
    if not sequence or sequence <= self.completed_sequence then
        return result.failure("HU_STALE_TRANSACTION", "过期事务序号")
    end
    if self.txn and self.txn ~= request.txn_id then
        return result.failure("HU_UPGRADE_BUSY", "实例已有升级")
    end
    -- 保留同一个 Guard 的 owner 约束，避免覆盖已有安全点后留下半个事务。
    if self.guard.owner and self.guard.owner ~= "candidate" and self.guard.owner ~= request.txn_id then
        return result.failure("HU_UPGRADE_BUSY", "安全点正被其它更新占有")
    end
    -- txn 直到 finish/abort 清理；Guard owner 与此处身份共同限定当前控制事务。
    self.txn = request.txn_id
    if self.guard.owner == "candidate" then
        self.guard.owner = request.txn_id
    end
    return result.success()
end

--- 取得安全点并等待活动业务处理排空；wait_idle 会 yield，超时仍保持暂停状态供协调方收敛。
---@param request table 含本次 txn_id 与毫秒 timeout_ms。
---@return FlyWowHotUpgradeResult 成功进入 QUIESCED；超时保留暂停状态，须由协调者恢复或收敛。
function Runtime:prepare(request)
    local began = self:begin(request)
    if not began.ok then
        return began
    end
    local paused = self.guard:prepare_upgrade(request.txn_id)
    if not paused.ok then
        return paused
    end
    -- 入口先关闭，再等已经接纳的业务调用和 Adapter 附加条件满足。
    self.phase = "QUIESCING"
    local waited = self.guard:wait_idle(request.txn_id, request.timeout_ms or 10000, self.adapter.can_upgrade)
    if waited.ok then
        self.phase = "QUIESCED"
    end
    return waited
end

--- 在安全点内暂存模块；失败时不修改正在运行的模块导出表。
---@param request table 含事务身份及本实例已声明模块的冻结 modules 数组。
---@return FlyWowHotUpgradeResult 暂存句柄只留在本 State，不暴露给调用方。
function Runtime:stage(request)
    if self.options.candidate then
        return result.failure("HU_PHASE_INVALID", "候选已由冻结源码初始化，不执行模块 Stage")
    end
    if self.phase ~= "QUIESCED" or self.guard.owner ~= request.txn_id then
        return result.failure("HU_SAFEPOINT_REQUIRED", "暂存需要已取得安全点")
    end
    local began = self:begin(request)
    if not began.ok then
        return began
    end
    if self.stage_data then
        return result.success()
    end
    -- 受信模块只能声明代码和常量；Stage 不安装线上导出，也不接管业务状态。
    local staged = self.modules:stage(request.modules or {})
    if not staged.ok then
        return staged
    end
    -- Stage 只在本 Lua State 保存，可恢复的旧导出不经 RPC 或控制面持有。
    self.stage_data = staged.stage
    return result.success()
end

--- 在 Guard 已静止时调用 Service 自己的状态交接导出回调。
---@param request table 当前事务上下文。
---@return FlyWowHotUpgradeResult 交接值由 Service 定义，必须可经 Skynet 消息传递。
function Runtime:export(request)
    if self.phase ~= "QUIESCED" or self.guard.active > 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "状态仍可能变化")
    end
    local exported = hook(self.adapter, "export_state", request)
    if not exported.ok then
        return exported
    end
    return exported
end

--- 候选实例接收 Service 自己定义的交接数据并重建派生资源。
---@param request table 含事务身份和 Service 导出的 state。
---@return FlyWowHotUpgradeResult 导入或重建失败会使候选不能 READY。
function Runtime:import(request)
    if not self.options.candidate then
        return result.failure("HU_PHASE_INVALID", "只有未发布候选可以接收状态")
    end
    local began = self:begin(request)
    if not began.ok then
        return began
    end
    local paused = self.guard:prepare_upgrade(request.txn_id)
    if not paused.ok then
        return paused
    end
    -- 先接管显式状态，再检查候选安全条件；控制面不必再发一次 prepare RPC。
    local imported = hook(self.adapter, "import_state", request.state, request)
    if not imported.ok then
        return imported
    end
    self.phase = "QUIESCING"
    local waited = self.guard:wait_idle(request.txn_id, request.timeout_ms or 10000, self.adapter.can_upgrade)
    if waited.ok then
        self.phase = "QUIESCED"
    end
    return waited
end

--- 提交暂存模块；必须持有安全点且不允许任何活动业务调用。
---@param request table 当前事务身份。
---@return FlyWowHotUpgradeResult postcheck 失败时恢复导出表；检查必须无副作用。
function Runtime:activate(request)
    if self.options.candidate then
        return result.failure("HU_PHASE_INVALID", "Service 替换不执行模块 Activate")
    end
    if self.phase == "ACTIVATED" then
        return result.success()
    end
    if self.guard.owner ~= request.txn_id or self.guard.active ~= 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "激活需要持有安全点")
    end
    if not self.stage_data then
        return result.failure("HU_PHASE_INVALID", "尚未完成 Stage")
    end
    local committed = self.modules:commit(self.stage_data, self.adapter.postcheck)
    if not committed.ok then
        return committed
    end
    self.phase = "ACTIVATED"
    return result.success()
end

--- 发布决定前恢复模块；恢复失败时保持暂停并标记 RECOVERY_REQUIRED。
---@param request table 当前事务身份；txn_id 后缀含单调序号。
---@return FlyWowHotUpgradeResult 完成恢复后才释放 Guard 和 Runtime 事务 owner。
function Runtime:abort(request)
    if self.phase == "RUNNING" and self.completed_txn == request.txn_id then
        return result.success()
    end
    -- 撤销模块导出；失败时保留暂停状态，不推定业务外部资源已恢复。
    if self.stage_data then
        local aborted = self.modules:abort(self.stage_data)
        if not aborted.ok then
            self.phase = "RECOVERY_REQUIRED"
            return aborted
        end
    end

    -- 模块恢复后才释放安全点并清除本地事务 owner。
    local resumed = self.guard:resume(request.txn_id)
    if not resumed.ok then
        self.phase = "RECOVERY_REQUIRED"
        return resumed
    end
    self.completed_sequence = tonumber(request.txn_id:match(":(%d+)$"))
    self.completed_txn = request.txn_id
    self.txn = nil
    self.stage_data = nil
    self.phase = self.options.candidate and "CANDIDATE" or "RUNNING"
    return result.success()
end

--- 发布决定后同步完成本地清理与开放，避免 resume/finish 两次 RPC 之间留下半完成状态。
---@param request table 当前事务身份；txn_id 后缀含单调序号。
---@return FlyWowHotUpgradeResult 仅接受已激活的原地更新或已就绪的候选。
function Runtime:finish(request)
    if self.guard.owner ~= request.txn_id or self.guard.active ~= 0
        or (self.phase ~= "ACTIVATED" and not (self.options.candidate and self.phase == "QUIESCED")) then
        return result.failure("HU_PHASE_INVALID", "参与者尚未完成发布准备")
    end
    if self.stage_data then
        local finished = self.modules:finish(self.stage_data)
        if not finished.ok then return finished end
    end
    local resumed = self.guard:resume(request.txn_id)
    if not resumed.ok then return resumed end
    self.options.candidate = false
    self.phase = "RUNNING"
    self.completed_sequence, self.completed_txn = tonumber(request.txn_id:match(":(%d+)$")), request.txn_id
    self.txn, self.stage_data = nil, nil
    return result.success()
end

--- 只接受稳定 Router 的调用；Guard:run 在业务结束后释放在途计数。
---@param request table 序列化业务 command/payload 和目标实例身份。
---@param source integer 注册时指定的稳定 Router Service handle。
---@return FlyWowHotUpgradeResult 业务 Adapter 返回值或可识别失败；调用期间可能 yield。
function Runtime:invoke(request, source)
    if source ~= self.options.router_handle then
        return result.failure("HU_UNAUTHORIZED", "业务请求必须经过稳定 Router")
    end
    return self.guard:run(self.adapter.dispatch, request.command, request.payload)
end

--- 校验实例身份、控制来源和事务序号后分派内部命令；普通业务调用走 invoke。
---@param command string 专用 hotupgrade 协议命令。
---@param request table 该命令的序列化 record。
---@param source integer Skynet 消息来源 handle。
---@return FlyWowHotUpgradeResult 稳定协议结果；RPC handler 捕获未预期异常。
function Runtime:control(command, request, source)
    if request.instance_handle ~= self.options.instance_handle then
        return result.failure("HU_STALE_INSTANCE", "实例身份不匹配")
    end

    -- invoke 由已经授权的业务 Service 发起，不属于控制面专属命令。
    if command == "invoke" then
        return self:invoke(request, source)
    end
    if source ~= self.options.controller_handle then
        return result.failure("HU_UNAUTHORIZED", "控制来源不匹配")
    end
    if self.completed_txn == request.txn_id and (command == "abort" or command == "finish") then
        return result.success()
    end
    local sequence = type(request.txn_id) == "string" and tonumber(request.txn_id:match(":(%d+)$"))
    if not sequence or sequence <= self.completed_sequence then
        return result.failure("HU_STALE_TRANSACTION", "过期控制消息")
    end
    if self.txn and request.txn_id ~= self.txn then
        return result.failure("HU_STALE_TRANSACTION", "事务不匹配")
    end
    if command == "health" then
        if not self.options.candidate or self.phase ~= "QUIESCED" or self.guard.owner ~= request.txn_id then
            return result.failure("HU_SAFEPOINT_REQUIRED", "候选状态尚未准备完成")
        end
        return hook(self.adapter, "healthcheck", request)
    end
    if command == "retire" then
        if self.guard.active ~= 0 or self.guard.owner ~= request.txn_id or self.phase ~= "QUIESCED" then
            return result.failure("HU_RETIRE_BLOCKED", "旧实例未在本事务安全点排空")
        end
        -- 成功仅确认下一 tick 退出已安排；不代表业务外部资源已释放。
        skynet.timeout(1, skynet.exit)
        return result.success()
    end
    local allowed = {prepare = true, stage = true, export = true, import = true,
        activate = true, abort = true, finish = true}
    if not allowed[command] then
        return result.failure("HU_UNKNOWN_COMMAND", tostring(command))
    end
    return self[command](self, request)
end

return M
