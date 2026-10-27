--- 现存 Service 的登记与原地更新；所有业务对象、快照和模块表仅留在本 Lua State。
local skynet = require "skynet"
local skynet_require = require "skynet.require"
local flywow_result = require "flywow_result"
local hotupgrade_common = require "flywow_hotupgrade_common"
local hotupgrade_native = require "flywow_hotupgrade_native"
local hotupgrade_module_patch = require "flywow_hotupgrade_module_patch"
local M =
{
    patching = false, -- prepare 起禁止新业务进入，本批 finish/abort 结束后解除。
}
local module_state =
{
    hotupgrade_handle = nil, -- 首次跨 Service RPC 时取得；宿主必须先完成控制面初始化。
    registered            = false,                            -- Controller 已确认首次登记；配置建立早于此确认。
    registration_complete = false,                            -- 首次登记 RPC 已返回；失败后不得继续本 State 的业务启动。
    registration_waiters  = {},                               -- 首次登记 RPC 期间的声明等待者，避免遗漏初始元数据快照。
    registration          = nil,                              -- 本 Lua State 登记配置；私有表和函数不发送给 Controller。
    active_transaction    = nil,                              -- 当前事务的撤销数据保留至 finish/abort 确认完成。
    completed_sequence    = 0,                                -- 已结束的 Controller 递增序号，拒绝迟到控制消息。
    last_batch_id         = nil,                              -- 最近完成的批次，用于 finish/abort 幂等响应。
    declared_modules      = {},                               -- 规范名到首次加载名/路径的记录；声明与候选执行共用。
    module_loads          = {},                               -- 同一规范模块的首次声明串行完成，等待者不能观察半完成的本地状态。
    module_sources        = setmetatable({}, {__mode = "k"}), -- 仅保存本入口确认的模块表与文件路径；弱键不延长模块生命周期。
}

---@class FlyWowHotUpgradeNewModuleContext
---@field owner thread 当前 Update 协程；只允许此协程执行声明清单内的新模块加载。
---@field batch_id string 当前 Controller 批次身份；写入 register_new_module 请求。
---@field names table<string, boolean> 已核验的新模块规范名集合；阻止候选加载未声明依赖。

---@class FlyWowHotUpgradeTransaction
---@field batch_id string Controller 为本次发布生成的身份；用于拒绝其他批次的控制命令。
---@field sequence integer Controller 单调递增的本地序号；finish/abort 后写入 completed_sequence。
---@field phase? string nil 表示 Update 尚未开始，之后为 STAGED 或 ACTIVATED；Finish/Abort 结束时事务本身被清除。
---@field new_module_context? FlyWowHotUpgradeNewModuleContext Update 中的临时声明权限；候选 Stage 完成后立即清除。
---@field module_stage? FlyWowHotUpgradeModuleStage 候选模块的旧/新导出记录；保留至 Finish 或 Abort。
---@field service_patch? FlyWowHotUpgradeServicePatchTransaction Service 私有状态与函数的提交/恢复记录。

local require_module -- 公共 require 和 new_modules 复用已验证身份的同一加载流程。

-- 文件顶部 require 不执行 RPC；宿主启动入口先初始化唯一控制 Service。
--- 获取宿主启动时创建的唯一 HotUpgrade Controller handle，并在本 State 缓存。
--- 首次调用通过 skynet.uniqueservice 取得 handle，可能 yield；后续直接返回缓存值。
---@return integer handle 原生唯一控制 Service handle。
local function get_hotupgrade_handle()
    if not module_state.hotupgrade_handle then
        module_state.hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    end
    return module_state.hotupgrade_handle
end

---@class FlyWowHotUpgradeModuleIdentity
---@field name string 调用方使用的原始 require 名。
---@field source_path string package.path 首次搜索到的 Lua 文件路径。
---@field resolved_path string Native 解析后的真实绝对路径，用于核验缓存来源。
---@field canonical_name string 相对 root_path 的文件身份，去掉 .lua 并将 / 转为点。

--- 普通 require 与本批新模块声明共用同一文件身份，防止别名绕过批次清单。
---@param name string 调用方使用的原始 require 名
---@return FlyWowHotUpgradeModuleIdentity 已通过 root_path 边界检查的模块身份
local function resolve_module_identity(name)
    local root_path = assert(skynet.getenv(hotupgrade_common.ROOT_PATH_ENV),
        "HU_NOT_INITIALIZED: 须先初始化 Controller，再声明可更新模块")
    local source_path = assert(package.searchpath(name, package.path),
        "HU_INVALID_PATH: 可更新模块必须能通过 package.path 定位 Lua 文件: " .. name)
    assert(package.preload[name] == nil, "HU_INVALID_PATH: 可更新模块不支持 package.preload: " .. name)
    local resolved_path = assert(hotupgrade_native.resolve(source_path),
        "HU_INVALID_PATH: 无法解析模块文件路径: " .. source_path)
    local root_prefix = root_path == "/" and "/" or root_path .. "/"
    assert(resolved_path:sub(1, #root_prefix) == root_prefix,
        "HU_INVALID_PATH: 模块文件不在 root_path 内: " .. resolved_path)
    local relative_path = resolved_path:sub(#root_prefix + 1)
    assert(relative_path:sub(-4) == ".lua" and not relative_path:find("\\", 1, true),
        "HU_INVALID_PATH: 模块必须对应宿主目录中的 Lua 文件: " .. relative_path)
    local canonical_name = relative_path:sub(1, -5):gsub("/", ".")
    assert(canonical_name ~= "", "HU_INVALID_PATH: 模块文件路径无效")
    return {name = name, source_path = source_path, resolved_path = resolved_path, canonical_name = canonical_name}
end

-- 与 Controller Service 使用同一原生消息协议；不建立独立协议/RPC 模块。
skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID, pack = skynet.pack, unpack = skynet.unpack})

