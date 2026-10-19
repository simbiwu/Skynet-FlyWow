--- 现存 Service 夹具：所有业务状态和函数保持在自己的 Lua State。
local skynet = require "skynet"
local hotupgrade = require "flywow_hotupgrade"
local logic = hotupgrade.require("test_worker_logic")
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

package.preload.hotupgrade_extra = function()
    return {value = function() return 1 end}
end

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
                service_type = "player",
                service = service,
                after_upgrade = function()
                    if worker_test_config.after_upgrade_failure then
                        error("after_upgrade failed")
                    end
                    if worker_test_config.break_module then
                        package.loaded.test_worker_logic = {}
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
                module_identity = logic == module_identity and package.loaded.test_worker_logic == logic,
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
            package.loaded.test_worker_logic = logic
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
