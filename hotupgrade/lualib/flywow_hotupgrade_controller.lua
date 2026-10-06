--- 控制面 owner：冻结 Patch、协调参与者、持久化决定；正常请求不经过此模块。
local skynet = require "skynet"
require "skynet.manager"
local result = require "flywow_hotupgrade_error"
local registry_module = require "flywow_hotupgrade_registry"
local patch_module = require "flywow_hotupgrade_patch"
local history_module = require "flywow_hotupgrade_history"
local dependency = require "flywow_hotupgrade_dependency"
local migration = require "flywow_hotupgrade_migration"
local batch = require "flywow_hotupgrade_batch"
local transaction = require "flywow_hotupgrade_transaction"
local metrics = require "flywow_hotupgrade_metrics"
local rpc = require "flywow_hotupgrade_rpc"
local native = require "flywow_hotupgrade_native"
local M = {}
local Controller = {}
Controller.__index = Controller
local terminal_phases = {COMPLETED = true, ABORTED = true, PARTIAL = true, DRY_RUN_COMPLETED = true}

local function restore_journal_boundaries(controller)
    for _, record in pairs(controller.history.records) do
        controller.sequence = math.max(controller.sequence, record.sequence or 0)
        if not terminal_phases[record.phase] then
            controller.recovery_required = true
            for _, target in ipairs(record.participants or {}) do
                controller.locks[target.old.key] = record.txn_id
            end
        end
    end
end

---@param options table patch_root/history_path/admin_handles
---@return flywow_hotupgrade_result
function M.new(options)
    local opened = history_module.open(options.history_path)
    if not opened.ok then return opened end
    local controller = setmetatable(
    {
        options = options, registry = registry_module.new(), history = opened.history,
        metrics = metrics.new(options.metrics), sources = {}, locks = {}, transactions = {},
        bootstraps = {}, sequence = 0,
    }, Controller)
    restore_journal_boundaries(controller)
    return result.success({controller = controller})
end

function Controller:register(request, source)
    if request.address ~= source then return result.failure("HU_UNAUTHORIZED", "不能代其它实例注册") end
    request.modules = request.modules or {}
    local module_set = {}
    for _, name in ipairs(request.modules) do module_set[name] = true end
    request.modules = module_set
    local checked = self.registry:register(request)
    if not checked.ok then return checked end
    local caller = tostring(source) .. ":" .. request.generation
    self.sources[source] = {caller = caller, record = request}
    if request.candidate then return result.success() end
    local declared = self.registry:declare(caller, request.dependencies)
    if not declared.ok then return declared end
    if request.router_handle then
        local granted = self:grant(result.success({record = request}), request.router_handle)
        if not granted.ok then return granted end
        return rpc.call(request.router_handle, "bind", {key = request.key, record = request}, 10000)
    end
    return result.success()
end

function Controller:register_module(request, source)
    local caller = self.sources[source]
    if not caller or type(request.name) ~= "string" or request.name == "" then
        return result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未注册")
    end
    caller.record.modules[request.name] = true
    return result.success()
end

function Controller:grant(resolved, source)
    if not resolved.ok then return resolved end
    local granted = rpc.call(resolved.record.address, "grant",
        {generation = resolved.record.generation, instance_id = resolved.record.instance_id, visitor = source}, 10000)
    if not granted.ok then return granted end
    return resolved
end

function Controller:resolve(request, source)
    if type(request.ref_id) ~= "string" or #request.ref_id ~= 32 then
        return result.failure("HU_INVALID_REQUEST", "引用身份缺失")
    end
    local caller = self.sources[source]
    if not caller then return result.failure("HU_SERVICE_NOT_REGISTERED", "调用者未注册") end
    local granted = self:grant(self.registry:resolve(caller.caller, request.target), source)
    if not granted.ok then return granted end
    return self.registry:acquire(caller.caller, request.target, request.ref_id)
end

function Controller:release_ref(request, source)
    local caller = self.sources[source]
    if not caller then return result.failure("HU_SERVICE_NOT_REGISTERED", "调用者未注册") end
    return self.registry:release_binding(caller.caller, request.target, request.ref_id)
