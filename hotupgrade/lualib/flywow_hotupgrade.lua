--- 现存 Service 的登记与原地更新；所有业务对象、快照和模块表仅留在本 Lua State。
local skynet = require "skynet" -- 提供 Service 内协程、消息分发和跨 Service 调用。
local skynet_require = require "skynet.require" -- 用于识别 Skynet 自己的协程 require 加载器。
local flywow_result = require "flywow_result" -- 构造本模块对外和内部统一使用的 FlyWowResult。
local hotupgrade_common = require "flywow_hotupgrade_common" -- 提供协议号、路径环境变量和状态快照边界。
local hotupgrade_native = require "flywow_hotupgrade_native" -- 解析模块真实路径，核对来源位于宿主根目录内。
local hotupgrade_module_patch = require "flywow_hotupgrade_module_patch" -- 在当前 Lua State 中暂存、提交和恢复模块导出。
-- 对宿主公开的受管理 Service 创建、登记与模块 require 入口。
local M =
{
    patching = false, -- prepare 起禁止新业务进入，本批 finish/abort 结束后解除。
}
-- 模块级私有状态表保存本 Lua State 共用的登记、当前批次和模块加载记录。
local module_state =
{
    hotupgrade_handle = nil, -- 首次跨 Service RPC 时取得；宿主必须先完成控制面初始化。
    registration_config  = nil,                              -- 本 Lua State 的回调配置；登记结果单独保存在 registration_result。
    registration_result  = nil,                              -- nil 表示无最终结果；配置存在时为 RPC 在途，true/false 表示登记成功/失败。
    -- Controller 登记 RPC 会 yield；期间到达的并发 require 协程在这里等待最终登记结果。
    registration_waiters  = {},
    active_batch          = nil,                              -- 当前批次的恢复数据保留至 finish/abort 确认完成。
    completed_sequence    = 0,                                -- 已结束的 Controller 递增序号，拒绝迟到控制消息。
    last_batch_id         = nil,                              -- 最近完成的批次，用于 finish/abort 幂等响应。
    declared_modules      = {},                               -- 统一模块名到首次加载名/路径的记录；例如 a/b.lua 会登记为 a.b。
    module_loads          = {},                               -- 同一规范模块的首次声明串行完成，等待者不能观察半完成的本地状态。
    module_sources        = setmetatable({}, {__mode = "k"}), -- 仅保存本入口确认的模块表与文件路径；弱键不延长模块生命周期。
}

---@class FlyWowHotUpgradeNewModuleContext
---@field owner thread 当前 Update 协程；只允许此协程执行声明清单内的新模块加载。
---@field batch_id string 当前 Controller 批次身份；写入 register_new_module 请求。
---@field names table<string, boolean> 已核验的新模块统一名称集合；例如 a/b.lua 对应 a.b；阻止候选加载未声明依赖。

---@class FlyWowHotUpgradeServiceBatch
---@field batch_id string Controller 为本次发布生成的身份；用于拒绝其他批次的控制命令。
---@field sequence integer Controller 单调递增的本地序号；finish/abort 后写入 completed_sequence。
---@field new_module_context? FlyWowHotUpgradeNewModuleContext Update 中的临时声明权限；候选 Stage 完成后立即清除。
---@field module_stage? FlyWowHotUpgradeModuleStage 候选模块的旧/新导出记录；保留至 Finish 或 Abort。
---@field service_patch? FlyWowHotUpgradeServicePatchState Service 私有状态与函数的提交/恢复记录。

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

--- 按传入的 require 名找到 Lua 文件并确认其位于宿主 root_path 内。
---@param name string 调用方传入的 require 名；本函数用它在 package.path 查找 Lua 文件。
---@return FlyWowResult<FlyWowHotUpgradeModuleIdentity> 成功载荷为文件身份；路径、配置或来源不合法时返回稳定 HU 错误。
local function resolve_module_identity(name)
    -- Controller 初始化后发布的宿主根目录；缺失时不能确认模块文件归属。
    local root_path = skynet.getenv(hotupgrade_common.ROOT_PATH_ENV)
    if type(root_path) ~= "string" or root_path == "" then
        return flywow_result.failure("HU_NOT_INITIALIZED", "须先初始化 Controller，再声明可更新模块")
    end

    -- 用原始 require 名按当前 package.path 找文件，并拒绝 preload 伪装成可更新文件。
    local source_path, search_failure = package.searchpath(name, package.path)
    if not source_path then
        return flywow_result.failure("HU_INVALID_PATH", tostring(search_failure or ("无法定位模块: " .. name)))
    end
    if package.preload[name] ~= nil then
        return flywow_result.failure("HU_INVALID_PATH", "可更新模块不支持 package.preload: " .. name)
    end

    -- Native 解析符号链接后的路径；后续边界和登记身份都以此真实路径为准。
    local resolved_path, resolve_failure = hotupgrade_native.resolve(source_path)
    if not resolved_path then
        local code = type(resolve_failure) == "table" and resolve_failure.code or "HU_INVALID_PATH"
        local message = type(resolve_failure) == "table" and resolve_failure.message or tostring(resolve_failure)
        return flywow_result.failure(code, message)
    end

    -- 真实文件路径已确认在宿主根目录内，再准备前缀完成逐级边界校验。
    local root_prefix = root_path == "/" and "/" or root_path .. "/"
    if resolved_path:sub(1, #root_prefix) ~= root_prefix then
        return flywow_result.failure("HU_INVALID_PATH", "模块文件不在 root_path 内: " .. resolved_path)
    end

    -- 检查真实路径仍在宿主根目录内，再从相对 Lua 文件路径生成 Controller 模块名。
    local relative_path = resolved_path:sub(#root_prefix + 1)
    if relative_path:sub(-4) ~= ".lua" or relative_path:find("\\", 1, true) then
        return flywow_result.failure("HU_INVALID_PATH", "模块必须对应宿主目录中的 Lua 文件: " .. relative_path)
    end

    -- 路径边界通过后，从相对文件路径生成统一模块名。
    local canonical_name = relative_path:sub(1, -5):gsub("/", ".")
    if canonical_name == "" then
        return flywow_result.failure("HU_INVALID_PATH", "模块文件路径无效")
    end

    return flywow_result.success(
        {name = name, source_path = source_path, resolved_path = resolved_path, canonical_name = canonical_name})
end

-- 与 Controller Service 使用同一原生消息协议；不建立独立协议/RPC 模块。
skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID, pack = skynet.pack, unpack = skynet.unpack})

