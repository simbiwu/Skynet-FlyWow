--- 控制面 owner：冻结 Patch、协调参与者、持久化决定；正常请求不经过此模块。
local skynet = require "skynet"
require "skynet.manager"
local result = require "flywow_hotupgrade_error"
local registry_module = require "flywow_hotupgrade_registry"
local patch_module = require "flywow_hotupgrade_patch"
local history_module = require "flywow_hotupgrade_history"
local M = {}
local Controller = {}
Controller.__index = Controller
-- 候选启动最多等待 10 秒；Skynet tick 为 10 毫秒，CPU 预算由薄壳单独限制。
local CANDIDATE_TIMEOUT_TICKS = 1000
-- 重启后只有明确终态可释放恢复门禁；其它阶段保守地要求人工恢复。
local terminal_phases = {COMPLETED = true, ABORTED = true, PARTIAL = true, DRY_RUN_COMPLETED = true}

-- DJB2 32 位滚动散列；固定种子和模数让相同 Patch 与 origin_service_handle 映射到同一灰度桶。
local function stable_ratio(patch_id, origin_service_handle)
    local hash = 5381
    local input = patch_id .. ":" .. tostring(origin_service_handle)
    for index = 1, #input do
        hash = (hash * 33 + input:byte(index)) % 4294967296
    end
    return hash / 4294967296
end

