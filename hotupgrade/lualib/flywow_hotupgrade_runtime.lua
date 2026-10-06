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

local function hook(adapter, name, ...)
    if not adapter[name] then return result.success() end
    local executed = result.execute(adapter[name], 1000000, ...)
    if not executed.ok then return executed end
    local value = executed.values[1]
    if value == false then return result.failure("HU_HOOK_REJECTED", name) end
    if type(value) == "table" and value.ok ~= nil then return value end
    return result.success({value = value})
end

---@param options table controller/generation/adapter/code_version/candidate/dependencies
---@return table Service 内独占 Runtime
function M.new(options)
    local stable = {}
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

function Runtime:begin(request)
    if type(request.sequence) ~= "number" or request.sequence <= self.completed_sequence then
        return result.failure("HU_STALE_TRANSACTION", "过期事务序号")
    end
    if self.txn and self.txn ~= request.txn_id then
        return result.failure("HU_UPGRADE_BUSY", "实例已有升级")
    end
    self.txn = request.txn_id
    self.sequence = request.sequence
    if self.guard.owner == "candidate" then self.guard.owner = request.txn_id end
    return result.success()
end

function Runtime:prepare(request)
    local began = self:begin(request)
    if not began.ok then return began end
    local paused = self.guard:prepare_upgrade(request.txn_id)
    if not paused.ok then return paused end
    self.phase = "QUIESCING"
    local waited = self.guard:wait_idle(request.txn_id, request.timeout_ms or 10000, self.adapter.can_upgrade)
    if waited.ok then self.phase = "QUIESCED" end
    return waited
end

local function stage_configs(runtime, patch, txn_id)
    for _, entry in ipairs(patch.configs or {}) do
        if not entry.service_type or entry.service_type == runtime.options.service_type then
            local loaded = patch_module.load_pure(entry.source)
            if not loaded.ok then return loaded end
            local _, current_version = runtime.config:get(entry.name)
            local staged = runtime.config:stage(entry.name, loaded.value, (current_version or 0) + 1, txn_id)
            if not staged.ok then return staged end
        end
    end
    return result.success()
end

function Runtime:stage(request)
    if self.phase ~= "QUIESCED" or self.guard.owner ~= request.txn_id then
        return result.failure("HU_SAFEPOINT_REQUIRED", "暂存需要已取得安全点")
    end
    local began = self:begin(request)
    if not began.ok then return began end
    if self.stage_data then return result.success() end
    local staged = self.modules:stage(request.patch.modules or {})
    if not staged.ok then return staged end
    self.stage_data = staged.stage
    local configs = stage_configs(self, request.patch, request.txn_id)
    if not configs.ok then
        self.modules:abort(self.stage_data)
        self.config:abort(request.txn_id)
    end
    return configs
end

function Runtime:export(request)
    if self.phase ~= "QUIESCED" or self.guard.active > 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "状态仍可能变化")
    end
    local exported = hook(self.adapter, "export_state", request)
    if not exported.ok then return exported end
    return snapshot.clone(exported.value)
end

function Runtime:import(request)
    local began = self:begin(request)
    if not began.ok then return began end
    local paused = self.guard:prepare_upgrade(request.txn_id)
    if not paused.ok then return paused end
    local cloned = snapshot.clone(request.snapshot)
    if not cloned.ok then return cloned end
    local imported = hook(self.adapter, "import_state", cloned.value, request)
    if not imported.ok then return imported end
    return hook(self.adapter, "rebuild_runtime", request)
end

function Runtime:activate(request)
    if self.phase == "ACTIVATED" then return result.success() end
    if self.guard.owner ~= request.txn_id or self.guard.active ~= 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "激活需要持有安全点")
    end
    if not self.stage_data then return result.failure("HU_PHASE_INVALID", "尚未完成 Stage") end
    local configs = self.config:activate(request.txn_id)
    if not configs.ok then return configs end
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