--- 通过 Controller 记录并调用 Skynet newservice 创建受管理 Service。
--- 创建 RPC 可能 yield；成功返回 handle，Controller 失败或原生调用抛错时按 Skynet API 习惯抛错。
---@param service_name string 要启动的 Skynet Service 入口名，例如 player_service；Controller 原样传给 skynet.newservice。
---@param ... any 传给新 Service 的入口参数；Controller 不解析，原样交给 skynet.newservice。
---@return integer service_handle 成功返回原生 handle；失败抛错，调用方可按原生 Skynet 入口使用 pcall。
function M.newservice(service_name, ...)
    -- 基础设施转发未知启动签名，固定 n 以保留参数个数和 nil。
    -- Controller 返回的 FlyWowResult；成功值里包含新 Service 的 handle。
    local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "newservice",
        {service_name = service_name, arguments = table.pack(...)})
    assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
    return answer.value.service_handle
end

--- 按 Controller 内的逻辑名创建或复用受管理 Service；同名并发调用会等待同一次创建结果。
--- 本地唯一名等待和创建可能 yield；传入 true 的全局唯一形式会抛错，调用方按原生入口使用 pcall。
---@param name_or_global string|boolean 本地唯一时传 Service 逻辑名；传 true 表示不支持的全局唯一形式。
---@param ... any 除第一个参数外的原生启动参数；仅首次创建时生效，Controller 原样转交 Skynet。
---@return integer service_handle 成功返回原生 handle；失败抛错，调用方可按原生 Skynet 入口使用 pcall。
function M.uniqueservice(name_or_global, ...)
    -- 保留调用方全部启动参数及 nil 位置，原样交给 Controller 查找或创建唯一 Service。
    local arguments = table.pack(...)
    -- true 重载表示 Skynet 全局唯一名；否则只按 Controller 内的逻辑名查找。
    local global = name_or_global == true
    -- Controller 用来匹配唯一 Service 的名字；全局重载时改从首个参数取名。
    local name = name_or_global
    if global then
        name = arguments[1]
        arguments = table.pack(table.unpack(arguments, 2, arguments.n))
    end

    -- 调用 Controller 查询或创建唯一 Service，并保留原生 handle/抛错合同。
    -- Controller 返回的 FlyWowResult；成功值里包含唯一 Service 的 handle。
    local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "uniqueservice",
        {service_name = name, global = global, arguments = arguments})
    assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
    return answer.value.service_handle
end

--- 通知 Controller 终止尚未登记的受管理 Service，并删除它的创建记录。
--- 只有原创建者能取消；未知 handle、已登记实例和非创建者都会得到失败结果。
---@param service_handle integer hotupgrade.newservice 返回的目标 handle；Controller 用它找到创建记录并核对创建者。
---@return FlyWowResult<nil> 取消结果。
function M.cancel_service_creation(service_handle)
    return skynet.call(get_hotupgrade_handle(), "hotupgrade", "cancel_service_creation",
        {service_handle = service_handle})
end

--- 用本批保存的状态快照和旧函数恢复当前 Service。
---@param batch FlyWowHotUpgradeServiceBatch 当前 Service 的本批恢复记录；本函数读取 old_state、old_functions 和 Service 恢复回调。
---@return FlyWowResult<nil> 恢复成功；回调拒绝或抛错时返回 HU_RECOVERY_REQUIRED。
local function restore_service(batch)
    -- 尚未触及线上 Service 状态时无需恢复；否则先恢复状态，再恢复业务函数引用。
    if not batch.service_patch or not batch.service_patch.touched then
        return flywow_result.success()
    end

    -- 本批没有 Service Patch 时无需恢复；存在时从快照恢复 Service 私有状态。
    local service_update = module_state.registration_config.service_update
    local restore_result = flywow_result.success()

    -- 自定义或默认状态恢复失败时保留结果，但仍继续装回所有旧函数。
    if batch.service_patch.has_old_state then
        if service_update.restore then
            local called, accepted = pcall(service_update.restore,
                service_update.state, batch.service_patch.old_state)
            if not called then
                restore_result = flywow_result.failure("HU_RECOVERY_REQUIRED", tostring(accepted))
            elseif type(accepted) ~= "table" or type(accepted.ok) ~= "boolean" then
                restore_result = flywow_result.failure("HU_RECOVERY_REQUIRED", "Service restore 必须返回 FlyWowResult<nil>")
            elseif not accepted.ok then
                restore_result = flywow_result.failure("HU_RECOVERY_REQUIRED",
                    accepted.message or accepted.code, {cause_code = accepted.code})
            end
        else
            restore_result = hotupgrade_module_patch.restore_state(
                batch.service_patch.old_state, service_update.state)
        end
    end

    -- 旧状态恢复完成后，再恢复原函数引用并保留 functions 表身份。
    for name, fn in pairs(batch.service_patch.old_functions) do
        rawset(service_update.functions, name, fn)
    end
    return restore_result
end

--- 结束当前 Service 的本地批次，记录已完成序号并清除活动记录。
--- 清理完成后将 patching 设为 false，重新允许业务入口执行。
---@param batch FlyWowHotUpgradeServiceBatch 已经完成 Finish 或 Abort 的本地批次；本函数读取其 sequence 和 batch_id 保存终态身份。
---@return nil
local function close_batch(batch)
    -- 本地完成序号和批次身份用于识别迟到或重复控制消息；释放 active_batch 后才重新接纳业务。
    module_state.completed_sequence = batch.sequence
    module_state.last_batch_id = batch.batch_id
    module_state.active_batch = nil
    M.patching = false
end

