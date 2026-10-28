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
    registration_waiters  = {},                               -- 登记 RPC 期间等待最终结果的首次 require 协程。
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
---@field phase? string nil 表示 Update 尚未开始，之后为 UPDATING 或 ACTIVATED；Finish/Abort 结束时批次记录本身被清除。
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

--- 按传入的 require 名找到 Lua 文件，确认它位于宿主 root_path 内，并生成 Controller 使用的统一模块名。
--- 普通首次加载和本批 new_modules 都通过这份文件身份识别模块。
---@param name string 调用方传入的 require 名，例如 player_logic；本函数用它在 package.path 查找 Lua 文件。
---@return FlyWowHotUpgradeModuleIdentity 已通过 root_path 边界检查的模块身份
local function resolve_module_identity(name)
    -- 宿主配置给本 State 使用的 Lua 根目录；用来确认模块文件没有越出运行目录。
    local root_path = assert(skynet.getenv(hotupgrade_common.ROOT_PATH_ENV),
        "HU_NOT_INITIALIZED: 须先初始化 Controller，再声明可更新模块")
    -- Lua 按调用方名称在 package.path 找到的文件；用于核对实际加载来源。
    local source_path = assert(package.searchpath(name, package.path),
        "HU_INVALID_PATH: 可更新模块必须能通过 package.path 定位 Lua 文件: " .. name)
    assert(package.preload[name] == nil, "HU_INVALID_PATH: 可更新模块不支持 package.preload: " .. name)
    -- 去掉符号链接后的实际文件路径；Controller 登记和缓存来源都按它识别文件。
    local resolved_path = assert(hotupgrade_native.resolve(source_path),
        "HU_INVALID_PATH: 无法解析模块文件路径: " .. source_path)
    -- 以目录分隔符结尾的根路径前缀，避免 /game 与 /game-old 被当成同一目录。
    local root_prefix = root_path == "/" and "/" or root_path .. "/"
    assert(resolved_path:sub(1, #root_prefix) == root_prefix,
        "HU_INVALID_PATH: 模块文件不在 root_path 内: " .. resolved_path)
    -- 模块文件相对宿主 Lua 根目录的位置，后面将路径中的 / 换成 . 生成模块名。
    local relative_path = resolved_path:sub(#root_prefix + 1)
    assert(relative_path:sub(-4) == ".lua" and not relative_path:find("\\", 1, true),
        "HU_INVALID_PATH: 模块必须对应宿主目录中的 Lua 文件: " .. relative_path)
    -- Controller 使用的模块名；例如 lualib/player/logic.lua 变为 lualib.player.logic。
    local canonical_name = relative_path:sub(1, -5):gsub("/", ".")
    assert(canonical_name ~= "", "HU_INVALID_PATH: 模块文件路径无效")
    return {name = name, source_path = source_path, resolved_path = resolved_path, canonical_name = canonical_name}
end

-- 与 Controller Service 使用同一原生消息协议；不建立独立协议/RPC 模块。
skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID, pack = skynet.pack, unpack = skynet.unpack})

--- 通过 Controller 记录并调用 Skynet newservice 创建受管理 Service。
--- 创建 RPC 可能 yield；返回 handle 后由调用方负责业务 init 和 register_service。
---@param service_name string 要启动的 Skynet Service 入口名，例如 player_service；Controller 原样传给 skynet.newservice。
---@param ... any 传给新 Service 的入口参数；Controller 不解析，原样交给 skynet.newservice。
---@return integer service_handle
function M.newservice(service_name, ...)
    -- 基础设施转发未知启动签名，固定 n 以保留参数个数和 nil。
    -- Controller 返回的 FlyWowResult；成功值里包含新 Service 的 handle。
    local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "newservice",
        {service_name = service_name, arguments = table.pack(...)})
    assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
    return answer.value.service_handle
end

