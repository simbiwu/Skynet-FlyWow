--- 每个场景使用独立 Lua State，通过真实业务接收入口验证状态合并和组合恢复。
local common = require "flywow_hotupgrade_common"
local scenario_name = assert(arg[1], "需要状态合并场景名")
local scenarios = {}
local shared_patch = [[
return function()
    return {
        migrate = function(old_state)
            old_state.a.keep_a = 999
            local shared = {changed = 3}
            return {a = shared, b = shared}
        end,
    }
end
]]

local function shared_scenario()
    return {
        state = {a = {keep_a = 1}, b = {keep_b = 2}},
        source = shared_patch,
        check = function(state)
            assert(state.a ~= state.b)
            assert(state.a.changed == 3 and state.a.keep_a == 1 and state.a.keep_b == nil)
            assert(state.b.changed == 3 and state.b.keep_a == nil and state.b.keep_b == 2)
        end,
    }
end
scenarios.shared = shared_scenario
scenarios.custom = function()
    local scenario = shared_scenario()
    scenario.custom = true
    return scenario
end

scenarios.nested_shared = function()
    return {
        state = {a = {keep_a = 1, shared = {left = 11}}, b = {keep_b = 2, shared = {right = 22}}},
        source = [[return function()
            return {migrate = function()
                local shared = {changed = 3}
                return {a = {shared = shared}, b = {shared = shared}, c = shared, d = shared}
            end}
        end]],
        check = function(state)
            assert(state.a.keep_a == 1 and state.b.keep_b == 2)
            assert(state.a.shared ~= state.b.shared and state.c ~= state.d)
            assert(state.a.shared.changed == 3 and state.a.shared.left == 11 and state.a.shared.right == nil)
            assert(state.b.shared.changed == 3 and state.b.shared.left == nil and state.b.shared.right == 22)
            assert(state.c.changed == 3 and state.d.changed == 3)
        end,
    }
end

scenarios.cycles = function()
    local state = {a = {keep_a = 1}, b = {keep_b = 2}}
    state.self = state
    return {
        state = state,
        source = [[return function()
            return {migrate = function()
                local shared = {changed = 3}
                shared.self = shared
                shared.peer = {back = shared}
                local updates = {a = shared, b = shared}
                updates.self = updates
                return updates
            end}
        end]],
        check = function(state)
            assert(state.self == state and state.a ~= state.b)
            assert(state.a.self == state.a and state.b.self == state.b)
            assert(state.a.peer.back == state.a and state.b.peer.back == state.b)
            assert(state.a.keep_a == 1 and state.b.keep_b == 2)
            assert(state.a.changed == 3 and state.b.changed == 3)
        end,
    }
end

scenarios.old_alias = function()
    local shared = {retained = 7}
    shared.self = shared
    return {
        state = {a = shared, b = shared},
        source = [[return function()
            return {migrate = function() return {a = {left = 1}, b = {right = 2}} end}
        end]],
        check = function(state)
            assert(state.a == state.b and state.a.self == state.a)
            assert(state.a.retained == 7 and state.a.left == 1 and state.a.right == 2)
        end,
    }
end

scenarios.types = function()
    return {
        state = {nested = {kept = 7}, ranks = {1, 2, 3}, scalar = 4, replaced = {old = true},
            disabled = true, zero = 5, text = "old", obsolete = true},
        source = [[return function()
            return {migrate = function(old_state)
                old_state.nested.kept = 999
                local updates = {nested = {changed = 3}, ranks = {[2] = 9}, scalar = {new = true},
                    replaced = 0, disabled = false, zero = 0, text = "", [false] = {enabled = true}}
                updates.obsolete = nil
                return updates
            end}
        end]],
        check = function(state)
            assert(state.nested.kept == 7 and state.nested.changed == 3)
            assert(state.ranks[1] == 1 and state.ranks[2] == 9 and state.ranks[3] == 3)
            assert(state.scalar.new and state.replaced == 0)
            assert(state.disabled == false and state.zero == 0 and state.text == "")
            assert(state[false].enabled and state.obsolete)
        end,
    }