end

function Controller:switch(request, source)
    local caller = self.sources[source]
    if not caller then return result.failure("HU_SERVICE_NOT_REGISTERED", "调用者未注册") end
    return self:grant(self.registry:switch(caller.caller, request.target, request.can_switch), source)
end

local function current_records(controller, service_type)
    local records = {}
    for _, target in pairs(controller.registry.targets) do
        local instance = target.instances[target.current]
        if instance and instance.record.service_type == service_type then
            records[#records + 1] = instance.record
        end
    end
    return records
end

local function check_capability(record, spec)
    if type(spec.new_code_version) ~= "number" or spec.new_code_version % 1 ~= 0 then
        return result.failure("HU_INVALID_MANIFEST", "新代码版本必须为整数")
    end
    if spec.old_code_version and record.code_version ~= spec.old_code_version then
        return result.failure("HU_VERSION_MISMATCH", record.key)
    end
    if spec.mode == "module_patch" then return result.success() end
    if spec.replacement_mode ~= "drain" and spec.replacement_mode ~= "migrate" then
        return result.failure("HU_INVALID_MANIFEST", "必须明确 replacement_mode")
    end
    if record.capabilities.prepare_retire and not record.capabilities.cancel_retire then
        return result.failure("HU_CAPABILITY_MISSING", "prepare_retire 必须可恢复")
    end
    if spec.replacement_mode == "migrate" then
        for _, name in ipairs({"export_state", "import_state", "healthcheck"}) do
            if not record.capabilities[name] then
                return result.failure("HU_CAPABILITY_MISSING", name)
            end
        end
    end
    if spec.replacement_mode == "drain" and (not record.capabilities.can_retire or not record.capabilities.healthcheck) then
        return result.failure("HU_CAPABILITY_MISSING", "DRAIN 需要 can_retire/healthcheck")
    end
    return result.success()
end

--- MIGRATE 不保留旧权威写入者；组外声明者尚未解绑时必须拒绝。
local function validate_migration_visitors(controller, targets)
    local selected_callers = {}
    for _, target in ipairs(targets) do
        if target.spec.replacement_mode == "migrate" then
            local source = controller.sources[target.old.address]
            if source then selected_callers[source.caller] = true end
        end
    end

    for _, target in ipairs(targets) do
        if target.spec.replacement_mode == "migrate" then
            local instance = controller.registry.targets[target.old.key].instances[target.old.generation]
            for caller in pairs(instance.visitors) do
                if not selected_callers[caller] then
                    return result.failure("HU_GENERATION_INCOMPATIBLE", "MIGRATE 存在组外旧代访问者")
                end
            end
        end
    end
    return result.success()
end

function Controller:targets(patch)
    local targets, graph, selected = {}, {}, {}
    for _, target in pairs(self.registry.targets) do
        local instance = target.instances[target.current]
        local record = instance and instance.record
        local entries = {}
        local configs = {}
        if record then
            for _, entry in ipairs(patch.modules) do
                if record.modules and record.modules[entry.name] then entries[#entries + 1] = entry end
            end
            for _, entry in ipairs(patch.configs) do
                if entry.service_type == record.service_type then configs[#configs + 1] = entry end
            end
        end
        local replacement = record and patch.services[record.service_type]
        if #entries > 0 or #configs > 0 or replacement then
            local spec = {service_type = record.service_type, mode = "module_patch",
                new_code_version = record.code_version + ((replacement or #entries > 0) and 1 or 0)}
            if #entries > 0 then entries = patch.modules end
            if replacement then
                -- Replacement candidates need all Patch modules, including new dependencies.
                entries = patch.modules
                spec.mode, spec.entry_file = nil, replacement.entry_file
                spec.replacement_mode, spec.new_state_version = "drain", record.state_version

                -- Only an unambiguous chain starting at this instance's schema selects MIGRATE.
                local steps, next_version = {}, record.state_version
                while true do
                    local next_step
                    for _, entry in ipairs(patch.migrations) do
                        if entry.service_type == record.service_type and entry.from == next_version then
                            if next_step then return result.failure("HU_INVALID_PATCH", "迁移链存在分叉") end
                            next_step = entry
                        end
                    end
                    if not next_step then break end
                    local loaded = patch_module.load_pure(next_step.source)
                    if not loaded.ok or type(loaded.value) ~= "function" then
                        return result.failure("HU_INVALID_MIGRATION", "迁移文件必须返回函数")
                    end
                    steps[#steps + 1] = {from = next_step.from, to = next_step.to, up = loaded.value}
                    next_version = next_step.to
                    if #steps > #patch.migrations then
                        return result.failure("HU_INVALID_PATCH", "迁移链存在环")
                    end
                end
                if #steps > 0 then
                    local chain = migration.resolve(steps, record.state_version, next_version)
                    if not chain.ok then return chain end
                    spec.replacement_mode, spec.new_state_version = "migrate", next_version
                end
            end
            if selected[record.key] or self.locks[record.key] then
                return result.failure("HU_UPGRADE_BUSY", record.key)
            end
            local checked = check_capability(record, spec)
            if not checked.ok then return checked end
            targets[#targets + 1] = {old = record, spec = spec, modules = entries, configs = configs}
            selected[record.key], graph[record.key] = true, record.dependencies
        end
    end
    if #targets == 0 then return result.failure("HU_TARGET_MISSING", "没有选中目标") end
    local checked = dependency.validate(graph)
    if not checked.ok then return checked end
    local visitors = validate_migration_visitors(self, targets)
    if not visitors.ok then return visitors end
    return result.success({targets = targets})
end

function Controller:load(request)
    if self.recovery_required then
        return result.failure("HU_RECOVERY_REQUIRED", "历史存在未决事务，不能开始新的升级")
    end
    local loaded = patch_module.load({root = self.options.patch_root, path = request.path})
    if not loaded.ok then return loaded end
    for _, record in pairs(self.history.records) do
        if record.patch_id == loaded.patch.patch_id and record.phase ~= "DRY_RUN_COMPLETED" then
            return result.failure("HU_ALREADY_APPLIED", "Patch 已有事务记录，请查询原事务")
        end
    end
    local targets = self:targets(loaded.patch)
    if not targets.ok then return targets end
    return result.success({patch = loaded.patch, targets = targets.targets, checksum = loaded.checksum})
end

local function journal_participants(targets)
    local participants = {}
    for _, target in ipairs(targets) do
        participants[#participants + 1] =
        {
            old = target.old, new = target.new, spec = target.spec,
            prepared_retire = target.prepared_retire,
        }
    end
    return participants
end

function Controller:record(txn, phase, extra)
    txn.phase = phase
    local record =
    {
        txn_id = txn.id, patch_id = txn.patch.patch_id, phase = phase,
        checksum = txn.checksum, operator = txn.operator, started = txn.started,
        finished = skynet.now() * 10, success = txn.success or 0, failed = txn.failed or 0,
        current_batch = txn.current_batch or 0, target_count = #txn.targets,
        sequence = txn.sequence, controller = skynet.self(), patch_path = txn.patch_path,
        participants = journal_participants(txn.targets),
    }
    if extra then record.error = extra end
    local appended = self.history:append(record)
    if appended.ok then self.metrics:add("phase_" .. phase, 1) end
    return appended
end

local function request_for(txn, record)
    return {txn_id = txn.id, sequence = txn.sequence, generation = record.generation, instance_id = record.instance_id,
        timeout_ms = txn.patch.strategy and txn.patch.strategy.timeout_ms or 10000,
        patch = txn.patch}
end

function Controller:step(txn, record, command, extra)
    if txn.cancelled and command ~= "abort" and command ~= "cancel_retire" and command ~= "retire" then
        return result.failure("HU_ABORT_REQUESTED", txn.id)
    end
    local request = request_for(txn, record)
    for key, value in pairs(extra or {}) do request[key] = value end
    local called = rpc.call(record.address, command, request, request.timeout_ms)
    if not called.ok then called.step = command end
    return called
end

function Controller:migrate_state(txn, target)
    local exported = self:step(txn, target.old, "export")
    if not exported.ok then return exported end
    local steps = {}
    for _, entry in ipairs(txn.patch.migrations or {}) do
        if entry.service_type == target.old.service_type then
            local loaded = patch_module.load_pure(entry.source)
            if not loaded.ok then return loaded end
            steps[#steps + 1] = {from = entry.from, to = entry.to, up = loaded.value}
        end
    end
    local chain = migration.resolve(steps, target.old.state_version, target.spec.new_state_version or target.old.state_version)
    if not chain.ok then return chain end
    return migration.apply(exported.value, chain.chain, {txn_id = txn.id})
end

function Controller:create_candidate(txn, target)
    local spec = target.spec
    local source = txn.patch.frozen_files[spec.entry_file]
    if not source then return result.failure("HU_INVALID_MANIFEST", "候选入口未校验") end
    local generation = target.old.generation + 1
    local token, identity_error = native.nonce()
    if not token then return result.failure(identity_error, "候选身份生成失败") end
    self.bootstraps[token] =
    {
        source = source,
        context =
        {
            controller = skynet.self(), txn_id = txn.id,
            service_type = target.old.service_type, service_id = target.old.service_id,
            generation = generation, code_version = spec.new_code_version,
            state_version = spec.new_state_version or target.old.state_version,
            candidate = true, dependencies = target.old.dependencies,
            router_handle = target.old.router_handle,
        },
    }
    local ok, address = pcall(skynet.newservice, "flywow_hotupgrade_candidate", skynet.self(), token)
    self.bootstraps[token] = nil
    if not ok then return result.failure("HU_CREATE_FAILED", tostring(address)) end
    local instance = self.registry.targets[target.old.key].instances[generation]
    if not instance or instance.record.address ~= address then
        skynet.kill(address)
        return result.failure("HU_CREATE_FAILED", "候选没有注册")
    end
    target.new = instance.record
    return result.success()
end

function Controller:prepare_target(txn, target)
    if target.old.router_handle then
        local paused = rpc.call(target.old.router_handle, "pause",
            {key = target.old.key, txn_id = txn.id}, 10000)
        if not paused.ok then return paused end
    end
    local mode = target.spec.mode
    if mode == "module_patch" or target.spec.replacement_mode == "migrate" then
        local prepared = self:step(txn, target.old, "prepare")
        if not prepared.ok then return prepared end
    else
        local prepared = self:step(txn, target.old, "prepare_retire")
        if not prepared.ok then return prepared end
        target.prepared_retire = true
    end
    return result.success()
end

function Controller:prepare_candidate(txn, target)
    if target.spec.replacement_mode == "migrate" then
        local migrated = self:migrate_state(txn, target)
        if not migrated.ok then return migrated end
        target.snapshot = migrated.value
    end
    local created = self:create_candidate(txn, target)
    if not created.ok then return created end
    if target.snapshot then
        local imported = self:step(txn, target.new, "import", {snapshot = target.snapshot})
        if not imported.ok then return imported end
    end
    local prepared = self:step(txn, target.new, "prepare")
    if not prepared.ok then return prepared end
    local staged = self:step(txn, target.new, "stage",
        {patch = {modules = target.modules, configs = target.configs}})
    if not staged.ok then return staged end
    return result.success()
end

function Controller:stage_target(txn, target)
    local prepared = self:prepare_target(txn, target)
    if not prepared.ok then return prepared end
    if target.spec.mode == "module_patch" then
        return self:step(txn, target.old, "stage",
            {patch = {modules = target.modules, configs = target.configs}})
    end

    return self:prepare_candidate(txn, target)
end

function Controller:bind_candidates(txn, targets)
    local generations = {}
    for _, target in ipairs(targets) do
        if target.new then generations[target.old.key] = target.new.generation end
    end
    for _, target in ipairs(targets) do
        if target.new then
            local owner = self.sources[target.new.address]
            local declared = self.registry:declare(owner.caller, target.new.dependencies, generations)
            if not declared.ok then return declared end
            local healthy = self:step(txn, target.new, "health")
            if not healthy.ok then return healthy end
        end
    end
    return result.success()
end

function Controller:discard_candidate(txn, target)
    if not target.new then return result.success() end
    local cleaned = self:step(txn, target.new, "retire")
    if not cleaned.ok then return cleaned end

    local caller = self.sources[target.new.address]
    if caller then self.registry:release(caller.caller) end
    self.registry.targets[target.old.key].instances[target.new.generation] = nil
    self.sources[target.new.address] = nil
    return result.success()
end

function Controller:restore_old(txn, target)
    if target.prepared_retire then
        local restored = self:step(txn, target.old, "cancel_retire")
        if not restored.ok then return restored end
    end
    local aborted = self:step(txn, target.old, "abort")
    if not aborted.ok then return aborted end

    if target.old.router_handle then
        return rpc.call(target.old.router_handle, "abort",
            {key = target.old.key, txn_id = txn.id}, 10000)
    end
    return result.success()
end

function Controller:abort_targets(txn, targets)
    local failed
    for _, target in ipairs(targets) do
        local cleaned = self:discard_candidate(txn, target)
        -- 排他资源的候选清理失败时不能恢复对应旧实例，但不影响其它目标收敛。
        local restored = cleaned.ok and self:restore_old(txn, target) or cleaned
        if not restored.ok then failed = restored end
    end
    if failed then return result.failure("HU_ABORT_FAILED", failed.message, failed.step) end
    return result.success()
end

function Controller:activate_targets(txn, targets)
    for _, target in ipairs(targets) do
        local record = target.new or target.old
        local activated = self:step(txn, record, "activate", {new_code_version = target.spec.new_code_version})
        if not activated.ok then return activated end
    end
    return result.success()
end

function Controller:switch_routes(txn, targets)
    for _, target in ipairs(targets) do
        if target.new and target.old.router_handle then
            local granted = self:grant(result.success({record = target.new}), target.old.router_handle)
            if not granted.ok then return granted end
            local switched = rpc.call(target.old.router_handle, "switch",
                {key = target.old.key, txn_id = txn.id, expected = target.old.generation, record = target.new}, 10000)
            if not switched.ok then return switched end
        end
    end
    return result.success()
end

function Controller:publish_registry(targets)
    for _, target in ipairs(targets) do
        if target.new then
            local published = self.registry:publish(target.old.key, target.old.generation, target.new.generation)
            if not published.ok then return published end
        end
    end
    return result.success()
end

function Controller:release_old_dependencies(targets)
    -- MIGRATE 旧实例已静止且永久停止写入，解除组内旧调用链避免互相阻塞退休。
    for _, target in ipairs(targets) do
        if target.spec.replacement_mode == "migrate" then
            local caller = self.sources[target.old.address]
            if caller then self.registry:release(caller.caller) end
        end
    end
    return result.success()
end

function Controller:resume_participants(txn, targets)
    for _, target in ipairs(targets) do
        local record = target.new or target.old
        local opened = self:step(txn, record, "resume")
        if not opened.ok then return opened end
        local finished = self:step(txn, record, "finish")
        if not finished.ok then return finished end
        record.code_version = target.spec.new_code_version or record.code_version
    end
    return result.success()
end

function Controller:resume_routes(txn, targets)
    for _, target in ipairs(targets) do
        if target.old.router_handle then
            local resumed = rpc.call(target.old.router_handle, "resume",
                {key = target.old.key, txn_id = txn.id}, 10000)
            if not resumed.ok then return resumed end
        end
    end
    return result.success()
end

function Controller:publish_targets(txn, targets)
    local switched = self:switch_routes(txn, targets)
    if not switched.ok then return switched end
    local published = self:publish_registry(targets)
    if not published.ok then return published end

    self:release_old_dependencies(targets)
    local opened = self:resume_participants(txn, targets)
    if not opened.ok then return opened end
    return self:resume_routes(txn, targets)
end

function Controller:cleanup_old(txn, targets)
    local deadline = skynet.now() + math.ceil((txn.patch.strategy and txn.patch.strategy.drain_timeout_ms or 10000) / 10)
    local pending = {}
    for _, target in ipairs(targets) do
        if target.new then
            local draining = self:step(txn, target.old, "begin_drain")
            if not draining.ok then return result.failure("HU_RECOVERY_REQUIRED", draining.message) end
            pending[#pending + 1] = target
        end
    end
    while #pending > 0 and skynet.now() < deadline do
        for index = #pending, 1, -1 do
            local target = pending[index]
            local checked = self:step(txn, target.old, "can_retire")
            if checked.ok and self.registry:strong_count(target.old.key, target.old.generation) == 0 then
                local prepared = self:step(txn, target.old, "prepare")
                local retired = prepared.ok and self:step(txn, target.old, "retire") or prepared
                if retired.ok then
                    local caller = self.sources[target.old.address]
                    if caller then self.registry:release(caller.caller) end
                    self.sources[target.old.address] = nil
                    self.registry:retire(target.old.key, target.old.generation)
                    table.remove(pending, index)
                end
            end
        end
        if #pending > 0 then skynet.sleep(1) end
    end
    if #pending > 0 then return result.failure("HU_DRAIN_TIMEOUT", "旧实例仍有合法访问者") end
    return result.success()
end

function Controller:stage_group(txn, targets)
    for _, target in ipairs(targets) do
        local staged = self:stage_target(txn, target)
        if not staged.ok then
            local aborted = self:abort_targets(txn, targets)
            return aborted.ok and staged or aborted
        end
    end
    local bound = self:bind_candidates(txn, targets)
    if not bound.ok then
        local aborted = self:abort_targets(txn, targets)
        return aborted.ok and bound or aborted
    end
    return result.success()
end

function Controller:decide_group(txn, targets)
    txn.machine:move("READY")
    txn.machine:move("ACTIVATING")
    local decided = self:record(txn, "ACTIVATING")
    if not decided.ok then self:abort_targets(txn, targets); return decided end
    local activated = self:activate_targets(txn, targets)
    if not activated.ok then
        local aborted = self:abort_targets(txn, targets)
        return aborted.ok and activated or aborted
    end
    local durable = self:record(txn, "PUBLISH_DECIDED")
    if not durable.ok then self:abort_targets(txn, targets); return durable end
    txn.published = true
    txn.group_published = true
    txn.machine:move("PUBLISHED")
    return result.success()
end

function Controller:finish_group(txn, targets)
    local published = self:publish_targets(txn, targets)
    if not published.ok then return result.failure("HU_RECOVERY_REQUIRED", published.message) end
    txn.machine:move("DRAINING")
    local cleaned = self:cleanup_old(txn, targets)
    txn.machine:move(cleaned.ok and "COMPLETED" or "COMMITTED_DRAIN_PENDING")
    return cleaned
end

function Controller:run_group(txn, targets, dry_run)
    txn.group_published = false
    txn.machine = transaction.new(txn.id .. ":" .. txn.current_batch)
    txn.machine:move("VALIDATING")
    txn.machine:move("PREPARING")
    txn.machine:move("STAGING")
    local staged = self:stage_group(txn, targets)
    if not staged.ok then return staged end
    if dry_run then return self:abort_targets(txn, targets) end

    local decided = self:decide_group(txn, targets)
    if not decided.ok then return decided end
    return self:finish_group(txn, targets)
end

function Controller:run(txn, dry_run)
    local policy = txn.patch.strategy or {}
    local size = (policy.batch or {}).size or math.min(100, #txn.targets)
    if txn.patch.consistency_groups and #txn.patch.consistency_groups > 0 then
        if #txn.targets > 100 then
            return result.failure("HU_GROUP_LIMIT", "一致性组不能超过本次并发容量")
        end
        size = #txn.targets
    end
    if type(size) ~= "number" or size < 1 or size > 100 or size % 1 ~= 0 then
        return result.failure("HU_INVALID_BATCH", "batch size 必须为 1..100 整数")
    end
    for start = 1, #txn.targets, size do
        local targets = {}
        for index = start, math.min(start + size - 1, #txn.targets) do targets[#targets + 1] = txn.targets[index] end
        txn.current_batch = (txn.current_batch or 0) + 1
        local completed = self:run_group(txn, targets, dry_run)
        if not completed.ok then
            txn.failed = txn.failed + #targets
            local phase = completed.code == "HU_DRAIN_TIMEOUT" and "COMMITTED_DRAIN_PENDING"
                or (completed.code == "HU_ABORT_FAILED" and "RECOVERY_REQUIRED")
                or (txn.group_published and "RECOVERY_REQUIRED" or (txn.success > 0 and "PARTIAL" or "ABORTED"))
            local recorded = self:record(txn, phase, completed)
            if not recorded.ok then return recorded end
            if phase ~= "RECOVERY_REQUIRED" and phase ~= "COMMITTED_DRAIN_PENDING" then
                for _, target in ipairs(txn.targets) do self.locks[target.old.key] = nil end
            end
            return completed
        end
        txn.success = txn.success + #targets
    end
    local recorded = self:record(txn, dry_run and "DRY_RUN_COMPLETED" or "COMPLETED")
    if not recorded.ok then return recorded end
    for _, target in ipairs(txn.targets) do self.locks[target.old.key] = nil end
    return result.success()
end

function Controller:apply(request, source, dry_run)
    local loaded = self:load(request)
    if not loaded.ok then return loaded end
    self.sequence = self.sequence + 1
    local id = loaded.patch.patch_id .. ":" .. tostring(skynet.self()) .. ":" .. self.sequence
    local txn =
    {
        id = id, sequence = self.sequence, patch = loaded.patch, targets = loaded.targets,
        checksum = loaded.checksum, operator = tostring(source), started = skynet.now() * 10,
        patch_path = request.path,
        success = 0, failed = 0,
    }
    local recorded = self:record(txn, "PREPARING")
    if not recorded.ok then return recorded end
    self.transactions[id] = txn
    for _, target in ipairs(txn.targets) do self.locks[target.old.key] = id end
    skynet.fork(function()
        local ok, value = pcall(self.run, self, txn, dry_run)
        if not ok then self:record(txn, "RECOVERY_REQUIRED", result.failure("HU_CONTROL_FAILED", tostring(value))) end
    end)
    return result.success({txn_id = id, target_count = #txn.targets})
end

function Controller:control(command, request, source)
    if command == "register" then return self:register(request, source) end
    if command == "register_module" then return self:register_module(request, source) end
    if command == "resolve" then return self:resolve(request, source) end
    if command == "switch" then return self:switch(request, source) end
    if command == "release_ref" then return self:release_ref(request, source) end
    if command == "bootstrap" then
        return result.success({bootstrap = self.bootstraps[request.token]})
    end
    if not self.options.admin_handles[source] then return result.failure("HU_UNAUTHORIZED", "管理来源未授权") end
    if command == "validate" then return self:load(request) end
    if command == "apply" or command == "dry_run" then return self:apply(request, source, command == "dry_run") end
    if command == "history" then return result.success({records = self.history.records}) end
    if command == "metrics" then return result.success({values = self.metrics.values}) end
    if command == "status" then
        return result.success({record = self.history.records[request.txn_id]})
    end
    if command == "abort" then
        local txn = self.transactions[request.txn_id]
        if not txn or txn.published then return result.failure("HU_ROLLBACK_NOT_SAFE", "事务不存在或已发布") end
        txn.cancelled = true
        return result.success()
    end
    if command == "rollback" then
        if type(request.path) == "string" then return self:apply({path = request.path}, source, false) end
        local txn = self.transactions[request.txn_id]
        if not txn or not txn.patch.reversible or type(txn.patch.rollback_patch) ~= "string" then
            return result.failure("HU_ROLLBACK_NOT_SAFE", "原 Patch 未声明可逆及反向 Patch")
        end
        return self:apply({path = txn.patch.rollback_patch}, source, false)
    end
    return result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
