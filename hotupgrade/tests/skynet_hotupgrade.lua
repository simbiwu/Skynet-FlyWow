--- 真实多 State：handle/状态身份、组合恢复、queue 排空、部分成功与恢复门禁。
local skynet = require "skynet"
require "skynet.manager"
local hotupgrade


local hotupgrade_service_handle
local controller_initialized = false
local function create_controller(service_path)
    local handle = hotupgrade_service_handle
    if controller_initialized then
        assert(service_path == nil, "共享 Controller 不能重复更改配置")
        return handle
    end
    assert(skynet.call(handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    assert(skynet.call(handle, "lua", "init", {}).code == "HU_INVALID_OPTIONS")
    local config = require "hotupgrade_test_options"
    assert(skynet.call(handle, "lua", "init",
        {patch_path = config.patch_path, root_path = config.root_path, service_path = service_path or config.service_path}).ok)
    assert(skynet.call(handle, "lua", "init", {}).code == "HU_ALREADY_INITIALIZED")
    controller_initialized = true
    return handle
end

local function worker(worker_config)
    local handle = hotupgrade.newservice("skynet_hotupgrade_worker")
    worker_config = worker_config or {}
    local registered = skynet.call(handle, "lua", "init", worker_config)
    if not registered.ok then
        assert(hotupgrade.cancel_service_creation(handle).ok)
        error(registered.message)
    end
    return handle
end

local function read(handle)
    return skynet.call(handle, "lua", "read", {})
end

local function start(hotupgrade_service_handle, path, dry_run)
    local answer = skynet.call(hotupgrade_service_handle, "hotupgrade", "begin", {path = path, dry_run = dry_run})
    assert(answer.ok, tostring(answer.code) .. ":" .. tostring(answer.message))
    return answer.batch_id
end

local function wait(hotupgrade_service_handle, id, expected)
    for _ = 1, 1000 do
        local status = skynet.call(hotupgrade_service_handle, "hotupgrade", "status", {batch_id = id})
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

local function lifecycle_status(hotupgrade_service_handle)
    local status = skynet.call(hotupgrade_service_handle, "hotupgrade", "status", {})
    assert(status.ok)
    return status.lifecycle
end

local function lifecycle_blocked(hotupgrade_service_handle)
    for _, command in ipairs({"unknown_command", "validate", "dry_run", "apply"}) do
        local rejected = skynet.call(hotupgrade_service_handle, "hotupgrade", command, {path = "module"})
        local expected = "HU_UNKNOWN_COMMAND"
        assert(rejected.code == expected and rejected.batch_id == nil)
    end
    assert(lifecycle_status(hotupgrade_service_handle).active_batch_id == nil)
end

local function creation_lifecycle_tests()
    local hotupgrade_service_handle = create_controller()
    local pending = hotupgrade.newservice("skynet_hotupgrade_worker")
    assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 1)
    lifecycle_blocked(hotupgrade_service_handle)
    assert(not skynet.call(pending, "lua", "init", {init_failure = true}).ok)
    local registered = worker()
    local unauthorized = skynet.call(registered, "lua", "cancel_creation",
        {handle = pending})
    assert(unauthorized.code == "HU_UNAUTHORIZED" and lifecycle_status(hotupgrade_service_handle).pending_creations == 1)
    assert(hotupgrade.cancel_service_creation(pending).ok)
    assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 0)
    assert(hotupgrade.cancel_service_creation(registered).code == "HU_SERVICE_ALREADY_REGISTERED")
    pending = hotupgrade.newservice("skynet_hotupgrade_worker")
    assert(hotupgrade.cancel_service_creation(pending).ok)

    -- Worker 的独立协程可在原生返回前发出登记，但不阻止 start 回调结束。
    local early = hotupgrade.newservice("skynet_hotupgrade_worker", "auto", "original_tail")
    assert(original(early).handle == early and lifecycle_status(hotupgrade_service_handle).pending_creations == 0)
    -- 并发启动按各自真实 handle 关联；一项登记不能解除另一项的待登记屏障。
    local concurrent_early
    local concurrent_late
    skynet.fork(function()
        concurrent_early = hotupgrade.newservice("skynet_hotupgrade_worker",
            "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent_late = hotupgrade.newservice("skynet_hotupgrade_worker")
    end)
    for _ = 1, 1000 do
        if concurrent_early and concurrent_late then
            break
        end
        skynet.sleep(1)
    end
    assert(concurrent_early and concurrent_late and concurrent_early ~= concurrent_late)
    original(concurrent_early)
    assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 1)
    lifecycle_blocked(hotupgrade_service_handle)
    assert(skynet.call(concurrent_late, "lua", "init", {}).ok)
    assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 0)
    original(concurrent_early)
    local target_count = wait(hotupgrade_service_handle, start(hotupgrade_service_handle, "module", true),
        "DRY_RUN_COMPLETED").target_count
    for _, fixture in ipairs({
        {name = "hotupgrade_missing_service"},
        {name = "skynet_hotupgrade_worker", mode = "fail"},
    }) do
        local created, message = pcall(hotupgrade.newservice, fixture.name,
            fixture.mode)
        assert(not created and tostring(message):find("HU_SERVICE_CREATE_FAILED", 1, true))
        assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 0)
        local measured = wait(hotupgrade_service_handle, start(hotupgrade_service_handle, "module", true),
            "DRY_RUN_COMPLETED")
        assert(measured.target_count == target_count)
    end
    print("HOTUPGRADE_SKYNET_CREATION_LIFECYCLE_OK")
