--- 真实多 State：handle/状态身份、组合恢复、Guard 排空、部分成功与恢复门禁。
local skynet = require "skynet"
require "skynet.manager"
local hotupgrade = require "flywow_hotupgrade"
require "test_files"

local function create_controller(service_dir)
    local handle = skynet.newservice("flywow_hotupgrade_service")
    assert(skynet.call(handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    local config = require "hotupgrade_test_options"
    assert(skynet.call(handle, "lua", "init",
        {patch_root = config.patch_root, root_path = config.root_path, service_dir = service_dir or config.service_dir}).ok)
    assert(skynet.call(handle, "lua", "init", {}).code == "HU_ALREADY_INITIALIZED")
    return handle
end

local function worker(controller_handle, worker_config)
    local handle = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker")
    worker_config = worker_config or {}
    worker_config.controller_handle = controller_handle
    local registered = skynet.call(handle, "lua", "init", worker_config)
    if not registered.ok then
        assert(hotupgrade.cancel_service_creation(controller_handle, handle).ok)
        error(registered.message)
    end
    return handle
end

local function read(handle)
    return skynet.call(handle, "lua", "read", {})
end

local function start(controller_handle, path, command)
    local begun = skynet.call(controller_handle, "hotupgrade", "begin", {})
    assert(begun.ok, begun.message)
    for _ = 1, 1000 do
        local status = skynet.call(controller_handle, "hotupgrade", "status", {batch_id = begun.batch_id})
        if status.lifecycle.phase == "DEPLOYING" then
            break
        end
        skynet.sleep(1)
    end
    local answer = skynet.call(controller_handle, "hotupgrade", command or "apply",
        {batch_id = begun.batch_id, path = path})
    assert(answer.ok, tostring(answer.code) .. ":" .. tostring(answer.message))
    return answer.batch_id
end

local function wait(controller_handle, id, expected)
    for _ = 1, 1000 do
        local status = skynet.call(controller_handle, "hotupgrade", "status", {batch_id = id})
        assert(status.ok, status.message)
        local record = status.record
        if record.phase == "COMPLETED" or record.phase == "DRY_RUN_COMPLETED"
            or record.phase == "ABORTED" or record.phase == "PARTIAL" or record.phase == "RECOVERY_REQUIRED" then
            assert(record.phase == expected, record.phase .. ":" ..
                tostring(record.error and record.error.message))
            return record
        end
        skynet.sleep(1)
    end
    error("HotUpgrade integration timeout")
end

local function original(handle)
    local value = read(handle)
    assert(value.handle == handle and value.state_identity and value.lua_state_identity and value.module_identity)
    assert(value.equip == "刀" and value.level == 50 and value.schema_version == 1)
    assert(value.attack == 100 and value.module_value == 1 and value.save_identity and not value.paused)
    assert(value.nested_count == 7)
    return value
end

local function lifecycle_status(controller_handle)
    local status = skynet.call(controller_handle, "hotupgrade", "status", {})
    assert(status.ok)
    return status.lifecycle
end

local function lifecycle_blocked(controller_handle)
    for _, command in ipairs({"validate", "dry_run", "apply"}) do
        local rejected = skynet.call(controller_handle, "hotupgrade", command, {path = "module"})
        assert(rejected.code == (command == "validate" and "HU_LIFECYCLE_PENDING" or "HU_BATCH_MISSING") and rejected.batch_id == nil)
    end
    assert(lifecycle_status(controller_handle).active_batch_id == nil)
end

local function creation_lifecycle_tests()
    local controller_handle = create_controller()
    local pending = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker")
    assert(lifecycle_status(controller_handle).pending_creations == 1)
    lifecycle_blocked(controller_handle)
    assert(not skynet.call(pending, "lua", "init", {init_failure = true}).ok)
    local registered = worker(controller_handle)
    local unauthorized = skynet.call(registered, "lua", "cancel_creation",
        {controller_handle = controller_handle, handle = pending})
    assert(unauthorized.code == "HU_UNAUTHORIZED" and lifecycle_status(controller_handle).pending_creations == 1)
    assert(hotupgrade.cancel_service_creation(controller_handle, pending).ok)
    assert(lifecycle_status(controller_handle).pending_creations == 0)
    assert(hotupgrade.cancel_service_creation(controller_handle, registered).code == "HU_SERVICE_ALREADY_REGISTERED")
    pending = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker")
    assert(hotupgrade.cancel_service_creation(controller_handle, pending).ok)

    -- 此 Worker 在 skynet.start 回调中登记，原生 newservice 尚未返回。
    local early = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker", controller_handle, "auto", "original_tail")
    assert(original(early).handle == early and lifecycle_status(controller_handle).pending_creations == 0)
    -- 并发启动使用各自创建标识；一项早登记不能解除另一项的待登记屏障。
    local concurrent_early
    local concurrent_late
    skynet.fork(function()
        concurrent_early = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker",
            controller_handle, "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent_late = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker")
    end)
    for _ = 1, 1000 do
        if concurrent_early and concurrent_late then
            break
        end
        skynet.sleep(1)
    end
    assert(concurrent_early and concurrent_late and concurrent_early ~= concurrent_late)
    assert(lifecycle_status(controller_handle).pending_creations == 1)
    lifecycle_blocked(controller_handle)
    assert(skynet.call(concurrent_late, "lua", "init", {controller_handle = controller_handle}).ok)
    assert(lifecycle_status(controller_handle).pending_creations == 0)
    original(concurrent_early)
    local target_count = skynet.call(controller_handle, "hotupgrade", "validate", {path = "module"}).target_count
    for _, fixture in ipairs({
        {name = "hotupgrade_missing_service"},
        {name = "skynet_hotupgrade_worker", mode = "fail"},
        {name = "skynet_hotupgrade_worker", mode = "fail_after_register"},
    }) do
        local created, message = pcall(hotupgrade.newservice, controller_handle, fixture.name,
            controller_handle, fixture.mode)
        assert(not created and tostring(message):find("HU_SERVICE_CREATE_FAILED", 1, true))
        assert(lifecycle_status(controller_handle).pending_creations == 0)
        assert(skynet.call(controller_handle, "hotupgrade", "validate", {path = "module"}).target_count == target_count)
    end
    print("HOTUPGRADE_SKYNET_CREATION_LIFECYCLE_OK")
end

local function module_lifecycle_tests()
    local controller_handle = create_controller()
    local handle = worker(controller_handle)
    assert(skynet.call(handle, "lua", "declare_failure", {}))
    assert(lifecycle_status(controller_handle).pending_module_loads == 0)
    local loaded = false
    local concurrent_loaded = false
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "declare_slow", {}) == 1)
        loaded = true
    end)
    for _ = 1, 1000 do
        if lifecycle_status(controller_handle).pending_module_loads == 1 then
            break
        end
        skynet.sleep(1)
    end
    assert(lifecycle_status(controller_handle).pending_module_loads == 1)
    lifecycle_blocked(controller_handle)
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "declare", {}) == 1)
        concurrent_loaded = true
    end)
    for _ = 1, 1000 do
        if loaded and concurrent_loaded then
            break
        end
        skynet.sleep(1)
    end
    assert(loaded and concurrent_loaded and lifecycle_status(controller_handle).pending_module_loads == 0)
    assert(skynet.call(controller_handle, "hotupgrade", "validate", {path = "extra"}).target_count == 1)

    -- 活动批次的 Guard 排空窗口中，创建和首次模块执行必须在入口被拒绝。
    controller_handle = create_controller()
    handle = worker(controller_handle)
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "hold", {ticks = 15}).ok)
    end)
    while skynet.call(handle, "lua", "active", {}) == 0 do
        skynet.sleep(1)
    end
    local id = start(controller_handle, "module")
    local queued_handle
    skynet.fork(function()
        queued_handle = hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker")
    end)
    skynet.sleep(1)
    assert(queued_handle == nil)
    assert(skynet.call(handle, "lua", "try_declare", {}))
    local status = lifecycle_status(controller_handle)
    assert(status.pending_creations == 0 and status.pending_module_loads == 0 and status.active_batch_id == id)
    wait(controller_handle, id, "COMPLETED")
    while not queued_handle do skynet.sleep(1) end
    assert(hotupgrade.cancel_service_creation(controller_handle, queued_handle).ok)
    print("HOTUPGRADE_SKYNET_MODULE_LIFECYCLE_OK")