end

scenarios.empty = function()
    local state = {a = {keep_a = 1}}
    state.self = state
    return {
        state = state,
        source = [[return function()
            return {migrate = function(old_state) old_state.a.keep_a = 999; return {} end}
        end]],
        check = function(state) assert(state.a.keep_a == 1 and state.self == state) end,
    }
end

scenarios.returned_snapshot = function()
    local state = {a = {keep_a = 1}, b = {keep_b = 2}}
    state.self = state
    return {
        state = state,
        source = [[return function()
            return {migrate = function(old_state) old_state.a.changed = 3; return old_state end}
        end]],
        check = function(state)
            assert(state.self == state and state.a ~= state.b)
            assert(state.a.keep_a == 1 and state.a.changed == 3 and state.b.keep_b == 2)
        end,
    }
end

scenarios.expansion = function()
    return {
        state = {kept = 7},
        source = [[return function()
            return {migrate = function()
                local shared = {changed = 3}
                for _ = 1, 14 do shared = {left = shared, right = shared} end
                return {expanded = shared}
            end}
        end]],
        expected_failure = "HU_SERVICE_STAGE_FAILED",
        error_text = "状态更新展开超过字段限制",
        check = function(state) assert(state.kept == 7 and state.expanded == nil) end,
    }
end

scenarios.depth = function()
    return {
        state = {kept = 7},
        source = ([[return function()
            return {migrate = function()
                local root = {}
                local child = root
                for _ = 1, %d do child.next = {}; child = child.next end
                return root
            end}
        end]]):format(common.MAX_STATE_DEPTH),
        expected_failure = "HU_SERVICE_STAGE_FAILED",
        error_text = "状态快照嵌套超过限制",
        check = function(state) assert(state.kept == 7 and state.next == nil) end,
    }
end

scenarios.depth_boundary = function()
    return {
        state = {kept = 7},
        source = ([[return function()
            return {migrate = function()
                local root = {}
                local child = root
                for _ = 2, %d do child.next = {}; child = child.next end
                child.value = 3
                return root
            end}
        end]]):format(common.MAX_STATE_DEPTH),
        check = function(state)
            assert(state.kept == 7)
            local child = state
            for _ = 2, common.MAX_STATE_DEPTH do child = child.next end
            assert(child.value == 3)
        end,
    }
end

scenarios.field_boundary = function()
    return {
        state = {[1] = "old"},
        source = ([[return function()
            return {migrate = function()
                local updates = {}
                for index = 1, %d do updates[index] = index end
                return updates
            end}
        end]]):format(common.MAX_STATE_FIELDS),
        check = function(state)
            for index = 1, common.MAX_STATE_FIELDS do assert(state[index] == index) end
        end,
    }
end

scenarios.candidate_size = function()
    local scenario = scenarios.field_boundary()
    scenario.state = {kept = 7}
    scenario.expected_failure = "HU_SERVICE_STAGE_FAILED"
    scenario.error_text = "状态快照超过字段限制"
    scenario.check = function(state) assert(state.kept == 7 and state[1] == nil) end
    return scenario
end

local function restored_scenario()
    local scenario = shared_scenario()
    local old_shared = {retained = 7}
    scenario.state.first = old_shared
    scenario.state.second = old_shared
    scenario.state.self = scenario.state
    scenario.check_updated = scenario.check
    scenario.check = function(state)
        assert(state.a ~= state.b and state.a.keep_a == 1 and state.b.keep_b == 2)
        assert(state.a.changed == nil and state.b.changed == nil)
        assert(state.first == state.second and state.first.retained == 7 and state.self == state)
    end
    return scenario
end
scenarios.abort = function()
    local scenario = restored_scenario()
    scenario.abort = true
    return scenario
