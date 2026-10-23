--- 现存 Service 的登记与原地更新；所有业务对象、快照和模块表仅留在本 Lua State。
local skynet = require "skynet"
local skynet_require = require "skynet.require"
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"
local hotupgrade_native = require "flywow_hotupgrade_native"
local hotupgrade_module_patch = require "flywow_hotupgrade_module_patch"
local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
local M =
{
    patching = false, -- prepare 起禁止新业务进入，finish 或确认恢复后解除。
}
local module_state =
{
    registered            = false,                            -- Controller 已确认首次登记；配置建立早于此确认。
    registration_complete = false,                            -- 首次登记 RPC 已返回；失败后不得继续本 State 的业务启动。
    registration_waiters  = {},                               -- 首次登记 RPC 期间的声明等待者，避免遗漏初始元数据快照。
    registration          = nil,                              -- 本 Lua State 登记配置；私有表和函数不发送给 Controller。
    active_transaction    = nil,                              -- 当前事务的撤销数据保留至 finish/abort 确认完成。
    completed_sequence    = 0,                                -- 已结束的 Controller 递增序号，拒绝迟到控制消息。
    last_batch_id         = nil,                              -- 最近完成的批次，用于 finish/abort 幂等响应。
    declared_modules      = {},                               -- hotupgrade.require 已登记的模块集合。
    module_loads          = {},                               -- 同一规范模块的首次声明串行完成，等待者不能观察半完成的本地状态。
    module_sources        = setmetatable({}, {__mode = "k"}), -- 仅保存本入口确认的模块表与文件路径；弱键不延长模块生命周期。
}


-- 与 Controller Service 使用同一原生消息协议；不建立独立协议/RPC 模块。
skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID, pack = skynet.pack, unpack = skynet.unpack})

--- 创建受管理 Service；排空和 Prepare 期间正常接纳，Update 起等待发布终态；恢复未确认则拒绝。
--- 会 yield，成功直接返回原生 handle，不等待调用方后续业务 init。
--- 启动参数遵循 skynet.newservice 的原有约束；失败抛出含 HU_ 错误码的异常。
---@param service_name string 原生 Skynet Service 入口名
---@param ... any 原样转交原生 newservice 的启动参数
---@return integer service_handle
function M.newservice(service_name, ...)
    -- 基础设施转发未知启动签名，固定 n 以保留参数个数和 nil。
    local answer = skynet.call(hotupgrade_handle, "hotupgrade", "newservice",
        {service_name = service_name, arguments = table.pack(...)})
    assert(type(answer) == "table" and answer.ok,
        tostring(type(answer) == "table" and answer.code) .. ": " ..
        tostring(type(answer) == "table" and answer.message or answer))
    return answer.service_handle
end

--- 仅本 Controller 内的本地唯一服务；Update 起可能等待发布，也可能等待同名在途创建。
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
    local answer = skynet.call(hotupgrade_handle, "hotupgrade", "uniqueservice",
        {service_name = name, global = global, arguments = arguments})
    assert(type(answer) == "table" and answer.ok,
        tostring(type(answer) == "table" and answer.code) .. ": " ..
        tostring(type(answer) == "table" and answer.message or answer))
    return answer.service_handle
end

--- 创建者在业务 init 失败后取消尚未登记的 Service；Controller 负责终止并解除屏障。
--- 已登记、未知 handle 或非创建者请求均明确拒绝；可能 yield。
---@param service_handle integer newservice 返回的待登记 Service handle
---@return FlyWowHotUpgradeResult
function M.cancel_service_creation(service_handle)
    return skynet.call(hotupgrade_handle, "hotupgrade", "cancel_service_creation",
        {service_handle = service_handle})
end

local function restore_service(txn)
    local staged = txn.service
    if not staged or not staged.touched then
        return
    end

    local service_update = module_state.registration.service_update
    -- 自定义恢复只处理 Service 自己的对象；即使它失败也继续尝试还原函数字段。
    local ok, message = pcall(function()
        if staged.old_state then
            if service_update.restore then
                assert(service_update.restore(service_update.state, staged.old_state) ~= false, "Service 拒绝恢复")
            else
                hotupgrade_module_patch.restore_state(staged.old_state, service_update.state)
            end
        end
    end)

    for name, fn in pairs(staged.old_functions) do
        rawset(service_update.functions, name, fn)
    end

    assert(ok, message)
