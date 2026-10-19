--- 现存 Service 夹具：所有业务状态和函数保持在自己的 Lua State。
local skynet = require "skynet"
local hotupgrade = require "flywow_hotupgrade"
local logic = hotupgrade.require("test_worker_logic")
local runtime = hotupgrade.require("battle.state_sync.runtime")
local package_logic = hotupgrade.require("packages.demo")
local settings = hotupgrade.require("config.settings")
local cached = logic.value
local module_identity = logic
local service_state = {equip = "刀", level = 50, schema_version = 1, nested = {count = 7}}
local nested_identity = service_state.nested
local service_state_identity = service_state
local marker = {} -- 仅此 Lua State 中创建的身份标记，用于更新前后比对。
local original_marker = marker
local business = {}
local worker_test_config -- 本 State 的故障注入配置。
local extra_logic  -- 登记后才声明的模块，用于验证 register_module 真实链路。

function business.load(item)
    return item.base_attack
end
function business.save()
    return "saved"
end
local original_save = business.save

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer
        if command == "init" then
            worker_test_config = request
            local service = {state = service_state, functions = business}
            if worker_test_config.custom then
                service.snapshot = function(value)
                    return require("flywow_hotupgrade_module_patch").copy_state(value)
                end
                service.commit = function(value, candidate)
                    value.equip = candidate.equip
                    error("partial service commit")
                end
                service.restore = function(value, snapshot)
                    if worker_test_config.restore_failure then
                        error("service restore failed")
                    end
                    require("flywow_hotupgrade_module_patch").restore_state(value, snapshot)
                end
            end
            if worker_test_config.custom_success then
                -- 模拟不可直接复制的业务对象，快照只包含它可迁移的普通数据。
                setmetatable(service_state.nested, {})
                service.snapshot = function(value)
                    return {equip = value.equip, level = value.level, schema_version = value.schema_version,
                        nested = {count = value.nested.count}}
                end
                service.commit = function(value, next_state)
                    value.equip = next_state.equip
                    value.level = next_state.level
                    value.schema_version = next_state.schema_version
                    value.nested.count = next_state.nested.count
                end
                service.restore = service.commit
            end
            answer = hotupgrade.register_service(
            {
                controller_handle = worker_test_config.controller_handle,
                service_type = worker_test_config.service_type or "player",
                service = service,
                after_upgrade = function()
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
        elseif command == "read" then
            -- 仅测试诊断用的只读观察，不是可绕过 Guard 的生产业务入口。
            answer =
            {
                handle = skynet.self(), marker_token = tostring(marker),
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
                paused = hotupgrade.guard().owner ~= nil,
                nested_count = service_state.nested and service_state.nested.count,
                nested_identity = service_state.nested == nested_identity,
                extra_value = extra_logic and extra_logic.value(),
            }
        elseif command == "check_declarations" then
            assert(hotupgrade.require("test_worker_logic") == logic)
            local conflicting = {}
            package.loaded["lualib.hotupgrade_extra"] = conflicting
            local ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            assert(not ok and tostring(message):find("HU_DUPLICATE_MODULE", 1, true))
            assert(package.loaded["lualib.hotupgrade_extra"] == conflicting)
            package.loaded["lualib.hotupgrade_extra"] = nil
            for _, name in ipairs({"hotupgrade_test_options", "missing_module"}) do
                ok, message = pcall(hotupgrade.require, name)
                assert(not ok and tostring(message):find("HU_INVALID_PATH", 1, true))
            end

            -- 动态登记失败必须清理本次别名；随后 declare 仍能沿真实 RPC 重试。
            local original_call = skynet.call
            skynet.call = function() return {ok = false, message = "injected declaration failure"} end
            ok, message = pcall(hotupgrade.require, "hotupgrade_extra")
            skynet.call = original_call
            assert(not ok and tostring(message):find("injected declaration failure", 1, true))
            assert(package.loaded["lualib.hotupgrade_extra"] == nil)
            answer = true
        elseif command == "declare" then
            extra_logic = hotupgrade.require("hotupgrade_extra")
            answer = extra_logic.value()
        elseif command == "bump" then
            answer = hotupgrade.guard():run(logic.bump)
        elseif command == "hold" then
            answer = hotupgrade.guard():run(function()
                skynet.sleep(request.ticks or 10)
                return service_state.level
            end)
        elseif command == "active" then
            answer = hotupgrade.guard().active
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
