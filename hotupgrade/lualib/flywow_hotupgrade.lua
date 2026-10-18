--- 现存 Service 的登记与原地更新；所有业务对象、快照和模块表仅留在本 Lua State。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local module_patch = require "flywow_hotupgrade_module_patch"
local M = {}
local options           -- 本 State 的登记配置；函数和私有表不发送给 Controller。
local guard             -- 注册前创建的业务 Guard 在注册后继续复用。
local engine            -- 本 State 唯一完整模块更新器。
local transaction       -- 当前事务；保留撤销数据直到 finish/abort 确认完成。
local completed = 0     -- 已结束的 Controller 递增序号，拒绝迟到控制消息。
local last_id           -- 最近完成事务，用于 finish/abort 幂等响应。
local declared_count = 0 -- 本 State 已成功声明模块数，与控制面 1024 上限一致。
local declared = {}     -- hotupgrade.require 已登记的模块集合。

-- 与 Controller Service 使用同一原生消息协议；不建立独立协议/RPC 模块。
skynet.register_protocol({name = "hotupgrade", id = 20, pack = skynet.pack, unpack = skynet.unpack})

---@class FlyWowHotUpgradeServiceUpdate
---@field state table 现存 Service 私有状态表，整个更新期间保持身份
---@field functions table Service 原有业务函数表；直接替换指定字段，不增加函数注册表
---@field snapshot? fun(state:table):table 非普通对象的独立快照；与 commit/restore 成组提供
---@field commit? fun(state:table, next_state:table) 同步原地提交；不替换 state，不写外部权威数据
---@field restore? fun(state:table, old_state:table) 同步恢复；抛错或 false 均使 Guard 保持关闭

---@class FlyWowHotUpgradeRegistration
---@field controller_handle integer 宿主已启动的控制 Service handle
---@field service_type string 对应 services/<service_type>.lua
---@field service? FlyWowHotUpgradeServiceUpdate 可选 Service 内部状态/函数更新入口
---@field postcheck? fun():boolean 同步无副作用检查；false/异常触发组合恢复
---@field can_upgrade? fun():boolean Guard 排空后的同步附加安全条件

--- 当前 Service 的唯一 Guard；业务请求和会写状态的后台任务都须经过它。
---@return table Guard:run 可执行正常 yield 的业务回调。
function M.guard()
    if not guard then
        guard = require("flywow_hotupgrade_guard").new(
        {
            now = function()
                return skynet.now() * 10
            end,
            sleep = function(ms)
                skynet.sleep(math.max(1, math.ceil(ms / 10)))
            end,
        })
    end
    return guard
end

local function restore_service(txn)
    local staged = txn.service
    if not staged or not staged.touched then
        return
    end
    local service = options.service
    -- 自定义恢复只处理 Service 自己的对象；即使它失败也继续尝试还原函数字段。
    local ok, message = pcall(function()
        if staged.old_state then
            if service.restore then
                assert(service.restore(service.state, staged.old_state) ~= false, "Service 拒绝恢复")
            else
                module_patch.restore_state(service.state, staged.old_state)
            end
        end
    end)
    for name, fn in pairs(staged.old_functions) do
        rawset(service.functions, name, fn)
    end
    assert(ok, message)
end