end

local function abort(txn)
    -- 先尝试恢复 Service 私有状态，再恢复模块导出；一个失败也继续另一项。
    local errors = {}
    local ok, message = pcall(restore_service, txn)
    if not ok then
        errors[#errors + 1] = tostring(message)
    end

    if txn.modules then
        local restored = hotupgrade_module_patch.abort(txn.modules)
        if not restored.ok then
            errors[#errors + 1] = restored.message
        else
            txn.modules = nil
        end
    end

    -- 任何恢复项失败都保留关闭状态；只有全部恢复成功才释放事务。
    if #errors > 0 then
        txn.phase = "RECOVERY_REQUIRED"
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end

    module_state.completed_sequence = txn.sequence
    module_state.last_batch_id = txn.batch_id
    module_state.active_transaction = nil
    M.patching = false
    return hotupgrade_result.success()
end

-- 按路径合并部分更新：旧字段保留，Patch 的共享表在不同分支分别应用。
local function merge_service_state(target_state, update_state)
    local ancestors   = {} -- 只记录当前递归路径；遇到 Patch 循环时连回本路径的目标祖先。
    local field_count = 0  -- 本次合并实际展开的字段数，防止共享数据沿多条路径展开后失控。

    local function merge_table(target_table, source_table, nesting_depth)
        assert(nesting_depth <= hotupgrade_common.MAX_STATE_DEPTH, "Service 状态更新嵌套超过限制")
        ancestors[source_table] = target_table
        for key, update_value in pairs(source_table) do
            field_count = field_count + 1
            assert(field_count <= hotupgrade_common.MAX_STATE_FIELDS, "Service 状态更新展开超过字段限制")
            if type(update_value) ~= "table" then
                rawset(target_table, key, update_value)
            elseif ancestors[update_value] then
                -- 循环引用在本分支闭合；不会复用已经完成的兄弟分支。
                rawset(target_table, key, ancestors[update_value])
            else
                local target_child = rawget(target_table, key)
                if type(target_child) ~= "table" then
                    target_child = {}
                end
                merge_table(target_child, update_value, nesting_depth + 1)
                rawset(target_table, key, target_child)
            end
        end

        ancestors[source_table] = nil
    end

    merge_table(target_state, update_state, 1)
end

-- 只在业务安全点已确认时执行受信同步脚本；此函数不提供安全沙箱或副作用撤销。
local function stage_service(source)
    if not source then
        return nil
    end

    -- 执行受信 Patch 构建函数并校验结果；此时尚不写入线上状态。
    local service_update = assert(module_state.registration.service_update, "Service 未提供内部更新入口")
    local chunk = assert(load(source, "=Service Patch", "t", _G))
    local build = chunk()
    assert(type(build) == "function", "Service Patch 必须返回构建函数")
    local patch = build(service_update.state)

    assert(type(patch) == "table" and getmetatable(patch) == nil, "Service 构建结果必须是普通表")
    assert(patch.migrate == nil or type(patch.migrate) == "function", "migrate 必须是函数")
    assert(patch.functions == nil or (type(patch.functions) == "table"
        and getmetatable(patch.functions) == nil), "functions 必须是普通表")
    assert(patch.migrate or (patch.functions and next(patch.functions)), "Service Patch 没有更新内容")

    -- 保存本次可能替换的旧函数，Activate 失败时逐字段恢复。
    local staged =
    {
        patch = patch,       -- 仅本 State 持有的新函数和迁移函数。
        old_functions = {}, -- 本次将替换的现有函数，不处理未列出的字段。
        touched = false,    -- 首次线上写入前置 true，部分提交同样必须恢复。
    }
    for name, fn in pairs(patch.functions or {}) do
        assert(type(name) == "string" and type(fn) == "function"
            and type(rawget(service_update.functions, name)) == "function", "只能直接替换现有业务函数")
        staged.old_functions[name] = rawget(service_update.functions, name)
    end

    -- 迁移只接触隔离快照；将部分更新递归合入完整候选，不改线上状态。
    if patch.migrate then
        if service_update.snapshot then
            staged.old_state = service_update.snapshot(service_update.state)
            assert(type(staged.old_state) == "table" and staged.old_state ~= service_update.state,
                "自定义快照必须返回独立状态表")
        else
            staged.old_state = hotupgrade_module_patch.snapshot_state(service_update.state)
        end

        local isolated = hotupgrade_module_patch.snapshot_state(staged.old_state)
        local update_state = patch.migrate(isolated)
        assert(type(update_state) == "table" and update_state ~= service_update.state,
            "migrate 必须返回部分状态更新表")
        update_state = hotupgrade_module_patch.snapshot_state(update_state)

        staged.next_state = hotupgrade_module_patch.snapshot_state(staged.old_state)
        merge_service_state(staged.next_state, update_state)
        staged.next_state = hotupgrade_module_patch.snapshot_state(staged.next_state)
    end

    return staged
end

---@alias FlyWowHotUpgradeServiceCommand
---| "prepare"
---| "update"
---| "abort"
---| "finish"

--- 当前 State 的控制入口；请求只携带源码与批次号，不传递业务状态、函数或私有表。
--- prepare 通过业务 queue 等待排空，允许 yield；update/abort/finish 必须同步。
---@param command FlyWowHotUpgradeServiceCommand Controller Service 分发的稳定控制命令
---@param request table batch_id、sequence；update 另含 modules 和可选 service_source
---@param source integer 由 Skynet 提供的真实调用来源
---@return FlyWowHotUpgradeResult 恢复不确定时保持 patching=true
local function handle_upgrade(command, request, source)
    -- 先核验 Controller 来源；批次身份由 Controller 生成，再与本地事务记录比对。
    if source ~= hotupgrade_handle then
        return hotupgrade_result.failure("HU_UNAUTHORIZED", "控制来源不匹配")
    end

    if command ~= "prepare" and command ~= "update" and command ~= "abort" and command ~= "finish" then
        return hotupgrade_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
    end

    if module_state.last_batch_id == request.batch_id and (command == "abort" or command == "finish") then
        return hotupgrade_result.success()
    end

    if request.sequence <= module_state.completed_sequence or (module_state.active_transaction and module_state.active_transaction.batch_id ~= request.batch_id) then
        return hotupgrade_result.failure("HU_STALE_TRANSACTION", "过期或冲突批次命令")
    end

    -- 先禁止新业务，再通过业务自己的 queue 等待；callback 内允许正常 yield。
    if command == "prepare" then
        if module_state.active_transaction then
            return hotupgrade_result.failure("HU_UPGRADE_BUSY", "当前批次已在处理中")
        end

        module_state.active_transaction = {batch_id = request.batch_id, sequence = request.sequence}
        M.patching = true

        local ok, answer = pcall(module_state.registration.before_upgrade)

        if not ok then
            return hotupgrade_result.failure("HU_PREPARE_FAILED", tostring(answer))
        end
        if answer ~= true and not (type(answer) == "table" and answer.ok == true) then
            return hotupgrade_result.failure("HU_SAFEPOINT_REQUIRED",
                type(answer) == "table" and (answer.message or answer.code) or "before_upgrade 未确认业务安全点")
        end
        return hotupgrade_result.success()
    end

    local txn = module_state.active_transaction
    if not txn or txn.sequence ~= request.sequence or not M.patching then
        return hotupgrade_result.failure("HU_STALE_TRANSACTION", "未取得本批次安全点")
    end

    if command == "abort" then
        return abort(txn)
    end

    if command == "update" then
        if txn.phase ~= nil then
            return hotupgrade_result.failure("HU_PHASE_INVALID", "当前批次已进入更新或恢复阶段")
        end
        -- Controller 已按本 State 的登记模块筛选 Patch；Stage 准备候选和快照，不写线上状态。
        local staged = hotupgrade_module_patch.stage(request.modules)
        if not staged.ok then
            return staged
        end

        txn.modules = staged.stage
        local ok, service = pcall(stage_service, request.service_source)
        if not ok then
            return hotupgrade_result.failure("HU_SERVICE_STAGE_FAILED", tostring(service))
        end

        txn.service = service
        txn.phase = "STAGED"

        -- Activate 同步提交；任一步失败先组合恢复，再由 Controller 整批 Abort。
        local installed = hotupgrade_module_patch.commit(txn.modules)
        local ok, message = pcall(function()
            assert(installed.ok, installed.message)
            local staged = txn.service
            if staged then
                local service_update = module_state.registration.service_update
                staged.touched = true
                if staged.next_state then
                    if service_update.commit then
                        assert(service_update.commit(service_update.state, staged.next_state) ~= false, "Service 拒绝提交")
                    else
                        hotupgrade_module_patch.restore_state(staged.next_state, service_update.state)
                    end
                end

                for name, fn in pairs(staged.patch.functions or {}) do
                    rawset(service_update.functions, name, fn)
                end
            end

            if module_state.registration.after_upgrade then
                assert(module_state.registration.after_upgrade() ~= false, "after_upgrade 拒绝更新")
            end
        end)

        if not ok then
            local restored = abort(txn)
            return restored.ok and hotupgrade_result.failure("HU_ACTIVATE_FAILED", tostring(message)) or restored
        end

        txn.phase = "ACTIVATED"
        return hotupgrade_result.success()
    end

    -- finish 确认提交后才清理旧快照并重新开放业务入口。
    if command == "finish" and txn.phase == "ACTIVATED" then
        local finished = hotupgrade_module_patch.finish(txn.modules)
        if not finished.ok then
            txn.phase = "RECOVERY_REQUIRED"
            return finished
        end

        module_state.completed_sequence = txn.sequence
        module_state.last_batch_id = txn.batch_id
        module_state.active_transaction = nil
        M.patching = false
        return hotupgrade_result.success()
    end

    return hotupgrade_result.failure("HU_PHASE_INVALID", "当前阶段不能执行 " .. tostring(command))
end

---@class FlyWowHotUpgradeServiceUpdate
---@field state table 现存 Service 私有状态表；更新只改其字段，不替换该表。
---@field functions table Service 原有业务函数表；Patch 只替换本次列出的现有函数字段。
---@field snapshot? fun(state:table):table Stage 开始迁移前生成与线上对象隔离的普通状态图快照；与 commit、restore 成组提供。
---@field commit? fun(state:table, next_state:table) Activate 内同步原地应用合并后的完整候选状态；不得 yield 或写外部权威数据。
---@field restore? fun(state:table, old_state:table) 提交失败时同步恢复快照；返回 false 或抛错会保持 patching=true。

---@class FlyWowHotUpgradeRegistration
---@field service_update? FlyWowHotUpgradeServiceUpdate 可选 Service 内部状态/函数更新入口
---@field before_upgrade fun():boolean|table 注册必填；每次 Prepare 设置 patching 后调用，允许 yield；须通过业务自己的 queue 确认此前业务结束。true 或 {ok=true} 才允许 Update，失败则 Abort
---@field after_upgrade? fun():boolean Update 内 Activate 提交模块与 Service 状态后、finish 前调用；false 或异常触发组合恢复。只检查已提交状态，不得产生外部副作用或 yield

--- 登记现存 Service；仅元数据跨 Service 传递。可能 yield，成功前宿主不能宣布 READY。
---@param registration FlyWowHotUpgradeRegistration 本 State 必须提供 before_upgrade；service_update 可选
---@return FlyWowHotUpgradeResult 登记结果
function M.register_service(registration)
    -- 先验证回调与可选更新入口合同；检查完成前不安装 dispatch 或登记状态。
    if module_state.registration then
        return hotupgrade_result.failure("HU_DUPLICATE_SERVICE", "当前 State 已登记")
    end

    if type(registration) ~= "table" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "Service 登记参数无效")
    end
    if registration.service_module ~= nil then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "不再接受 service_module")
    end

    if type(registration.before_upgrade) ~= "function" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "before_upgrade 必须为函数")
    end

    if registration.after_upgrade ~= nil and type(registration.after_upgrade) ~= "function" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "after_upgrade 必须为函数")
    end

    local service_update = registration.service_update
    if service_update ~= nil then
        if type(service_update) ~= "table" or type(service_update.state) ~= "table"
            or type(service_update.functions) ~= "table" or getmetatable(service_update.functions) ~= nil then
            return hotupgrade_result.failure("HU_INVALID_OPTIONS", "Service 更新入口需要私有 state 与现有函数表")
        end

        local custom = service_update.snapshot ~= nil or service_update.commit ~= nil
            or service_update.restore ~= nil
        if custom and (type(service_update.snapshot) ~= "function" or type(service_update.commit) ~= "function"
            or type(service_update.restore) ~= "function") then
            return hotupgrade_result.failure("HU_INVALID_OPTIONS", "自定义快照、提交、恢复必须成组提供")
        end

        if not custom and getmetatable(service_update.state) ~= nil then
            return hotupgrade_result.failure("HU_INVALID_OPTIONS", "特殊状态对象需要自定义快照与恢复")
        end
    end

    if next(module_state.module_loads) then
        return hotupgrade_result.failure("HU_LIFECYCLE_PENDING", "本 State 仍有模块首次加载，完成后再登记 Service")
    end

    -- 合同有效后固定本地登记配置并安装接收器，再向 Controller 登记元数据。
    module_state.registration = registration
    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local ok, answer = pcall(handle_upgrade, command, request, source)
        if not ok then
            -- 未预期异常可能发生在写入后；保留本地事务与 patching，不能伪称恢复成功。
            if module_state.active_transaction then
                module_state.active_transaction.phase = "RECOVERY_REQUIRED"
            end
            answer = hotupgrade_result.failure("HU_RECOVERY_REQUIRED", tostring(answer))
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
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
    local ok, answer = pcall(skynet.call, hotupgrade_handle, "hotupgrade", "register", metadata)
    -- 发布登记 RPC 的最终结果，再唤醒等待首次 require 的协程。
    module_state.registration_complete = true
    module_state.registered = ok and type(answer) == "table" and answer.ok == true
    for _, thread in ipairs(module_state.registration_waiters) do
        skynet.wakeup(thread)
    end
    module_state.registration_waiters = {}
    -- RPC 失败可能意味着 Controller 已登记；保持本 State 配置，要求宿主终止未 READY 的启动。
    return ok and answer or hotupgrade_result.failure("HU_RPC_FAILED", tostring(answer))