--- 创建受管理 Service；排空和 Prepare 期间正常接纳，Update 起等待本批发布终态，失败不阻止后续操作。
--- 会 yield，成功直接返回原生 handle，不等待调用方后续业务 init。
--- 启动参数遵循 skynet.newservice 的原有约束；失败抛出含 HU_ 错误码的异常。
---@param service_name string 原生 Skynet Service 入口名
---@param ... any 原样转交原生 newservice 的启动参数
---@return integer service_handle
function M.newservice(service_name, ...)
    -- 基础设施转发未知启动签名，固定 n 以保留参数个数和 nil。
    local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "newservice",
        {service_name = service_name, arguments = table.pack(...)})
    assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
    return answer.value.service_handle
end

--- 仅本 Controller 内的本地唯一服务；可能 yield 等待发布或同名在途创建。
--- true 重载明确抛出 HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED，不启动 Service。
---@param name_or_global string|boolean 逻辑名，或 true 表示后续首参为全局逻辑名
---@param ... any 完整启动参数；首次请求的参数生效
---@return integer service_handle
function M.uniqueservice(name_or_global, ...)
    local arguments = table.pack(...)
    local global = name_or_global == true
    local name = name_or_global
    if global then
        name = arguments[1]
        arguments = table.pack(table.unpack(arguments, 2, arguments.n))
    end
    local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "uniqueservice",
        {service_name = name, global = global, arguments = arguments})
    assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
    return answer.value.service_handle
end

--- 创建者在业务 init 失败后取消尚未登记的 Service；Controller 负责终止并解除屏障。
--- 已登记、未知 handle 或非创建者请求均明确拒绝；可能 yield。
---@param service_handle integer newservice 返回的待登记 Service handle
---@return FlyWowResult<nil> 取消结果。
function M.cancel_service_creation(service_handle)
    return skynet.call(get_hotupgrade_handle(), "hotupgrade", "cancel_service_creation",
        {service_handle = service_handle})
end

--- 恢复 Service 私有状态和被替换的函数；Abort 调用，恢复回调失败时抛出异常供上层汇总。
---@param transaction FlyWowHotUpgradeTransaction 当前 Service 的失败事务记录
---@return nil 无返回值；恢复回调失败时抛出异常。
local function restore_service(transaction)
    if not transaction.service_patch or not transaction.service_patch.touched then
        return
    end

    local service_update = module_state.registration.service_update
    -- 自定义恢复只处理 Service 自己的对象；即使它失败也继续尝试还原函数字段。
    local restore_succeeded, restore_failure = pcall(function()
        if transaction.service_patch.old_state then
            if service_update.restore then
                assert(service_update.restore(service_update.state, transaction.service_patch.old_state) ~= false, "Service 拒绝恢复")
            else
                hotupgrade_module_patch.restore_state(transaction.service_patch.old_state, service_update.state)
            end
        end
    end)

    for name, fn in pairs(transaction.service_patch.old_functions) do
        rawset(service_update.functions, name, fn)
    end

    assert(restore_succeeded, restore_failure)
end

--- 统一结束本地事务：记录终态身份、清除活动事务并重新开放 Service 业务入口。
---@param transaction FlyWowHotUpgradeTransaction 已完成 Finish/Abort 的本地事务
---@return nil
local function close_transaction(transaction)
    module_state.completed_sequence = transaction.sequence
    module_state.last_batch_id = transaction.batch_id
    module_state.active_transaction = nil
    M.patching = false
end

