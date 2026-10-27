--- 现存 Service 夹具：所有业务状态和函数保持在自己的 Lua State。
local startup_arguments = table.pack(...)
local startup_mode = ...
assert(SERVICE_NAME == "skynet_hotupgrade_worker" or SERVICE_NAME:match("^skynet_hotupgrade_unique_[ab]$"))
assert(SERVICE_PATH:sub(-#"hotupgrade/tests/") == "hotupgrade/tests/")
if startup_mode == "auto" then
    assert(startup_arguments.n == 2 and startup_arguments[2] == "original_tail")
elseif not startup_mode then
    assert(startup_arguments.n == 0)
end
local skynet = require "skynet"
require "skynet.manager"
local business_queue = require "skynet.queue"()
local holding = false -- 仅测试观察 queue 中可 yield 业务是否仍未退出。
local hotupgrade = require "flywow_hotupgrade"
local logic = hotupgrade.require("test_worker_logic")
local runtime
local package_logic
local settings
local cached
local module_identity
local service_nested = {count = 7, retained = 23}
local service_state =
{
    equip = "刀", level = 50, schema_version = 1, obsolete = true,
    a = {keep_a = 1}, b = {keep_b = 2},
    nested = service_nested, nested_alias = service_nested, ranks = {1, 2, 3}, mode = "legacy", replaced = {old = true},
}
service_state.self = service_state
local nested_identity = service_state.nested
local service_state_identity = service_state
local marker = {} -- 仅此 Lua State 中创建的身份标记，用于更新前后比对。
local original_marker = marker
local business = {}
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
local original_save = business.save

local function initialize(request)
    worker_test_config = request
    local service_update = {state = service_state, functions = business}
    if worker_test_config.custom then
        service_update.snapshot = function(source_state)
            return require("flywow_hotupgrade_module_patch").snapshot_state(source_state)
        end
        service_update.restore = function(target_state, source_snapshot)
            if worker_test_config.restore_failure then
                error("service restore failed")
            end
            require("flywow_hotupgrade_module_patch").restore_state(source_snapshot, target_state)
        end
    end
    if worker_test_config.custom_success then
        -- 模拟不可直接复制的业务对象，快照只包含它可迁移的普通数据。
        setmetatable(service_state.nested, {})
        service_update.snapshot = function(source_state)
            return {equip = source_state.equip, level = source_state.level,
                schema_version = source_state.schema_version, nested = {count = source_state.nested.count}}
        end
        service_update.restore = function(value, next_state)
            value.equip = next_state.equip
            value.level = next_state.level
            value.schema_version = next_state.schema_version
            value.nested.count = next_state.nested.count
        end
    end
    -- 在接收真实事务消息时退出，验证 Controller 对原生退出与 RPC 失败交错的处理。
    if worker_test_config.exit_command then
        local dispatch = skynet.dispatch
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
            if worker_test_config.custom then error("partial service update") end
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
        local answer
        if command == "preload_seen" then
            answer = hotupgrade_preload_seen == true
        elseif command == "init" then
            if request.init_failure then
                answer = {ok = false, code = "HU_FIXTURE_INIT_FAILED", message = "business init failed"}
            else
                answer = initialize(request)
            end
        elseif command == "read" then
            while startup_mode and not startup_registration do skynet.sleep(1) end
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

            -- 原名就是规范名时，未知缓存仍须拒绝，不能凭名称相同认定文件来源。
            local original_settings = package.loaded["config.settings"] -- 本测试结束后恢复已登记模块缓存。
            local conflicting       = {}                                -- 模拟来源不明的占位表，不得被覆盖或登记。
            package.loaded["config.settings"] = conflicting
            local ok, message = pcall(hotupgrade.require, "config.settings")
            assert(not ok and tostring(message):find("HU_INVALID_PATH", 1, true))
            assert(package.loaded["config.settings"] == conflicting)
            package.loaded["config.settings"] = original_settings
            assert(hotupgrade.require("config.settings") == settings)

            -- 规范名被缓存或 preload 占用时，连原名缓存也不能新增。
            package.loaded["lualib.hotupgrade_extra"] = conflicting
            ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            assert(not ok and tostring(message):find("HU_DUPLICATE_MODULE", 1, true))
            assert(package.loaded["lualib.hotupgrade_extra"] == conflicting)
            assert(package.loaded.hotupgrade_extra == nil)
            package.loaded["lualib.hotupgrade_extra"] = nil

            local preload_loader = function() return conflicting end
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
            local original_require = _G.require
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
            local original_call = skynet.call
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
            local original_require = _G.require
            local path = assert(package.searchpath("hotupgrade_extra", package.path))
            _G.require = function(name)
                if name == "hotupgrade_extra" then
                    skynet.sleep(10)
                    local value = original_require(name)
                    return value, path
                end
                return original_require(name)
            end
            local loaded_ok, loaded_value = pcall(hotupgrade.require, "hotupgrade_extra")
            _G.require = original_require
            assert(loaded_ok, loaded_value)
            extra_logic = loaded_value
            answer = extra_logic.value()
        elseif command == "declare_failure" then
            local original_require = _G.require
            _G.require = function(name)
                if name == "hotupgrade_extra" then
                    package.loaded[name] = {}
                    error("injected execution failure")
                end
                return original_require(name)
            end
            local loaded_ok = pcall(hotupgrade.require, "hotupgrade_extra")
            _G.require = original_require
            assert(not loaded_ok and package.loaded.hotupgrade_extra == nil
                and package.loaded["lualib.hotupgrade_extra"] == nil)
            answer = true
        elseif command == "start_new_module_conflict" then
            local original_call = skynet.call
            local dependency_registration_started = false
            local ordinary_load_waiting = false
            new_module_conflict_result = nil
            skynet.fork(function()
                while not dependency_registration_started do skynet.sleep(1) end
                local ok, message = pcall(hotupgrade.require, "hotupgrade_new_rules")
                new_module_conflict_result = {ok = ok, message = tostring(message)}
                skynet.call = original_call
            end)
            skynet.call = function(target, protocol, operation, request)
                if protocol == "hotupgrade" and operation == "register_new_module"
                    and request.name == "lualib.hotupgrade_new_dependency" then
                    dependency_registration_started = true
                    while not ordinary_load_waiting do skynet.sleep(1) end
                elseif protocol == "hotupgrade" and operation == "begin_module_load"
                    and request.name == "lualib.hotupgrade_new_rules" then
                    ordinary_load_waiting = true
                end
                return original_call(target, protocol, operation, request)
            end
            answer = true
        elseif command == "new_module_conflict_result" then
            while not new_module_conflict_result do skynet.sleep(1) end
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
