--- 只模拟控制面消息编排；目标 State 的真实提交由 Skynet 集成覆盖。
local pending = {} -- 待调度的控制面事务协程。
local calls = {}   -- 各目标最近收到的控制步骤。
local failure
package.loaded.skynet =
{
    self = function() return 99 end,
    fork = function(fn) pending[#pending + 1] = fn end,
    call = function(handle, protocol, command, request)
        assert(protocol == "hotupgrade" and request.sequence > 0)
        calls[handle] = command
        if failure and failure.handle == handle and failure.command == command then
            return {ok = false, code = "HU_FIXTURE_FAILED", message = command}
        end
        return {ok = true}
    end,
}
package.loaded.flywow_hotupgrade_native =
{
    resolve = function(path) return path end,
    list_lua = function(_root, path, category)
        if path == "module" and category == "modules" then
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
local function run(command)
    local answer = c:control(command or "apply", {path = "module"}, 1)
    assert(answer.ok)
    assert(not c:control("apply", {path = "module"}, 1).ok)
    pending[#pending]()
    return c:control("status", {txn_id = answer.txn_id}, 1)
end
local status = run()
assert(status.record.phase == "COMPLETED" and status.record.success == 2 and calls[20] == "finish")
failure = {handle = 20, command = "activate"}
status = run()
assert(status.record.phase == "PARTIAL" and status.record.success == 1 and status.record.failed == 1)
assert(calls[20] == "abort")
failure = nil
status = run("dry_run")
assert(status.record.phase == "DRY_RUN_COMPLETED" and calls[10] == "abort")
local started = c:control("apply", {path = "module"}, 1)
assert(c:control("abort", {txn_id = started.txn_id}, 1).ok)
pending[#pending]()
assert(c:control("status", {txn_id = started.txn_id}, 1).record.phase == "ABORTED")
failure = {handle = 10, command = "finish"}
status = run()
assert(status.recovery_required and status.record.phase == "RECOVERY_REQUIRED")
assert(not c:control("apply", {path = "module"}, 1).ok)
assert(not c:control("history", {}, 1).ok)
-- 持有容量和只保留最近终态的合同，不能靠清空查询记录绕过恢复门禁。
assert(c:control("status", {txn_id = "99:1"}, 1).code == "HU_TRANSACTION_MISSING")
local bounded = assert(controller.new({patch_root = "build/hotupgrade-tests/patches"}).controller)
for handle = 1, 1024 do
    assert(bounded:control("register", {service_type = "empty", modules = {}, service_patch = false}, handle).ok)
end
assert(bounded:control("register", {service_type = "empty", modules = {}, service_patch = false}, 1025).code
    == "HU_TARGET_LIMIT")
local names = {}
for index = 1, 1024 do
    names[index] = "logic_" .. index
end
local limited = assert(controller.new({patch_root = "build/hotupgrade-tests/patches"}).controller)
assert(limited:control("register", {service_type = "empty", modules = names, service_patch = false}, 1).ok)
assert(limited:control("register_module", {name = names[1]}, 1).ok)
assert(limited:control("register_module", {name = "overflow"}, 1).code == "HU_MODULE_LIMIT")
print("HOTUPGRADE_CONTROLLER_OK")