--- 尝试恢复当前 Service 的普通模块导出、私有状态和业务函数。
--- 恢复完成或失败都会关闭本地批次；恢复失败通过 HU_RECOVERY_REQUIRED 报告。
---@param batch FlyWowHotUpgradeServiceBatch Controller 要求回退的本地批次；本函数读取其模块 Stage 和 Service 恢复记录。
---@return FlyWowResult<nil> 成功表示本地恢复完成；失败以 HU_RECOVERY_REQUIRED 报告全部恢复错误。
local function abort(batch)
    -- 先尝试恢复 Service 私有状态，再恢复模块导出；一个失败也继续另一项。
    -- 汇总 Service 状态和模块导出的恢复错误；一项失败也继续尝试另一项。
    local errors = {}
    -- Service 私有状态恢复是否成功及其错误原因，供最终失败结果报告。
    local service_restore_result = restore_service(batch)
    if not service_restore_result.ok then
        errors[#errors + 1] = service_restore_result.message
    end

    -- Service 私有状态恢复后，再恢复本批可能已提交的普通模块导出。
    if batch.module_stage then
        -- 模块导出恢复结果；失败时记录错误并继续结束本地批次。
        local restored = hotupgrade_module_patch.abort(batch.module_stage)
        if not restored.ok then
            errors[#errors + 1] = restored.message
        end
    end

    -- 尽力恢复后清除本地批次并开放临时门禁；错误只通过结果报告。
    close_batch(batch)
    if #errors > 0 then
        return flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end
    return flywow_result.success()
end

---@class FlyWowHotUpgradeServicePatchDefinition
---@field new_modules? string[] 本 Service 本批首次加载的模块名；未登记依赖也须列入，从下一批普通 Stage 起参与候选匹配。
---@field update_state? fun() 在 Update 提交时直接修改构建函数捕获的现存 state；不得 yield 或产生外部副作用。
---@field replace_functions? table<string, function> 本次要替换的现有业务函数；未列出的字段保持原样。

---@class FlyWowHotUpgradeServicePatchState: FlyWowHotUpgradeServicePatchDefinition
---@field old_functions table<string, function> 本次替换前的函数；Abort 时逐项装回原业务函数表。
---@field has_old_state boolean 是否存在本次快照；用于保留 nil/false 等合法快照载荷。
---@field old_state any 自定义或默认 snapshot 返回的旧状态载荷；只在 has_old_state 为 true 时读取。
---@field touched boolean 提交开始写入业务状态或函数前置 true，失败时据此恢复。

--- 执行 Service .patch 构建回调，校验更新定义并保存恢复快照。
---@param service_patch_source string Controller 固定读取并发送的 Service .patch 源码。
---@return FlyWowResult<FlyWowHotUpgradeServicePatchState> 成功载荷为提交记录；构建代码异常或合同无效时返回 HU_SERVICE_STAGE_FAILED。
local function stage_service_patch(service_patch_source)
    -- 编译并执行受信 Patch 构建代码；这里只生成定义，不改动线上状态。
    local chunk, compile_failure = load(
        hotupgrade_common.normalize_source(service_patch_source), "=Service Patch", "t", _G)
    if not chunk then
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", tostring(compile_failure))
    end

    -- 源码编译成功后才执行候选 chunk，取得构建函数并生成本批定义。
    local service_update = module_state.registration_config.service_update
    local build_succeeded, build_patch = pcall(chunk)
    if not build_succeeded then
        local failure_text = tostring(build_patch)
        local cause_code, cause_message = failure_text:match("(HU_[A-Z0-9_]+):%s*(.*)$")
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", cause_message or failure_text,
            cause_code and {cause_code = cause_code} or nil)
    end
    if type(build_patch) ~= "function" then
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "Service Patch 必须返回构建函数")
    end

    -- 候选 chunk 返回构建函数后，以现存 Service 状态生成更新定义。
    local definition_succeeded, patch_definition = pcall(build_patch, service_update.state)
    if not definition_succeeded then
        local failure_text = tostring(patch_definition)
        local cause_code, cause_message = failure_text:match("(HU_[A-Z0-9_]+):%s*(.*)$")
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", cause_message or failure_text,
            cause_code and {cause_code = cause_code} or nil)
    end
    -- 校验状态回调、函数替换表和新模块清单的结构，拒绝不完整 Patch。
    if type(patch_definition) ~= "table" or getmetatable(patch_definition) ~= nil then
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "Service 构建结果必须是普通表")
    end
    if patch_definition.update_state ~= nil and type(patch_definition.update_state) ~= "function" then
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "update_state 必须是函数")
    end
    if patch_definition.replace_functions ~= nil and (type(patch_definition.replace_functions) ~= "table"
        or getmetatable(patch_definition.replace_functions) ~= nil) then
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "replace_functions 必须是普通表")
    end

    -- 基础更新回调和替换表通过后，校验可选的新模块声明数组。
    if patch_definition.new_modules ~= nil then
        if type(patch_definition.new_modules) ~= "table" or getmetatable(patch_definition.new_modules) ~= nil then
            return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "new_modules 必须是普通数组")
        end
        local item_count = 0
        local last_index = 0
        for index, module_name in pairs(patch_definition.new_modules) do
            if math.type(index) ~= "integer" or index <= 0 or type(module_name) ~= "string" or module_name == "" then
                return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "new_modules 必须是非空模块名组成的连续数组")
            end
            item_count = item_count + 1
            last_index = math.max(last_index, index)
        end
        if item_count ~= last_index then
            return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "new_modules 必须是连续数组")
        end
    end
    -- 各更新字段的结构已通过校验；拒绝没有任何实际更新内容的定义。
    if not (patch_definition.update_state
        or (patch_definition.replace_functions and next(patch_definition.replace_functions))
        or (patch_definition.new_modules and next(patch_definition.new_modules))) then
        return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "Service Patch 没有更新内容")
    end

    -- 定义字段和函数全部通过校验后，保存供 Update 与 Abort 使用的恢复记录。
    local service_patch =
    {
        update_state = patch_definition.update_state,
        replace_functions = patch_definition.replace_functions,
        new_modules = patch_definition.new_modules,
        old_functions = {},
        has_old_state = false,
        touched = false,
    }
    for name, replacement_function in pairs(patch_definition.replace_functions or {}) do
        if type(name) ~= "string" or type(replacement_function) ~= "function"
            or type(rawget(service_update.functions, name)) ~= "function" then
            return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "只能直接替换现有业务函数")
        end
        service_patch.old_functions[name] = rawget(service_update.functions, name)
    end

    -- 只在 Patch 会改状态时保存旧快照；has_old_state 另行标记 nil/false 合法载荷。
    if patch_definition.update_state then
        if service_update.snapshot then
            local snapshot_called, snapshot_result = pcall(service_update.snapshot, service_update.state)
            if not snapshot_called then
                return flywow_result.failure("HU_SERVICE_STAGE_FAILED", tostring(snapshot_result))
            end
            if type(snapshot_result) ~= "table" or type(snapshot_result.ok) ~= "boolean" then
                return flywow_result.failure("HU_SERVICE_STAGE_FAILED", "自定义 snapshot 必须返回 FlyWowResult<any>")
            end
            if not snapshot_result.ok then
                return flywow_result.failure("HU_SERVICE_STAGE_FAILED",
                    snapshot_result.message or snapshot_result.code, {cause_code = snapshot_result.code})
            end
            service_patch.old_state = snapshot_result.value
        else
            local snapshot_result = hotupgrade_module_patch.snapshot_state(service_update.state)
            if not snapshot_result.ok then
                return flywow_result.failure("HU_SERVICE_STAGE_FAILED", snapshot_result.message,
                    {cause_code = snapshot_result.code})
            end
            service_patch.old_state = snapshot_result.value
        end
        service_patch.has_old_state = true
    end
    return flywow_result.success(service_patch)
