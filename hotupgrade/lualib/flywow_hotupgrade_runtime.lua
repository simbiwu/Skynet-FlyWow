--- 注册 Service 的本地热更参与者；业务状态和 Adapter 永远留在本 Lua State。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local guard = require "flywow_hotupgrade_guard"
local modules = require "flywow_hotupgrade_module_patch"
local config = require "flywow_hotupgrade_config"
local snapshot = require "flywow_hotupgrade_snapshot"
local patch_module = require "flywow_hotupgrade_patch"
local M = {}
local Runtime = {}
Runtime.__index = Runtime

-- 在本 Service State 同步执行 Adapter，并统一处理异常、拒绝和普通返回值。
local function hook(adapter, name, ...)
    if not adapter[name] then
        return result.success()
    end
    local executed = result.execute(adapter[name], 1000000, ...)
    if not executed.ok then
        return executed
    end
    local value = executed.values[1]
    if value == false then
        return result.failure("HU_HOOK_REJECTED", name)
    end
    if type(value) == "table" and value.ok ~= nil then
        return value
    end
    return result.success({value = value})
end

--- 创建一个 Lua State 独占的 Runtime；Adapter 函数不进入控制面消息或审计记录。
---@param options table controller、实例/代际身份、版本、候选标记和本地 Adapter。
---@return table 当前 Service 独占 Runtime；内部 Guard、模块缓存和访客计数不跨 State 共享。
function M.new(options)
    -- stable 的 table 身份只在这个 Runtime 和 Lua State 内延续，不作为跨 Service 状态迁移。
    local stable = {}
    -- Guard 统一用毫秒计时；Skynet 的 now/sleep 单位是 10 毫秒刻度。
    local clock =
    {
        now = function() return skynet.now() * 10 end,
        sleep = function(ms) skynet.sleep(math.max(1, math.ceil(ms / 10))) end,
    }
    return setmetatable(
    {
        options = options, adapter = options.adapter or {},
        guard = guard.new(clock), stable = stable,
        modules = modules.new({stable = stable, trusted = options.trusted_modules}),
        config = config.new(), version = options.code_version,
        phase = options.candidate and "CANDIDATE" or "RUNNING", completed_sequence = 0,
        visitors = {}, visitor_active = {},
    }, Runtime)
end

--- 建立单个事务 owner 并拒绝已完成序号；candidate 首次加入事务时转交 Guard 所有权。
---@param request table 控制面请求，必须含 txn_id 和单调 sequence。
---@return flywow_hotupgrade_result 重放、冲突事务或有效 owner 状态。
function Runtime:begin(request)
    if type(request.sequence) ~= "number" or request.sequence <= self.completed_sequence then
        return result.failure("HU_STALE_TRANSACTION", "过期事务序号")
    end
    if self.txn and self.txn ~= request.txn_id then
        return result.failure("HU_UPGRADE_BUSY", "实例已有升级")
    end
    self.txn = request.txn_id
    self.sequence = request.sequence
    if self.guard.owner == "candidate" then
        self.guard.owner = request.txn_id
    end
    return result.success()
end

--- 取得安全点并等待活动业务处理排空；wait_idle 会 yield，超时仍保持暂停状态供协调方收敛。
---@param request table 含本次 txn_id 与毫秒 timeout_ms。
---@return flywow_hotupgrade_result 成功进入 QUIESCED；超时保留暂停状态，须由协调者恢复或收敛。
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

-- 暂存适用于当前 service_type 的配置工厂；激活前不替换线上快照。
local function stage_configs(runtime, patch, txn_id)
    for _, entry in ipairs(patch.configs or {}) do
        if not entry.service_type or entry.service_type == runtime.options.service_type then
            local loaded = patch_module.load_pure(entry.source)
            if not loaded.ok then
                return loaded
            end
            local _, current_version = runtime.config:get(entry.name)
            local staged = runtime.config:stage(entry.name, loaded.value, (current_version or 0) + 1, txn_id)
            if not staged.ok then
                return staged
            end
        end
    end
    return result.success()
end

--- 在安全点内暂存模块和配置；失败时撤销本次候选，不修改正在运行的配置快照。
---@param request table 含事务身份及控制面已校验/冻结的 Patch record。
---@return flywow_hotupgrade_result 暂存句柄只留在本 State，不暴露给调用方。
function Runtime:stage(request)
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
    -- 模块引擎只构建隔离的导出表；此时 package.loaded、线上配置与 stable 状态仍不可写。
    local staged = self.modules:stage(request.patch.modules or {})
    if not staged.ok then
        return staged
    end
    self.stage_data = staged.stage
    local configs = stage_configs(self, request.patch, request.txn_id)
    if not configs.ok then
        self.modules:abort(self.stage_data)
        self.config:abort(request.txn_id)
    end
    return configs
