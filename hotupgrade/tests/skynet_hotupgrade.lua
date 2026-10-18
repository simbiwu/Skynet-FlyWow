--- 真实 Skynet 多 State 验证：模块更新、Service 替换、状态交接和失败恢复。
local skynet = require "skynet"
-- Native 导出 Skynet 内部 allocator 符号；文件系统测试必须在 Skynet 进程内加载。
require "test_files"
require "skynet.manager"
local hotupgrade = require "flywow_hotupgrade"

local function control(controller_handle, command, request)
    local answer = skynet.call(controller_handle, "hotupgrade", command, request or {})
    assert(answer and answer.ok, answer and (tostring(answer.code) .. ":" .. tostring(answer.message)))
    return answer
end

local function wait_finished(controller_handle, id, expected)
    for _ = 1, 1500 do
        local record = control(controller_handle, "status", {txn_id = id}).record
        if record and (record.phase == "COMPLETED" or record.phase == "DRY_RUN_COMPLETED") then
            return record
        end
        if record and (record.phase == "ABORTED" or record.phase == "RECOVERY_REQUIRED"
            or record.phase == "COMMITTED_DRAIN_PENDING" or record.phase == "PARTIAL") then
            if record.phase == expected then
                return record
            end
            error(record.phase .. ":" .. tostring(record.error and record.error.message))
        end
        skynet.sleep(1)
    end
    error("transaction completion timeout")
end

local function start_controller()
    local controller_handle = skynet.newservice("flywow_hotupgrade_service")
    local initialized = skynet.call(controller_handle, "lua", "init", require "hotupgrade_test_options")
    assert(initialized and initialized.ok, initialized and initialized.message)
    return controller_handle
end

local function start_worker(controller_handle, router_handle, service_type, requested_origin_service_handle)
    local worker = skynet.newservice("skynet_hotupgrade_worker")
    local initialized = skynet.call(worker, "lua", "init",
    {
        controller_handle = controller_handle, router_handle = router_handle,
        service_type = service_type or "worker", origin_service_handle = requested_origin_service_handle,
    })
    assert(initialized and initialized.ok, initialized and initialized.message)
    return worker
end

