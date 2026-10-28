--- 现存 Service 夹具：所有业务状态和函数保持在自己的 Lua State。
local startup_arguments = table.pack(...)
local startup_mode = ... -- Skynet 启动参数选择 worker 的特殊测试行为。
assert(SERVICE_NAME == "skynet_hotupgrade_worker" or SERVICE_NAME:match("^skynet_hotupgrade_unique_[ab]$"))
assert(SERVICE_PATH:sub(-#"hotupgrade/tests/") == "hotupgrade/tests/")
if startup_mode == "auto" then
    assert(startup_arguments.n == 2 and startup_arguments[2] == "original_tail")
elseif not startup_mode then
    assert(startup_arguments.n == 0)
end
local skynet = require "skynet" -- 当前 worker 的 RPC、调度与日志接口。
require "skynet.manager"
local business_queue = require "skynet.queue"() -- 模拟排队中的业务协程，验证热更等待期间是否仍在运行。
local holding = false -- 仅测试观察 queue 中可 yield 业务是否仍未退出。
local hotupgrade = require "flywow_hotupgrade" -- 当前 State 的受管理热更 API。
local logic = hotupgrade.require("test_worker_logic") -- 本 worker 登记并使用的业务逻辑模块。
local runtime -- 供命令处理器观察的业务运行状态。
local package_logic -- 保存模块根表中的既有函数引用，用于验证热更不会改写旧引用。
local settings -- 由普通 require 加载的配置模块，验证原生加载路径。
local cached -- 测试前缓存的模块字段，热更后仍指向旧函数或旧值。
local module_identity -- 热更前的模块表身份，提交后确认根表未被替换。
local service_nested = {count = 7, retained = 23} -- Service 私有状态中的嵌套表，验证快照保留表内字段。
local service_state = -- 本 worker 的私有状态图；Service Update 在此迁移可迁移的数据。
{
    equip = "刀", level = 50, schema_version = 1, obsolete = true,
    a = {keep_a = 1}, b = {keep_b = 2},
    nested = service_nested, nested_alias = service_nested, ranks = {1, 2, 3}, mode = "legacy", replaced = {old = true},
}
service_state.self = service_state
local nested_identity = service_state.nested -- 保存嵌套表身份，确认状态恢复原地复用该对象。
local service_state_identity = service_state -- 保存业务状态根表身份，热更前后都应保持不变。
local marker = {} -- 仅此 Lua State 中创建的身份标记，用于更新前后比对。
local original_marker = marker -- 保存本 State 的身份标记，确认迁移不会复制或替换该对象。
local business = {} -- 注册给热更合同的业务函数集合。
local worker_test_config -- 本 State 的故障注入配置。
local startup_registration -- 独立启动登记协程的结果；业务观察等待它完成。
local extra_logic  -- 登记后才声明的模块，用于验证 register_module 真实链路。
local new_module_conflict_result -- 后台协程的同名模块首次加载结果；测试查询后即可结束夹具。

function business.load(item)
    return item.base_attack
end
function business.save()
    return "saved"
end
local original_save = business.save -- 缓存 V1 函数引用，验证热更不会重绑定调用方的旧引用。

--- 按场景配置 Service 更新回调与故障注入，再登记本测试 Service。
---@param request table 管理测试发来的 Worker 初始化配置；本函数把其中的故障开关保存给本 State 的更新回调读取。
---@return FlyWowResult<nil> Controller 登记结果；失败时原样返回对应错误码和诊断。
local function initialize(request)
    -- service_update 绑定现存 state/functions；自定义 snapshot/restore 只改变恢复方式，不替换这两个根表。
    worker_test_config = request
    local service_update = {state = service_state, functions = business} -- 交给 register_service 的私有状态和函数更新对象。

    -- 按场景安装自定义状态恢复；这些回调只存在于当前测试 Worker 的 Lua State。
    if worker_test_config.custom then
        service_update.snapshot = function(source_state)
            return require("flywow_hotupgrade_module_patch").snapshot_state(source_state)
        end
        service_update.restore = function(target_state, source_snapshot)
            if worker_test_config.restore_failure then
                error("service restore failed")
            end
            return require("flywow_hotupgrade_module_patch").restore_state(source_snapshot, target_state)
        end
    end

    if worker_test_config.custom_success then
        -- 模拟不可直接复制的业务对象，快照只包含它可迁移的普通数据。
        setmetatable(service_state.nested, {})
        service_update.snapshot = function(source_state)
            return require("flywow_result").success(
                {equip = source_state.equip, level = source_state.level,
                    schema_version = source_state.schema_version, nested = {count = source_state.nested.count}})
        end
        service_update.restore = function(value, next_state)
            -- value 是仍在线的业务状态，next_state 是 snapshot 返回的恢复数据；这里只回填已约定字段。
            value.equip = next_state.equip
            value.level = next_state.level
            value.schema_version = next_state.schema_version
            value.nested.count = next_state.nested.count
            return require("flywow_result").success()
        end
    end

    -- 按故障场景覆盖协议分发；只在指定控制命令到达时终止当前测试 Service。
    if worker_test_config.exit_command then
        local dispatch = skynet.dispatch -- 保存协议分发函数，以测试配置控制消息处理。
        skynet.dispatch = function(protocol, callback)
            if protocol == "hotupgrade" then
                dispatch(protocol, function(session, source, command, request)
                    if command == worker_test_config.exit_command then
                        if worker_test_config.kill then
                            skynet.kill(skynet.self())
                            skynet.wait(coroutine.running())
                        end
                        skynet.exit()
                    end
                    callback(session, source, command, request)
                end)
            else
                dispatch(protocol, callback)
            end
        end
    end

    -- 最后提交登记，返回 Controller 的结果供 Skynet 初始化调用方决定是否继续。
    return hotupgrade.register_service(
    {
        service_update = service_update,
        before_upgrade = not worker_test_config.before_missing and function()
            assert(hotupgrade.patching)
            if worker_test_config.before_error then
                error("injected before_upgrade failure")
            end
            if worker_test_config.before_false then
                return false
            end
            return business_queue(function() return true end)
        end or nil,
        after_upgrade = function()
            if worker_test_config.custom then
                error("partial service update")
            end
            if worker_test_config.after_upgrade_failure then
                error("after_upgrade failed")
            end
            if worker_test_config.break_module then
                package.loaded["lualib.test_worker_logic"] = {}
                error("module identity corrupted")
            end
            return true
        end,
    })
end

skynet.start(function()
    runtime = hotupgrade.require("battle.state_sync.runtime")
    package_logic = hotupgrade.require("packages.demo")
    settings = hotupgrade.require("config.settings")
    cached = logic.value
    module_identity = logic
    if startup_mode then
        if startup_mode == "fail" then
            error("injected startup failure")
        end
        -- 原生 newservice 等待 start 回调结束；登记必须在独立协程执行，避免相互等待。
        skynet.fork(function()
            startup_registration = initialize({})
            assert(startup_registration.ok, startup_registration.message)
        end)
    end
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer -- 当前收到的 worker 命令最终返回结果。
        if command == "preload_seen" then
            answer = hotupgrade_preload_seen == true
        elseif command == "init" then
            if request.init_failure then
                answer = {ok = false, code = "HU_FIXTURE_INIT_FAILED", message = "business init failed"}
            else
                answer = initialize(request)
            end
        elseif command == "read" then
            -- 诊断字段先在本 State 比较原始引用，再把布尔结果发给管理测试；跨 State 复制表本身不能验证身份。
            while startup_mode and not startup_registration do
                skynet.sleep(1)
            end
            assert(not startup_registration or startup_registration.ok)
            -- 仅测试诊断用的只读观察，不是生产业务入口。
            answer =
            {
                service_handle = skynet.self(), marker_token = tostring(marker),
                state_identity = service_state == service_state_identity,
                lua_state_identity = marker == original_marker,
                module_identity = logic == module_identity and package.loaded.test_worker_logic == logic
                    and package.loaded["lualib.test_worker_logic"] == logic,
                runtime_value = runtime.value(), max_level = settings.max_level,
                package_value = package_logic.value(),
                package_alias_identity = package.loaded["lualib.packages.demo.init"] == package_logic
                    and package.loaded["packages.demo"] == package_logic,
                runtime_alias_identity = package.loaded["lualib.battle.state_sync.runtime"] == runtime
                    and package.loaded["battle.state_sync.runtime"] == runtime,
                equip = service_state.equip, level = service_state.level, schema_version = service_state.schema_version,
                attack = business.load({base_attack = 100}),
                save_identity = business.save == original_save,
                module_value = logic.value(), cached_value = cached(),
                removed = logic.removed, added = logic.added,
                paused = hotupgrade.patching,
                nested_count = service_state.nested and service_state.nested.count,
                nested_retained = service_state.nested and service_state.nested.retained,
                nested_self_cycle = service_state.nested and service_state.nested.self == service_state.nested,
                nested_identity = service_state.nested == nested_identity,
                nested_alias_identity = service_state.nested_alias == service_state.nested,
                root_cycle = service_state.self == service_state,
                merge_distinct = service_state.a ~= service_state.b,
                a_changed = service_state.a.changed, a_keep_a = service_state.a.keep_a, a_keep_b = service_state.a.keep_b,
                b_changed = service_state.b.changed, b_keep_a = service_state.b.keep_a, b_keep_b = service_state.b.keep_b,
                obsolete = service_state.obsolete,
                rank_2 = service_state.ranks[2],
                rank_3 = service_state.ranks[3],
                mode_phase = type(service_state.mode) == "table" and service_state.mode.phase,
                replaced_value = service_state.replaced,
                extra_value = extra_logic and extra_logic.value(),
            }
        elseif command == "check_declarations" then
            assert(hotupgrade.require("test_worker_logic") == logic)
            assert(hotupgrade.require("config.settings") == settings)

            -- 原始 require 名已等于统一模块名时，未知缓存仍须拒绝，不能仅凭名称相同认定文件来源。
            local original_settings = package.loaded["config.settings"] -- 本测试结束后恢复已登记模块缓存。
            local conflicting       = {}                                -- 模拟来源不明的占位表，不得被覆盖或登记。
            package.loaded["config.settings"] = conflicting
            local ok, message = pcall(hotupgrade.require, "config.settings") -- 并发冲突测试中 hotupgrade.require 是否正常返回。
            assert(not ok and tostring(message):find("HU_INVALID_PATH", 1, true))
            assert(package.loaded["config.settings"] == conflicting)
            package.loaded["config.settings"] = original_settings
            assert(hotupgrade.require("config.settings") == settings)

            -- 统一模块名已被缓存或 preload 占用时，连原始 require 名缓存也不能新增。
            package.loaded["lualib.hotupgrade_extra"] = conflicting
            ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            assert(not ok and tostring(message):find("HU_DUPLICATE_MODULE", 1, true))
            assert(package.loaded["lualib.hotupgrade_extra"] == conflicting)
            assert(package.loaded.hotupgrade_extra == nil)
            package.loaded["lualib.hotupgrade_extra"] = nil

            local preload_loader = function() return conflicting end -- 临时注入 package.preload 的冲突加载器，验证缓存身份检查。
            package.preload["lualib.hotupgrade_extra"] = preload_loader
            ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            assert(not ok and tostring(message):find("HU_DUPLICATE_MODULE", 1, true))
            assert(package.preload["lualib.hotupgrade_extra"] == preload_loader)
            assert(package.loaded.hotupgrade_extra == nil and package.loaded["lualib.hotupgrade_extra"] == nil)
            package.preload["lualib.hotupgrade_extra"] = nil
            package.preload["lualib.test_worker_logic"] = preload_loader
            ok, message = pcall(hotupgrade.require, "test_worker_logic")
            assert(not ok and tostring(message):find("HU_DUPLICATE_MODULE", 1, true))
            assert(package.loaded.test_worker_logic == logic and package.loaded["lualib.test_worker_logic"] == logic)
            assert(package.preload["lualib.test_worker_logic"] == preload_loader)
            package.preload["lualib.test_worker_logic"] = nil

            -- 普通 require 先加载的表没有本入口的来源记录；拒绝时必须保留原缓存且不建别名。
            local ordinarily_loaded = require("hotupgrade_extra")
            ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            assert(not ok and tostring(message):find("HU_INVALID_PATH", 1, true))
            assert(package.loaded.hotupgrade_extra == ordinarily_loaded)
            assert(package.loaded["lualib.hotupgrade_extra"] == nil)
            package.loaded.hotupgrade_extra = nil

            -- 未知加载器省略来源或返回其他文件时，恢复它刚建立的原名缓存，不留下别名。
            local original_require = _G.require -- 被暂时替换的全局 require，测试后必须恢复。
            for _, loader_path in ipairs({false, assert(package.searchpath("test_worker_logic", package.path))}) do
                _G.require = function(name)
                    assert(name == "hotupgrade_extra")
                    package.loaded[name] = conflicting
                    return conflicting, loader_path or nil
                end
                ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
                _G.require = original_require
                assert(not ok and tostring(message):find("HU_INVALID_PATH", 1, true))
                assert(package.loaded.hotupgrade_extra == nil and package.loaded["lualib.hotupgrade_extra"] == nil)
            end

            for _, name in ipairs({"hotupgrade_test_options", "missing_module"}) do
                ok, message = pcall(hotupgrade.require, name)
                assert(not ok and tostring(message):find("HU_INVALID_PATH", 1, true))
            end

            -- 动态登记失败必须清理本次别名；随后 declare 仍能沿真实 RPC 重试。
            local original_call = skynet.call -- 被暂时替换的 Skynet RPC 函数，测试后必须恢复。
            skynet.call = function(target, protocol, operation, declaration)
                if operation == "register_module" then
                    return {ok = false, message = "injected declaration failure"}
                end
                return original_call(target, protocol, operation, declaration)
            end
            ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            skynet.call = original_call
            assert(not ok and tostring(message):find("injected declaration failure", 1, true))
            assert(package.loaded["lualib.hotupgrade_extra"] == nil and package.loaded.hotupgrade_extra == nil)
            assert(skynet.call(skynet.uniqueservice("flywow_hotupgrade_service"), "hotupgrade", "status", {}).value.lifecycle.pending_module_count == 0)
            answer = true
        elseif command == "allow_next_upgrade" then
            -- 测试宿主修正注入的根表缓存故障，并提交下一批针对现场的修复包。
            worker_test_config.custom = false
            worker_test_config.restore_failure = false
            worker_test_config.break_module = false
            package.loaded["lualib.test_worker_logic"] = logic
            answer = {ok = true}
        elseif command == "cancel_creation" then
            answer = hotupgrade.cancel_service_creation(request.service_handle)
        elseif command == "declare_slow" then
            -- 仅测试暂停实际模块执行，形成可观察的许可窗口；生产模块顶层仍须同步。
            local original_require = _G.require -- 被暂时替换的全局 require，测试后必须恢复。
            local path = assert(package.searchpath("hotupgrade_extra", package.path)) -- Native require 解析出的模块文件路径。
            _G.require = function(name)
                if name == "hotupgrade_extra" then
                    skynet.sleep(10)
                    local value = original_require(name) -- 原生 require 返回的模块导出值。
                    return value, path
                end
                return original_require(name)
            end
            local loaded_ok, loaded_value = pcall(hotupgrade.require, "hotupgrade_extra") -- 受控 require 是否成功完成。
            _G.require = original_require
            assert(loaded_ok, loaded_value)
            extra_logic = loaded_value
            answer = extra_logic.value()
        elseif command == "declare_failure" then
            local original_require = _G.require -- 被暂时替换的全局 require，测试后必须恢复。
            _G.require = function(name)
                if name == "hotupgrade_extra" then
                    package.loaded[name] = {}
                    error("injected execution failure")
                end
                return original_require(name)
            end
            local loaded_ok = pcall(hotupgrade.require, "hotupgrade_extra") -- 受控 require 是否成功完成。
            _G.require = original_require
            assert(not loaded_ok and package.loaded.hotupgrade_extra == nil
                and package.loaded["lualib.hotupgrade_extra"] == nil)
            answer = true
        elseif command == "start_new_module_conflict" then
            local original_call = skynet.call -- 被暂时替换的 Skynet RPC 函数，测试后必须恢复。
            local dependency_registration_started = false -- 测试用同步标志；新模块登记 RPC 启动后设为 true。
            local ordinary_load_waiting = false -- 普通模块首次加载是否已进入等待，用于验证冲突会立即失败而非互等。
            new_module_conflict_result = nil
            skynet.fork(function()
                while not dependency_registration_started do
                    skynet.sleep(1)
                end
                local ok, message = pcall(hotupgrade.require, "hotupgrade_new_rules") -- 并发冲突测试中 hotupgrade.require 是否正常返回。
                new_module_conflict_result = {ok = ok, message = tostring(message)}
                skynet.call = original_call
            end)
            skynet.call = function(target, protocol, operation, request)
                if protocol == "hotupgrade" and operation == "register_new_module"
                    and request.name == "lualib.hotupgrade_new_dependency" then
                    dependency_registration_started = true
                    while not ordinary_load_waiting do
                        skynet.sleep(1)
                    end
                elseif protocol == "hotupgrade" and operation == "begin_module_load"
                    and request.name == "lualib.hotupgrade_new_rules" then
                    ordinary_load_waiting = true
                end
                return original_call(target, protocol, operation, request)
            end
            answer = true
        elseif command == "new_module_conflict_result" then
            while not new_module_conflict_result do
                skynet.sleep(1)
            end
            answer = new_module_conflict_result
        elseif command == "declare" then
            extra_logic = hotupgrade.require("hotupgrade_extra")
            answer = extra_logic.value()
        elseif command == "bump" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function() return {ok = true, value = logic.bump()} end)
            end
        elseif command == "hold" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function()
                    holding = true
                    skynet.sleep(request.ticks or 10)
                    holding = false
                    return {ok = true, level = service_state.level}
                end)
            end
        elseif command == "holding" then
            answer = holding
        elseif command == "repair" then
            package.loaded["lualib.test_worker_logic"] = logic
            answer = true
        elseif command == "exit" then
            skynet.exit()
        else
            error("unknown fixture command")
        end
        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