end

--- 在 Guard 已静止时同步导出业务状态，并复制为无共享引用的可迁移 Snapshot。
---@param request table 当前事务上下文；Adapter 只应返回可序列化业务数据。
---@return flywow_hotupgrade_result 导出副本或稳定的类型/容量错误。
function Runtime:export(request)
    if self.phase ~= "QUIESCED" or self.guard.active > 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "状态仍可能变化")
    end
    local exported = hook(self.adapter, "export_state", request)
    if not exported.ok then
        return exported
    end
    return snapshot.clone(exported.value)
end

--- 候选实例导入独占 Snapshot 副本并重建派生资源；此时候选尚未接收生产流量。
---@param request table 含事务身份、Snapshot 和目标版本。
---@return flywow_hotupgrade_result 导入或重建失败会使候选不能 READY。
function Runtime:import(request)
    local began = self:begin(request)
    if not began.ok then
        return began
    end
    local paused = self.guard:prepare_upgrade(request.txn_id)
    if not paused.ok then
        return paused
    end
    local cloned = snapshot.clone(request.snapshot)
    if not cloned.ok then
        return cloned
    end
    local imported = hook(self.adapter, "import_state", cloned.value, request)
    if not imported.ok then
        return imported
    end
    return hook(self.adapter, "rebuild_runtime", request)
end

--- 仅在持有安全点且活动调用为零时提交配置与模块，再切换当前代码版本。
--- 提交暂存配置和模块并更新代码版本；必须持有安全点且不允许任何活动业务调用。
---@param request table 当前事务身份和提交后的 code_version。
---@return flywow_hotupgrade_result postcheck 失败时恢复配置与导出表。
function Runtime:activate(request)
    if self.phase == "ACTIVATED" then
        return result.success()
    end
    if self.guard.owner ~= request.txn_id or self.guard.active ~= 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "激活需要持有安全点")
    end
    if not self.stage_data then
        return result.failure("HU_PHASE_INVALID", "尚未完成 Stage")
    end
    -- 配置先保存 undo 并激活；模块提交中的 postcheck 失败时据此精确撤销。
    local configs = self.config:activate(request.txn_id)
    if not configs.ok then
        return configs
    end
    local committed = self.modules:commit(self.stage_data, self.adapter.postcheck)
    if not committed.ok then
        self.config:abort(request.txn_id)
        return committed
    end
    self.old_version = self.version
    self.version = request.new_code_version or self.version
    self.phase = "ACTIVATED"
    return result.success()
end

--- 发布决定前恢复模块、配置和业务 Adapter；恢复失败时保持暂停并标记 RECOVERY_REQUIRED。
---@param request table 当前事务身份与 sequence。
---@return flywow_hotupgrade_result 完成恢复后才释放 Guard 和 Runtime 事务 owner。
function Runtime:abort(request)
    if self.phase == "RUNNING" and self.completed_txn == request.txn_id then
        return result.success()
    end
    if self.stage_data then
        self.modules:abort(self.stage_data)
    end
    self.config:abort(request.txn_id)
    local restored = hook(self.adapter, "on_abort", request)
    if not restored.ok then
        self.phase = "RECOVERY_REQUIRED"
        return result.failure("HU_ABORT_FAILED", restored.message)
    end
    self.version = self.old_version or self.version
    self.guard:resume(request.txn_id)
    self.completed_sequence = request.sequence
    self.completed_txn = request.txn_id
    self.txn = nil
    self.stage_data = nil
    self.old_version = nil
    self.phase = self.options.candidate and "CANDIDATE" or "RUNNING"
    return result.success()
end

--- 发布成功后释放可回滚快照，并记录已完成事务序号以拒绝迟到控制消息。
---@param request table 当前事务身份与 sequence。
---@return flywow_hotupgrade_result 本地清理完成。
function Runtime:finish(request)
    self.config:finish(request.txn_id)
    self.completed_sequence = request.sequence
    self.completed_txn = request.txn_id
    self.txn = nil
    self.stage_data = nil
    self.old_version = nil
    return result.success()
end