local function select_records(patch_id, records, selector)
    selector = selector or {all = true}
    if type(selector) ~= "table" then
        return result.failure("HU_INVALID_SELECTOR", "selector 必须是 table")
    end
    if selector.all ~= nil and type(selector.all) ~= "boolean" then
        return result.failure("HU_INVALID_SELECTOR", "all 必须是 boolean")
    end
    if selector.percent ~= nil and (type(selector.percent) ~= "number"
        or selector.percent ~= selector.percent or selector.percent < 0 or selector.percent > 1) then
        return result.failure("HU_INVALID_SELECTOR", "percent 范围是 0..1")
    end
    if selector.all == false and selector.percent == nil then
        return result.failure("HU_INVALID_SELECTOR", "all=false 需要提供 percent")
    end

    local selected = {}
    for _, record in ipairs(records) do
        local include = selector.all or selector.percent == nil
            or stable_ratio(patch_id, record.origin_service_handle) < selector.percent
        if include then
            selected[#selected + 1] = record
        end
    end
    table.sort(selected, function(left, right)
        return left.origin_service_handle < right.origin_service_handle
    end)

    return result.success({records = selected})
end

--- 打开有界历史；未决阶段只设置全局恢复门禁，不重建无消费者的目标锁。
---@param options table patch_root/history_path。
---@return FlyWowHotUpgradeResult 成功包含 controller；历史错误拒绝启动。
function M.new(options)
    local opened = history_module.open(options.history_path)
    if not opened.ok then return opened end
    local controller = setmetatable(
    {
        options = options,                -- init RPC 交付的控制面配置；运行期间只读。
        registry = registry_module.new(), -- 当前每个逻辑 Service 的实例与模块声明。
        history = opened.history,         -- 从 history_path 重放并追加事务阶段记录。
        sources = {},                     -- 已注册 Service 的 source handle 到同一注册 record 的索引。
        bootstraps = {},                  -- 候选启动窗口；按 launch 返回的 instance_handle 关联。
        sequence = 0,                     -- txn_id 的递增尾号；启动时从历史记录恢复最大值。
    }, Controller)
    for _, record in pairs(controller.history.records) do
        local old_sequence = type(record.txn_id) == "string"
            and tonumber(record.txn_id:match(":(%d+)$"))
        controller.sequence = math.max(controller.sequence, old_sequence or record.sequence or 0)
        if not terminal_phases[record.phase] then controller.recovery_required = true end
    end
    return result.success({controller = controller})
end

function Controller:register(request, source)
    if type(request) ~= "table" or type(request.service_type) ~= "string" or request.service_type == ""
        or request.instance_handle ~= source or type(request.modules) ~= "table"
        or type(request.capabilities) ~= "table"
        or (request.router_handle ~= nil and math.type(request.router_handle) ~= "integer") then
        return result.failure("HU_INVALID_OPTIONS", "注册元数据无效")
    end
    if self.sources[source] then
        return result.failure("HU_DUPLICATE_SERVICE", "当前 Service 已注册")
    end

    -- 候选必须来自当前启动窗口；预期身份由控制面保存，不信任 factory 改写后的 context。
    local startup = self.bootstraps[source]
    if request.candidate or startup then
        if not startup or startup.registered or not request.candidate then
            return result.failure("HU_INVALID_OPTIONS", "候选不属于当前启动窗口")
        end
        local context = startup.context
        for _, field in ipairs({"service_type", "origin_service_handle", "router_handle"}) do
            if request[field] ~= context[field] then
                return result.failure("HU_INVALID_OPTIONS", "候选元数据不匹配: " .. field)
            end
        end
    else
        request.origin_service_handle = source
    end
    request.instance_handle = source
    local module_set = {}
    for _, name in ipairs(request.modules) do
        if type(name) ~= "string" or name == "" then
            return result.failure("HU_INVALID_OPTIONS", "模块名无效")
        end
        module_set[name] = true
    end
    request.modules = module_set

    if startup then
        startup.registered = request
        self.sources[source] = request
        return result.success()
    end

    -- 绑定等待期间不写入 Registry/current；同 source 的并发注册也不得覆盖 Router。
    self.sources[source] = {}
    if request.router_handle then
        local ok, bound = pcall(skynet.call, request.router_handle, "hotupgrade", "bind",
            {origin_service_handle = request.origin_service_handle, record = request})
        if not ok then bound = result.failure("HU_RPC_FAILED", tostring(bound)) end
        if not bound then bound = result.failure("HU_RPC_FAILED", "Router bind 失败") end
        if not bound.ok then
            self.sources[source] = nil
            return bound
        end
    end
    local registered = self.registry:register(request)
    if not registered.ok then
        self.sources[source] = nil
        self.recovery_required = true
        return registered
    end
    self.sources[source] = request
    return result.success()
end

function Controller:register_module(request, source)
    local caller = self.sources[source]
    if not caller or not caller.modules or type(request.name) ~= "string" or request.name == "" then
        return result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未注册")
    end
    caller.modules[request.name] = true
    return result.success()
end

--- 按已登记模块和 Service 类型筛选目标，再按稳定 origin_service_handle 应用灰度。
---@param patch table 已冻结的 Patch。
---@param selector? table 默认全量；percent 在 0..1 之间。
---@return FlyWowHotUpgradeResult 成功时包含已排序的目标快照。
function Controller:targets(patch, selector)
    local available = {}
    for _, record in pairs(self.registry.targets) do
        local has_module = false
        for _, entry in ipairs(patch.modules) do
            if record.modules[entry.name] then
                has_module = true
                break
            end
        end
        if has_module or patch.services[record.service_type] then
            available[#available + 1] = record
        end
    end

    local selection = select_records(patch.patch_id, available, selector)
    if not selection.ok then
        return selection
    end
    if #selection.records == 0 then
        return result.failure("HU_TARGET_MISSING", "灰度条件没有选中 Service 实例")
    end

    local targets = {}
    for _, record in ipairs(selection.records) do
        local replacement = patch.services[record.service_type]
        local target_modules = {}
        for _, entry in ipairs(patch.modules) do
            -- 替换在新 State 内按需加载冻结模块；只有原地更新需要形成已声明模块列表。
            if not replacement and record.modules[entry.name] then
                target_modules[#target_modules + 1] = entry
            end
        end

        local spec =
        {
            service = replacement,
        }
        if replacement and not record.router_handle then
            return result.failure("HU_ROUTER_REQUIRED", "Service 替换需要稳定 Router")
        end
        targets[#targets + 1] = {old = record, spec = spec, modules = target_modules}
    end

    return result.success({targets = targets})
end

--- 加载并校验 Patch，生成一次不可变的目标快照；同步文件读取可能阻塞当前控制 Service。
---@param request table path 是 Patch Root 下的相对目录，不接受调用者自带源码。
---@return FlyWowHotUpgradeResult 冻结源码、校验身份与目标记录，供 validate/apply 共用。
function Controller:load(request)
    if self.recovery_required then
        return result.failure("HU_RECOVERY_REQUIRED", "历史存在未决事务，不能开始新的升级")
    end
    local loaded = patch_module.load({root = self.options.patch_root, path = request.path})
    if not loaded.ok then
        return loaded
    end
    local targets = self:targets(loaded.patch, request.selector)
    if not targets.ok then
        return targets
    end
    return result.success({patch = loaded.patch, targets = targets.targets})
end

-- 持久化人工核对所需的实例身份，不把运行时对象放入日志。
local function instance_snapshot(record)
    if not record then
        return nil
    end

    return
    {
        service_type = record.service_type,
        origin_service_handle = record.origin_service_handle,
        instance_handle = record.instance_handle,
    }
end

local function journal_participants(targets)
    local participants = {}
    for _, target in ipairs(targets) do
        participants[#participants + 1] =
        {
            old = instance_snapshot(target.old),
            new = instance_snapshot(target.new),
            starting_instance_handle = target.starting_instance_handle,
        }
    end

    return participants
end

--- 同步追加事务阶段记录；History 在返回成功前完成文件与父目录 fsync。
---@param txn table 当前控制面持有的事务状态。
---@param phase string 写入审计的可恢复阶段名。
---@param extra? any 可序列化错误详情，不作为流程分支依据。
---@return FlyWowHotUpgradeResult 持久化失败时返回错误，调用者不得假定阶段已提交。
function Controller:record(txn, phase, extra)
    txn.phase = phase
    local record =
    {
        txn_id = txn.id, patch_id = txn.patch.patch_id, phase = phase,
        operator = txn.operator, started = txn.started,
        finished = skynet.now() * 10, success = txn.success or 0, failed = txn.failed or 0,
        target_count = #txn.targets,
        controller_handle = skynet.self(), patch_path = txn.patch_path,
        participants = journal_participants(txn.targets),
    }
    if extra then
        record.error = extra
    end
    local appended = self.history:append(record)
    if not appended.ok then
        self.recovery_required = true
        txn.persistence_error = txn.persistence_error or appended
    end
    return appended
end

--- 向显式实例发送控制请求；身份最后写入，步骤数据不能覆盖它们。
---@param txn table 当前事务。
---@param record table 目标 instance_handle 和事务身份。
---@param command string 内部控制命令。
---@param request? table 仅包含本步骤需要的数据；调用后归本步骤所有。
---@return FlyWowHotUpgradeResult RPC 可 yield；超时不取消远端操作。
function Controller:step(txn, record, command, request)
    if txn.cancelled and command ~= "abort" and command ~= "retire" then
        return result.failure("HU_ABORT_REQUESTED", txn.id)
    end
    request = request or {}
    request.txn_id = txn.id
    request.instance_handle = record.instance_handle
    request.timeout_ms = 10000
    local requests = skynet.request
    {
        record.instance_handle, "hotupgrade", command, request,
    }
    local called
    for _, response in requests:select(math.max(1, math.ceil(request.timeout_ms / 10))) do
        called = response
    end
    if requests.timeout then
        called = result.failure("HU_RPC_TIMEOUT", "目标操作可能仍在执行")
    elseif not called then
        called = result.failure("HU_RPC_FAILED", "目标 Service 未返回结果")
    end
    if not called.ok then called.step = command end
    return called
end

--- 同步取得候选 instance_handle 后打开以 RPC source 为键的启动窗口，再等待完整初始化和注册。
---@param txn table 当前事务和冻结源码。
---@param target table 旧实例与替换入口；成功后写入 new。
---@return FlyWowHotUpgradeResult 失败关闭窗口并终止候选，不把候选写入当前实例索引。
function Controller:create_candidate(txn, target)
    local service = target.spec.service
    if not service or type(service.source) ~= "string" then
        return result.failure("HU_INVALID_MANIFEST", "候选入口未冻结")
    end
    local startup =
    {
        source = service.source, entry_file = service.entry_file, modules = txn.patch.modules,
        context =
        {
            controller_handle = skynet.self(), service_type = target.old.service_type,
            origin_service_handle = target.old.origin_service_handle, candidate = true,
            router_handle = target.old.router_handle,
        },
    }
    -- skynet.launch 是同步的 LAUNCH 命令；此处到窗口登记之间不 yield。
    local ok, instance_handle = pcall(skynet.launch, "snlua", "flywow_hotupgrade_candidate", skynet.self())
    if not ok or not instance_handle then
        return result.failure("HU_CREATE_FAILED", tostring(instance_handle or "候选启动失败"))
    end
    self.bootstraps[instance_handle] = startup
    target.starting_instance_handle = instance_handle
    local deadline = skynet.now() + CANDIDATE_TIMEOUT_TICKS
    -- 在第一次 yield 前落盘候选 instance_handle，重启后可定位初始化中的孤立候选。
    local recorded = self:record(txn, "CANDIDATE_STARTING")
    while recorded.ok and not startup.answer and not txn.cancelled and skynet.now() < deadline do
        skynet.sleep(1)
    end
    self.bootstraps[instance_handle] = nil
    if recorded.ok and startup.answer and startup.answer.ok and startup.registered and not txn.cancelled then
        target.new = startup.registered
        return result.success()
    end

    -- 窗口先关闭再终止；迟到的 bootstrap、候选注册和 ready 都不能重新加入。
    skynet.kill(instance_handle)
    self.sources[instance_handle] = nil
    if not recorded.ok then return recorded end
    if txn.cancelled then return result.failure("HU_ABORT_REQUESTED", txn.id) end
    return result.failure("HU_CREATE_FAILED", startup.answer and startup.answer.message
        or "候选未注册、初始化失败或超过 10 秒期限")
end

--- 关闭旧入口并排空，然后分别准备原地更新或全新候选；两种更新不共享模块安装流程。
function Controller:prepare_target(txn, target)
    if target.old.router_handle then
        target.route_paused = true -- pause 先关闭入口；排空超时也必须恢复该路由。
        local ok, paused = pcall(skynet.call, target.old.router_handle, "hotupgrade", "pause",
            {origin_service_handle = target.old.origin_service_handle, txn_id = txn.id})
        if not ok then return result.failure("HU_RPC_FAILED", tostring(paused)) end
        if not paused then paused = result.failure("HU_RPC_FAILED", "Router pause 失败") end
        if not paused.ok then return paused end
    end
    target.old_preparing = true
    local prepared = self:step(txn, target.old, "prepare")
    if not prepared.ok then return prepared end
    if not target.spec.service then
        return self:step(txn, target.old, "stage", {modules = target.modules})
    end

    -- 候选先装入冻结模块的加载入口，再运行 factory；就绪后才进行成对状态交接。
    local created = self:create_candidate(txn, target)
    if not created.ok then return created end
    local exports_state = target.old.capabilities.export_state
    if exports_state ~= target.new.capabilities.import_state then
        return result.failure("HU_CAPABILITY_MISMATCH", "状态交接必须由旧/新 Service 成对提供")
    end
    if exports_state then
        local exported = self:step(txn, target.old, "export")
        if not exported.ok then return exported end
        local imported = self:step(txn, target.new, "import", {state = exported.value})
        if not imported.ok then return imported end
    else
        local ready = self:step(txn, target.new, "prepare")
        if not ready.ok then return ready end
    end
    return self:step(txn, target.new, "health")
end

--- 发布决定前直接销毁本事务持有的候选，再恢复旧 Guard 与原路由。
function Controller:abort_target(txn, target)
    if target.new then
        skynet.kill(target.new.instance_handle)
        self.sources[target.new.instance_handle] = nil
        target.new = nil
    end
    if target.old_preparing then
        local aborted = self:step(txn, target.old, "abort")
        if not aborted.ok then return result.failure("HU_ABORT_FAILED", aborted.message, aborted.step) end
    end
    if target.route_paused then
        local ok, restored = pcall(skynet.call, target.old.router_handle, "hotupgrade", "abort",
            {origin_service_handle = target.old.origin_service_handle, txn_id = txn.id})
        if not ok then restored = result.failure("HU_RPC_FAILED", tostring(restored)) end
        if not restored then restored = result.failure("HU_RPC_FAILED", "Router abort 失败") end
        if not restored.ok then return result.failure("HU_ABORT_FAILED", restored.message) end
    end
    return result.success()
end

--- 逐实例执行：准备与检查 → 持久化决定 → 切换、开放入口 → 退休旧实例。
function Controller:run_target(txn, target, dry_run)
    txn.commit_decided = false
    local prepared = self:prepare_target(txn, target)
    if prepared.ok and not target.spec.service then
        prepared = self:record(txn, "ACTIVATING")
        if prepared.ok then
            prepared = self:step(txn, target.old, "activate")
        end
    end
    if prepared.ok and not dry_run then prepared = self:record(txn, "PUBLISH_DECIDED") end
    if not prepared.ok or dry_run then
        local aborted = self:abort_target(txn, target)
        return aborted.ok and prepared or aborted
    end
    -- 只有发布决定成功落盘后才切换；此后失败保留当前阶段，禁止假称恢复旧实例。
    txn.commit_decided, txn.any_commit_decided = true, true
    local published = result.success()
    if target.new then
        local ok, switched = pcall(skynet.call, target.old.router_handle, "hotupgrade", "switch",
            {origin_service_handle = target.old.origin_service_handle, txn_id = txn.id,
                expected = target.old.instance_handle, record = target.new})
        if not ok then
            published = result.failure("HU_RPC_FAILED", tostring(switched))
        else
            published = switched or result.failure("HU_RPC_FAILED", "Router switch 失败")
        end
        if published.ok then
            published = self.registry:publish(target.old.origin_service_handle, target.old.instance_handle, target.new)
        end
    end
    if published.ok then
        local record = target.new or target.old
        published = self:step(txn, record, "finish")
    end
    if published.ok and target.old.router_handle then
        local ok, resumed = pcall(skynet.call, target.old.router_handle, "hotupgrade", "resume",
            {origin_service_handle = target.old.origin_service_handle, txn_id = txn.id})
        if not ok then
            published = result.failure("HU_RPC_FAILED", tostring(resumed))
        else
            published = resumed or result.failure("HU_RPC_FAILED", "Router resume 失败")
        end
    end
    if not published.ok then return result.failure("HU_RECOVERY_REQUIRED", published.message, published.step) end
    if target.new then
        local retired = self:step(txn, target.old, "retire")
        if not retired.ok then return result.failure("HU_RECOVERY_REQUIRED", retired.message) end
        self.sources[target.old.instance_handle] = nil
    end
    return result.success()
end

--- 按稳定灰度结果逐实例推进；已完成实例保留，后续失败记录为部分成功。
function Controller:run(txn, dry_run)
    -- 灰度逐实例串行推进；已发布实例保留，后续失败记录为部分成功。
    for _, target in ipairs(txn.targets) do
        local completed = self:run_target(txn, target, dry_run)
        if not completed.ok then
            txn.failed = txn.failed + 1
            local phase = (completed.code == "HU_ABORT_FAILED" or completed.code == "HU_RECOVERY_REQUIRED" or txn.commit_decided)
                and "RECOVERY_REQUIRED" or (txn.success > 0 and "PARTIAL" or "ABORTED")
            if phase == "RECOVERY_REQUIRED" then
                self.recovery_required = true
            end
            local recorded = self:record(txn, phase, completed)
            if not recorded.ok then
                return recorded
            end
            return completed
        end
        txn.success = txn.success + 1
    end

    local recorded = self:record(txn, dry_run and "DRY_RUN_COMPLETED" or "COMPLETED")
    if not recorded.ok then
        return recorded
    end
    return result.success()
end

--- 一次仅执行一个发布；逐实例推进，不创建发布队列。返回 txn_id 供 status/history 查询。
function Controller:apply(request, source, dry_run)
    if self.active and not self.recovery_required then return result.failure("HU_UPGRADE_BUSY", "已有发布尚未结束") end
    -- 先冻结 Patch 并验证目标，失败时不分配事务号或占用活动发布位置。
    local loaded = self:load(request)
    if not loaded.ok then
        return loaded
    end

    -- sequence 在单一控制面生命周期内单调递增；嵌入 txn_id 以拒绝迟到的旧控制消息。
    self.sequence = self.sequence + 1
    local id = tostring(skynet.self()) .. ":" .. self.sequence
    local txn =
    {
        id = id, patch = loaded.patch, targets = loaded.targets,
        operator = tostring(source), started = skynet.now() * 10,
        patch_path = request.path, -- 保留宿主相对路径，历史记录可指出执行时选择的 Patch 目录。
        success = 0, failed = 0,
    }
    local recorded = self:record(txn, "PREPARING")
    if not recorded.ok then
        return recorded
    end
    -- 单一活动事务覆盖正常执行与失败恢复；历史终态落盘后才释放。
    self.active = txn
    skynet.fork(function()
        local ok, value = pcall(self.run, self, txn, dry_run)
        if not ok then
            self.recovery_required = true
            self:record(txn, "RECOVERY_REQUIRED", result.failure("HU_CONTROL_FAILED", tostring(value)))
        end
        -- 查询只依赖有界历史；已持久化的终态不再持有冻结源码和运行时参与者。
        if not txn.persistence_error and terminal_phases[txn.phase] then
            self.active = nil
        end
    end)
    return result.success({txn_id = id, target_count = #txn.targets})
end

--- 控制面命令入口：参与者请求校验来源；管理命令不做调用者 handle 白名单校验。
function Controller:control(command, request, source)
    if type(request) ~= "table" then return result.failure("HU_INVALID_REQUEST", "请求必须是 table") end
    -- 参与者命令只允许注册 Service 自己的 handle，并由对应方法校验业务资格。
    if command == "register" then
        return self:register(request, source)
    end
    if command == "register_module" then
        return self:register_module(request, source)
    end
    if command == "bootstrap" or command == "candidate_ready" then
        local startup = self.bootstraps[source]
        if not startup then
            return result.failure("HU_CREATE_FAILED", "候选启动窗口已结束或来源不匹配")
        end
        if command == "bootstrap" then
            return result.success({bootstrap = {source = startup.source, entry_file = startup.entry_file,
                modules = startup.modules, context = startup.context}})
        end
        if startup.answer or type(request.answer) ~= "table" or type(request.answer.ok) ~= "boolean" then
            return result.failure("HU_INVALID_REQUEST", "候选初始化结果无效或已报告")
        end
        startup.answer = request.answer
        return result.success()
    end
    -- 其余命令属于管理面；发布状态变更仍走单一活动事务与历史。
    if command == "validate" then
        return self:load(request)
    end
    if command == "apply" or command == "dry_run" then
        return self:apply(request, source, command == "dry_run")
    end
    if command == "history" then
        return result.success({records = self.history.records})
    end
    if command == "status" then
        local txn = self.active
        if txn and txn.id ~= request.txn_id then txn = nil end
        return result.success({record = self.history.records[request.txn_id],
            recovery_required = self.recovery_required == true,
            error = txn and txn.persistence_error})
    end
    if command == "abort" then
        local txn = self.active
        if txn and txn.id ~= request.txn_id then txn = nil end
        if not txn or txn.any_commit_decided then
            return result.failure("HU_ROLLBACK_NOT_SAFE", "事务不存在或已有实例越过发布决定")
        end
        txn.cancelled = true
        return result.success()
    end
    return result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