local function run()
    -- Guard 只验证真实 Skynet yield、暂停拒绝新任务和等待在途任务；不执行模块更新。
    local gate = hotupgrade.guard()
    local entered = false
    local finished = false
    skynet.fork(function()
        local answer = gate:run(function()
            entered = true
            skynet.sleep(10)
            finished = true
        end)
        assert(answer.ok)
    end)
    while not entered do
        skynet.sleep(1)
    end
    assert(gate:prepare_upgrade("guard-fixture").ok)
    assert(not gate:run(function() error("paused Guard must reject new work") end).ok)
    assert(gate:wait_idle("guard-fixture", 10000).ok and finished)
    assert(gate.active == 0 and gate:resume("guard-fixture").ok)
    print("HOTUPGRADE_SKYNET_GUARD_OK")

    os.remove("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history")
    local controller_handle = start_controller()
    local first = start_worker(controller_handle)
    local second = start_worker(controller_handle)
    assert(skynet.call(first, "lua", "read").value == 1)
    local missing_router = skynet.call(controller_handle, "hotupgrade", "validate", {path = "replace"})
    assert(not missing_router.ok and missing_router.code == "HU_ROUTER_REQUIRED")

    -- Dry Run 在门禁内暂时激活并检查，结束后恢复原模块，不对外发布。
    local dry = control(controller_handle, "dry_run", {path = "dry"})
    wait_finished(controller_handle, dry.txn_id)
    assert(skynet.call(first, "lua", "read").value == 1)
    -- 原地 Module Patch 更新所有声明使用该模块的 Worker。
    local applied = control(controller_handle, "apply", {path = "module"})
    wait_finished(controller_handle, applied.txn_id)
    assert(skynet.call(first, "lua", "read").value == 2)
    assert(skynet.call(second, "lua", "read").value == 2)
    print("HOTUPGRADE_SKYNET_MODULE_OK")

    -- 同时验证已有磁盘模块被冻结源码覆盖、新模块可用、无关模块不被提前执行。
    assert(package.searchpath("test_candidate_only", package.path) == nil)
    local frozen_router = skynet.newservice("flywow_hotupgrade_router", controller_handle)
    local frozen_worker = start_worker(controller_handle, frozen_router, "worker_frozen")
    local frozen_route = hotupgrade.router_ref(
        {router_handle = frozen_router, origin_service_handle = frozen_worker})
    assert(frozen_route:call("read").values[1].initialized_value == 1)
    local frozen_dry = control(controller_handle, "dry_run", {path = "frozen"})
    wait_finished(controller_handle, frozen_dry.txn_id)
    local retained = frozen_route:call("read").values[1]
    assert(retained.instance_handle == frozen_worker and retained.initialized_value == 1)
    local frozen = control(controller_handle, "apply", {path = "frozen"})
    wait_finished(controller_handle, frozen.txn_id)
    local initialized = frozen_route:call("read").values[1]
    assert(initialized.value == 2 and initialized.initialized_value == 2 and initialized.initialized_count == 43)
    assert(initialized.state.count == 7 and initialized.instance_handle ~= frozen_worker)
    skynet.sleep(2)
    assert(not pcall(skynet.call, frozen_worker, "lua", "read"), "旧实例须在切换后退出")
    skynet.kill(initialized.instance_handle)
    skynet.kill(frozen_router)
    print("HOTUPGRADE_SKYNET_FROZEN_INITIALIZATION_OK")

    -- 重启控制面后验证候选失败恢复、Service 状态交接、稳定路由和文件回滚。
    skynet.kill(first)
    skynet.kill(second)
    skynet.kill(controller_handle)
    skynet.sleep(2)
    os.remove("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history")
    controller_handle = start_controller()
    local router_handle = skynet.newservice("flywow_hotupgrade_router", controller_handle)
    -- 初代传入的 origin_service_handle 不决定身份；稳定 origin_service_handle 必须仍由真实 RPC source 派生。
    first = start_worker(controller_handle, router_handle, "worker", 999)
    local override_route = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = first})
    local first_read = override_route:call("read").values[1]
    assert(first_read.state.count == 7 and first_read.instance_handle == first)
    local stale_identity = skynet.call(first, "hotupgrade", "status", {instance_handle = first + 1})
    assert(not stale_identity.ok and stale_identity.code == "HU_STALE_INSTANCE")
    local second = start_worker(controller_handle, router_handle)
    local failure = control(controller_handle, "apply", {path = "failed_candidate"})
    wait_finished(controller_handle, failure.txn_id, "ABORTED")
    assert(skynet.call(first, "lua", "read").value == 1)
    local busy = control(controller_handle, "apply", {path = "busy_candidate"})
    wait_finished(controller_handle, busy.txn_id, "ABORTED")
    local routed = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = first})
    local routed_second = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = second})
    assert(routed_second:call("read").values[1].instance_handle == second)

    -- 注册成功后再失败必须移除候选实例；重复失败后正常替换仍可继续。
    for _ = 1, 2 do
        local failed = control(controller_handle, "apply", {path = "registered_failure"})
        local record = wait_finished(controller_handle, failed.txn_id, "ABORTED")
        assert(record.error.code == "HU_CREATE_FAILED")
        assert(routed:call("read").values[1].instance_handle == first)
    end
    -- 已注册候选在初始化中长期 yield，超过启动期限后也必须恢复旧路由。
    local waiting = control(controller_handle, "apply", {path = "registered_waiting"})
    assert(wait_finished(controller_handle, waiting.txn_id, "ABORTED").error.code == "HU_CREATE_FAILED")
    assert(routed:call("read").values[1].instance_handle == first)
    -- 尚未注册的等待可以由 abort 提前结束，而不是一直等到启动期限。
    local cancelled = control(controller_handle, "apply", {path = "waiting"})
    skynet.sleep(2)
    control(controller_handle, "abort", {txn_id = cancelled.txn_id})
    wait_finished(controller_handle, cancelled.txn_id, "ABORTED")
    print("HOTUPGRADE_SKYNET_CANDIDATE_FAILURE_CLEANUP_OK")

    -- 参数错误在分配事务号和锁目标前拒绝。
    local invalid_selector = skynet.call(controller_handle, "hotupgrade", "validate",
        {path = "replace", selector = {percent = 1.5}})
    assert(not invalid_selector.ok and invalid_selector.code == "HU_INVALID_SELECTOR")

    -- 用 Controller 的真实稳定选择结果二分出一个只命中单实例的百分比。
    -- 逻辑身份现由 Skynet handle 派生，测试不再依赖手工挑选 ID。
    local gray_percent
    local selected_instance_handle
    local low, high = 0, 1
    for _ = 1, 48 do
        local percent = (low + high) / 2
        local selection = skynet.call(controller_handle, "hotupgrade", "validate", {
            path = "replace", selector = {percent = percent},
        })
        local selected_count = selection.ok and #selection.targets or 0
        assert(selection.ok or selection.code == "HU_TARGET_MISSING",
            tostring(selection.code) .. ":" .. tostring(selection.message))
        if selected_count == 1 then
            gray_percent = percent
            selected_instance_handle = selection.targets[1].old.instance_handle
            break
        elseif selected_count == 0 then
            low = percent
        else
            high = percent
        end
    end
    assert(gray_percent, "两个不同 Service 必须能被稳定百分比区分")
    assert(routed:call("add", 5).ok)
    assert(routed_second:call("add", 5).ok)
    local selected_route = selected_instance_handle == first and routed or routed_second
    local unselected_route = selected_instance_handle == first and routed_second or routed
    local unselected_instance_handle = selected_instance_handle == first and second or first
    local slow_finished = false
    skynet.fork(function()
        local slow = selected_route:call("slow", 20)
        slow_finished = slow.ok
    end)
    skynet.sleep(1)
    local replaced = control(controller_handle, "apply", {
        path = "replace", selector = {percent = gray_percent},
    })
    assert(replaced.target_count == 1)
    wait_finished(controller_handle, replaced.txn_id)
    assert(slow_finished, "Router 暂停必须先排空已接纳请求")
    local unchanged = unselected_route:call("read").values[1]
    local upgraded = selected_route:call("read").values[1]
    assert(unchanged.state.count == 12 and upgraded.state.count == 12)
    assert(unchanged.instance_handle == unselected_instance_handle)
    assert(upgraded.instance_handle ~= first and upgraded.instance_handle ~= second)
    assert(unchanged.value == 1 and upgraded.value == 2 and upgraded.state.ok == true)
    print("HOTUPGRADE_SKYNET_SERVICE_REPLACE_OK")
    print("HOTUPGRADE_SKYNET_GRAY_OK")

    -- 回滚是再次应用旧文件；两个 Service 都由自身回调交接权威计数。
    local rollback = control(controller_handle, "apply", {path = "rollback"})
    wait_finished(controller_handle, rollback.txn_id)
    local reversed = routed:call("read").values[1]
    local reversed_second = routed_second:call("read").values[1]
    assert(reversed.value == 1 and reversed.state.count == 12)
    assert(reversed_second.value == 1 and reversed_second.state.count == 12)
    print("HOTUPGRADE_SKYNET_ROLLBACK_OK")
    local audit = control(controller_handle, "history").records
    assert(#audit[rollback.txn_id].participants == 2)
    local first_replacement = audit[rollback.txn_id].participants[1].new.instance_handle
    local second_replacement = audit[rollback.txn_id].participants[2].new.instance_handle
    assert(first_replacement ~= second_replacement)
    assert(reversed.instance_handle == first_replacement and reversed_second.instance_handle == second_replacement)

    -- health 必须看到候选初始化时已加载的新代码；dry_run 检查后销毁候选并恢复旧实例。
    local health_worker = start_worker(controller_handle, router_handle, "worker_health")
    local health_route = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = health_worker})
    local health_dry = control(controller_handle, "dry_run", {path = "health"})
    wait_finished(controller_handle, health_dry.txn_id)
    local health_unchanged = health_route:call("read").values[1]
    assert(health_unchanged.value == 1 and health_unchanged.instance_handle == health_worker)
    local healthy = control(controller_handle, "apply", {path = "health"})
    wait_finished(controller_handle, healthy.txn_id)
    assert(health_route:call("read").values[1].value == 2)
    print("HOTUPGRADE_SKYNET_ACTIVATED_HEALTH_OK")

    -- 状态交接能力必须成对出现；候选缺少 import_state 时，旧路由应恢复到旧实例。
    local missing_import = start_worker(controller_handle, router_handle, "worker_missing_import")
    local mismatch = control(controller_handle, "apply", {path = "missing_import"})
    local mismatch_record = wait_finished(controller_handle, mismatch.txn_id, "ABORTED")
    assert(mismatch_record.error.code == "HU_CAPABILITY_MISMATCH")
    local mismatch_router = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = missing_import})
    assert(mismatch_router:call("read").values[1].state.count == 7)
    print("HOTUPGRADE_SKYNET_STATE_HOOK_PAIR_OK")

    -- 旧实例导出失败时，不发布候选，也不丢失旧实例可服务状态。
    local export_failure = start_worker(controller_handle, router_handle, "worker_export_failure")
    local export_failed = control(controller_handle, "apply", {path = "export_failure"})
    local export_record = wait_finished(controller_handle, export_failed.txn_id, "ABORTED")
    assert(export_record.error.code == "HU_HOOK_REJECTED")
    local export_router = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = export_failure})
    assert(export_router:call("read").values[1].state.count == 7)
    print("HOTUPGRADE_SKYNET_STATE_EXPORT_FAILURE_OK")

    -- 候选导入失败时沿旧路由恢复，不能让未初始化候选接收请求。
    local import_failure = start_worker(controller_handle, router_handle, "worker_import_failure")
    local import_failed = control(controller_handle, "apply", {path = "import_failure"})
    local import_record = wait_finished(controller_handle, import_failed.txn_id, "ABORTED")
    assert(import_record.error.code == "HU_HOOK_REJECTED")
    local import_router = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = import_failure})
    assert(import_router:call("read").values[1].state.count == 7)
    print("HOTUPGRADE_SKYNET_STATE_IMPORT_FAILURE_OK")

    -- 未声明交接回调的 Service 在 candidate factory 注册前从权威来源重建状态。
    local rebuild = start_worker(controller_handle, router_handle, "worker_rebuild")
    local rebuilt = control(controller_handle, "apply", {path = "rebuild"})
    wait_finished(controller_handle, rebuilt.txn_id)
    local rebuild_router = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = rebuild})
    assert(rebuild_router:call("read").values[1].state.count == 73)
    print("HOTUPGRADE_SKYNET_STATE_REBUILD_OK")

    -- 第二个灰度实例导入失败时，第一个已发布的新代保留，失败目标恢复旧代。
    local partial_success = start_worker(controller_handle, router_handle, "worker_partial_a")
    local partial_failure = start_worker(controller_handle, router_handle, "worker_partial_z")
    local partial = control(controller_handle, "apply", {path = "partial"})
    local partial_record = wait_finished(controller_handle, partial.txn_id, "PARTIAL")
    assert(partial_record.success == 1 and partial_record.failed == 1)
    local first_route = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = partial_success})
        :call("read").values[1]
    local second_route = hotupgrade.router_ref(
        {router_handle = router_handle, origin_service_handle = partial_failure})
        :call("read").values[1]
    assert(first_route.instance_handle ~= partial_success)
    assert(second_route.instance_handle == partial_failure)
    print("HOTUPGRADE_SKYNET_PARTIAL_GRAY_FAILURE_OK")

    local native = require "flywow_hotupgrade_native"
    assert(native.append_sync("./third_party/skynet-flywow/build/hotupgrade-tests/integration.history",
        'return {txn_id="unresolved",phase="ACTIVATING",sequence=999,participants={}}\n'))
    skynet.kill(controller_handle)
    skynet.sleep(2)
    controller_handle = start_controller()
    assert(control(controller_handle, "status", {txn_id = "unresolved"}).record.phase == "ACTIVATING")
    local blocked = skynet.call(controller_handle, "hotupgrade", "apply", {path = "module"})
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