end

local function unique_lifecycle_tests()
    local controller_handle = create_controller()
    for _, global in ipairs({false, true}) do
        local function unique(name, ...)
            if global then
                return hotupgrade.uniqueservice(controller_handle, true, name, ...)
            end
            return hotupgrade.uniqueservice(controller_handle, name, ...)
        end
        local first
        local concurrent
        skynet.fork(function()
            first = unique("skynet_hotupgrade_unique_a", controller_handle, "auto", "original_tail")
        end)
        skynet.fork(function()
            concurrent = unique("skynet_hotupgrade_unique_a", controller_handle, "auto", "original_tail")
        end)
        while not first or not concurrent do skynet.sleep(1) end
        assert(concurrent == first and unique("skynet_hotupgrade_unique_a") == first)
        local second = unique("skynet_hotupgrade_unique_b")
        assert(second ~= first)
        assert(hotupgrade.cancel_service_creation(controller_handle, second).ok)
        local failed = pcall(unique, "skynet_hotupgrade_unique_b", controller_handle, "fail")
        assert(not failed and lifecycle_status(controller_handle).pending_creations == 0)
        second = unique("skynet_hotupgrade_unique_b")
        assert(second ~= first)
        local begun = skynet.call(controller_handle, "hotupgrade", "begin", {})
        assert(begun.ok)
        assert(lifecycle_status(controller_handle).phase == "WAITING_CREATIONS")
        local returned
        local finished = false
        local created
        skynet.fork(function()
            created, returned = pcall(unique, "skynet_hotupgrade_unique_a")
            finished = true
        end)
        skynet.sleep(1)
        assert(not finished)
        assert(skynet.call(second, "lua", "init",
            {controller_handle = controller_handle, after_upgrade_failure = global}).ok)
        while lifecycle_status(controller_handle).phase ~= "DEPLOYING" do skynet.sleep(1) end
        assert(skynet.call(controller_handle, "hotupgrade", "dry_run",
            {batch_id = begun.batch_id, path = "module"}).ok)
        wait(controller_handle, begun.batch_id, global and "PARTIAL" or "DRY_RUN_COMPLETED")
        while not finished do skynet.sleep(1) end
        if global then
            assert(not created and tostring(returned):find("HU_DEPLOYMENT_BLOCKED", 1, true))
        else
            assert(created and returned == first)
        end
    end
    print("HOTUPGRADE_SKYNET_UNIQUE_LIFECYCLE_OK")
