--- 只模拟控制面消息编排；目标 State 的真实提交由 Skynet 集成覆盖。
local hotupgrade_common = require "flywow_hotupgrade_common"
local module_state =
{
    pending_control_coroutines = {}, -- 测试替身排队的 Controller 控制面协程。
    last_control_command_by_handle = {}, -- 各目标最近收到的控制步骤。
    injected_control_failure = nil, -- 当前测试注入的目标和命令失败条件。
}
package.loaded.skynet =
{
    self = function() return 99 end,
    fork = function(fn) module_state.pending_control_coroutines[#module_state.pending_control_coroutines + 1] = fn end,
    call = function(handle, protocol, command, request)
        assert(protocol == "hotupgrade" and request.sequence > 0)
        module_state.last_control_command_by_handle[handle] = command
        if module_state.injected_control_failure and module_state.injected_control_failure.handle == handle and module_state.injected_control_failure.command == command then
            return {ok = false, code = "HU_FIXTURE_FAILED", message = command}
        end
        return {ok = true}
    end,
}
package.loaded.flywow_hotupgrade_native =
{
    resolve = function(path) return path end,
    list_lua = function(_root, path, category)
        if path == "unmatched_module" and category == "modules" then
            return {"test_worker_logic.lua", "missing_logic.lua"}
        end
        if path == "unmatched_service" and category == "services" then
            return {"unused.lua"}
        end
        if path == "combined" and category == "services" then
            return {"player.lua"}
        end
        if (path == "module" or path == "combined" or path == "unmatched_service")
            and category == "modules" then
            return {"test_worker_logic.lua"}
        end
        return nil, {code = "HU_PATCH_EMPTY"}
    end,
}
local controller = require "flywow_hotupgrade_controller"
assert(not controller.new({}).ok)
local c = assert(controller.new({patch_root = "build/hotupgrade-tests/patches"}).controller)
for _, handle in ipairs({10, 20}) do
    assert(c:control("register", {service_type = "player", modules = {"test_worker_logic"},
        service_patch = false}, handle).ok)
end
assert(not c:control("register", {service_type = "player", modules = {}, service_patch = false}, 10).ok)
assert(c:control("register_module", {name = "extra"}, 10).ok)
assert(not c:control("register_module", {name = "extra"}, 30).ok)
assert(not c:control("validate", {path = "module", selector = {percent = 0.5}}, 1).ok)
assert(c:control("validate", {path = "module"}, 1).target_count == 2)
-- 三种入口必须在整包匹配失败时拒绝启动，连 prepare 都不能发给已匹配目标。
for _, fixture in ipairs({
    {path = "unmatched_module", file = "modules/missing_logic.lua", reason = "声明模块"},
    {path = "unmatched_service", file = "services/unused.lua", reason = "service_type"},
}) do
    for _, command in ipairs({"validate", "dry_run", "apply"}) do
        module_state.last_control_command_by_handle = {}
        local pending_count = #module_state.pending_control_coroutines
        local sequence = c.sequence
        local rejected = c:control(command, {path = fixture.path}, 1)
        assert(not rejected.ok and rejected.code == "HU_TARGET_MISSING")
        assert(rejected.message:find(fixture.path .. "/" .. fixture.file, 1, true))
        assert(rejected.message:find(fixture.reason, 1, true))
        assert(next(module_state.last_control_command_by_handle) == nil and #module_state.pending_control_coroutines == pending_count and not c.active and c.sequence == sequence)
    end
end
-- 同一模块仍可匹配多个 Service，组合包中的 Service 脚本也必须被覆盖。
local combined = assert(controller.new({patch_root = "build/hotupgrade-tests/patches"}).controller)
for _, handle in ipairs({30, 40}) do
    assert(combined:control("register", {service_type = "player", modules = {"test_worker_logic"},
        service_patch = true}, handle).ok)
end
for _, command in ipairs({"validate", "dry_run", "apply"}) do
    assert(combined:control(command, {path = "combined"}, 1).target_count == 2)
    if command ~= "validate" then
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        assert(combined.last.success == 2)
    end
end
local unsupported = c:control("validate", {path = "combined"}, 1)
assert(unsupported.code == "HU_SERVICE_PATCH_UNSUPPORTED")
assert(unsupported.message:find("combined/services/player.lua", 1, true))
local function run(command)
    local answer = c:control(command or "apply", {path = "module"}, 1)
    assert(answer.ok)
    assert(not c:control("apply", {path = "module"}, 1).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    return c:control("status", {txn_id = answer.txn_id}, 1)
end
local status = run()
assert(status.record.phase == "COMPLETED" and status.record.success == 2 and module_state.last_control_command_by_handle[20] == "finish")
module_state.injected_control_failure = {handle = 20, command = "activate"}
status = run()
assert(status.record.phase == "PARTIAL" and status.record.success == 1 and status.record.failed == 1)
assert(module_state.last_control_command_by_handle[20] == "abort")
module_state.injected_control_failure = nil
status = run("dry_run")
assert(status.record.phase == "DRY_RUN_COMPLETED" and module_state.last_control_command_by_handle[10] == "abort")
local started = c:control("apply", {path = "module"}, 1)
assert(c:control("abort", {txn_id = started.txn_id}, 1).ok)
module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
assert(c:control("status", {txn_id = started.txn_id}, 1).record.phase == "ABORTED")
module_state.injected_control_failure = {handle = 10, command = "finish"}
status = run()
assert(status.recovery_required and status.record.phase == "RECOVERY_REQUIRED")
assert(not c:control("apply", {path = "module"}, 1).ok)
assert(not c:control("history", {}, 1).ok)
-- 持有容量和只保留最近终态的合同，不能靠清空查询记录绕过恢复门禁。
assert(c:control("status", {txn_id = "99:1"}, 1).code == "HU_TRANSACTION_MISSING")
local bounded = assert(controller.new({patch_root = "build/hotupgrade-tests/patches"}).controller)
for handle = 1, hotupgrade_common.MAX_TARGETS do
    assert(bounded:control("register", {service_type = "empty", modules = {}, service_patch = false}, handle).ok)
end
assert(bounded:control("register", {service_type = "empty", modules = {}, service_patch = false}, hotupgrade_common.MAX_TARGETS + 1).code
    == "HU_TARGET_LIMIT")
local names = {}
for index = 1, hotupgrade_common.MAX_MODULES do
    names[index] = "logic_" .. index
end
local limited = assert(controller.new({patch_root = "build/hotupgrade-tests/patches"}).controller)
assert(limited:control("register", {service_type = "empty", modules = names, service_patch = false}, 1).ok)
assert(limited:control("register_module", {name = names[1]}, 1).ok)
assert(limited:control("register_module", {name = "overflow"}, 1).code == "HU_MODULE_LIMIT")
print("HOTUPGRADE_CONTROLLER_OK")