local hooks = {health = "healthcheck", prepare_retire = "prepare_retire",
    cancel_retire = "cancel_retire", begin_drain = "begin_drain", can_retire = "can_retire"}

--- 校验访问者和代际后计入活动调用；Guard:run 在业务处理结束后释放计数，供安全点排空。
---@param request table 序列化业务 command/payload 和目标 generation。
---@param source integer 已由控制面授权的调用 Service handle。
---@return flywow_hotupgrade_result 业务 Adapter 返回值或可识别失败；调用期间可能 yield。
function Runtime:invoke(request, source)
    if not self.visitors[source] then
        return result.failure("HU_UNAUTHORIZED", "访问者未绑定")
    end
    if request.generation ~= self.options.generation then
        return result.failure("HU_STALE_GENERATION", "调用代际不匹配")
    end
    -- 该计数独立于 Guard：释放引用时的同源屏障要等此访问者已接纳调用返回。
    self.visitor_active[source] = (self.visitor_active[source] or 0) + 1
    local called = self.guard:run(self.adapter.dispatch, request.command, request.payload)
    self.visitor_active[source] = self.visitor_active[source] - 1
    return called
end

--- 等待指定访问者已进入的调用完成；循环 sleep 会 yield，供旧路由排空后再退休实例。
---@param request table 当前实例的屏障请求。
---@param source integer 要等待的已授权访问者 handle。
---@return flywow_hotupgrade_result 访问者调用排空后返回成功。
function Runtime:visitor_barrier(request, source)
    if not self.visitors[source] then
        return result.failure("HU_UNAUTHORIZED", "访问者未绑定")
    end
    while (self.visitor_active[source] or 0) > 0 do
        skynet.sleep(1)
    end
    return result.success()
end

--- 校验实例身份、控制来源和事务序号后分派内部命令；普通业务调用走 invoke。
---@param command string 专用 hotupgrade 协议命令。
---@param request table 该命令的序列化 record。
---@param source integer Skynet 消息来源 handle。
---@return flywow_hotupgrade_result 稳定协议结果；RPC handler 捕获未预期异常。
function Runtime:control(command, request, source)
    if request.instance_id ~= self.options.instance_id then
        return result.failure("HU_STALE_INSTANCE", "实例身份不匹配")
    end
    -- 两个 visitor 命令由已经授权的业务 Service 发起，不属于控制面专属命令。
    if command == "invoke" then
        return self:invoke(request, source)
    end
    if command == "visitor_barrier" then
        return self:visitor_barrier(request, source)
    end
    if source ~= self.options.controller then
        return result.failure("HU_UNAUTHORIZED", "控制来源不匹配")
    end
    if command == "grant" then
        self.visitors[request.visitor] = true
        return result.success()
    end
    if request.generation ~= self.options.generation then
        return result.failure("HU_STALE_GENERATION", "实例代际不匹配")
    end
    if command == "status" then
        return result.success(
        {
            phase = self.phase,
            txn_id = self.txn,
            active = self.guard.active,
            code_version = self.version,
        })
    end
    if self.completed_txn == request.txn_id and (command == "abort" or command == "finish") then
        return result.success()
    end
    if type(request.sequence) ~= "number" or request.sequence <= self.completed_sequence then
        return result.failure("HU_STALE_TRANSACTION", "过期控制消息")
    end
    if self.txn and request.txn_id ~= self.txn then
        return result.failure("HU_STALE_TRANSACTION", "事务不匹配")
    end
    if command == "prepare_retire" then
        local began = self:begin(request)
        if not began.ok then
            return began
        end
    end
    if hooks[command] then
        return hook(self.adapter, hooks[command], request)
    end
    if command == "resume" then
        local resumed = self.guard:resume(request.txn_id)
        if not resumed.ok then
            return resumed
        end
        self.phase = "RUNNING"
        return hook(self.adapter, "on_resume", request)
    end
    if command == "retire" then
        if self.guard.active ~= 0 then
            return result.failure("HU_RETIRE_BLOCKED", "请求仍在执行")
        end
        local retired = hook(self.adapter, "retire", request)
        if retired.ok then
            skynet.timeout(1, skynet.exit)
        end
        return retired
    end
    local allowed = {prepare = true, stage = true, export = true, import = true,
        activate = true, abort = true, finish = true}
    if not allowed[command] then
        return result.failure("HU_UNKNOWN_COMMAND", tostring(command))
    end
    return self[command](self, request)
end

M.hook = hook
return M