end

-- 最后执行：preload 是进程共享配置，本测试进程随后退出，不影响其他夹具。
local function preload_contract_tests()
    local controller_handle = create_controller()
    skynet.setenv("preload", "./third_party/skynet-flywow/hotupgrade/tests/skynet_hotupgrade_preload.lua")
    for _, create in ipairs({
        function() return hotupgrade.newservice(controller_handle, "skynet_hotupgrade_worker") end,
        function() return hotupgrade.uniqueservice(controller_handle, "skynet_hotupgrade_unique_a") end,
        function() return hotupgrade.uniqueservice(controller_handle, true, "skynet_hotupgrade_unique_a") end,
    }) do
        local ok, message = pcall(create)
        assert(not ok and tostring(message):find("HU_PRELOAD_UNSUPPORTED", 1, true))
        assert(lifecycle_status(controller_handle).pending_creations == 0)
    end
    local native = skynet.newservice("skynet_hotupgrade_worker")
    assert(skynet.call(native, "lua", "preload_seen", {}))
    skynet.kill(native)
    print("HOTUPGRADE_SKYNET_PRELOAD_CONTRACT_OK")
end

local function run()
    unique_lifecycle_tests()
    module_lifecycle_tests()
    local controller_handle = create_controller()
    local handle = worker(controller_handle)
    local before = original(handle)
    -- 原 require 名和文件登记名共同指向同一模块；提交与 dry_run 均能通过真实路径匹配。
    assert(before.runtime_alias_identity and before.runtime_value == 1 and before.max_level == 100)
    wait(controller_handle, start(controller_handle, "host_paths", "dry_run"), "DRY_RUN_COMPLETED")
    assert(read(handle).runtime_value == 1 and read(handle).max_level == 100)
    assert(read(handle).package_value == 1 and read(handle).package_alias_identity)
    wait(controller_handle, start(controller_handle, "host_paths"), "COMPLETED")
    assert(read(handle).runtime_value == 2 and read(handle).max_level == 200 and read(handle).runtime_alias_identity)
    assert(read(handle).package_value == 2 and read(handle).package_alias_identity)
    local nested_controller = create_controller()
    local nested_worker = worker(nested_controller, {service_module = "battle.worker"})
    wait(nested_controller, start(nested_controller, "nested_service"), "COMPLETED")
    assert(read(nested_worker).attack == 120)
    local changed_controller = create_controller("actors")
    local changed_worker = worker(changed_controller, {service_module = "zone.player"})
    wait(changed_controller, start(changed_controller, "custom_service"), "COMPLETED")
    assert(read(changed_worker).attack == 120)
    print("HOTUPGRADE_SKYNET_HOST_PATHS_OK")

    -- 整包匹配失败必须在任何目标控制步骤前返回，线上代码、状态和 Guard 均保持原值。
    for _, path in ipairs({"unmatched_module", "unmatched_service"}) do
        for _, command in ipairs({"validate", "dry_run", "apply"}) do
            local rejected = skynet.call(controller_handle, "hotupgrade", command, {path = path})
            assert(not rejected.ok and rejected.code == "HU_TARGET_MISSING")
            assert(rejected.batch_id == nil)
            assert(original(handle).marker_token == before.marker_token)
        end
    end
    print("HOTUPGRADE_SKYNET_PATCH_MATCH_OK")
    assert(skynet.call(handle, "lua", "bump", {}).values[1] == 8)
    local held = false
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "hold", {ticks = 15}).ok)
        held = true
    end)
    while skynet.call(handle, "lua", "active", {}) == 0 do
        skynet.sleep(1)
    end
    local id = start(controller_handle, "combined")
    while not read(handle).paused do
        skynet.sleep(1)
    end
    local rejected = skynet.call(handle, "lua", "hold", {ticks = 1})
    assert(not rejected.ok and rejected.code == "HU_UPGRADING")
    wait(controller_handle, id, "COMPLETED")
    assert(held)
    local after = read(handle)
    assert(after.handle == handle and after.state_identity and after.lua_state_identity and after.module_identity)
    assert(after.marker_token == before.marker_token)
    assert(after.equip == "剑" and after.level == 50 and after.schema_version == 2)
    assert(after.attack == 120 and after.save_identity)
    assert(after.module_value == 2 and after.cached_value == 1 and after.added and after.removed == nil)
    assert(skynet.call(handle, "lua", "bump", {}).values[1] == 9)
    print("HOTUPGRADE_SKYNET_IDENTITY_STATE_GUARD_OK")

    controller_handle = create_controller()
    handle = worker(controller_handle)
    wait(controller_handle, start(controller_handle, "combined", "dry_run"), "DRY_RUN_COMPLETED")
    original(handle)
    print("HOTUPGRADE_SKYNET_DRY_RUN_OK")

    controller_handle = create_controller()
    handle = worker(controller_handle)
    wait(controller_handle, start(controller_handle, "functions"), "COMPLETED")
    assert(read(handle).equip == "刀" and read(handle).attack == 100)
    wait(controller_handle, start(controller_handle, "state_only"), "COMPLETED")
    assert(read(handle).equip == "剑" and read(handle).attack == 120 and read(handle).module_value == 1)
    assert(read(handle).nested_count == nil)
    print("HOTUPGRADE_SKYNET_OPTIONAL_SERVICE_PATCH_OK")

    controller_handle = create_controller()
    handle = worker(controller_handle)
    assert(skynet.call(controller_handle, "hotupgrade", "validate", {path = "extra"}).code == "HU_TARGET_MISSING")
    assert(skynet.call(handle, "lua", "check_declarations", {}))
    assert(skynet.call(handle, "lua", "declare", {}) == 1)
    assert(skynet.call(handle, "lua", "declare", {}) == 1)
    wait(controller_handle, start(controller_handle, "extra"), "COMPLETED")
    assert(read(handle).extra_value == 2)
    assert(skynet.call(handle, "hotupgrade", "activate",
        {batch_id = "foreign", sequence = 999}).code == "HU_UNAUTHORIZED")
    print("HOTUPGRADE_SKYNET_DECLARATION_OK")

    controller_handle = create_controller()
    handle = worker(controller_handle)
    wait(controller_handle, start(controller_handle, "bad_functions"), "ABORTED")
    original(handle)

    controller_handle = create_controller()
    handle = worker(controller_handle)
    wait(controller_handle, start(controller_handle, "stage_failure"), "ABORTED")
    original(handle)
    print("HOTUPGRADE_SKYNET_STAGE_FAILURE_OK")

    for _, worker_config in ipairs({{after_upgrade_failure = true}, {custom = true}}) do
        controller_handle = create_controller()
        handle = worker(controller_handle, worker_config)
        wait(controller_handle, start(controller_handle, "combined"), "ABORTED")
        original(handle)
    end
    controller_handle = create_controller()
    handle = worker(controller_handle, {custom_success = true})
    wait(controller_handle, start(controller_handle, "combined"), "COMPLETED")
    assert(read(handle).attack == 120 and read(handle).nested_identity and read(handle).nested_count == 7)
    controller_handle = create_controller()
    handle = worker(controller_handle, {custom_success = true, after_upgrade_failure = true})
    wait(controller_handle, start(controller_handle, "combined"), "ABORTED")
    original(handle)
    assert(read(handle).nested_identity)
    print("HOTUPGRADE_SKYNET_ACTIVATE_RESTORE_OK")

    controller_handle = create_controller()
    local first = worker(controller_handle)
    local second = worker(controller_handle)
    local record = wait(controller_handle, start(controller_handle, "module"), "COMPLETED")
    assert(record.success == 2 and read(first).module_value == 2 and read(second).module_value == 2)

    controller_handle = create_controller()
    first = worker(controller_handle)
    second = worker(controller_handle, {after_upgrade_failure = true})
    record = wait(controller_handle, start(controller_handle, "combined"), "PARTIAL")
    assert(record.success == 1 and record.failed == 1)
    assert(read(first).equip == "剑" and not read(first).paused)
    original(second)
    assert(lifecycle_status(controller_handle).failed_locked)
    local denied, denial = pcall(hotupgrade.newservice, controller_handle, "skynet_hotupgrade_worker")
    assert(not denied and tostring(denial):find("HU_DEPLOYMENT_BLOCKED", 1, true))
    assert(skynet.call(controller_handle, "hotupgrade", "resolve_deployment",
        {batch_id = record.batch_id, confirmed = true, confirmation = "UNCHANGED"}).code == "HU_RECOVERY_CONFIRMATION_REQUIRED")
    print("HOTUPGRADE_SKYNET_PARTIAL_OK")

    controller_handle = create_controller()
    handle = worker(controller_handle)
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "hold", {ticks = 15}).ok)
    end)
    while skynet.call(handle, "lua", "active", {}) == 0 do
        skynet.sleep(1)
    end
    id = start(controller_handle, "combined")
    assert(skynet.call(controller_handle, "hotupgrade", "abort", {batch_id = id}).ok)
    wait(controller_handle, id, "ABORTED")
    original(handle)
    print("HOTUPGRADE_SKYNET_ABORT_OK")

    for _, worker_config in ipairs({{custom = true, restore_failure = true}, {break_module = true}}) do
        controller_handle = create_controller()
        handle = worker(controller_handle, worker_config)
        wait(controller_handle, start(controller_handle, "combined"), "RECOVERY_REQUIRED")
        assert(read(handle).paused)
        local locked = lifecycle_status(controller_handle)
        assert(skynet.call(controller_handle, "hotupgrade", "resolve_deployment",
            {batch_id = locked.batch_id, confirmed = true, confirmation = "CONVERGED_CACHE_CLEARED"}).code == "HU_RECOVERY_REQUIRED")
        local answer = skynet.call(controller_handle, "hotupgrade", "apply", {path = "module"})
        assert(not answer.ok and answer.code == "HU_DEPLOYMENT_BLOCKED")
    end
    print("HOTUPGRADE_SKYNET_RECOVERY_REQUIRED_OK")
    creation_lifecycle_tests()
    preload_contract_tests()
    print("HOTUPGRADE_SKYNET_ALL_OK")
end

skynet.start(function()
    local ok, message = xpcall(run, debug.traceback)
    if not ok then
        print(message)
        print("HOTUPGRADE_SKYNET_FAILED")
    end
    skynet.abort()
end)