--- 按 Controller 内的逻辑名创建或复用受管理 Service；同名并发调用会等待同一次创建结果。
--- 本地唯一名等待和创建可能 yield；传入 true 的全局唯一形式会明确失败。
---@param name_or_global string|boolean 本地唯一时传 Service 逻辑名；传 true 表示不支持的全局唯一形式。
---@param ... any 除第一个参数外的原生启动参数；仅首次创建时生效，Controller 原样转交 Skynet。
---@return integer service_handle
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
--- 即使状态恢复回调失败，也会继续恢复旧函数；错误向上抛给 Abort 汇总。
---@param batch FlyWowHotUpgradeServiceBatch 当前 Service 的本批恢复记录；本函数读取其中的 old_state、old_functions 和 service_update.restore。
---@return nil 无返回值；恢复回调失败时抛出异常。
local function restore_service(batch)
    -- service_patch 保存本 State 在 Stage 留下的旧状态和旧函数；touched 为 false 时尚未写业务对象。
    if not batch.service_patch or not batch.service_patch.touched then
        return
    end

    -- 本 State 登记时提供的业务恢复入口；通过它恢复保存过的私有状态。
    local service_update = module_state.registration_config.service_update
    -- 自定义恢复只处理 Service 自己的对象；即使它失败也继续尝试还原函数字段。
    -- 捕获业务恢复回调异常，确保后续恢复旧函数的步骤仍会执行。
    local restore_succeeded, restore_failure = pcall(function()
        if batch.service_patch.old_state then
            if service_update.restore then
                assert(service_update.restore(service_update.state, batch.service_patch.old_state) ~= false, "Service 拒绝恢复")
            else
                hotupgrade_module_patch.restore_state(batch.service_patch.old_state, service_update.state)
            end
        end
    end)

    for name, fn in pairs(batch.service_patch.old_functions) do
        rawset(service_update.functions, name, fn)
    end

    assert(restore_succeeded, restore_failure)
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
    local service_restore_succeeded, service_restore_failure = pcall(restore_service, batch)
    if not service_restore_succeeded then
        errors[#errors + 1] = tostring(service_restore_failure)
    end

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
---@field old_state? table 提交前的隔离状态快照；只有 update_state 存在时保存。
---@field touched boolean 提交开始写入业务状态或函数前置 true，失败时据此恢复。

--- 编译并运行 Service .patch 的构建函数，收集状态更新回调、函数替换表和 new_modules 清单。
--- 此步只准备本地候选和恢复快照，不写入线上状态或函数。
---@param service_patch_source string Controller 从本批发布包读取并发送的 Service .patch 源码；本函数执行它以取得状态更新回调、函数替换表和 new_modules 清单。
---@return FlyWowHotUpgradeServicePatchState service_patch 本 State 的提交内容及恢复快照；准备失败抛出异常，由控制入口转换为 FlyWowResult。
local function stage_service_patch(service_patch_source)
    -- registration_config.service_update 持有业务原有的 state/functions 及恢复回调；构建函数捕获这些对象，不能替换其根表。
    -- 执行受信 Patch 构建函数并校验结果；此时尚不写入线上状态。
    -- 本 State 登记的业务对象和恢复回调；Patch 构建函数会捕获其中的 state 根表。
    local service_update = module_state.registration_config.service_update
    -- 已部署 Service Patch 的编译结果；执行后必须返回构建更新定义的函数。
    local chunk = assert(load(hotupgrade_common.normalize_source(service_patch_source), "=Service Patch", "t", _G))
    -- Patch 源码返回的构建函数；它读取现存业务状态并描述本批修改。
    local build_patch = chunk()
    assert(type(build_patch) == "function", "Service Patch 必须返回构建函数")
    ---@type FlyWowHotUpgradeServicePatchDefinition
    -- 业务 Patch 对现存状态生成的更新定义；此处只读取，不修改线上对象。
    local patch_definition = build_patch(service_update.state)

    assert(type(patch_definition) == "table" and getmetatable(patch_definition) == nil, "Service 构建结果必须是普通表")
    assert(patch_definition.update_state == nil or type(patch_definition.update_state) == "function", "update_state 必须是函数")
    assert(patch_definition.replace_functions == nil or (type(patch_definition.replace_functions) == "table"
        and getmetatable(patch_definition.replace_functions) == nil), "replace_functions 必须是普通表")
    if patch_definition.new_modules ~= nil then
        assert(type(patch_definition.new_modules) == "table" and getmetatable(patch_definition.new_modules) == nil,
            "new_modules 必须是普通数组")
        -- 统计声明清单中的模块数量，与最大下标比较以拒绝稀疏数组。
        local item_count = 0
        -- 记录声明清单的最大下标，用于确认它是连续数组。
        local last_index = 0
        -- index 用于检查数组连续性，module_name 是宿主声明的新模块加载名。
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
    ---@type FlyWowHotUpgradeServicePatchState
    local service_patch =
    {
        update_state      = patch_definition.update_state,      -- 本 State 的提交回调，不发送给 Controller。
        replace_functions = patch_definition.replace_functions, -- 本次要安装的函数，提交时直接使用。
        new_modules       = patch_definition.new_modules,       -- 原始声明清单，随后解析一次模块身份。
        old_functions     = {},                                -- 本次将替换的旧函数，失败时逐字段恢复。
        touched           = false,                             -- 首次线上写入前置 true，部分提交同样必须恢复。
    }
    -- name 是现有业务函数字段，replacement_function 是本批准备安装的新实现。
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

--- 运行 Service .patch 构建函数，核对 new_modules 清单并加载登记其中的模块。
--- 新模块登记 RPC 可能 yield；清单外的首次加载会失败，错误结果会带回 Controller。
---@param batch FlyWowHotUpgradeServiceBatch Controller 为本次 Update 建立的 Service 本地记录；本函数读取 batch_id，让 new_modules 登记归入同一批热更。
---@param service_patch_source? string Controller 为当前 Service 匹配到的 .patch 源码；没有对应 .patch 时为 nil，本函数跳过 Service 状态和函数更新。
---@return FlyWowResult<FlyWowHotUpgradeServicePatchState|nil> 加载/登记可能 yield；成功返回提交记录或 nil，失败清除上下文并报告 HU_ 错误码。
local function stage_service_patch_and_new_modules(batch, service_patch_source)
    -- 清单保留到普通候选 Stage 结束；未声明的新依赖立即失败，不能申请普通许可后与本批 Update 互等。
    -- 只授权当前 Update 协程加载清单内的新模块，并将登记请求绑定到本批次。
    local new_module_context =
    {
        owner = coroutine.running(), -- 允许本批声明新模块加载的 Update 协程。
        batch_id = batch.batch_id,   -- Controller 当前发布批次身份，新模块登记时原样带回。
        names = {}                    -- 本批允许首次加载的模块统一名称集合。
    }
    batch.new_module_context = new_module_context
    -- 当前阶段失败使用的错误码；开始加载新模块后切换为更具体的错误码。
    local failure_code = "HU_SERVICE_STAGE_FAILED"
    -- 捕获 Patch 构建和新模块登记的异常，统一转换为 FlyWowResult。
    local stage_succeeded, service_patch_or_error = pcall(function()
        if not service_patch_source then
            return nil
        end

        -- 先构建并核验完整声明清单，再加载模块，避免边加载边发现重复路径。
        -- 当前 Service 的更新定义；其中 new_modules 指定本批首次加载的模块。
        local service_patch = stage_service_patch(service_patch_source)
        -- 解析完成的模块文件身份；校验重复路径后直接用于加载，不再重新查找文件。
        local new_module_identities = {} -- 保存已验证身份，首次加载直接复用，不再解析同一路径。
        for _, name in ipairs(service_patch.new_modules or {}) do
            -- 清单名称对应的真实文件身份；例如 a/b.lua 与 a.b.lua 都是模块名 a.b，重复项会被拒绝。
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
        -- 内部若已返回 FlyWowResult 则保留其错误码，普通 Lua 异常只保留错误文本。
        local cause = type(service_patch_or_error) == "table" and service_patch_or_error.ok == false and service_patch_or_error or nil
        batch.new_module_context = nil
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

--- 在本 Service 建立本批记录并设置 patching，阻止新的业务请求进入。
--- 随后调用 before_upgrade 等业务 queue 安全点；该回调可能 yield，失败留给 Controller Abort。
---@param request FlyWowHotUpgradeControlRequest Controller 发来的 Prepare 请求；本函数读取 batch_id 和 sequence 创建本地批次记录。
---@return FlyWowResult<nil> 回调失败或未确认安全点时保留批次记录，交由现有 Abort 收尾
local function prepare_batch(request)
    -- active_batch 是当前 Service 的本地记录；request 的身份来自 Controller，回调与业务对象仍只留在此 Lua State。
    if module_state.active_batch then
        return flywow_result.failure("HU_UPGRADE_BUSY", "当前批次已在处理中")
    end

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
    if prepare_result ~= true and not (type(prepare_result) == "table" and prepare_result.ok == true) then
        return flywow_result.failure("HU_SAFEPOINT_REQUIRED",
            type(prepare_result) == "table" and (prepare_result.message or prepare_result.code) or "before_upgrade 未确认业务安全点")
    end
    return flywow_result.success()
end

--- 根据 Controller 发送的候选源码准备普通模块和 Service 状态更新，再同步提交它们。
--- 新增模块的加载/登记可能 yield；失败时保留 Stage 与旧状态供 Abort 恢复。
---@param batch FlyWowHotUpgradeServiceBatch Prepare 已建立的本地批次；本函数把模块 Stage 和 Service 恢复记录写入其中。
---@param request FlyWowHotUpgradeControlRequest Controller 发给当前 Service 的 Update 内容；modules 保存普通模块名和源码，service_patch_source 保存可选的 Service .patch 源码。
---@return FlyWowResult<nil> 成功将批次记录设为 ACTIVATED；失败保留恢复记录，交由 Abort 处理
local function update_batch(batch, request)
    -- batch.phase 标识本地 Update 是否已开始；request.modules 和 service_patch_source 是 Controller 已为本批固定读取的输入。
    if batch.phase ~= nil then
        return flywow_result.failure("HU_PHASE_INVALID", "当前批次已进入更新或恢复阶段")
    end
    batch.phase = "UPDATING"
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
    local stage_succeeded, module_result = pcall(hotupgrade_module_patch.stage,
        request.modules, module_state.declared_modules)
    batch.new_module_context = nil
    if not stage_succeeded then
        -- 内部若已返回 FlyWowResult 则保留其错误码，普通 Lua 异常由本阶段错误码包装。
        local cause = type(module_result) == "table" and module_result.ok == false and module_result or nil
        return flywow_result.failure("HU_MODULE_STAGE_FAILED",
            cause and cause.message or tostring(module_result), cause and {cause_code = cause.code} or nil)
    end
    if not module_result.ok then
        return module_result
    end

    batch.module_stage = module_result.value.stage
    batch.service_patch = service_patch

    -- Activate 同步提交；失败先报告，再由 Controller 串行 Abort 整批目标。
    -- 原地安装候选模块导出的结果；失败后由 Controller 调用 Abort 恢复。
    local commit_result = hotupgrade_module_patch.commit(batch.module_stage)
    if not commit_result.ok then
        return flywow_result.failure("HU_ACTIVATE_FAILED", commit_result.message)
    end
    -- 捕获 Service 状态、函数及 after_upgrade 提交异常，交由 Controller 统一 Abort。
    local activation_succeeded, activation_failure = pcall(function()
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
            assert(module_state.registration_config.after_upgrade() ~= false, "after_upgrade 拒绝更新")
        end
    end)

    if not activation_succeeded then
        -- Controller 串行发出一次 Abort，报告更新错误与独立恢复结果。
        return flywow_result.failure("HU_ACTIVATE_FAILED", tostring(activation_failure))
    end

    batch.phase = "ACTIVATED"
    return flywow_result.success()
end

--- 确认本 Service 的 Update 成功，释放普通模块 Stage 和 Service 恢复记录。
--- Finish 不执行回滚；完成后重新开放业务入口。
---@param batch FlyWowHotUpgradeServiceBatch Prepare 建立且 Update 已成功的本地批次；本函数释放其中保存的候选和恢复快照。
---@return FlyWowResult<nil> 模块快照清理结果；未 Activate 时返回 HU_PHASE_INVALID
local function finish_batch(batch)
    -- module_stage 保留旧导出和候选引用；到 Finish 才释放，Service 业务入口随后由 close_batch 打开。
    if batch.phase ~= "ACTIVATED" then
        return flywow_result.failure("HU_PHASE_INVALID", "当前阶段不能执行 finish")
    end
    -- 释放模块 Stage 保存的旧/新导出引用；Finish 不执行回滚。
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
                if batch.module_stage then hotupgrade_module_patch.finish(batch.module_stage) end
                close_batch(batch)
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
---@field restore? fun(state:table, old_state:table) 提交失败时同步恢复快照；返回 false 或抛错报告恢复失败，仍结束本批次记录。

---@class FlyWowHotUpgradeRegistration
---@field service_update? FlyWowHotUpgradeServiceUpdate 可选 Service 内部状态/函数更新入口
---@field before_upgrade fun():boolean|table 注册必填；每次 Prepare 设置 patching 后调用，允许 yield；须通过业务自己的 queue 确认此前业务结束。true 或 {ok=true} 才允许 Update，失败则 Abort
---@field after_upgrade? fun():boolean Update 内 Activate 提交模块与 Service 状态后、finish 前调用；false 或异常触发组合恢复。只检查已提交状态，不得产生外部副作用或 yield

--- 在当前 Lua State 登记本 Service 的模块清单和可选状态更新回调。
--- 登记会向 Controller 发 RPC，可能 yield；返回成功前宿主不能把 Service 标为 READY。
---@param registration FlyWowHotUpgradeRegistration 当前 Service 启动代码准备的登记表；Controller 用 before_upgrade 排空业务，并保存可选的 service_update、after_upgrade。
---@return FlyWowResult<nil> 登记结果
function M.register_service(registration)
    -- registration_config 保存本 State 的回调，registration_result 保存登记 RPC 的最终成败，等待首次 require 的协程据后者继续。
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
    -- 发布登记 RPC 的最终结果，再唤醒等待首次 require 的协程。
    module_state.registration_result = registration_call_succeeded and registration_response.ok == true
    for _, thread in ipairs(module_state.registration_waiters) do
        skynet.wakeup(thread)
    end
    module_state.registration_waiters = {}
    -- RPC 失败可能意味着 Controller 已登记；保持本 State 配置，要求宿主终止未 READY 的启动。
    if not registration_call_succeeded then
        return flywow_result.failure("HU_RPC_FAILED", tostring(registration_response))
    end
    return registration_response
end

--- 按本次加载记录调用原生 require，并验证返回的模块表确实来自已解析的 Lua 文件。
--- 仅在本次第一次建立模块表到文件的对应关系时记录来源；失败清理由外层完成。
---@param name string 业务调用方传入的 require 名；用于读取原名和统一模块名对应的 package.loaded 槽。
---@param module_identity FlyWowHotUpgradeModuleIdentity resolve_module_identity 找到的文件路径和统一模块名；本函数据此确认原生 require 加载的是目标文件。
---@param module_load_attempt table 本次首次加载的临时记录；本函数把实际加载路径、返回的模块表和是否新增来源记录写入其中，供失败时恢复。
---@return nil 原生 require 可能 yield；验证失败抛出原错误，由调用方恢复本次变更
local function load_module_exports(name, module_identity, module_load_attempt)
    -- cache_snapshot 保存了取得许可前的原始 require 名和统一模块名缓存；本函数只确认导出来源，失败回退由外层加载流程负责。
    local source_path    = module_identity.source_path    -- package.path 首次找到的文件，用于核对 Skynet 加载器。
    local resolved_path  = module_identity.resolved_path  -- 解析符号链接后的实际文件路径，用于确认缓存来源。
    local canonical_name = module_identity.canonical_name -- 相对宿主根目录的模块名，例如 lualib/a.lua 对应 lualib.a。
    module_load_attempt.module_exports = module_load_attempt.cache_snapshot.module
    -- 缓存占用不能证明来源；仅复用本入口确认过的同表来源。
    assert(module_load_attempt.cache_snapshot.module == nil or (type(module_load_attempt.cache_snapshot.module) == "table"
        and module_state.module_sources[module_load_attempt.cache_snapshot.module] == resolved_path),
        "HU_INVALID_PATH: 无法确认缓存模块来源，须先通过 hotupgrade.require 加载: " .. name)
    assert(package.preload[canonical_name] == nil and package.preload[name] == nil,
        "HU_DUPLICATE_MODULE: 模块名称已被 package.preload 占用: " .. canonical_name)
    assert(module_load_attempt.cache_snapshot.canonical_alias == nil or (rawequal(module_load_attempt.cache_snapshot.canonical_alias, module_load_attempt.cache_snapshot.module)
        and module_state.module_sources[module_load_attempt.cache_snapshot.canonical_alias] == resolved_path),
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
end

--- 完成一次普通或 new_modules 模块首次加载，并把模块表和声明登记到当前 Lua State/Controller。
--- 许可、require 和登记 RPC 可能 yield；失败时只恢复本次尝试改动的缓存与声明，再抛出原错误。
---@param name string 当前调用使用的 require 名；本函数按它读取/写入原名缓存并执行模块加载。
---@param module_identity FlyWowHotUpgradeModuleIdentity 已确认的模块文件身份；本函数用它选择加载路径并检查返回模块来源。
---@param new_module_context? FlyWowHotUpgradeNewModuleContext 当前 Update 的 new_modules 清单；存在时，本函数只允许加载清单内尚未登记的模块。
---@param register_new_module? boolean 是否把成功加载的模块登记到当前 Update；普通 require 许可流程传 false。
---@return table module_exports 已完成加载与登记的稳定导出表；许可、require 或登记可能 yield
local function load_and_register_module(name, module_identity, new_module_context, register_new_module)
    -- 从文件路径转换得到的统一模块名；例如 a/b.lua 对应 a.b，本地并发记录和 Controller 都用它识别同一模块。
    local canonical_name = module_identity.canonical_name -- 统一登记名；本地声明、缓存别名和 Controller 都按它关联。
    -- 本次模块首次加载的许可、缓存和本地登记变更；失败时只回退这次尝试实际改动的内容。
    local module_load_attempt =
    {
        loader_path              = module_identity.source_path, -- 加载器返回路径缺失时沿用首次 searchpath 结果。
        permit_id                = nil,                         -- 普通首次声明的许可；登记完成或失败取消后释放。
        cache_snapshot           = nil,                         -- 许可返回后保存两个缓存槽；失败时按原值恢复。
        module_exports           = nil,                         -- 本次加载或复用的模块表，供来源映射与成功返回使用。
        source_mapping_added     = false,                       -- 只撤销本次新建的模块表到文件路径映射。
        module_declaration_added = false,                       -- 只撤销本次新增的本地模块声明。
    }
    -- 捕获模块加载或登记异常；失败时按本次尝试记录恢复缓存与本地声明。
    local load_succeeded, load_failure = pcall(function()
        if module_state.registration_config and not module_state.declared_modules[canonical_name] and not register_new_module then
            -- Controller 返回本次首次加载许可；permit_id 必须随完成登记请求交回。
            local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade",
                "begin_module_load", {name = canonical_name})
            assert(answer.ok, tostring(answer.code) .. ": " .. tostring(answer.message))
            module_load_attempt.permit_id = answer.value.permit_id
        end

        -- 申请许可会 yield；恢复后再读取快照，等待者须等本次登记成功或完整回退。
        module_load_attempt.cache_snapshot =
        {
            module          = package.loaded[name],           -- 原始 require 名的旧缓存，失败时恢复。
            canonical_alias = package.loaded[canonical_name], -- 规范登记名的旧别名，失败时恢复。
        }
        load_module_exports(name, module_identity, module_load_attempt)

        -- 登记 RPC 前建立全部本地状态；许可阻止 Controller 在此关键区间启动批次。
        package.loaded[canonical_name] = module_load_attempt.module_exports
        if not module_state.declared_modules[canonical_name] then
            module_state.declared_modules[canonical_name] = {name = name, path = module_load_attempt.loader_path}
            module_load_attempt.module_declaration_added = true
        end
        if module_load_attempt.permit_id then
            -- 普通首次加载的登记答复；成功后 Controller 才会移除此模块的许可记录。
            local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade",
                "register_module", {name = canonical_name, permit_id = module_load_attempt.permit_id})
            assert(answer.ok, "模块登记失败: " .. tostring(answer.message))
        elseif register_new_module and module_load_attempt.module_declaration_added then
            -- 本批声明的新模块登记答复；它从下一批普通 Stage 起成为候选。
            local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "register_new_module",
                {batch_id = new_module_context.batch_id, name = canonical_name})
            assert(answer.ok, "新模块登记失败: " .. tostring(answer.message))
        end
    end)
    -- 任一步失败都恢复原名缓存、规范别名和本次新增的本地声明。
    if not load_succeeded then
        if module_load_attempt.cache_snapshot then
            package.loaded[name] = module_load_attempt.cache_snapshot.module
            package.loaded[canonical_name] = module_load_attempt.cache_snapshot.canonical_alias
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
---@param name string 业务代码原本传给 require 的模块名；本函数用它读写 package.loaded 中对应的原名缓存。
---@param module_identity FlyWowHotUpgradeModuleIdentity 已找到并校验的模块文件信息；其中统一模块名用于和 Controller 的登记记录对应（例如 a/b.lua 对应 a.b）。
---@return table module_exports 本 State 的稳定模块根导出表；失败时回退后抛出异常
require_module = function(name, module_identity)
    -- declared_modules 是已完成本地声明的模块；module_loads 保存尚在加载的 owner/等待者，两者不能互相代替。
    -- 入口已固定模块身份；等待和加载后的缓存/来源检查保留在实际变化点。
    local canonical_name = module_identity.canonical_name
    -- 当前批次的新模块清单；只有创建清单的 Update 协程可以使用其加载权限。
    local new_module_context = module_state.active_batch
        and module_state.active_batch.new_module_context
    -- 判断当前协程是否拥有这份清单；其他协程不能借用本批的新模块权限。
    local in_new_module_context = new_module_context and new_module_context.owner == coroutine.running()
    -- 当前模块是否列在本批 new_modules 中，决定使用批次内新模块登记通道。
    local register_new_module = in_new_module_context and new_module_context.names[canonical_name] == true
    if in_new_module_context and not module_state.declared_modules[canonical_name] and not register_new_module then
        error(flywow_result.failure("HU_NEW_MODULE_NOT_DECLARED",
            "新模块依赖未列入 new_modules: " .. canonical_name .. "\n" .. debug.traceback("", 2)), 0)
    end

    -- 当前 State 已进入首次登记时先等待 Controller 结果，避免声明越过登记快照。
    if module_state.registration_config then
        if module_state.registration_result == nil then
            -- 当前 require 协程；等待首次 Service 登记 RPC 给出成功或失败结果。
            local thread = coroutine.running()
            module_state.registration_waiters[#module_state.registration_waiters + 1] = thread
            skynet.wait(thread)
        end
        assert(module_state.registration_result == true,
            "HU_SERVICE_NOT_REGISTERED: 首次登记失败，须终止本次启动")
    end

    -- 同一规范路径首次加载串行化，等待者完成后重新检查缓存和声明。
    -- 本 State 中该模块正在进行的首次加载记录；存在时需要等待或拒绝互等。
    local module_load = module_state.module_loads[canonical_name]
    if module_load then
        -- 当前 require 协程；登记为等待者后由首次加载协程唤醒。
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
    -- 首次加载与登记结果；失败时先释放本地占用，再把原错误交还调用方。
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

--- 加载并登记一个普通 Lua 模块，返回当前 Lua State 的模块导出表。
--- 缓存命中且来源已由本入口确认时直接返回；首次加载、许可或并发等待可能 yield，登记失败会抛错。
---@param name string 调用方原有的 require 模块名；本函数用 package.path 定位文件，再向 Controller 登记统一模块名。
---@return table 当前 State 的稳定模块导出表
function M.require(name)
    assert(type(name) == "string" and name ~= "", "模块名无效")
    return require_module(name, resolve_module_identity(name))
end

return M