end

local function module_lifecycle_tests()
    local hotupgrade_service_handle = create_controller()
    local handle = worker()
    assert(skynet.call(handle, "lua", "declare_failure", {}))
    assert(lifecycle_status(hotupgrade_service_handle).pending_module_loads == 0)
    local loaded = false
    local concurrent_loaded = false
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "declare_slow", {}) == 1)
        loaded = true
    end)
    for _ = 1, 1000 do
        if lifecycle_status(hotupgrade_service_handle).pending_module_loads == 1 then
            break
        end
        skynet.sleep(1)
    end
    assert(lifecycle_status(hotupgrade_service_handle).pending_module_loads == 1)
    lifecycle_blocked(hotupgrade_service_handle)
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
    assert(loaded and concurrent_loaded and lifecycle_status(hotupgrade_service_handle).pending_module_loads == 0)
    local extra_batch = start(hotupgrade_service_handle, "extra", true)
    assert(wait(hotupgrade_service_handle, extra_batch, "DRY_RUN_COMPLETED").target_count == 1)

    -- 活动批次的 queue 排空窗口中，创建和首次模块执行等待成功终态。
    hotupgrade_service_handle = create_controller()
    handle = worker()
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "hold", {ticks = 15}).ok)
    end)
    while skynet.call(handle, "lua", "holding", {}) == false do
        skynet.sleep(1)
    end
    local id = start(hotupgrade_service_handle, "module")
    local queued_handle
    skynet.fork(function()
        queued_handle = hotupgrade.newservice("skynet_hotupgrade_worker")
    end)
    skynet.sleep(1)
    assert(queued_handle == nil)
    local declared = false
    skynet.fork(function()
        assert(skynet.call(handle, "lua", "declare", {}) == 1)
        declared = true
    end)
    skynet.sleep(1)
    assert(not declared)
    local status = lifecycle_status(hotupgrade_service_handle)
    assert(status.pending_creations == 0 and status.pending_module_loads == 0 and status.active_batch_id == id)
    wait(hotupgrade_service_handle, id, "COMPLETED")
    while not queued_handle or not declared do skynet.sleep(1) end
    assert(hotupgrade.cancel_service_creation(queued_handle).ok)
    print("HOTUPGRADE_SKYNET_MODULE_LIFECYCLE_OK")
end