end

--- 构建 Service Patch、校验 new_modules 清单并执行对应首次加载登记。
---@param batch FlyWowHotUpgradeServiceBatch Controller 为本次 Update 建立的本地记录；本函数把 batch_id 绑定到新模块登记。
---@param service_patch_source? string 当前目标的 Service .patch 源码；nil 表示本批不更新 Service 状态或函数。
---@return FlyWowResult<FlyWowHotUpgradeServicePatchState|nil> 成功载荷为提交记录或 nil；失败保留所属阶段错误码。
local function stage_service_patch_and_new_modules(batch, service_patch_source)
    -- 临时上下文只允许当前 Update 协程加载 Patch 清单内的新模块。
    local new_module_context =
    {
        owner = coroutine.running(),
        batch_id = batch.batch_id,
        names = {},
    }
    batch.new_module_context = new_module_context
    if not service_patch_source then
        return flywow_result.success()
    end

    -- 先完整构建并验证清单，再解析所有模块身份，避免边加载边发现重复项。
    local service_patch_result = stage_service_patch(service_patch_source)
    if not service_patch_result.ok then
        batch.new_module_context = nil
        return service_patch_result
    end

    -- Service Patch 构建成功后，解析并登记它声明的新模块清单。
    local service_patch = service_patch_result.value
    local identities = {}
    for _, name in ipairs(service_patch.new_modules or {}) do
        local identity_result = resolve_module_identity(name)
        if not identity_result.ok then
            batch.new_module_context = nil
            return identity_result
        end
        local identity = identity_result.value
        if new_module_context.names[identity.canonical_name] then
            batch.new_module_context = nil
            return flywow_result.failure("HU_DUPLICATE_MODULE",
                "new_modules 重复指向同一文件: " .. identity.canonical_name)
        end
        new_module_context.names[identity.canonical_name] = true
        identities[#identities + 1] = identity
    end

    -- 身份集合核验完成后才逐项加载并登记，避免部分加载后才发现清单重复。
    for _, identity in ipairs(identities) do
        local load_result = require_module(identity.name, identity)
        if not load_result.ok then
            batch.new_module_context = nil
            return flywow_result.failure("HU_NEW_MODULE_FAILED", load_result.message,
                {cause_code = load_result.details and load_result.details.cause_code or load_result.code})
        end
    end
    return flywow_result.success(service_patch)
end

---@alias FlyWowHotUpgradeServiceCommand
---| "prepare"
---| "update"
---| "abort"
---| "finish"

--- 在本 Service 建立本批记录并设置 patching，阻止新的业务请求进入。
--- 随后调用 before_upgrade 等业务 queue 安全点；该回调可能 yield，失败留给 Controller Abort。
---@param request FlyWowHotUpgradeControlRequest Controller 发来的 Prepare 请求；本函数读取 batch_id 和 sequence 创建本地批次记录。
---@return FlyWowResult<nil> 回调失败或未确认安全点时保留批次记录，交由现有 Abort 收尾
local function prepare_batch(request)
    -- active_batch 是当前 Service 的本地记录；request 的身份来自 Controller，回调与业务对象仍只留在此 Lua State。
    if module_state.active_batch then
        return flywow_result.failure("HU_UPGRADE_BUSY", "当前批次已在处理中")
    end

    -- 批次身份和阶段均已校验；现在记录活动批次以拒绝并行更新。
    module_state.active_batch =
    {
        batch_id = request.batch_id, -- Controller 为本次发布生成的身份，后续控制命令必须一致。
        sequence = request.sequence, -- Controller 单调递增的批次序号，用于拒绝迟到命令。
        new_module_context = nil, -- 仅 Update 期间临时保存新模块清单；Prepare 与收尾阶段没有加载权限。
    }
    M.patching = true

    -- 业务安全点回调的执行状态和返回值；未明确确认安全点时本批不能进入 Update。
    local prepare_succeeded, prepare_result = pcall(module_state.registration_config.before_upgrade)

    if not prepare_succeeded then
        return flywow_result.failure("HU_PREPARE_FAILED", tostring(prepare_result))
    end
    if type(prepare_result) ~= "boolean" then
        return flywow_result.failure("HU_PREPARE_FAILED", "before_upgrade 必须返回 boolean")
    end
    if not prepare_result then
        return flywow_result.failure("HU_SAFEPOINT_REQUIRED", "before_upgrade 未确认业务安全点")
    end
    return flywow_result.success()
end

--- 根据 Controller 发送的候选源码准备普通模块和 Service 状态更新，再同步提交它们。
--- 新增模块的加载/登记可能 yield；失败时保留 Stage 与旧状态供 Abort 恢复。
---@param batch FlyWowHotUpgradeServiceBatch Prepare 已建立的本地批次；本函数把模块 Stage 和 Service 恢复记录写入其中。
---@param request FlyWowHotUpgradeControlRequest Controller 发给当前 Service 的 Update 内容；modules 保存普通模块名和源码，service_patch_source 保存可选的 Service .patch 源码。
---@return FlyWowResult<nil> 成功完成本 Service 的候选提交；失败保留恢复记录，交由 Abort 处理
local function update_batch(batch, request)
    -- request.modules 和 service_patch_source 是 Controller 为本批固定读取的候选输入。
    -- Controller 在 Prepare 收口时已固定普通候选；new_modules 在这里才首次加载并登记，从下一批 Stage 起才会匹配。
    -- Service Patch 构建和 new_modules 登记结果；成功后才能执行普通候选 Stage。
    local service_patch_result = stage_service_patch_and_new_modules(batch, request.service_patch_source)
    if not service_patch_result.ok then
        return service_patch_result
    end

    -- 当前 Service 的提交定义和恢复材料；本批没有匹配的 Service Patch 时为 nil。
    local service_patch = service_patch_result.value

    -- 保留同一声明上下文直到候选模块执行结束，漏列的新依赖须立即失败，不能在 UPDATE 等许可。
    -- 普通模块候选 Stage 的执行状态和结果；失败时需清除临时新模块加载权限。
    local module_result = hotupgrade_module_patch.stage(request.modules, module_state.declared_modules)
    batch.new_module_context = nil
    if not module_result.ok then
        return module_result
    end

    -- 候选模块 Stage 成功后，记录模块暂存和 Service Patch 供提交或恢复。
    batch.module_stage = module_result.value.stage
    batch.service_patch = service_patch

    -- Activate 同步提交；失败先报告，再由 Controller 串行 Abort 整批目标。
    -- 原地安装候选模块导出的结果；失败后由 Controller 调用 Abort 恢复。
    local commit_result = hotupgrade_module_patch.commit(batch.module_stage)
    if not commit_result.ok then
        return flywow_result.failure("HU_ACTIVATE_FAILED", commit_result.message)
    end

    -- 捕获 Service 状态、函数及 after_upgrade 提交异常，交由 Controller 统一 Abort。
    local activation_succeeded, after_upgrade_result = pcall(function()
        if service_patch then
            -- 当前 Service 原有状态表和函数表；更新只改字段，不替换根表。
            local service_update = module_state.registration_config.service_update
            service_patch.touched = true
            if service_patch.update_state then
                service_patch.update_state()
            end

            -- name 是 Patch 指定的业务函数字段，fn 是准备安装的新实现。
            for name, fn in pairs(service_patch.replace_functions or {}) do
                rawset(service_update.functions, name, fn)
            end
        end

        if module_state.registration_config.after_upgrade then
            return module_state.registration_config.after_upgrade()
        end
    end)

    if not activation_succeeded then
        return flywow_result.failure("HU_ACTIVATE_FAILED", tostring(after_upgrade_result))
    end
    if module_state.registration_config.after_upgrade and type(after_upgrade_result) ~= "boolean" then
        return flywow_result.failure("HU_ACTIVATE_FAILED", "after_upgrade 必须返回 boolean")
    end
    if module_state.registration_config.after_upgrade and not after_upgrade_result then
        return flywow_result.failure("HU_ACTIVATE_FAILED", "after_upgrade 拒绝更新")
    end

    return flywow_result.success()
end

--- 确认本 Service 的 Update 成功，释放普通模块 Stage 和 Service 恢复记录。
--- Finish 不执行回滚；完成后重新开放业务入口。
---@param batch FlyWowHotUpgradeServiceBatch Prepare 建立且 Update 已成功的本地批次；本函数释放其中保存的候选和恢复快照。
---@return FlyWowResult<nil> 释放模块 Stage 快照的结果；完成后关闭本地批次并重新开放业务入口
local function finish_batch(batch)
    -- Controller 仅在全部目标 Update 成功后发送 Finish；这里释放旧/新导出引用并开放业务入口。
    local finished = hotupgrade_module_patch.finish(batch.module_stage)
    close_batch(batch)
    return finished
end

--- 核对消息来源和批次身份后，将 prepare、update、abort、finish 分派到本地对应步骤。
--- 本函数不实现阶段细节；阶段结果和可能的 yield 原样返回给 RPC 分发器。
---@param command FlyWowHotUpgradeServiceCommand Controller 发来的阶段名，只接受 prepare、update、abort 或 finish。
---@param request FlyWowHotUpgradeControlRequest Controller 发来的批次号、序号及 Update 候选；本函数将其交给对应阶段处理。
---@param source integer Skynet 消息头提供的调用方 handle；本函数用它确认请求来自宿主 Controller。
---@return FlyWowResult<nil> Prepare/Update/Abort 可能 yield；阶段错误原样返回，异常交由 dispatch_upgrade_command 转换。
local function handle_upgrade(command, request, source)
    -- 先核验 Controller 来源；批次身份由 Controller 生成，再与本地批次记录比对。
    if source ~= module_state.hotupgrade_handle then
        return flywow_result.failure("HU_UNAUTHORIZED", "控制来源不匹配")
    end

    if command ~= "prepare" and command ~= "update" and command ~= "abort" and command ~= "finish" then
        return flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
    end

    if module_state.last_batch_id == request.batch_id and (command == "abort" or command == "finish") then
        return flywow_result.success()
    end

    if request.sequence <= module_state.completed_sequence or (module_state.active_batch and module_state.active_batch.batch_id ~= request.batch_id) then
        return flywow_result.failure("HU_STALE_BATCH", "过期或冲突批次命令")
    end

    if command == "prepare" then
        return prepare_batch(request)
    end

    -- 当前 Service 正在处理的本地批次；用它核对 Controller 命令的序号和身份。
    local batch = module_state.active_batch
    if not batch or batch.sequence ~= request.sequence then
        return flywow_result.failure("HU_STALE_BATCH", "未取得本批次安全点")
    end

    if command == "abort" then
        return abort(batch)
    end

    if command == "update" then
        return update_batch(batch, request)
    end
    if command == "finish" then
        return finish_batch(batch)
    end

    return flywow_result.failure("HU_PHASE_INVALID", "当前阶段不能执行 " .. tostring(command))
end

--- 接收原生 hotupgrade 协议消息，调用 handle_upgrade 并把 FlyWowResult 回给 RPC 调用方。
--- 控制处理异常由这里转换为失败结果，并按当前发布阶段执行既有清理。
---@param session integer Skynet 消息头中的 RPC session；为 0 时表示调用方不等待回包。
---@param source integer Skynet 消息头中的真实发送方 handle；传给 handle_upgrade 核对 Controller 身份。
---@param command FlyWowHotUpgradeServiceCommand RPC 解包得到的热更阶段名，随后传给 handle_upgrade 分派。
---@param request FlyWowHotUpgradeControlRequest RPC 解包得到的批次请求；包含批次身份，Update 时还携带候选源码。
---@return nil 回复 FlyWowResult；异常转换沿用 HU_CONTROL_FAILED 和原有 Abort/Finish 清理
local function dispatch_upgrade_command(session, source, command, request)
    -- 控制阶段的执行状态和结果；异常在此转换并按发布阶段完成收尾。
    local control_succeeded, control_result = pcall(handle_upgrade, command, request, source)
    if not control_succeeded then
        -- 异常也必须结束本批；Finish 已越过发布决定，只释放快照而不回滚。
        -- 原始控制异常结果；Abort 也失败时会作为 details 返回给调用方。
        local original = flywow_result.failure("HU_CONTROL_FAILED", tostring(control_result))
        -- 当前仍未结束的本地批次；Finish 异常只能释放记录，不能回滚已发布更新。
        local batch = module_state.active_batch
        if batch and command ~= "finish" then
            control_result = abort(batch)
            if control_result.ok then
                control_result = original
            else
                control_result.details = {original_error = original}
            end
        else
            if batch then
                if batch.module_stage then
                    hotupgrade_module_patch.finish(batch.module_stage)
                end
                close_batch(batch)
            end
            control_result = original
        end
    end

    -- 控制命令的状态清理完成后，只向真实请求会话返回结果。
    if session ~= 0 then
        skynet.retpack(control_result)
    end
end

---@class FlyWowHotUpgradeServiceUpdate
---@field state table 现存 Service 私有状态表；更新只改其字段，不替换该表。
---@field functions table Service 原有业务函数表；Patch 只替换本次列出的现有函数字段。
---@field snapshot? fun(state:table):FlyWowResult<any> 更新前生成与线上对象隔离的恢复快照；与 restore 成对提供。
---@field restore? fun(state:table, old_state:any):FlyWowResult<nil> 提交失败时同步恢复快照；失败结果或抛错映射为 HU_RECOVERY_REQUIRED，仍结束本批次记录。

---@class FlyWowHotUpgradeRegistration
---@field service_update? FlyWowHotUpgradeServiceUpdate 可选 Service 内部状态/函数更新入口
---@field before_upgrade fun():boolean 注册必填；每次 Prepare 设置 patching 后调用，允许 yield；须通过业务自己的 queue 确认此前业务结束。true 才允许 Update，false 拒绝并 Abort；抛错转换为 HU_PREPARE_FAILED
---@field after_upgrade? fun():boolean Update 内 Activate 提交模块与 Service 状态后、finish 前调用；true 确认提交，false 拒绝并触发恢复；返回非 boolean 或抛错转换为 HU_ACTIVATE_FAILED

--- 在当前 Lua State 登记本 Service 的模块清单和可选状态更新回调。
--- 登记会向 Controller 发 RPC，可能 yield；返回成功前宿主不能把 Service 标为 READY。
---@param registration FlyWowHotUpgradeRegistration 当前 Service 启动代码准备的登记表；Controller 用 before_upgrade 排空业务，并保存可选的 service_update、after_upgrade。
---@return FlyWowResult<nil> 登记结果
function M.register_service(registration)
    -- 固定本 State 的登记回调后，Controller RPC 会 yield。
    -- 期间到达的并发 require 暂停在 registration_waiters，等待登记结果后继续或失败返回。
    -- 先验证回调与可选更新入口合同；检查完成前不安装 dispatch 或登记状态。
    if module_state.registration_config then
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

    -- 本次登记要保存在当前 State 的业务更新入口；Controller 只接收它是否存在。
    local service_update = registration.service_update
    if service_update ~= nil then
        if type(service_update) ~= "table" or type(service_update.state) ~= "table"
            or type(service_update.functions) ~= "table" or getmetatable(service_update.functions) ~= nil then
            return flywow_result.failure("HU_INVALID_OPTIONS", "Service 更新入口需要私有 state 与现有函数表")
        end

        -- 标记宿主是否提供自定义快照和恢复；两者必须成对出现。
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
    module_state.registration_config = registration
    skynet.dispatch("hotupgrade", dispatch_upgrade_command)
    -- 收集完整模块声明并排序，形成跨 Service 传递的稳定元数据快照。
    -- 收集本 State 通过 hotupgrade.require 声明的模块名，发送前排序成稳定数组。
    local names = {}
    for name in pairs(module_state.declared_modules) do
        names[#names + 1] = name
    end

    -- 模块名集合收集完成后排序，保证登记快照顺序稳定。
    table.sort(names)
    ---@type FlyWowHotUpgradeTargetMetadata
    -- 发给 Controller 的登记快照；业务状态、函数和回调不跨 Lua State 传递。
    local metadata =
    {
        modules = names,
        has_service_update = service_update ~= nil,
    }
    -- Controller 登记 RPC 是否正常返回，以及它对本 State 登记请求的答复。
    local registration_call_succeeded, registration_response = pcall(
        skynet.call, get_hotupgrade_handle(), "hotupgrade", "register", metadata)
    -- 先保存 Controller 的最终答复；等待中的 require 恢复后会据此决定是否继续加载。
    local response_is_result = type(registration_response) == "table"
        and type(registration_response.ok) == "boolean"
    module_state.registration_result = registration_call_succeeded and response_is_result
        and registration_response.ok == true
    -- Controller 答复已固定；唤醒所有因本次登记尚未完成而暂停的 require 协程。
    for _, waiting_require_thread in ipairs(module_state.registration_waiters) do
        skynet.wakeup(waiting_require_thread)
    end

    -- 等待者已收到唤醒信号，释放本轮协程引用。
    -- RPC 成功时它们继续加载；失败时它们返回 HU_SERVICE_NOT_REGISTERED。
    module_state.registration_waiters = {}
    -- RPC 失败可能意味着 Controller 已登记；保持本 State 配置，要求宿主终止未 READY 的启动。
    if not registration_call_succeeded or not response_is_result then
        return flywow_result.failure("HU_RPC_FAILED", tostring(registration_response))
    end
    return registration_response
end

--- 调用原生 require 并验证模块表确实来自已解析的 Lua 文件。
---@param name string 业务调用方传入的 require 名；用于访问原名缓存。
---@param module_identity FlyWowHotUpgradeModuleIdentity 已核实的文件身份；用于核对加载来源。
---@param module_load_attempt table 本次加载记录；本函数写入模块表、路径及新增来源映射标记。
---@return FlyWowResult<nil> 验证成功；Native 来源或导出不符时返回对应 HU 错误。
local function load_module_exports(name, module_identity, module_load_attempt)
    -- 读取本次确认的文件身份与缓存快照，先拒绝来源不明或别名占用。
    local source_path = module_identity.source_path
    local resolved_path = module_identity.resolved_path
    local canonical_name = module_identity.canonical_name
    module_load_attempt.module_exports = module_load_attempt.cache_snapshot.module
    if module_load_attempt.cache_snapshot.module ~= nil
        and (type(module_load_attempt.cache_snapshot.module) ~= "table"
            or module_state.module_sources[module_load_attempt.cache_snapshot.module] ~= resolved_path) then
        return flywow_result.failure("HU_INVALID_PATH",
            "无法确认缓存模块来源，须先通过 hotupgrade.require 加载: " .. name)
    end
    if package.preload[canonical_name] ~= nil or package.preload[name] ~= nil then
        return flywow_result.failure("HU_DUPLICATE_MODULE",
            "模块名称已被 package.preload 占用: " .. canonical_name)
    end

    -- 排除缓存占用冲突后，核对规范别名是否仍指向已登记文件。
    local cached_alias = module_load_attempt.cache_snapshot.canonical_alias
    if cached_alias ~= nil and (not rawequal(cached_alias, module_load_attempt.cache_snapshot.module)
        or module_state.module_sources[cached_alias] ~= resolved_path) then
        return flywow_result.failure("HU_DUPLICATE_MODULE",
            "模块路径登记名已被其他模块占用: " .. canonical_name)
    end

    -- 缓存为空时才调用原生 require；加载、返回值和真实文件来源均在此边界校验。
    if module_load_attempt.module_exports == nil then
        local require_succeeded, module_exports, loader_path = pcall(require, name)
        if not require_succeeded then
            local failure_text = tostring(module_exports)
            local cause_code, cause_message = failure_text:match("(HU_[A-Z0-9_]+):%s*(.*)$")
            return flywow_result.failure("HU_MODULE_LOAD_FAILED", cause_message or failure_text,
                cause_code and {cause_code = cause_code} or nil)
        end
        module_load_attempt.module_exports = module_exports
        module_load_attempt.loader_path = loader_path
        if type(module_exports) ~= "table" then
            return flywow_result.failure("HU_MODULE_EXPORTS_INVALID", "可更新模块必须返回 table")
        end
        if loader_path ~= nil then
            if type(loader_path) ~= "string" then
                return flywow_result.failure("HU_INVALID_PATH", "原生 require 返回了无效模块路径: " .. name)
            end
            local actual_path, path_failure = hotupgrade_native.resolve(loader_path)
            if actual_path ~= resolved_path then
                local message = type(path_failure) == "table" and path_failure.message or tostring(path_failure)
                return flywow_result.failure("HU_INVALID_PATH",
                    "模块加载来源与 package.path 不一致: " .. name .. ": " .. message)
            end
        else
            local loadfile_succeeded, loader_chunk = pcall(loadfile, source_path, "t")
            if require ~= skynet_require.require or not loadfile_succeeded or not loader_chunk then
                return flywow_result.failure("HU_INVALID_PATH",
                    "加载器未提供可确认的模块来源: " .. name)
            end
        end
        -- 只有来源和缓存别名全部匹配后才记录新模块表的来源。
        local previous_source = module_state.module_sources[module_exports]
        if previous_source ~= nil and previous_source ~= resolved_path then
            return flywow_result.failure("HU_DUPLICATE_MODULE", "同一模块表已对应其他文件: " .. name)
        end
        if package.preload[name] ~= nil or package.preload[canonical_name] ~= nil then
            return flywow_result.failure("HU_DUPLICATE_MODULE",
                "模块名称已被 package.preload 占用: " .. canonical_name)
        end
        local canonical_cache = package.loaded[canonical_name]
        if canonical_cache ~= nil and not rawequal(canonical_cache, module_exports) then
            return flywow_result.failure("HU_DUPLICATE_MODULE",
                "模块路径登记名已被其他模块占用: " .. canonical_name)
        end
        module_load_attempt.loader_path = loader_path or source_path
        if previous_source == nil then
            module_state.module_sources[module_exports] = resolved_path
            module_load_attempt.source_mapping_added = true
        end
    end
    return flywow_result.success()
end

--- 完成模块首次加载、许可和登记，并在失败时回退本次缓存变更。
---@param name string 当前调用使用的 require 名；用于读写原名缓存并加载文件。
---@param module_identity FlyWowHotUpgradeModuleIdentity 已确认的模块文件身份；用于统一登记名和来源检查。
---@param new_module_context? FlyWowHotUpgradeNewModuleContext 当前 Update 的声明清单；存在时绑定新模块登记。
---@param register_new_module? boolean 是否走本批新模块登记通道。
---@return FlyWowResult<table> 成功载荷为模块表；许可、加载或登记失败返回稳定 HU 错误。
local function load_and_register_module(name, module_identity, new_module_context, register_new_module)
    -- 本次加载的统一身份；许可、缓存别名、登记和失败回退都使用它。
    local canonical_name = module_identity.canonical_name
    local attempt =
    {
        loader_path = module_identity.source_path,
        permit_id = nil,
        cache_snapshot = nil,
        module_exports = nil,
        source_mapping_added = false,
        module_declaration_added = false,
    }
    local result = flywow_result.success()

    -- 已登记 Service 的普通首次加载先申请许可；本批清单新模块走专用登记通道。
    if module_state.registration_config and not module_state.declared_modules[canonical_name]
        and not register_new_module then
        local called, answer = pcall(skynet.call, get_hotupgrade_handle(), "hotupgrade",
            "begin_module_load", {name = canonical_name})
        if not called then
            result = flywow_result.failure("HU_RPC_FAILED", tostring(answer))
        elseif type(answer) ~= "table" or type(answer.ok) ~= "boolean" then
            result = flywow_result.failure("HU_RPC_FAILED", "begin_module_load 返回无效结果")
        elseif not answer.ok then
            result = answer
        elseif type(answer.value) ~= "table" or type(answer.value.permit_id) ~= "string" then
            result = flywow_result.failure("HU_RPC_FAILED", "begin_module_load 未返回许可 ID")
        else
            attempt.permit_id = answer.value.permit_id
        end
    end

    -- 许可成功后保存两个缓存槽，再验证并加载模块；后续失败据此原样回退。
    if result.ok then
        attempt.cache_snapshot =
        {
            module = package.loaded[name],
            canonical_alias = package.loaded[canonical_name],
        }
        result = load_module_exports(name, module_identity, attempt)
    end

    -- 本地缓存和声明建立后再向 Controller 登记，避免远端看到未完成的本地状态。
    if result.ok then
        package.loaded[canonical_name] = attempt.module_exports
        if not module_state.declared_modules[canonical_name] then
            module_state.declared_modules[canonical_name] =
                {name = name, path = attempt.loader_path}
            attempt.module_declaration_added = true
        end

        local command
        local request
        -- 本地登记状态恢复后，尽力通知 Controller 取消未消费的首次加载许可。
    if attempt.permit_id then
            command = "register_module"
            request = {name = canonical_name, permit_id = attempt.permit_id}
        elseif register_new_module and attempt.module_declaration_added then
            command = "register_new_module"
            request = {batch_id = new_module_context.batch_id, name = canonical_name}
        end
        if command then
            local called, answer = pcall(skynet.call, get_hotupgrade_handle(), "hotupgrade", command, request)
            if not called then
                result = flywow_result.failure("HU_RPC_FAILED", tostring(answer))
            elseif type(answer) ~= "table" or type(answer.ok) ~= "boolean" then
                result = flywow_result.failure("HU_RPC_FAILED", command .. " 返回无效结果")
            else
                result = answer
            end
        else
            result = flywow_result.success(attempt.module_exports)
        end
    end

    if result.ok then
        return flywow_result.success(attempt.module_exports)
    end

    -- 登记失败时回退缓存、来源映射和本地声明，并尽力取消仍在途的许可。
    if attempt.cache_snapshot then
        package.loaded[name] = attempt.cache_snapshot.module
        package.loaded[canonical_name] = attempt.cache_snapshot.canonical_alias
    end

    -- 缓存恢复后，逐项撤销本次加载新增的来源映射与模块声明。
    if attempt.source_mapping_added then
        module_state.module_sources[attempt.module_exports] = nil
    end

    -- 来源映射恢复后，再移除本次添加的本地模块声明。
    if attempt.module_declaration_added then
        module_state.declared_modules[canonical_name] = nil
    end

    -- 本地登记状态恢复后，尽力通知 Controller 取消未消费的首次加载许可。
    if attempt.permit_id then
        pcall(skynet.call, get_hotupgrade_handle(), "hotupgrade",
            "cancel_module_load", {name = canonical_name, permit_id = attempt.permit_id})
    end
    return result
end

--- 已验证身份的首次加载与登记；等待许可或同模块加载时可能 yield。
---@param name string 业务代码原本传给 require 的模块名；用于读写原名缓存。
---@param module_identity FlyWowHotUpgradeModuleIdentity 已找到并校验的文件身份；用于登记统一模块名。
---@return FlyWowResult<table> 成功载荷为稳定模块表；加载或许可失败以 HU 错误结果返回。
require_module = function(name, module_identity)
    local canonical_name = module_identity.canonical_name
    local new_module_context = module_state.active_batch
        and module_state.active_batch.new_module_context
    local in_new_module_context = new_module_context
        and new_module_context.owner == coroutine.running()
    local register_new_module = in_new_module_context
        and new_module_context.names[canonical_name] == true
    if in_new_module_context and not module_state.declared_modules[canonical_name]
        and not register_new_module then
        return flywow_result.failure("HU_NEW_MODULE_NOT_DECLARED",
            "新模块依赖未列入 new_modules: " .. canonical_name)
    end

    if module_state.registration_config then
        if module_state.registration_result == nil then
            -- register_service 的 skynet.call 尚未返回，登记成败仍未知。
            -- 暂停当前 require，避免在 Controller 确认登记前加载并暴露模块。
            local waiting_require_thread = coroutine.running()
            module_state.registration_waiters[#module_state.registration_waiters + 1] = waiting_require_thread
            skynet.wait(waiting_require_thread)
        end
        if module_state.registration_result ~= true then
            return flywow_result.failure("HU_SERVICE_NOT_REGISTERED", "首次登记失败，须终止本次启动")
        end
    end

    local module_load = module_state.module_loads[canonical_name]
    if module_load then
        local thread = coroutine.running()
        if register_new_module and module_load.owner ~= thread then
            return flywow_result.failure("HU_MODULE_LOADING", "新模块正由其他协程加载: " .. canonical_name)
        end
        if module_load.owner == thread then
            return flywow_result.failure("HU_MODULE_LOADING", "不支持循环声明: " .. canonical_name)
        end
        module_load.waiters[#module_load.waiters + 1] = thread
        skynet.wait(thread)
        return require_module(name, module_identity)
    end

    module_load = {owner = coroutine.running(), waiters = {}}
    module_state.module_loads[canonical_name] = module_load
    local result = load_and_register_module(name, module_identity, new_module_context, register_new_module)
    module_state.module_loads[canonical_name] = nil
    for _, thread in ipairs(module_load.waiters) do
        skynet.wakeup(thread)
    end
    return result
end

--- 加载并登记一个普通 Lua 模块，返回当前 Lua State 的模块导出表。
--- 保持 require 的成功单值和失败抛错行为；首次加载、许可或并发等待可能 yield，失败可由调用方用 pcall 捕获。
---@param name string 调用方原有的 require 模块名；本函数用 package.path 定位文件，再向 Controller 登记统一模块名。
---@return table module_exports 成功返回稳定模块表；失败抛错，可能 yield。
function M.require(name)
    -- 保持原生 require 的参数错误行为，随后确认模块名对应的真实文件身份。
    if type(name) ~= "string" or name == "" then
        error("HU_INVALID_REQUEST: 模块名无效", 2)
    end

    -- 参数形状通过后解析模块真实路径与统一身份，再进入受控加载和登记。
    local identity_result = resolve_module_identity(name)
    if not identity_result.ok then
        error(identity_result.code .. ": " .. identity_result.message, 2)
    end

    -- 身份校验通过后才加载并登记模块；失败仍按原生 require 抛错。
    local require_result = require_module(name, identity_result.value)
    if not require_result.ok then
        error(tostring(require_result.code or "HU_MODULE_LOAD_FAILED") .. ": " .. tostring(require_result.message), 2)
    end
    return require_result.value
end

return M