--- 尝试恢复 Service 状态与模块导出；无论恢复成败都结束事务并释放本地门禁。
---@param transaction FlyWowHotUpgradeTransaction 当前正在回退的本地事务
---@return FlyWowResult<nil> 成功表示本地恢复完成；失败以 HU_RECOVERY_REQUIRED 报告全部恢复错误。
local function abort(transaction)
    -- 先尝试恢复 Service 私有状态，再恢复模块导出；一个失败也继续另一项。
    local errors = {}
    local service_restore_succeeded, service_restore_failure = pcall(restore_service, transaction)
    if not service_restore_succeeded then
        errors[#errors + 1] = tostring(service_restore_failure)
    end

    if transaction.module_stage then
        local restored = hotupgrade_module_patch.abort(transaction.module_stage)
        if not restored.ok then
            errors[#errors + 1] = restored.message
        end
    end

    -- 本批尽力恢复后释放事务与临时门禁；错误只通过结果报告。
    close_transaction(transaction)
    if #errors > 0 then
        return flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end
    return flywow_result.success()
end

---@class FlyWowHotUpgradeServicePatchDefinition
---@field new_modules? string[] 本 Service 本批首次加载的模块名；未登记依赖也须列入，从下一批普通 Stage 起参与候选匹配。
---@field update_state? fun() 在 Update 提交时直接修改构建函数捕获的现存 state；不得 yield 或产生外部副作用。
---@field replace_functions? table<string, function> 本次要替换的现有业务函数；未列出的字段保持原样。

---@class FlyWowHotUpgradeServicePatchTransaction: FlyWowHotUpgradeServicePatchDefinition
---@field old_functions table<string, function> 本次替换前的函数；Abort 时逐项装回原业务函数表。
---@field old_state? table 提交前的隔离状态快照；只有 update_state 存在时保存。
---@field touched boolean 提交开始写入业务状态或函数前置 true，失败时据此恢复。

--- 在业务安全点加载构建函数并保存恢复数据；只准备回调，不执行状态更新。
---@param service_patch_source string Controller 已完成语法检查的 Service Patch 源码
---@return FlyWowHotUpgradeServicePatchTransaction service_patch 本 State 的提交内容及恢复快照；准备失败抛出异常，由控制入口转换为 FlyWowResult。
local function stage_service_patch(service_patch_source)
    -- 执行受信 Patch 构建函数并校验结果；此时尚不写入线上状态。
    local service_update = module_state.registration.service_update
    local chunk = assert(load(hotupgrade_common.normalize_source(service_patch_source), "=Service Patch", "t", _G))
    local build_patch = chunk()
    assert(type(build_patch) == "function", "Service Patch 必须返回构建函数")
    ---@type FlyWowHotUpgradeServicePatchDefinition
    local patch_definition = build_patch(service_update.state)

    assert(type(patch_definition) == "table" and getmetatable(patch_definition) == nil, "Service 构建结果必须是普通表")
    assert(patch_definition.update_state == nil or type(patch_definition.update_state) == "function", "update_state 必须是函数")
    assert(patch_definition.replace_functions == nil or (type(patch_definition.replace_functions) == "table"
        and getmetatable(patch_definition.replace_functions) == nil), "replace_functions 必须是普通表")
    if patch_definition.new_modules ~= nil then
        assert(type(patch_definition.new_modules) == "table" and getmetatable(patch_definition.new_modules) == nil,
            "new_modules 必须是普通数组")
        local item_count = 0
        local last_index = 0
        for index, module_name in pairs(patch_definition.new_modules) do
            assert(math.type(index) == "integer" and index > 0 and type(module_name) == "string"
                and module_name ~= "", "new_modules 必须是非空模块名组成的连续数组")
            item_count = item_count + 1
            last_index = math.max(last_index, index)
        end
        assert(item_count == last_index, "new_modules 必须是连续数组")
    end
    assert(patch_definition.update_state or (patch_definition.replace_functions and next(patch_definition.replace_functions))
        or (patch_definition.new_modules and next(patch_definition.new_modules)), "Service Patch 没有更新内容")

    -- 保存本次可能替换的旧函数，Activate 失败时逐字段恢复。
    ---@type FlyWowHotUpgradeServicePatchTransaction
    local service_patch =
    {
        update_state      = patch_definition.update_state,      -- 本 State 的提交回调，不发送给 Controller。
        replace_functions = patch_definition.replace_functions, -- 本次要安装的函数，提交时直接使用。
        new_modules       = patch_definition.new_modules,       -- 原始声明清单，随后解析一次模块身份。
        old_functions     = {},                                -- 本次将替换的旧函数，失败时逐字段恢复。
        touched           = false,                             -- 首次线上写入前置 true，部分提交同样必须恢复。
    }
    for name, replacement_function in pairs(patch_definition.replace_functions or {}) do
        assert(type(name) == "string" and type(replacement_function) == "function"
            and type(rawget(service_update.functions, name)) == "function", "只能直接替换现有业务函数")
        service_patch.old_functions[name] = rawget(service_update.functions, name)
    end

    -- 只保存恢复快照；更新回调留到提交阶段执行，不创建候选状态或做合并。
    if patch_definition.update_state then
        if service_update.snapshot then
            service_patch.old_state = service_update.snapshot(service_update.state)
            assert(type(service_patch.old_state) == "table" and service_patch.old_state ~= service_update.state,
                "自定义快照必须返回独立状态表")
        else
            service_patch.old_state = hotupgrade_module_patch.snapshot_state(service_update.state)
        end
    end

    return service_patch
end

--- 构建 Service Patch 并加载登记 new_modules；清单也必须覆盖这些模块尚未登记的依赖。
---@param transaction FlyWowHotUpgradeTransaction 当前 Update 事务；其中的 batch_id 限定新模块归属
---@param service_patch_source? string Controller 已部署并发送的目标 Service .patch 文件内容；未匹配 Patch 时为 nil
---@return FlyWowResult<FlyWowHotUpgradeServicePatchTransaction|nil> 加载/登记可能 yield；成功返回提交记录或 nil，失败清除上下文并报告 HU_ 错误码。
local function stage_service_patch_and_new_modules(transaction, service_patch_source)
    -- 清单保留到普通候选 Stage 结束；未声明的新依赖立即失败，不能申请普通许可后与本批 Update 互等。
    local new_module_context = {owner = coroutine.running(), batch_id = transaction.batch_id, names = {}}
    transaction.new_module_context = new_module_context
    local failure_code = "HU_SERVICE_STAGE_FAILED"
    local stage_succeeded, service_patch_or_error = pcall(function()
        if not service_patch_source then
            return nil
        end

        -- 先构建并核验完整声明清单，再加载模块，避免边加载边发现重复路径。
        local service_patch = stage_service_patch(service_patch_source)
        local new_module_identities = {} -- 保存已验证身份，首次加载直接复用，不再解析同一路径。
        for _, name in ipairs(service_patch.new_modules or {}) do
            local identity = resolve_module_identity(name)
            assert(not new_module_context.names[identity.canonical_name],
                "HU_DUPLICATE_MODULE: new_modules 重复指向同一文件: " .. identity.canonical_name)
            new_module_context.names[identity.canonical_name] = true
            new_module_identities[#new_module_identities + 1] = identity
        end

        -- 只有声明内的模块允许在 Update 期间首次加载；每次 require 仍完成正式登记。
        failure_code = "HU_NEW_MODULE_FAILED"
        for _, identity in ipairs(new_module_identities) do
            require_module(identity.name, identity)
        end
        return service_patch
    end)
    if not stage_succeeded then
        local cause = type(service_patch_or_error) == "table" and service_patch_or_error.ok == false and service_patch_or_error or nil
        transaction.new_module_context = nil
        return flywow_result.failure(failure_code,
            cause and cause.message or tostring(service_patch_or_error), cause and {cause_code = cause.code} or nil)
    end
    return flywow_result.success(service_patch_or_error)
end

---@alias FlyWowHotUpgradeServiceCommand
---| "prepare"
---| "update"
---| "abort"
---| "finish"

--- 建立本批本地事务并关闭新业务入口，再通过业务自己的 queue 等待安全点；before_upgrade 可 yield。
---@param request FlyWowHotUpgradeControlRequest Controller 已核验身份的 Prepare 请求
---@return FlyWowResult<nil> 回调失败或未确认安全点时保留事务，交由现有 Abort 收尾
local function prepare_transaction(request)
    if module_state.active_transaction then
        return flywow_result.failure("HU_UPGRADE_BUSY", "当前批次已在处理中")
    end

    module_state.active_transaction =
    {
        batch_id = request.batch_id,
        sequence = request.sequence,
        new_module_context = nil, -- Update 临时上下文覆盖 Patch 构建、新模块加载和候选 Stage，owner 限定当前控制协程。
    }
    M.patching = true

    local prepare_succeeded, prepare_result = pcall(module_state.registration.before_upgrade)

    if not prepare_succeeded then
        return flywow_result.failure("HU_PREPARE_FAILED", tostring(prepare_result))
    end
    if prepare_result ~= true and not (type(prepare_result) == "table" and prepare_result.ok == true) then
        return flywow_result.failure("HU_SAFEPOINT_REQUIRED",
            type(prepare_result) == "table" and (prepare_result.message or prepare_result.code) or "before_upgrade 未确认业务安全点")
    end
    return flywow_result.success()
end

--- 准备候选并同步提交模块、Service 状态与函数；仅新模块加载/登记阶段可能 yield。
---@param transaction FlyWowHotUpgradeTransaction Prepare 已建立的当前事务
---@param request FlyWowHotUpgradeControlRequest 本批冻结的普通候选及可选 Service Patch 源码
---@return FlyWowResult<nil> 成功将事务设为 ACTIVATED；失败保留恢复记录，交由 Abort 处理
local function update_transaction(transaction, request)
    if transaction.phase ~= nil then
        return flywow_result.failure("HU_PHASE_INVALID", "当前批次已进入更新或恢复阶段")
    end
    -- Controller 在 Prepare 收口时已固定普通候选；new_modules 在这里才首次加载并登记，从下一批 Stage 起才会匹配。
    local service_patch_result = stage_service_patch_and_new_modules(transaction, request.service_patch_source)
    if not service_patch_result.ok then
        return service_patch_result
    end
    local service_patch = service_patch_result.value

    -- 保留同一声明上下文直到候选模块执行结束，漏列的新依赖须立即失败，不能在 UPDATE 等许可。
    local stage_succeeded, module_result = pcall(hotupgrade_module_patch.stage,
        request.modules, module_state.declared_modules)
    transaction.new_module_context = nil
    if not stage_succeeded then
        local cause = type(module_result) == "table" and module_result.ok == false and module_result or nil
        return flywow_result.failure("HU_MODULE_STAGE_FAILED",
            cause and cause.message or tostring(module_result), cause and {cause_code = cause.code} or nil)
    end
    if not module_result.ok then
        return module_result
    end

    transaction.module_stage = module_result.value.stage
    transaction.service_patch = service_patch
    transaction.phase = "STAGED"

    -- Activate 同步提交；失败先报告，再由 Controller 串行 Abort 整批目标。
    local commit_result = hotupgrade_module_patch.commit(transaction.module_stage)
    if not commit_result.ok then
        return flywow_result.failure("HU_ACTIVATE_FAILED", commit_result.message)
    end
    local activation_succeeded, activation_failure = pcall(function()
        if service_patch then
            local service_update = module_state.registration.service_update
            service_patch.touched = true
            if service_patch.update_state then
                service_patch.update_state()
            end

            for name, fn in pairs(service_patch.replace_functions or {}) do
                rawset(service_update.functions, name, fn)
            end
        end

        if module_state.registration.after_upgrade then
            assert(module_state.registration.after_upgrade() ~= false, "after_upgrade 拒绝更新")
        end
    end)

    if not activation_succeeded then
        -- Controller 串行发出一次 Abort，报告更新错误与独立恢复结果。
        return flywow_result.failure("HU_ACTIVATE_FAILED", tostring(activation_failure))
    end

    transaction.phase = "ACTIVATED"
    return flywow_result.success()
end

--- 仅收尾已完成 Activate 的事务；释放候选快照并重新开放业务，不执行回滚。
---@param transaction FlyWowHotUpgradeTransaction 当前 Service 事务
---@return FlyWowResult<nil> 模块快照清理结果；未 Activate 时返回 HU_PHASE_INVALID
local function finish_transaction(transaction)
    if transaction.phase ~= "ACTIVATED" then
        return flywow_result.failure("HU_PHASE_INVALID", "当前阶段不能执行 finish")
    end
    local finished = hotupgrade_module_patch.finish(transaction.module_stage)
    close_transaction(transaction)
    return finished
end

--- 核验 Controller 来源、命令和批次，再分派本 Service 的事务阶段；不在此处执行各阶段细节。
---@param command FlyWowHotUpgradeServiceCommand Controller Service 分发的稳定控制命令
---@param request FlyWowHotUpgradeControlRequest 当前批次和序号；Update 另含本目标模块及可选 Service Patch 源码
---@param source integer 由 Skynet 提供的真实调用来源
---@return FlyWowResult<nil> Prepare/Update/Abort 可能 yield；阶段错误原样返回，异常交由 dispatch_upgrade_command 转换。
local function handle_upgrade(command, request, source)
    -- 先核验 Controller 来源；批次身份由 Controller 生成，再与本地事务记录比对。
    if source ~= module_state.hotupgrade_handle then
        return flywow_result.failure("HU_UNAUTHORIZED", "控制来源不匹配")
    end

    if command ~= "prepare" and command ~= "update" and command ~= "abort" and command ~= "finish" then
        return flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
    end

    if module_state.last_batch_id == request.batch_id and (command == "abort" or command == "finish") then
        return flywow_result.success()
    end

    if request.sequence <= module_state.completed_sequence or (module_state.active_transaction and module_state.active_transaction.batch_id ~= request.batch_id) then
        return flywow_result.failure("HU_STALE_TRANSACTION", "过期或冲突批次命令")
    end

    if command == "prepare" then
        return prepare_transaction(request)
    end

    local transaction = module_state.active_transaction
    if not transaction or transaction.sequence ~= request.sequence then
        return flywow_result.failure("HU_STALE_TRANSACTION", "未取得本批次安全点")
    end

    if command == "abort" then
        return abort(transaction)
    end

    if command == "update" then
        return update_transaction(transaction, request)
    end
    if command == "finish" then
        return finish_transaction(transaction)
    end

    return flywow_result.failure("HU_PHASE_INVALID", "当前阶段不能执行 " .. tostring(command))
end

--- 执行目标控制命令并回复 RPC；命令可 yield，异常时按发布决定前后分别恢复或释放事务。
---@param session integer 原生 RPC 会话；0 表示无需回复
---@param source integer 原生消息来源，由 handle_upgrade 核验 Controller 身份
---@param command FlyWowHotUpgradeServiceCommand 当前控制命令
---@param request FlyWowHotUpgradeControlRequest 当前批次请求
---@return nil 回复 FlyWowResult；异常转换沿用 HU_CONTROL_FAILED 和原有 Abort/Finish 清理
local function dispatch_upgrade_command(session, source, command, request)
    local control_succeeded, control_result = pcall(handle_upgrade, command, request, source)
    if not control_succeeded then
        -- 异常也必须结束本批；Finish 已越过发布决定，只释放快照而不回滚。
        local original = flywow_result.failure("HU_CONTROL_FAILED", tostring(control_result))
        local transaction = module_state.active_transaction
        if transaction and command ~= "finish" then
            control_result = abort(transaction)
            if control_result.ok then
                control_result = original
            else
                control_result.details = {original_error = original}
            end
        else
            if transaction then
                if transaction.module_stage then hotupgrade_module_patch.finish(transaction.module_stage) end
                close_transaction(transaction)
            end
            control_result = original
        end
    end

    if session ~= 0 then
        skynet.retpack(control_result)
    end
end

---@class FlyWowHotUpgradeServiceUpdate
---@field state table 现存 Service 私有状态表；更新只改其字段，不替换该表。
---@field functions table Service 原有业务函数表；Patch 只替换本次列出的现有函数字段。
---@field snapshot? fun(state:table):table 更新前生成与线上对象隔离的恢复快照；与 restore 成对提供。
---@field restore? fun(state:table, old_state:table) 提交失败时同步恢复快照；返回 false 或抛错报告恢复失败，仍结束本批事务。

---@class FlyWowHotUpgradeRegistration
---@field service_update? FlyWowHotUpgradeServiceUpdate 可选 Service 内部状态/函数更新入口
---@field before_upgrade fun():boolean|table 注册必填；每次 Prepare 设置 patching 后调用，允许 yield；须通过业务自己的 queue 确认此前业务结束。true 或 {ok=true} 才允许 Update，失败则 Abort
---@field after_upgrade? fun():boolean Update 内 Activate 提交模块与 Service 状态后、finish 前调用；false 或异常触发组合恢复。只检查已提交状态，不得产生外部副作用或 yield

--- 登记现存 Service；仅元数据跨 Service 传递。可能 yield，成功前宿主不能宣布 READY。
---@param registration FlyWowHotUpgradeRegistration 本 State 必须提供 before_upgrade；service_update 可选
---@return FlyWowResult<nil> 登记结果
function M.register_service(registration)
    -- 先验证回调与可选更新入口合同；检查完成前不安装 dispatch 或登记状态。
    if module_state.registration then
        return flywow_result.failure("HU_DUPLICATE_SERVICE", "当前 State 已登记")
    end

    if type(registration) ~= "table" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "Service 登记参数无效")
    end
    if type(registration.before_upgrade) ~= "function" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "before_upgrade 必须为函数")
    end

    if registration.after_upgrade ~= nil and type(registration.after_upgrade) ~= "function" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "after_upgrade 必须为函数")
    end

    local service_update = registration.service_update
    if service_update ~= nil then
        if type(service_update) ~= "table" or type(service_update.state) ~= "table"
            or type(service_update.functions) ~= "table" or getmetatable(service_update.functions) ~= nil then
            return flywow_result.failure("HU_INVALID_OPTIONS", "Service 更新入口需要私有 state 与现有函数表")
        end

        local custom = service_update.snapshot ~= nil or service_update.restore ~= nil
        if custom and (type(service_update.snapshot) ~= "function" or type(service_update.restore) ~= "function") then
            return flywow_result.failure("HU_INVALID_OPTIONS", "自定义快照、恢复必须成对提供")
        end

        if not custom and getmetatable(service_update.state) ~= nil then
            return flywow_result.failure("HU_INVALID_OPTIONS", "特殊状态对象需要自定义快照与恢复")
        end
    end

    if next(module_state.module_loads) then
        return flywow_result.failure("HU_LIFECYCLE_PENDING", "本 State 仍有模块首次加载，完成后再登记 Service")
    end

    -- 合同有效后固定本地登记配置并安装接收器，再向 Controller 登记元数据。
    module_state.registration = registration
    skynet.dispatch("hotupgrade", dispatch_upgrade_command)
    -- 收集完整模块声明并排序，形成跨 Service 传递的稳定元数据快照。
    local names = {}
    for name in pairs(module_state.declared_modules) do
        names[#names + 1] = name
    end
    table.sort(names)
    ---@type FlyWowHotUpgradeTargetMetadata
    local metadata =
    {
        modules = names,
        has_service_update = service_update ~= nil,
    }
    local registration_call_succeeded, registration_result = pcall(
        skynet.call, get_hotupgrade_handle(), "hotupgrade", "register", metadata)
    -- 发布登记 RPC 的最终结果，再唤醒等待首次 require 的协程。
    module_state.registration_complete = true
    module_state.registered = registration_call_succeeded and registration_result.ok == true
    for _, thread in ipairs(module_state.registration_waiters) do
        skynet.wakeup(thread)
    end
    module_state.registration_waiters = {}
    -- RPC 失败可能意味着 Controller 已登记；保持本 State 配置，要求宿主终止未 READY 的启动。
    if not registration_call_succeeded then
        return flywow_result.failure("HU_RPC_FAILED", tostring(registration_result))
    end
    return registration_result
end

--- 执行一次首次加载与登记；许可、缓存和本地声明构成同一恢复边界，失败先回退再抛出原错误。
---@param name string 调用方原始 require 名
---@param module_identity FlyWowHotUpgradeModuleIdentity 已验证的文件身份
---@param new_module_context? FlyWowHotUpgradeNewModuleContext 当前 Update 的新模块声明权限
---@param register_new_module? boolean 是否使用本批新模块登记通道
---@return table module_exports 已完成加载与登记的稳定导出表；许可、require 或登记可能 yield
local function load_and_register_module(name, module_identity, new_module_context, register_new_module)
    local source_path    = module_identity.source_path    -- 已验证的首次搜索路径，供加载器来源校验使用。
    local resolved_path  = module_identity.resolved_path  -- 已验证的真实路径，供缓存和实际加载来源比较。
    local canonical_name = module_identity.canonical_name -- 本地声明、缓存别名和 Controller 登记的共同身份。
    local module_load_attempt =
    {
        loader_path              = source_path, -- 加载器返回路径缺失时沿用首次 searchpath 结果。
        permit_id                = nil,         -- 普通首次声明的许可；登记完成或失败取消后释放。
        cached_module            = nil,         -- 取得许可后保存的原名缓存，失败时原样装回。
        previous_canonical_alias = nil,         -- 同时保存规范别名，避免回退时破坏既有合法缓存。
        module_exports           = nil,         -- 本次加载或复用的模块表，供来源映射与成功返回使用。
        cache_snapshot_taken     = false,       -- 许可失败时缓存尚未触及，不应执行缓存恢复。
        source_mapping_added     = false,       -- 只撤销本次新建的模块表到文件路径映射。
        module_declaration_added = false,       -- 只撤销本次新增的本地模块声明。
    }
    local load_succeeded, load_failure = pcall(function()
        if module_state.registration and not module_state.declared_modules[canonical_name] and not register_new_module then
            local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade",
                "begin_module_load", {name = canonical_name})
            assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
            module_load_attempt.permit_id = answer.value.permit_id
        end

        -- 申请许可会 yield；恢复后再读取快照，等待者须等本次登记成功或完整回退。
        module_load_attempt.cached_module = package.loaded[name]
        module_load_attempt.previous_canonical_alias = package.loaded[canonical_name]
        module_load_attempt.module_exports = module_load_attempt.cached_module
        module_load_attempt.cache_snapshot_taken = true
        -- 缓存占用不能证明来源；仅复用本入口确认过的同表来源。
        assert(module_load_attempt.cached_module == nil or (type(module_load_attempt.cached_module) == "table"
            and module_state.module_sources[module_load_attempt.cached_module] == resolved_path),
            "HU_INVALID_PATH: 无法确认缓存模块来源，须先通过 hotupgrade.require 加载: " .. name)
        assert(package.preload[canonical_name] == nil and package.preload[name] == nil,
            "HU_DUPLICATE_MODULE: 模块名称已被 package.preload 占用: " .. canonical_name)
        assert(module_load_attempt.previous_canonical_alias == nil or (rawequal(module_load_attempt.previous_canonical_alias, module_load_attempt.cached_module)
            and module_state.module_sources[module_load_attempt.previous_canonical_alias] == resolved_path),
            "HU_DUPLICATE_MODULE: 模块路径登记名已被其他模块占用: " .. canonical_name)
        if module_load_attempt.module_exports == nil then
            module_load_attempt.module_exports, module_load_attempt.loader_path = require(name)
            assert(type(module_load_attempt.module_exports) == "table", "可更新模块必须返回 table")
            if module_load_attempt.loader_path ~= nil then
                assert(type(module_load_attempt.loader_path) == "string" and hotupgrade_native.resolve(module_load_attempt.loader_path) == resolved_path,
                    "HU_INVALID_PATH: 模块加载来源与 package.path 不一致: " .. name)
            else
                -- Skynet 协程 require 不返回路径；固定走 searchpath/loadfile，只认可此已知加载器。
                assert(require == skynet_require.require and loadfile(source_path, "t") ~= nil,
                    "HU_INVALID_PATH: 加载器未提供可确认的模块来源: " .. name)
            end
            assert(module_state.module_sources[module_load_attempt.module_exports] == nil
                or module_state.module_sources[module_load_attempt.module_exports] == resolved_path,
                "HU_DUPLICATE_MODULE: 同一模块表已对应其他文件: " .. name)
            assert(package.preload[name] == nil and package.preload[canonical_name] == nil,
                "HU_DUPLICATE_MODULE: 模块名称已被 package.preload 占用: " .. canonical_name)
            assert(package.loaded[canonical_name] == nil or rawequal(package.loaded[canonical_name], module_load_attempt.module_exports),
                "HU_DUPLICATE_MODULE: 模块路径登记名已被其他模块占用: " .. canonical_name)
            module_load_attempt.loader_path = module_load_attempt.loader_path or source_path
            if module_state.module_sources[module_load_attempt.module_exports] == nil then
                module_state.module_sources[module_load_attempt.module_exports] = resolved_path
                module_load_attempt.source_mapping_added = true
            end
        end

        -- 登记 RPC 前建立全部本地状态；许可阻止 Controller 在此关键区间启动批次。
        package.loaded[canonical_name] = module_load_attempt.module_exports
        if not module_state.declared_modules[canonical_name] then
            module_state.declared_modules[canonical_name] = {name = name, path = module_load_attempt.loader_path}
            module_load_attempt.module_declaration_added = true
        end
        if module_load_attempt.permit_id then
            local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade",
                "register_module", {name = canonical_name, permit_id = module_load_attempt.permit_id})
            assert(answer.ok, "模块登记失败: " .. tostring(answer.message))
        elseif register_new_module and module_load_attempt.module_declaration_added then
            local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "register_new_module",
                {batch_id = new_module_context.batch_id, name = canonical_name})
            assert(answer.ok, "新模块登记失败: " .. tostring(answer.message))
        end
    end)
    -- 任一步失败都恢复原名缓存、规范别名和本次新增的本地声明。
    if not load_succeeded then
        if module_load_attempt.cache_snapshot_taken then
            package.loaded[name] = module_load_attempt.cached_module
            package.loaded[canonical_name] = module_load_attempt.previous_canonical_alias
        end
        if module_load_attempt.source_mapping_added then
            module_state.module_sources[module_load_attempt.module_exports] = nil
        end
        if module_load_attempt.module_declaration_added then
            module_state.declared_modules[canonical_name] = nil
        end
        if module_load_attempt.permit_id then
            -- 登记响应丢失时许可可能已消费；重复取消不会改变其他操作的许可。
            pcall(skynet.call, get_hotupgrade_handle(), "hotupgrade",
                "cancel_module_load", {name = canonical_name, permit_id = module_load_attempt.permit_id})
        end
        error(load_failure, 0)
    end
    return module_load_attempt.module_exports