end
scenarios.recovery = function()
    local scenario = restored_scenario()
    scenario.expected_failure = "HU_ACTIVATE_FAILED"
    return scenario
end
scenarios.recovery_retry = function()
    local scenario = scenarios.recovery()
    scenario.retry = true
    return scenario
end
scenarios.custom_recovery = function()
    local scenario = scenarios.recovery()
    scenario.custom = true
    return scenario
end

local scenario = assert(scenarios[scenario_name], scenario_name)()
local receiver -- register_service 安装的真实协议接收器。
local answer   -- retpack 捕获的控制命令返回值。
package.loaded.skynet = {
    uniqueservice = function() return 99 end,
    register_protocol = function() end,
    dispatch = function(protocol, callback) assert(protocol == "hotupgrade"); receiver = callback end,
    call = function(_, _, command) assert(command == "register"); return {ok = true} end,
    retpack = function(value) answer = value end,
}
package.loaded["skynet.require"] = {}
package.loaded.flywow_hotupgrade_native = {}
local hotupgrade = require "flywow_hotupgrade"
local module_patch = require "flywow_hotupgrade_module_patch"
local state_identity = scenario.state -- 迁移、提交和恢复均须保留现存状态根表。
local live_module = {version = 1}
local old_function = function() return 1 end
local functions = {load = old_function}
package.loaded.state_merge_logic = live_module
local service_update = {state = scenario.state, functions = functions}
if scenario.custom then
    service_update.snapshot = module_patch.snapshot_state
    service_update.commit = function(target, source) module_patch.restore_state(source, target) end
    service_update.restore = service_update.commit
end
local after_calls = 0 -- Stage 失败时必须仍为零；Activate 后才观察候选。
assert(hotupgrade.register_service({
    service_update = service_update,
    before_upgrade = function() return true end,
    after_upgrade = function()
        after_calls = after_calls + 1
        assert(live_module.version == 2)
        local check_state = scenario.check_updated or scenario.check
        check_state(scenario.state)
        return scenario.expected_failure ~= "HU_ACTIVATE_FAILED" or (scenario.retry == true and after_calls > 1)
    end,
}).ok)
local request = {
    batch_id = "state_merge_" .. scenario_name,
    sequence = 1,
    modules = {{name = "state_merge_logic", source = "return {version = 2}"}},
    service_source = scenario.source,
}
local function command(name)
    answer = nil
    receiver(1, 99, name, request)
    return assert(answer)
end

assert(command("prepare").ok and hotupgrade.patching)
local updated = command("update")
if scenario.expected_failure then
    assert(not updated.ok and updated.code == scenario.expected_failure, updated.message)
    if scenario.error_text then assert(updated.message:find(scenario.error_text, 1, true), updated.message) end
    if scenario.expected_failure == "HU_SERVICE_STAGE_FAILED" then
        assert(after_calls == 0 and hotupgrade.patching)
    else
        assert(after_calls == 1 and not hotupgrade.patching)
    end
    assert(command("abort").ok)
    assert(live_module.version == 1)
elseif scenario.abort then
    assert(updated.ok, updated.message)
    scenario.check_updated(scenario.state)
    assert(command("abort").ok and live_module.version == 1)
else
    assert(updated.ok, updated.message)
    assert(command("finish").ok and live_module.version == 2)
end
assert(scenario.state == state_identity and not hotupgrade.patching)
assert(functions.load == old_function)
scenario.check(scenario.state)
if scenario.retry then
    request.sequence = 2
    request.batch_id = request.batch_id .. "_retry"
    assert(command("prepare").ok)
    local retried = command("update")
    assert(retried.ok, retried.message)
    assert(command("finish").ok and not hotupgrade.patching and after_calls == 2)
    scenario.check_updated(scenario.state)
    assert(scenario.state.self == scenario.state and scenario.state.first == scenario.state.second)
    assert(scenario.state == state_identity and live_module.version == 2)
end
print("HOTUPGRADE_SERVICE_STATE_OK " .. scenario_name)