local function unique_lifecycle_tests()
    local hotupgrade_service_handle = create_controller()
    local global_ok, global_error = pcall(hotupgrade.uniqueservice, true, "skynet_hotupgrade_unique_a")
    assert(not global_ok and tostring(global_error):find("HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED", 1, true))
    local special_ok, special_error = pcall(hotupgrade.uniqueservice, "snaxd", "fixture")
    assert(not special_ok and tostring(special_error):find("HU_SPECIAL_SERVICE_UNSUPPORTED", 1, true))
    assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 0)

    local first
    local concurrent
    skynet.fork(function()
        first = hotupgrade.uniqueservice("skynet_hotupgrade_unique_a",
            "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent = hotupgrade.uniqueservice("skynet_hotupgrade_unique_a",
            "auto", "original_tail")
    end)
    while not first or not concurrent do skynet.sleep(1) end
    assert(concurrent == first and hotupgrade.uniqueservice("skynet_hotupgrade_unique_a") == first)
    local second = hotupgrade.uniqueservice("skynet_hotupgrade_unique_b")
    assert(second ~= first)
    assert(hotupgrade.cancel_service_creation(second).ok)
    for _, mode in ipairs({"fail"}) do
        local ok = pcall(hotupgrade.uniqueservice, "skynet_hotupgrade_unique_b", mode)
        assert(not ok and lifecycle_status(hotupgrade_service_handle).pending_creations == 0)
    end
    second = hotupgrade.uniqueservice("skynet_hotupgrade_unique_b")
    local begun = skynet.call(hotupgrade_service_handle, "hotupgrade", "begin", {path = "module", dry_run = true})
    assert(begun.ok and lifecycle_status(hotupgrade_service_handle).phase == "WAITING_CREATIONS")
    -- 已存在 handle 直接复用，新的逻辑键必须等待发布完成。
    assert(hotupgrade.uniqueservice("skynet_hotupgrade_unique_a") == first)
    local queued
    skynet.fork(function()
        queued = hotupgrade.uniqueservice("skynet_hotupgrade_worker")
    end)
    skynet.sleep(1)
    assert(queued == nil)
    assert(skynet.call(second, "lua", "init", {}).ok)
    assert(skynet.call(hotupgrade_service_handle, "hotupgrade", "unknown_command", {path = "module"}).code == "HU_UNKNOWN_COMMAND")
    wait(hotupgrade_service_handle, begun.batch_id, "DRY_RUN_COMPLETED")
    while not queued do skynet.sleep(1) end
    assert(queued ~= first and queued ~= second)
    assert(hotupgrade.cancel_service_creation(queued).ok)
    print("HOTUPGRADE_SKYNET_UNIQUE_LIFECYCLE_OK")
end

-- 原生 loader 对受管理和普通入口都执行相同 preload，并收到真实业务名及参数。
local function preload_contract_tests()
    local hotupgrade_service_handle = create_controller()
    skynet.setenv("preload", "./third_party/skynet-flywow/hotupgrade/tests/skynet_hotupgrade_preload.lua")
    local handles =
    {
        hotupgrade.newservice("skynet_hotupgrade_worker"),
        hotupgrade.uniqueservice("skynet_hotupgrade_unique_a"),
        skynet.newservice("skynet_hotupgrade_worker"),
    }
    for index, handle in ipairs(handles) do
        assert(skynet.call(handle, "lua", "preload_seen", {}))
        if index < 3 then
            assert(hotupgrade.cancel_service_creation(handle).ok)
        else
            skynet.kill(handle)
        end
    end
    assert(lifecycle_status(hotupgrade_service_handle).pending_creations == 0)
    print("HOTUPGRADE_SKYNET_PRELOAD_CONTRACT_OK")
end