function Runtime:abort(request)
    if self.phase == "RUNNING" and self.completed_txn == request.txn_id then return result.success() end
    if self.stage_data then self.modules:abort(self.stage_data) end
    self.config:abort(request.txn_id)
    local restored = hook(self.adapter, "on_abort", request)
    if not restored.ok then
        self.phase = "RECOVERY_REQUIRED"
        return result.failure("HU_ABORT_FAILED", restored.message)
    end
    self.version = self.old_version or self.version
    self.guard:resume(request.txn_id)
    self.completed_sequence, self.completed_txn = request.sequence, request.txn_id
    self.txn, self.stage_data, self.old_version = nil, nil, nil
    self.phase = self.options.candidate and "CANDIDATE" or "RUNNING"
    return result.success()
end

function Runtime:finish(request)
    self.config:finish(request.txn_id)
    self.completed_sequence, self.completed_txn = request.sequence, request.txn_id
    self.txn, self.stage_data, self.old_version = nil, nil, nil
    return result.success()
end

local hooks = {health = "healthcheck", prepare_retire = "prepare_retire",
    cancel_retire = "cancel_retire", begin_drain = "begin_drain", can_retire = "can_retire"}

function Runtime:invoke(request, source)
    if not self.visitors[source] then return result.failure("HU_UNAUTHORIZED", "访问者未绑定") end
    if request.generation ~= self.options.generation then
        return result.failure("HU_STALE_GENERATION", "调用代际不匹配")
    end
    self.visitor_active[source] = (self.visitor_active[source] or 0) + 1
    local called = self.guard:run(self.adapter.dispatch, request.command, request.payload)
    self.visitor_active[source] = self.visitor_active[source] - 1
    return called
end

function Runtime:visitor_barrier(request, source)
    if not self.visitors[source] then return result.failure("HU_UNAUTHORIZED", "访问者未绑定") end
    while (self.visitor_active[source] or 0) > 0 do skynet.sleep(1) end
    return result.success()
end

function Runtime:control(command, request, source)
    if request.instance_id ~= self.options.instance_id then
        return result.failure("HU_STALE_INSTANCE", "实例身份不匹配")
    end
    if command == "invoke" then return self:invoke(request, source) end
    if command == "visitor_barrier" then return self:visitor_barrier(request, source) end
    if source ~= self.options.controller then return result.failure("HU_UNAUTHORIZED", "控制来源不匹配") end
    if command == "grant" then
        self.visitors[request.visitor] = true
        return result.success()
    end
    if request.generation ~= self.options.generation then
        return result.failure("HU_STALE_GENERATION", "实例代际不匹配")
    end
    if command == "status" then
        return result.success({phase = self.phase, txn_id = self.txn, active = self.guard.active, code_version = self.version})
    end
    if self.completed_txn == request.txn_id and (command == "abort" or command == "finish") then
        return result.success()
    end
    if type(request.sequence) ~= "number" or request.sequence <= self.completed_sequence then
        return result.failure("HU_STALE_TRANSACTION", "过期控制消息")
    end
    if self.txn and request.txn_id ~= self.txn then return result.failure("HU_STALE_TRANSACTION", "事务不匹配") end
    if command == "prepare_retire" then
        local began = self:begin(request)
        if not began.ok then return began end
    end
    if hooks[command] then return hook(self.adapter, hooks[command], request) end
    if command == "resume" then
        local resumed = self.guard:resume(request.txn_id)
        if not resumed.ok then return resumed end
        self.phase = "RUNNING"
        return hook(self.adapter, "on_resume", request)
    end
    if command == "retire" then
        if self.guard.active ~= 0 then return result.failure("HU_RETIRE_BLOCKED", "请求仍在执行") end
        local retired = hook(self.adapter, "retire", request)
        if retired.ok then skynet.timeout(1, skynet.exit) end
        return retired
    end
    local allowed = {prepare = true, stage = true, export = true, import = true,
        activate = true, abort = true, finish = true}
    if not allowed[command] then return result.failure("HU_UNKNOWN_COMMAND", tostring(command)) end
    return self[command](self, request)
end

M.hook = hook
return M