end

--- 在本 State 加载完整模块；首次登记新模块可能 yield。登记失败抛错，允许再次声明。
--- 仅复用本入口确认过来源的缓存；普通 require 先加载的未知缓存会被明确拒绝。
---@param name string 宿主原有 require 名；Controller 使用实际文件的根目录相对路径登记
---@return table 当前 State 的稳定模块导出表
function M.require(name)
    -- 先解析原始 require 名对应的宿主文件身份，后续缓存和登记都以该路径核对。
    assert(type(name) == "string" and name ~= "", "模块名无效")
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
    local loading = module_state.module_loads[canonical_name]
    if loading then
        local thread = coroutine.running()
        assert(loading.owner ~= thread, "HU_MODULE_LOADING: 不支持循环声明 " .. canonical_name)
        loading.waiters[#loading.waiters + 1] = thread
        skynet.wait(thread)
        return M.require(name)
    end

    loading = {owner = coroutine.running(), waiters = {}}
    module_state.module_loads[canonical_name] = loading
    -- 建立本次加载的回滚边界；许可、缓存别名和声明必须整体完成或恢复。
    local permit_id                 -- 仅已登记 Service 的首次声明持有，完成登记或失败取消后释放。
    local cached_value              -- 许可恢复后读取的原名缓存，失败时原样恢复。
    local previous_alias            -- 许可恢复后读取的规范别名，不清除合法既有缓存。
    local value                     -- 本次加载或复用的模块根表。
    local snapshot_taken = false    -- 许可失败时尚未触碰本地缓存，无需回退。
    local added_source = false      -- 只撤销本次新建的来源映射。
    local added_declaration = false -- 只回退本次新增的本地模块声明。
    local ok, message = pcall(function()
        if module_state.registration and not module_state.declared_modules[canonical_name] then
            local answer = skynet.call(hotupgrade_handle, "hotupgrade",
                "begin_module_load", {name = canonical_name})
            assert(type(answer) == "table" and answer.ok and type(answer.permit_id) == "string",
                tostring(type(answer) == "table" and answer.code) .. ": " ..
                tostring(type(answer) == "table" and answer.message or answer))
            permit_id = answer.permit_id
        end

        -- 申请许可会 yield；恢复后再读取快照，等待者须等本次登记成功或完整回退。
        cached_value = package.loaded[name]
        previous_alias = package.loaded[canonical_name]
        value = cached_value
        snapshot_taken = true
        -- 缓存占用不能证明来源；仅复用本入口确认过的同表来源。
        assert(cached_value == nil or (type(cached_value) == "table"
            and module_state.module_sources[cached_value] == resolved_path),
            "HU_INVALID_PATH: 无法确认缓存模块来源，须先通过 hotupgrade.require 加载: " .. name)
        assert(package.preload[canonical_name] == nil and package.preload[name] == nil,
            "HU_DUPLICATE_MODULE: 模块名称已被 package.preload 占用: " .. canonical_name)
        assert(previous_alias == nil or (rawequal(previous_alias, cached_value)
            and module_state.module_sources[previous_alias] == resolved_path),
            "HU_DUPLICATE_MODULE: 模块路径登记名已被其他模块占用: " .. canonical_name)
        if value == nil then
            local loaded_value, loader_path = require(name)
            value = loaded_value
            assert(type(value) == "table", "可更新模块必须返回 table")
            if loader_path ~= nil then
                assert(type(loader_path) == "string" and hotupgrade_native.resolve(loader_path) == resolved_path,
                    "HU_INVALID_PATH: 模块加载来源与 package.path 不一致: " .. name)
            else
                -- Skynet 协程 require 不返回路径；固定走 searchpath/loadfile，只认可此已知加载器。
                assert(require == skynet_require.require and loadfile(source_path, "t") ~= nil,
                    "HU_INVALID_PATH: 加载器未提供可确认的模块来源: " .. name)
            end
            assert(module_state.module_sources[value] == nil
                or module_state.module_sources[value] == resolved_path,
                "HU_DUPLICATE_MODULE: 同一模块表已对应其他文件: " .. name)
            assert(package.preload[name] == nil and package.preload[canonical_name] == nil,
                "HU_DUPLICATE_MODULE: 模块名称已被 package.preload 占用: " .. canonical_name)
            assert(package.loaded[canonical_name] == nil or rawequal(package.loaded[canonical_name], value),
                "HU_DUPLICATE_MODULE: 模块路径登记名已被其他模块占用: " .. canonical_name)
            if module_state.module_sources[value] == nil then
                module_state.module_sources[value] = resolved_path
                added_source = true
            end
        end

        -- 登记 RPC 前建立全部本地状态；许可阻止 Controller 在此关键区间启动批次。
        package.loaded[canonical_name] = value
        if not module_state.declared_modules[canonical_name] then
            module_state.declared_modules[canonical_name] = true
            added_declaration = true
        end
        if permit_id then
            local answer = skynet.call(hotupgrade_handle, "hotupgrade",
                "register_module", {name = canonical_name, permit_id = permit_id})
            assert(type(answer) == "table" and answer.ok,
                "模块登记失败: " .. tostring(type(answer) == "table" and answer.message or answer))
        end
    end)
    -- 任一步失败都恢复原名缓存、规范别名和本次新增的本地声明。
    if not ok then
        if snapshot_taken then
            package.loaded[name] = cached_value
            package.loaded[canonical_name] = previous_alias
        end
        if added_source then
            module_state.module_sources[value] = nil
        end
        if added_declaration then
            module_state.declared_modules[canonical_name] = nil
        end
        if permit_id then
            -- 登记响应丢失时许可可能已消费；重复取消不会改变其他操作的许可。
            pcall(skynet.call, hotupgrade_handle, "hotupgrade",
                "cancel_module_load", {name = canonical_name, permit_id = permit_id})
        end
    end

    -- 释放首次加载锁并唤醒等待者，让它们重新检查模块状态。
    module_state.module_loads[canonical_name] = nil
    for _, thread in ipairs(loading.waiters) do
        skynet.wakeup(thread)
    end

    -- 回滚和清理完成后才把错误返回给 require 调用方。
    if not ok then
        error(message, 0)
    end
    return value
end

return M
