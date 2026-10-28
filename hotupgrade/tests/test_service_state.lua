--- 独立 Lua State 验证直接状态更新、快照边界及组合恢复。
local common = require "flywow_hotupgrade_common"
local scenario_name = assert(arg[1]) -- 命令行指定的 Service 状态迁移场景名。
local scenarios = {} -- 按名称保存各组初始状态、Service Patch 和断言函数。
--- 组装一项 Service 状态测试场景，供后续命令测试复用。
---@param service_patch_source string 本场景要执行的 Service .patch 源码。
---@param check fun(state:table) Update 后的断言函数；本场景记录并在适当阶段调用。
---@param state? table 本场景的初始 Service 状态；省略时使用带 a、b 两个字段的默认表。
local function scenario(service_patch_source, check, state)
    return {state = state or {a = {keep_a = 1}, b = {keep_b = 2}}, service_patch_source = service_patch_source, check = check}
end
--- 返回普通状态更新场景：候选代码分别修改 a 和 b。
local function normal()
    return scenario([[return function(state)
        return {update_state = function()
            state.a.changed = 3
            state.b.changed = 3
        end}
    end]], function(state)
        assert(state.a ~= state.b and state.a.keep_a == 1 and state.b.keep_b == 2)
        assert(state.a.changed == 3 and state.b.changed == 3)
    end)
end
scenarios.shared = function()
    return scenario([[return function(state)
        return {update_state = function()
            local shared = {changed = 3}
            state.a = shared
            state.b = shared
        end}
    end]], function(state) assert(state.a == state.b and state.a.changed == 3 and state.a.keep_a == nil) end)
end
scenarios.custom = function() local s = normal(); s.custom = true; return s end
scenarios.nested_shared = function()
    return scenario([[return function(state)
        return {update_state = function()
            local shared = {changed = 3}
            state.a.shared = shared
            state.b.shared = shared
        end}
    end]], function(state)
        assert(state.a.keep_a == 1 and state.b.keep_b == 2)
        assert(state.a.shared == state.b.shared and state.a.shared.changed == 3)
    end)
end
scenarios.cycles = function()
    return scenario([[return function(state)
        return {update_state = function()
            state.self = state
            state.a.self = state.a
            state.a.peer = {back = state.a}
        end}
    end]], function(state)
        assert(state.self == state and state.a.self == state.a and state.a.peer.back == state.a)
        assert(state.a.keep_a == 1)
    end)
end
scenarios.old_alias = function()
    local shared = {retained = 7}; shared.self = shared -- 恢复后两个字段共同引用的子表。
    return scenario([[return function(state)
        return {update_state = function() state.a.left = 1; state.b.right = 2 end}
    end]], function(state)
        assert(state.a == state.b and state.a.self == state.a)
        assert(state.a.retained == 7 and state.a.left == 1 and state.b.right == 2)
    end, {a = shared, b = shared})
end
scenarios.types = function()
    return scenario([[return function(state)
        return {update_state = function()
            state.nested.changed = 3
            state.ranks[2] = 9
            state.scalar = {new = true}
            state.replaced = 0
            state.disabled = false
            state.zero = 0
            state.text = ""
            state[false] = {enabled = true}
            state.obsolete = nil
        end}
    end]], function(state)
        assert(state.nested.kept == 7 and state.nested.changed == 3)
        assert(state.ranks[1] == 1 and state.ranks[2] == 9 and state.ranks[3] == 3)
        assert(state.scalar.new and state.replaced == 0 and state.disabled == false)
        assert(state.zero == 0 and state.text == "" and state[false].enabled and state.obsolete == nil)
    end, {nested = {kept = 7}, ranks = {1,2,3}, obsolete = true})
end
scenarios.empty = function()
    return scenario([[return function() return {update_state = function() end} end]],
        function(state) assert(state.a.keep_a == 1 and state.b.keep_b == 2) end)
end
scenarios.direct_fields = normal
scenarios.expansion = function()
    return scenario([[return function(state)
        return {update_state = function()
            local shared = {changed = 3}
            for _ = 1, 14 do shared = {left = shared, right = shared} end
            state.expanded = shared
        end}
    end]], function(state)
        local node = state.expanded -- 沿 expanded 状态链向下遍历的当前节点。
        for _ = 1, 14 do assert(node.left == node.right); node = node.left end
        assert(node.changed == 3 and state.a.keep_a == 1)
    end)