local function abort(txn)
    local errors = {}
    local ok, message = pcall(restore_service, txn)
    if not ok then
        errors[#errors + 1] = tostring(message)
    end
    if txn.modules then
        local restored = engine:abort(txn.modules)
        if not restored.ok then
            errors[#errors + 1] = restored.message
        else
            txn.modules = nil
        end
    end
    if #errors > 0 then
        txn.phase = "RECOVERY_REQUIRED"
        return result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end
    local resumed = guard:resume(txn.id)
    if not resumed.ok then
        txn.phase = "RECOVERY_REQUIRED"
        return resumed
    end
    completed = txn.sequence
    last_id = txn.id
    transaction = nil
    return result.success()
end

-- 只在 Guard 已排空时执行受信同步脚本；此函数不提供安全沙箱或副作用撤销。
local function stage_service(source)
    if not source then
        return nil
    end
    local service = assert(options.service, "Service 未提供内部更新入口")
    local chunk = assert(load(source, "@services/" .. options.service_type .. ".lua", "t", _G))
    local build = chunk()
    assert(type(build) == "function", "Service Patch 必须返回构建函数")
    local patch = build(service.state)
    assert(type(patch) == "table" and getmetatable(patch) == nil, "Service 构建结果必须是普通表")
    assert(patch.migrate == nil or type(patch.migrate) == "function", "migrate 必须是函数")
    assert(patch.functions == nil or (type(patch.functions) == "table"
        and getmetatable(patch.functions) == nil), "functions 必须是普通表")
    assert(patch.migrate or (patch.functions and next(patch.functions)), "Service Patch 没有更新内容")
    local staged =
    {
        patch = patch,       -- 仅本 State 持有的新函数和迁移函数。
        old_functions = {}, -- 本次将替换的现有函数，不处理未列出的字段。
        touched = false,    -- 首次线上写入前置 true，部分提交同样必须恢复。
    }
    for name, fn in pairs(patch.functions or {}) do
        assert(type(name) == "string" and type(fn) == "function"
            and type(rawget(service.functions, name)) == "function", "只能直接替换现有业务函数")
        staged.old_functions[name] = rawget(service.functions, name)
    end
    if patch.migrate then
        if service.snapshot then
            staged.old_state = service.snapshot(service.state)
            local isolated = service.snapshot(service.state)
            assert(type(staged.old_state) == "table" and type(isolated) == "table"
                and staged.old_state ~= service.state and isolated ~= staged.old_state
                and isolated ~= service.state, "自定义快照必须独立")
            staged.next_state = patch.migrate(isolated)
        else
            staged.old_state = module_patch.copy_state(service.state)
            staged.next_state = patch.migrate(module_patch.copy_state(staged.old_state))
            staged.next_state = module_patch.copy_state(staged.next_state)
        end
        assert(type(staged.next_state) == "table" and staged.next_state ~= service.state,
            "迁移须返回完整独立候选状态")
    end
    return staged
end

--- 当前 State 的控制入口；请求只携带源码与事务号，不传递业务状态、函数或私有表。
--- prepare 允许等待在途业务；stage/activate/abort/finish 的脚本和回调必须同步。
---@param command string prepare/stage/activate/abort/finish
---@param request table txn_id、sequence；stage 另含 modules 和可选 service_source
---@param source integer 由 Skynet 提供的真实调用来源
---@return FlyWowHotUpgradeResult 恢复不确定时保持 Guard 关闭
local function control(command, request, source)
    if not options or source ~= options.controller_handle then
        return result.failure("HU_UNAUTHORIZED", "控制来源不匹配")
    end
    if type(request) ~= "table" or type(request.txn_id) ~= "string"
        or math.type(request.sequence) ~= "integer" then
        return result.failure("HU_INVALID_REQUEST", "事务身份无效")
    end
    if last_id == request.txn_id and (command == "abort" or command == "finish") then
        return result.success()
    end
    if request.sequence <= completed or (transaction and transaction.id ~= request.txn_id) then
        return result.failure("HU_STALE_TRANSACTION", "过期或冲突事务")
    end

    if command == "prepare" then
        if transaction then
            return result.failure("HU_UPGRADE_BUSY", "当前事务已在处理中")
        end
        transaction = {id = request.txn_id, sequence = request.sequence, phase = "QUIESCING"}
        local paused = guard:prepare_upgrade(request.txn_id)
        if not paused.ok then
            transaction = nil
            return paused
        end
        local waited = guard:wait_idle(request.txn_id, request.timeout_ms or 10000, options.can_upgrade)
        -- wait_idle 可以 yield；恢复后须重新确认事务仍由当前请求持有。
        if not transaction or transaction.id ~= request.txn_id then
            return result.failure("HU_STALE_TRANSACTION", "等待时事务已结束")
        end
        if waited.ok then
            transaction.phase = "QUIESCED"
        end
        return waited
    end
    local txn = transaction
    if not txn or txn.sequence ~= request.sequence or guard.owner ~= txn.id then
        return result.failure("HU_STALE_TRANSACTION", "未取得本事务安全点")
    end
    if command == "abort" then
        return abort(txn)
    end
    if guard.active ~= 0 then
        return result.failure("HU_SAFEPOINT_REQUIRED", "在途业务尚未排空")
    end
    if command == "stage" and txn.phase == "QUIESCED" then
        for _, entry in ipairs(request.modules or {}) do
            if not declared[entry.name] then
                return result.failure("HU_MODULE_NOT_REGISTERED", tostring(entry.name))
            end
        end
        local staged = engine:stage(request.modules or {})
        if not staged.ok then
            return staged
        end
        txn.modules = staged.stage
        local ok, service = pcall(stage_service, request.service_source)
        if not ok then
            return result.failure("HU_SERVICE_STAGE_FAILED", tostring(service))
        end
        txn.service = service
        txn.phase = "STAGED"
        return result.success()
    end
    if command == "activate" and txn.phase == "STAGED" then
        local installed = engine:commit(txn.modules)
        local ok, message = pcall(function()
            assert(installed.ok, installed.message)
            local staged = txn.service
            if staged then
                local service = options.service
                staged.touched = true
                if staged.next_state then
                    if service.commit then
                        assert(service.commit(service.state, staged.next_state) ~= false, "Service 拒绝提交")
                    else
                        module_patch.restore_state(service.state, staged.next_state)
                    end
                end
                for name, fn in pairs(staged.patch.functions or {}) do
                    rawset(service.functions, name, fn)
                end
            end
            if options.postcheck then
                assert(options.postcheck() ~= false, "postcheck 拒绝更新")
            end
        end)
        if not ok then
            local restored = abort(txn)
            return restored.ok and result.failure("HU_ACTIVATE_FAILED", tostring(message)) or restored
        end
        txn.phase = "ACTIVATED"
        return result.success()
    end
    if command == "finish" and txn.phase == "ACTIVATED" then
        local finished = engine:finish(txn.modules)
        if not finished.ok then
            txn.phase = "RECOVERY_REQUIRED"
            return finished
        end
        local resumed = guard:resume(txn.id)
        if not resumed.ok then
            txn.phase = "RECOVERY_REQUIRED"
            return resumed
        end
        completed = txn.sequence
        last_id = txn.id
        transaction = nil
        return result.success()
    end
    return result.failure("HU_PHASE_INVALID", "当前阶段不能执行 " .. tostring(command))
end

--- 登记现存 Service；仅元数据跨 Service 传递。可能 yield，成功前宿主不能宣布 READY。
---@param registration FlyWowHotUpgradeRegistration 本 State 配置及可选 Service 内部入口
---@return FlyWowHotUpgradeResult 登记结果
function M.register_service(registration)
    if options then
        return result.failure("HU_DUPLICATE_SERVICE", "当前 State 已登记")
    end
    if type(registration) ~= "table" or math.type(registration.controller_handle) ~= "integer"
        or type(registration.service_type) ~= "string"
        or not registration.service_type:match("^[%w_.%-]+$") then
        return result.failure("HU_INVALID_OPTIONS", "Controller handle 或 Service 类型无效")
    end
    for _, name in ipairs({"postcheck", "can_upgrade"}) do
        if registration[name] ~= nil and type(registration[name]) ~= "function" then
            return result.failure("HU_INVALID_OPTIONS", name .. " 必须为函数")
        end
    end
    local service = registration.service
    if service then
        if type(service) ~= "table" or type(service.state) ~= "table"
            or type(service.functions) ~= "table" or getmetatable(service.functions) ~= nil then
            return result.failure("HU_INVALID_OPTIONS", "Service 内部入口需要私有 state 与现有函数表")
        end
        local custom = service.snapshot or service.commit or service.restore
        if custom and (type(service.snapshot) ~= "function" or type(service.commit) ~= "function"
            or type(service.restore) ~= "function") then
            return result.failure("HU_INVALID_OPTIONS", "自定义快照、提交、恢复必须成组提供")
        end
        if not custom and getmetatable(service.state) ~= nil then
            return result.failure("HU_INVALID_OPTIONS", "特殊状态对象需要自定义快照与恢复")
        end
    end

    options = registration
    engine = module_patch.new()
    M.guard()
    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local ok, answer = pcall(control, command, request, source)
        if not ok then
            -- 未预期异常可能发生在写入后；保留本地事务与 Guard，不能伪称恢复成功。
            if transaction then
                transaction.phase = "RECOVERY_REQUIRED"
            end
            answer = result.failure("HU_RECOVERY_REQUIRED", tostring(answer))
        end
        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
    local names = {}
    for name in pairs(declared) do
        names[#names + 1] = name
    end
    table.sort(names)
    ---@type FlyWowHotUpgradeTargetMetadata
    local metadata =
    {
        service_type = options.service_type,
        modules = names,
        service_patch = service ~= nil,
    }
    local ok, answer = pcall(skynet.call, options.controller_handle, "hotupgrade", "register", metadata)
    -- RPC 失败可能意味着 Controller 已登记；保持本 State 配置，要求宿主终止未 READY 的启动。
    return ok and answer or result.failure("HU_RPC_FAILED", tostring(answer))
end

--- 在本 State 加载完整模块；首次登记新模块可能 yield。登记失败抛错，允许再次声明。
---@param name string 与 modules/ 相对路径对应的 require 名
---@return table 当前 State 的稳定模块导出表
function M.require(name)
    assert(type(name) == "string" and name ~= "", "模块名无效")
    local value = require(name)
    assert(type(value) == "table", "可更新模块必须返回 table")
    if not declared[name] then
        assert(declared_count < 1024, "HU_MODULE_LIMIT: 模块声明已达 1024 上限")
        if options then
            local ok, answer = pcall(skynet.call, options.controller_handle, "hotupgrade",
                "register_module", {name = name})
            assert(ok and type(answer) == "table" and answer.ok,
                "模块登记失败: " .. tostring(type(answer) == "table" and answer.message or answer))
        end
        if not declared[name] then
            declared[name] = true
            declared_count = declared_count + 1
        end
    end
    return value
end

return M
