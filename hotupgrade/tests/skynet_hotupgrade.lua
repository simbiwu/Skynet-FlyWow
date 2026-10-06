--- 真实 Skynet 多 State 验证：原地更新、失败恢复、状态迁移和 DRAIN。
local skynet = require "skynet"
require "skynet.manager"
local rpc = require "flywow_hotupgrade_rpc"
local hotupgrade = require "flywow_hotupgrade"
local registry = require "flywow_hotupgrade_registry"

local function control(controller, command, request)
    local answer = rpc.call(controller, command, request or {}, 5000)
    assert(answer and answer.ok, answer and (tostring(answer.code) .. ":" .. tostring(answer.message)))
    return answer
end

local function wait_finished(controller, id, expected)
    for _ = 1, 1000 do
        local record = control(controller, "status", {txn_id = id}).record
        if record and (record.phase == "COMPLETED" or record.phase == "DRY_RUN_COMPLETED") then return record end
        if record and (record.phase == "ABORTED" or record.phase == "RECOVERY_REQUIRED" or record.phase == "COMMITTED_DRAIN_PENDING") then
            if record.phase == expected then return record end
            error(record.phase .. ":" .. tostring(record.error and record.error.message))
        end
        skynet.sleep(1)
    end
    error("transaction completion timeout")
end

local function start_worker(controller, id, router)
    return skynet.newservice("skynet_hotupgrade_worker", controller, id, router)
end

local function run()
    os.remove("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history")
    local controller = skynet.newservice("flywow_hotupgraded", "hotupgrade_test_options", skynet.self())
    local first = start_worker(controller, 1)
    local second = start_worker(controller, 2)
    assert(skynet.call(first, "lua", "read").value == 1)

    local dry = control(controller, "dry_run", {path = "dry"})
    wait_finished(controller, dry.txn_id)
    assert(skynet.call(first, "lua", "read").value == 1)
    local applied = control(controller, "apply", {path = "module"})
    wait_finished(controller, applied.txn_id)
    assert(skynet.call(first, "lua", "read").value == 2)
    assert(skynet.call(second, "lua", "read").value == 2)
    assert(not rpc.call(controller, "apply", {path = "module"}, 2000).ok)
    print("HOTUPGRADE_SKYNET_MODULE_OK")

    skynet.kill(first)
    skynet.kill(second)
    skynet.kill(controller)
    skynet.sleep(2)
    os.remove("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history")
    controller = skynet.newservice("flywow_hotupgraded", "hotupgrade_test_options", skynet.self())
    local router = skynet.newservice("flywow_hotupgrade_router", controller)
    first = start_worker(controller, 1, router)
    local failure = control(controller, "apply", {path = "failed_candidate"})
    wait_finished(controller, failure.txn_id, "ABORTED")
    local restored = skynet.call(first, "lua", "read")
    assert(restored.value == 1 and restored.resource)
    local busy = control(controller, "apply", {path = "busy_candidate"})
    wait_finished(controller, busy.txn_id, "ABORTED")
    assert(skynet.call(first, "lua", "read").resource)
    local drained = control(controller, "apply", {path = "drain"})
    wait_finished(controller, drained.txn_id)
    local routed = hotupgrade.router_ref({handle = router, key = registry.key("worker", 1)})
    assert(routed:call("read").values[1].value == 2)
    print("HOTUPGRADE_SKYNET_DRAIN_OK")
    skynet.kill(controller)
    skynet.sleep(2)
    os.remove("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history")
    controller = skynet.newservice("flywow_hotupgraded", "hotupgrade_test_options", skynet.self())
    router = skynet.newservice("flywow_hotupgrade_router", controller)
    first = start_worker(controller, 1, router)
    local migrated = control(controller, "apply", {path = "migrate"})
    wait_finished(controller, migrated.txn_id)
    routed = hotupgrade.router_ref({handle = router, key = registry.key("worker", 1)})
    local upgraded = routed:call("read").values[1]
    assert(upgraded.state.schema_version == 2 and upgraded.state.extra)
    assert(upgraded.state.count == 7 and upgraded.value == 2)
    assert(routed:call("add", 5).ok)
    local rollback = control(controller, "rollback", {path = "rollback"})
    wait_finished(controller, rollback.txn_id)
    local reversed = routed:call("read").values[1]
    assert(reversed.state.schema_version == 1 and reversed.state.extra == nil)
    assert(reversed.state.count == 12 and reversed.value == 1)
    print("HOTUPGRADE_SKYNET_ROLLBACK_OK")
    assert(hotupgrade.register_service(
    {
        controller = controller, service_type = "caller", service_id = 1,
        generation = 1, code_version = 1, adapter = {},
        dependencies = {{target = registry.key("worker", 1), edge = "strong"}},
    }).ok)
    local ref = assert(hotupgrade.service_ref({target = registry.key("worker", 1)}).ref)
    local read = ref:call("read", nil)
    assert(read.ok, read.message)
    assert(read.values[1].state.schema_version == 1)
    assert(read.values[1].state.count == 12 and not read.values[1].state.extra)
    assert(read.values[1].value == 1)
    assert(ref:release().ok)
    print("HOTUPGRADE_SKYNET_MIGRATE_OK")
    local audit = control(controller, "history").records
    assert(audit[rollback.txn_id].participants[1].new.generation == 3)
    assert(control(controller, "metrics").values.phase_COMPLETED == 2)
    local native = require "flywow_hotupgrade_native"
    assert(native.append_sync("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history",
        'return {txn_id="unresolved",phase="ACTIVATING",sequence=999,participants={}}\n'))
    skynet.kill(controller)
    skynet.sleep(2)
    controller = skynet.newservice("flywow_hotupgraded", "hotupgrade_test_options", skynet.self())
    assert(control(controller, "status", {txn_id = "unresolved"}).record.phase == "ACTIVATING")
    local blocked = rpc.call(controller, "apply", {path = "module"}, 2000)
    assert(not blocked.ok and blocked.code == "HU_RECOVERY_REQUIRED")
    print("HOTUPGRADE_SKYNET_RESTART_FAIL_CLOSED_OK")
    io.stdout:flush()
    skynet.abort()
end

skynet.start(function()
    local ok, message = xpcall(run, debug.traceback)
    if not ok then
        print("HOTUPGRADE_SKYNET_FAILED", message)
        io.stdout:flush()
        skynet.abort()
    end
end)