end
scenarios.depth_boundary = function()
    local state = {kept = 7}; local node = state -- state 是 Service 私有状态根表，node 从根表开始沿 next 链扩展。
    for _ = 2, common.MAX_STATE_DEPTH do node.next = {}; node = node.next end
    node.value = 3
    return scenario([[return function(state) return {update_state = function() state.kept = 8 end} end]],
        function(value) assert(value.kept == 8 and value.next) end, state)
end
scenarios.depth = function()
    local s = scenarios.depth_boundary(); local node = s.state -- s 是状态场景记录，node 从其状态根表开始沿 next 链查找末端。
    while node.next do node = node.next end
    node.next = {}
    s.expected_failure = "HU_SERVICE_STAGE_FAILED"
    s.error_text = "状态快照嵌套超过限制"
    s.check = function(state) assert(state.kept == 7) end
    return s
end
scenarios.field_boundary = function()
    local state = {} -- 传给快照边界场景的 Service 私有状态根表。
    for i = 1, common.MAX_STATE_FIELDS do state[i] = i end
    return scenario([[return function(state) return {update_state = function() state[1] = 9 end} end]],
        function(value) assert(value[1] == 9 and value[common.MAX_STATE_FIELDS] == common.MAX_STATE_FIELDS) end, state)
end
scenarios.snapshot_size = function()
    local s = scenarios.field_boundary(); s.state.extra = 1 -- 当前构造的状态测试场景记录。
    s.expected_failure = "HU_SERVICE_STAGE_FAILED"; s.error_text = "状态快照超过字段限制"
    s.check = function(state) assert(state[1] == 1 and state.extra == 1) end
    return s
end
--- 在正常更新场景上加入共享引用与根循环，改用恢复后检查以验证默认快照保持数据图关系。
local function restored()
    -- check_updated 保留更新成功时的断言；check 随后改成恢复断言，驱动层按当前阶段选择调用。
    local s = normal() -- 当前构造的状态测试场景记录。
    local shared = {retained = 7} -- 恢复后两个字段共同引用的子表。
    s.state.first = shared; s.state.second = shared; s.state.self = s.state
    s.check_updated = s.check
    s.check = function(state)
        assert(state.a.keep_a == 1 and state.b.keep_b == 2)
        assert(state.a.changed == nil and state.b.changed == nil)
        assert(state.first == state.second and state.first.retained == 7 and state.self == state)
    end
    return s
end
scenarios.abort = function() local s = restored(); s.abort = true; return s end
scenarios.recovery = function() local s = restored(); s.expected_failure = "HU_ACTIVATE_FAILED"; return s end
scenarios.recovery_retry = function() local s = scenarios.recovery(); s.retry = true; return s end
scenarios.custom_recovery = function() local s = scenarios.recovery(); s.custom = true; return s end

scenarios.partial_throw = function()
    local s = restored() -- 当前构造的状态测试场景记录。
    s.service_patch_source = [[return function(state) return {update_state = function()
        state.a.changed = 99
        state.a.keep_a = nil
        state.extra = true
        error("partial update rejected")
    end} end]]
    s.expected_failure = "HU_ACTIVATE_FAILED"
    s.expected_after_calls = 0
    local check = s.check -- 保存原更新断言，恢复场景在它后面追加对旧状态的检查。
    s.check = function(state) check(state); assert(state.extra == nil) end
    return s
end
scenarios.bad_state_callback = function()
    local s = normal() -- 当前构造的状态测试场景记录。
    s.service_patch_source = "return function() return {update_state = 12} end"
    s.expected_failure = "HU_SERVICE_STAGE_FAILED"
    s.check = function(state) assert(state.a.keep_a == 1 and state.a.changed == nil) end
    return s
