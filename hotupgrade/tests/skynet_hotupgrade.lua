--- 真实多 State：handle/状态身份、组合恢复、Guard 排空、部分成功与恢复门禁。
local skynet = require "skynet"
require "skynet.manager"
require "flywow_hotupgrade"
require "test_files"

local function create_controller()
    local handle = skynet.newservice("flywow_hotupgrade_service")
    assert(skynet.call(handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    assert(skynet.call(handle, "lua", "init", require "hotupgrade_test_options").ok)
    assert(skynet.call(handle, "lua", "init", {}).code == "HU_ALREADY_INITIALIZED")
    return handle
end

local function worker(controller_handle, worker_config)
    local handle = skynet.newservice("skynet_hotupgrade_worker")
    worker_config = worker_config or {}
    worker_config.controller_handle = controller_handle
    local registered = skynet.call(handle, "lua", "init", worker_config)
    assert(registered.ok, registered.message)
    return handle
end

local function read(handle)
    return skynet.call(handle, "lua", "read", {})
end

local function start(controller_handle, path, command)
    local answer = skynet.call(controller_handle, "hotupgrade", command or "apply", {path = path})
    assert(answer.ok, tostring(answer.code) .. ":" .. tostring(answer.message))
    return answer.txn_id
end

local function wait(controller_handle, id, expected)
    for _ = 1, 1000 do
        local status = skynet.call(controller_handle, "hotupgrade", "status", {txn_id = id})
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

local function run()
    local controller_handle = create_controller()
    local handle = worker(controller_handle)
    local before = original(handle)
    -- 整包匹配失败必须在任何目标控制步骤前返回，线上代码、状态和 Guard 均保持原值。
    for _, path in ipairs({"unmatched_module", "unmatched_service"}) do
        for _, command in ipairs({"validate", "dry_run", "apply"}) do
            local rejected = skynet.call(controller_handle, "hotupgrade", command, {path = path})
            assert(not rejected.ok and rejected.code == "HU_TARGET_MISSING")
            assert(rejected.txn_id == nil)
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
    assert(skynet.call(handle, "lua", "declare", {}) == 1)
    assert(skynet.call(handle, "lua", "declare", {}) == 1)
    wait(controller_handle, start(controller_handle, "extra"), "COMPLETED")
    assert(read(handle).extra_value == 2)
    assert(skynet.call(handle, "hotupgrade", "activate",
        {txn_id = "foreign", sequence = 999}).code == "HU_UNAUTHORIZED")
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
    assert(skynet.call(controller_handle, "hotupgrade", "abort", {txn_id = id}).ok)
    wait(controller_handle, id, "ABORTED")
    original(handle)
    print("HOTUPGRADE_SKYNET_ABORT_OK")

    for _, worker_config in ipairs({{custom = true, restore_failure = true}, {break_module = true}}) do
        controller_handle = create_controller()
        handle = worker(controller_handle, worker_config)
        wait(controller_handle, start(controller_handle, "combined"), "RECOVERY_REQUIRED")
        assert(read(handle).paused)
        local answer = skynet.call(controller_handle, "hotupgrade", "apply", {path = "module"})
        assert(not answer.ok and answer.code == "HU_RECOVERY_REQUIRED")
    end
    print("HOTUPGRADE_SKYNET_RECOVERY_REQUIRED_OK")
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