local function run()
    local group = assert(os.getenv("HOTUPGRADE_TEST_GROUP"), "HOTUPGRADE_TEST_GROUP is required")
    local controller = nil
    local handle = nil
    if group == "service_file" then
        controller = create_controller()
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        assert(native.read_file(root, "service/new_service.lua") == false)
        local dry = wait(controller, start(controller, "service_file", true), "DRY_RUN_COMPLETED")
        assert(dry.target_count == 0 and not dry.control_started)
        assert(native.read_file(root, "service/new_service.lua") == false)
        local record = wait(controller, start(controller, "service_file"), "COMPLETED")
        assert(record.target_count == 0 and not record.control_started)
        assert(assert(load(assert(native.read_file(root, "service/new_service.lua"))))().version == 2)
        assert(native.read_file(root, "service/skynet_hotupgrade_worker.patch") == false)
        local only_files = wait(controller, start(controller, "unmatched_module"), "COMPLETED")
        assert(only_files.target_count == 0)
        assert(read(worker()).module_value == 2)
        print("HOTUPGRADE_SKYNET_SERVICE_FILE_OK")
    elseif group == "deployment" then
        controller = create_controller()
        handle = worker()
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        wait(controller, start(controller, "deployment", true), "DRY_RUN_COMPLETED")
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old)
        assert(native.read_file(root, "lualib/new/dependency.lua") == false)
        wait(controller, start(controller, "deployment"), "COMPLETED")
        assert(read(handle).module_value == 2 and read(handle).equip == "剑")
        assert(read(worker()).module_value == 2)
        assert(require("new.dependency").version == 2)
        assert(native.read_file(root, "service/skynet_hotupgrade_worker.patch") == false)
        print("HOTUPGRADE_SKYNET_DEPLOYMENT_OK")
    elseif group == "deploy_failure" then
        controller = create_controller()
        handle = worker()
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        skynet.fork(function() assert(skynet.call(handle, "lua", "hold", {ticks = 20}).ok) end)
        while skynet.call(handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = start(controller, "deploy_failure")
        while not read(handle).paused do skynet.sleep(1) end
        -- begin 的异步发布已冻结源码并准备旧文件；在 queue 排空窗口注入目标路径失效。
        assert(os.execute("mkdir " .. root .. "/service/z_blocked.lua"))
        local record = wait(controller, id, "ABORTED")
        assert(record.error.code == "HU_INVALID_PATH" and record.control_started
            and record.target_count == 1 and record.failed == 1 and lifecycle_status(controller).phase == "IDLE")
        original(handle)
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old)
        assert(native.read_file(root, "lualib/a_added.lua") == false)
        assert(os.execute("rmdir " .. root .. "/service/z_blocked.lua"))
        print("HOTUPGRADE_SKYNET_DEPLOY_FAILURE_OK")
    elseif group == "lifecycle" then
        creation_lifecycle_tests()
        module_lifecycle_tests()
        unique_lifecycle_tests()
    elseif group == "preload" then
        preload_contract_tests()
    elseif group == "host_paths" then
        controller = create_controller()
        handle = worker()
        local before = original(handle)
        assert(before.runtime_alias_identity and before.runtime_value == 1 and before.max_level == 100)
        wait(controller, start(controller, "host_paths", true), "DRY_RUN_COMPLETED")
        assert(read(handle).runtime_value == 1 and read(handle).max_level == 100)
        assert(read(handle).package_value == 1 and read(handle).package_alias_identity)
        wait(controller, start(controller, "host_paths"), "COMPLETED")
        assert(read(handle).runtime_value == 2 and read(handle).max_level == 200 and read(handle).runtime_alias_identity)
        assert(read(handle).package_value == 2 and read(handle).package_alias_identity)
        local nested_worker = worker()
        wait(controller, start(controller, "nested_service"), "COMPLETED")
        assert(read(nested_worker).attack == 120)
        print("HOTUPGRADE_SKYNET_HOST_PATHS_OK")
    elseif group == "custom_paths" then
        controller = create_controller("actors")
        handle = worker()
        wait(controller, start(controller, "custom_service"), "COMPLETED")
        assert(read(handle).attack == 120)
        print("HOTUPGRADE_SKYNET_CUSTOM_PATHS_OK")
    elseif group == "patch_match" then
        controller = create_controller()
        handle = worker()
        local before = original(handle)
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old_source = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        local fixtures = {
            {path = "../module", code = "HU_INVALID_PATH"},
            {path = "invalid", code = "HU_MODULE_SYNTAX"},
            {path = "invalid_patch", code = "HU_INVALID_PATCH"},
            {path = "invalid_service", code = "HU_MODULE_SYNTAX"},
            {path = "unmatched_service", code = "HU_TARGET_MISSING"},
        }
        for _, fixture in ipairs(fixtures) do
            for _, dry_run in ipairs({true, false}) do
                local id = start(controller, fixture.path, dry_run)
                local record = wait(controller, id, "ABORTED")
                local rejected = record.error
                assert(rejected.code == fixture.code and rejected.message and #rejected.message > 0)
                local status = skynet.call(controller, "hotupgrade", "status", {batch_id = id})
                assert(status.ok and status.record.phase == "ABORTED")
                assert(status.record.error.code == fixture.code and not status.record.control_started)
                assert(original(handle).marker_token == before.marker_token)
                assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)
                assert(status.lifecycle.phase == "IDLE")
            end
        end
        assert(skynet.call(controller, "hotupgrade", "unknown_command", {path = "module"}).code == "HU_UNKNOWN_COMMAND")
        print("HOTUPGRADE_SKYNET_PATCH_MATCH_OK")
    elseif group == "identity_queue" then
        controller = create_controller()
        handle = worker()
        local before = original(handle)
        assert(skynet.call(handle, "lua", "bump", {}).value == 8)
        local held = false
        skynet.fork(function()
            assert(skynet.call(handle, "lua", "hold", {ticks = 15}).ok)
            held = true
        end)
        while skynet.call(handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = start(controller, "combined")
        while not read(handle).paused do skynet.sleep(1) end
        local rejected = skynet.call(handle, "lua", "hold", {ticks = 1})
        assert(not rejected.ok and rejected.code == "HU_UPGRADING")
        wait(controller, id, "COMPLETED")
        assert(held)
        local after = read(handle)
        assert(after.handle == handle and after.state_identity and after.lua_state_identity and after.module_identity)
        assert(after.marker_token == before.marker_token)
        assert(after.equip == "剑" and after.level == 50 and after.schema_version == 2)
        assert(after.attack == 120 and after.save_identity)
        assert(after.module_value == 2 and after.cached_value == 1 and after.added and after.removed == nil)
        assert(skynet.call(handle, "lua", "bump", {}).value == 9)
        print("HOTUPGRADE_SKYNET_IDENTITY_STATE_QUEUE_OK")
    elseif group == "prepare_missing" or group == "prepare_false" or group == "prepare_error" then
        controller = create_controller()
        local config = {}
        config[group == "prepare_missing" and "before_missing"
            or (group == "prepare_false" and "before_false" or "before_error")] = true
        handle = worker(config)
        local record = wait(controller, start(controller, "combined"), "ABORTED")
        assert(record.error.code == (group == "prepare_error" and "HU_PREPARE_FAILED" or "HU_SAFEPOINT_REQUIRED"))
        original(handle)
    elseif group == "dry_run" then
        controller = create_controller()
        handle = worker()
        wait(controller, start(controller, "combined", true), "DRY_RUN_COMPLETED")
        original(handle)
        print("HOTUPGRADE_SKYNET_DRY_RUN_OK")
    elseif group == "optional_service" then
        controller = create_controller()
        handle = worker()
        wait(controller, start(controller, "functions"), "COMPLETED")
        assert(read(handle).equip == "刀" and read(handle).attack == 100)
        wait(controller, start(controller, "state_only"), "COMPLETED")
        assert(read(handle).equip == "剑" and read(handle).attack == 120 and read(handle).module_value == 1)
        assert(read(handle).nested_count == nil)
        print("HOTUPGRADE_SKYNET_OPTIONAL_SERVICE_PATCH_OK")
    elseif group == "declaration" then
        controller = create_controller()
        handle = worker()
        assert(skynet.call(controller, "hotupgrade", "unknown_command", {path = "extra"}).code == "HU_UNKNOWN_COMMAND")
        assert(skynet.call(handle, "lua", "check_declarations", {}))
        assert(skynet.call(handle, "lua", "declare", {}) == 1)
        assert(skynet.call(handle, "lua", "declare", {}) == 1)
        wait(controller, start(controller, "extra"), "COMPLETED")
        assert(read(handle).extra_value == 2)
        assert(skynet.call(handle, "hotupgrade", "update",
            {batch_id = "foreign", sequence = 999}).code == "HU_UNAUTHORIZED")
        print("HOTUPGRADE_SKYNET_DECLARATION_OK")
    elseif group == "bad_functions" or group == "stage_failure" then
        controller = create_controller()
        handle = worker()
        local patch_path = group == "bad_functions" and "bad_functions" or "stage_failure"
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old_source = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        wait(controller, start(controller, patch_path), "ABORTED")
        original(handle)
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)
        print(group == "bad_functions" and "HOTUPGRADE_SKYNET_BAD_FUNCTIONS_OK" or "HOTUPGRADE_SKYNET_STAGE_FAILURE_OK")
    elseif group == "activation_after_failure" or group == "activation_custom_failure"
        or group == "activation_custom_success" or group == "activation_custom_success_failure" then
        controller = create_controller()
        local config
        local expected = "ABORTED"
        if group == "activation_after_failure" then
            config = {after_upgrade_failure = true}
        elseif group == "activation_custom_failure" then
            config = {custom = true}
        elseif group == "activation_custom_success" then
            config = {custom_success = true}
            expected = "COMPLETED"
        else
            config = {custom_success = true, after_upgrade_failure = true}
        end
        handle = worker(config)
        wait(controller, start(controller, "combined"), expected)
        if group == "activation_custom_success" then
            assert(read(handle).attack == 120 and read(handle).nested_identity and read(handle).nested_count == 7)
        else
            original(handle)
            if group == "activation_custom_success_failure" then assert(read(handle).nested_identity) end
        end
        print("HOTUPGRADE_SKYNET_ACTIVATE_RESTORE_OK " .. group)
    elseif group == "multiple_targets" then
        controller = create_controller()
        local first = worker()
        local second = worker()
        local record = wait(controller, start(controller, "module"), "COMPLETED")
        assert(record.success == 2 and read(first).module_value == 2 and read(second).module_value == 2)
        print("HOTUPGRADE_SKYNET_MULTIPLE_TARGETS_OK")
    elseif group == "partial" then
        controller = create_controller()
        local first = worker()
        local second = worker({after_upgrade_failure = true})
        local record = wait(controller, start(controller, "combined"), "ABORTED")
        assert(record.success == 0 and record.failed == 2)
        original(first)
        original(second)
        assert(lifecycle_status(controller).phase == "IDLE")
        local new_handle = hotupgrade.newservice("skynet_hotupgrade_worker")
        assert(hotupgrade.cancel_service_creation(new_handle).ok)
        print("HOTUPGRADE_SKYNET_PARTIAL_OK")
    elseif group == "abort" then
        controller = create_controller()
        handle = worker()
        skynet.fork(function() assert(skynet.call(handle, "lua", "hold", {ticks = 15}).ok) end)
        while skynet.call(handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = start(controller, "combined")
        while not read(handle).paused do skynet.sleep(1) end
        assert(skynet.call(controller, "hotupgrade", "abort", {batch_id = id}).ok)
        wait(controller, id, "ABORTED")
        original(handle)
        print("HOTUPGRADE_SKYNET_ABORT_OK")
    elseif group == "recovery_restore" or group == "recovery_module" then
        controller = create_controller()
        local config = group == "recovery_restore" and {custom = true, restore_failure = true} or {break_module = true}
        handle = worker(config)
        wait(controller, start(controller, "combined"), "RECOVERY_REQUIRED")
        assert(read(handle).paused)
        local locked = lifecycle_status(controller)
        assert(skynet.call(controller, "hotupgrade", "resolve_deployment",
            {batch_id = locked.batch_id, confirmed = true, confirmation = "UNCHANGED"}).code == "HU_RECOVERY_CONFIRMATION_REQUIRED")
        local answer = skynet.call(controller, "hotupgrade", "begin", {path = "module"})
        assert(not answer.ok and answer.code == "HU_DEPLOYMENT_BLOCKED")
        print("HOTUPGRADE_SKYNET_RECOVERY_REQUIRED_OK")
    else
        error("unknown HOTUPGRADE_TEST_GROUP: " .. tostring(group))
    end
    print("HOTUPGRADE_SKYNET_GROUP_OK " .. group)
end

skynet.start(function()
    hotupgrade_service_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    hotupgrade = require "flywow_hotupgrade"
    require "test_files"
    local ok, message = xpcall(run, debug.traceback)
    if not ok then
        print(message)
        print("HOTUPGRADE_SKYNET_FAILED")
    end
    skynet.abort()
end)