end
-- 场景记录集中提供初始 state、Patch 源码、预期失败与检查回调；后面的驱动使用同一份记录完成整个控制链。
local scenario = assert(scenarios[scenario_name], scenario_name)()
local receiver -- register_service 安装的真实协议接收器。
local answer   -- retpack 捕获的控制命令返回值。
package.loaded.skynet = {
    uniqueservice = function() return 99 end,
    getenv = function() return "/fixture/host" end,
    register_protocol = function() end,
    dispatch = function(protocol, callback) assert(protocol == "hotupgrade"); receiver = callback end,
    call = function(_, _, command) assert(command == "register"); return {ok = true} end,
    retpack = function(value) answer = value end,
}
package.loaded["skynet.require"] = {}
package.loaded.flywow_hotupgrade_native = {}
local hotupgrade = require "flywow_hotupgrade" -- 真实 Service 侧 HotUpgrade API，供本文件驱动控制消息。
local module_patch = require "flywow_hotupgrade_module_patch" -- 提供普通数据图快照和恢复实现的模块。
local state_identity = scenario.state -- 迁移、提交和恢复均须保留现存状态根表。
local live_module = {version = 1} -- 被更新的线上测试模块根表，提交后应保持引用身份。
local old_function = function() return 1 end -- 更新前函数表中的函数，热更不得替换该业务函数表。
local functions = {load = old_function} -- Service 私有函数集合，用于验证此轮仅迁移 state。
package.loaded.state_merge_logic = live_module
local service_update = {state = scenario.state, functions = functions} -- 登记给 HotUpgrade 的私有状态和函数集合。
if scenario.custom then
    service_update.snapshot = module_patch.snapshot_state
    service_update.restore = function(target, source) module_patch.restore_state(source, target) end
end
--- 确认无效的 service_update 配置会被拒绝，且不会安装控制消息接收器。
---@param config table 本次要验证的错误状态更新配置；本函数将它传给 register_service。
local function invalid_registration(config)
    local result = hotupgrade.register_service({ -- register_service 对当前完整 Service 配置的返回结果。
        service_update = config,
        before_upgrade = function() return true end,
    })
    assert(not result.ok and result.code == "HU_INVALID_OPTIONS" and receiver == nil)
end
invalid_registration({state = scenario.state, functions = functions, snapshot = module_patch.snapshot_state})
invalid_registration({state = scenario.state, functions = functions, restore = function() end})
local after_calls = 0 -- Stage 失败时必须仍为零；Activate 后才观察候选。
assert(hotupgrade.register_service({
    service_update = service_update,
    before_upgrade = function() return true end,
    after_upgrade = function()
        after_calls = after_calls + 1
        assert(live_module.version == 2)
        local check_state = scenario.check_updated or scenario.check -- Update 成功后选择执行的业务状态断言。
        check_state(scenario.state)
        return scenario.expected_failure ~= "HU_ACTIVATE_FAILED" or (scenario.retry == true and after_calls > 1)
    end,
}).ok)
local request = { -- Prepare/Update/Abort 共用的完整控制请求。
    batch_id = "state_merge_" .. scenario_name,
    sequence = 1,
    modules = {{name = "state_merge_logic", source = "return {version = 2}"}},
    service_patch_source = scenario.service_patch_source,
}
--- 向当前测试 Service 注入一条 HotUpgrade 控制命令并返回协议结果。
---@param name string prepare、update、abort 或 finish；本函数将它与共享 request 一起交给接收器。
local function command(name)
    answer = nil
    receiver(1, 99, name, request)
    return assert(answer)
end

assert(command("prepare").ok and hotupgrade.patching)
assert(scenario.state == state_identity and functions.load == old_function)
local updated = command("update") -- 当前 Update 的成功或失败结果。
if scenario.expected_failure then
    assert(not updated.ok and updated.code == scenario.expected_failure, updated.message)
    if scenario.error_text then assert(updated.message:find(scenario.error_text, 1, true), updated.message) end
    if scenario.expected_failure == "HU_SERVICE_STAGE_FAILED" then
        assert(after_calls == 0 and hotupgrade.patching)
    else
        assert(after_calls == (scenario.expected_after_calls or 1) and hotupgrade.patching)
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
    local retried = command("update") -- 恢复失败后第二次 Update 的结果。
    assert(retried.ok, retried.message)
    assert(command("finish").ok and not hotupgrade.patching and after_calls == 2)
    scenario.check_updated(scenario.state)
    assert(scenario.state.self == scenario.state and scenario.state.first == scenario.state.second)
    assert(scenario.state == state_identity and live_module.version == 2)
end
print("HOTUPGRADE_SERVICE_STATE_OK " .. scenario_name)