end

--- 已验证身份的首次加载与登记；等待登记、许可或同模块加载时可能 yield。
---@param name string 调用方传入的原始 require 名
---@param module_identity FlyWowHotUpgradeModuleIdentity 已解析的搜索路径、真实路径和规范登记名
---@return table module_exports 本 State 的稳定模块根导出表；失败时回退后抛出异常
require_module = function(name, module_identity)
    -- 入口已固定模块身份；等待和加载后的缓存/来源检查保留在实际变化点。
    local canonical_name = module_identity.canonical_name
    local transaction = module_state.active_transaction
    local new_module_context = transaction and transaction.new_module_context
    local in_new_module_context = new_module_context and new_module_context.owner == coroutine.running()
    local register_new_module = in_new_module_context and new_module_context.names[canonical_name] == true
    if in_new_module_context and not module_state.declared_modules[canonical_name] and not register_new_module then
        error(flywow_result.failure("HU_NEW_MODULE_NOT_DECLARED",
            "新模块依赖未列入 new_modules: " .. canonical_name .. "\n" .. debug.traceback("", 2)), 0)
    end

    -- 当前 State 已进入首次登记时先等待 Controller 结果，避免声明越过登记快照。
    if module_state.registration and not module_state.registered then
        if not module_state.registration_complete then
            local thread = coroutine.running()
            module_state.registration_waiters[#module_state.registration_waiters + 1] = thread
            skynet.wait(thread)
        end
        assert(module_state.registered, "HU_SERVICE_NOT_REGISTERED: 首次登记失败，须终止本次启动")
    end

    -- 同一规范路径首次加载串行化，等待者完成后重新检查缓存和声明。
    local module_load = module_state.module_loads[canonical_name]
    if module_load then
        local thread = coroutine.running()
        -- Update 不等待门禁中的普通加载协程，避免双方互相等待。
        if register_new_module and module_load.owner ~= thread then
            error(flywow_result.failure("HU_MODULE_LOADING",
                "新模块正由其他协程加载: " .. canonical_name .. "\n" .. debug.traceback("", 2)), 0)
        end
        assert(module_load.owner ~= thread, "HU_MODULE_LOADING: 不支持循环声明 " .. canonical_name)
        module_load.waiters[#module_load.waiters + 1] = thread
        skynet.wait(thread)
        return M.require(name)
    end

    module_load = {owner = coroutine.running(), waiters = {}}
    module_state.module_loads[canonical_name] = module_load
    local load_succeeded, module_or_error = pcall(load_and_register_module,
        name, module_identity, new_module_context, register_new_module)

    -- 释放首次加载锁并唤醒等待者，让它们重新检查模块状态。
    module_state.module_loads[canonical_name] = nil
    for _, thread in ipairs(module_load.waiters) do
        skynet.wakeup(thread)
    end

    -- 回滚和清理完成后才把错误返回给 require 调用方。
    if not load_succeeded then
        error(module_or_error, 0)
    end
    return module_or_error
end

--- 在本 State 加载完整模块；首次加载、等待登记或同模块并发加载时可能 yield。登记失败抛错，允许再次声明。
--- 仅复用本入口确认过来源的缓存；普通 require 先加载的未知缓存会被明确拒绝。
---@param name string 宿主原有 require 名；Controller 使用实际文件的根目录相对路径登记
---@return table 当前 State 的稳定模块导出表
function M.require(name)
    assert(type(name) == "string" and name ~= "", "模块名无效")
    return require_module(name, resolve_module_identity(name))
end

return M
