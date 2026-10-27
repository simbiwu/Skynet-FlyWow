--- 真实多 State：Service handle/状态身份、组合恢复、queue 排空、部分成功与恢复门禁。
local skynet = require "skynet"
require "skynet.manager"

local module_state =
{
    hotupgrade_api            = nil,    -- 当前测试进程的 HotUpgrade Lua API；Skynet 启动时加载。
    hotupgrade_handle = nil,    -- 唯一 HotUpgrade Service handle；所有测试场景共用该实例。
    controller_initialized   = false,  -- 首次成功初始化后锁定配置，后续场景复用同一 Controller。
}

local function create_controller(service_path)
    local hotupgrade_handle = module_state.hotupgrade_handle
    if module_state.controller_initialized then
        assert(service_path == nil, "共享 Controller 不能重复更改配置")
        return hotupgrade_handle
    end
    assert(skynet.call(hotupgrade_handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    assert(skynet.call(hotupgrade_handle, "lua", "init", {}).code == "HU_INVALID_OPTIONS")
    local hotupgrade_config = require "hotupgrade_test_options"
    assert(skynet.call(hotupgrade_handle, "lua", "init",
        {patch_path = hotupgrade_config.patch_path, root_path = hotupgrade_config.root_path,
            service_path = service_path or hotupgrade_config.service_path}).ok)
    assert(skynet.call(hotupgrade_handle, "lua", "init", {}).code == "HU_ALREADY_INITIALIZED")
    module_state.controller_initialized = true
    return hotupgrade_handle
end

local function create_worker_service(worker_config)
    local worker_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    worker_config = worker_config or {}
    local registration_result = skynet.call(worker_handle, "lua", "init", worker_config)
    if not registration_result.ok then
        assert(module_state.hotupgrade_api.cancel_service_creation(worker_handle).ok)
        error(registration_result.message)
    end
    return worker_handle
end

local function read_worker_state(worker_handle)
    return skynet.call(worker_handle, "lua", "read", {})
end

local function begin_update_batch(hotupgrade_handle, selected_patch_path)
    local begin_result = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = selected_patch_path})
    assert(begin_result.ok, tostring(begin_result.code) .. ":" .. tostring(begin_result.message))
    return begin_result.batch_id
end

local function wait_for_batch_phase(hotupgrade_handle, batch_id, expected_phase)
    for _ = 1, 1000 do
        local batch_status = skynet.call(hotupgrade_handle, "hotupgrade", "status", {batch_id = batch_id})
        assert(batch_status.ok, batch_status.message)
        local batch_record = batch_status.record
        if batch_record.phase == "COMPLETED"
            or batch_record.phase == "ABORTED" or batch_record.phase == "PARTIAL" or batch_record.phase == "RECOVERY_REQUIRED" then
            assert(batch_record.phase == expected_phase or (type(expected_phase) == "table" and expected_phase[batch_record.phase]), batch_record.phase .. ":" ..
                tostring(batch_record.error and batch_record.error.message))
            return batch_record
        end
        skynet.sleep(1)
    end
    error("HotUpgrade integration timeout")
end

local function assert_original_state(worker_handle)
    local worker_state = read_worker_state(worker_handle)
    assert(worker_state.service_handle == worker_handle and worker_state.state_identity and worker_state.lua_state_identity and worker_state.module_identity)
    assert(worker_state.equip == "刀" and worker_state.level == 50 and worker_state.schema_version == 1)
    assert(worker_state.attack == 100 and worker_state.module_value == 1 and worker_state.save_identity and not worker_state.paused)
    assert(worker_state.nested_count == 7)
    return worker_state
end

local function lifecycle_status(hotupgrade_handle)
    local controller_status = skynet.call(hotupgrade_handle, "hotupgrade", "status", {})
    assert(controller_status.ok)
    return controller_status.lifecycle
end

local function lifecycle_blocked(hotupgrade_handle)
    for _, command in ipairs({"unknown_command", "validate", "apply"}) do
        local rejected = skynet.call(hotupgrade_handle, "hotupgrade", command, {path = "module"})
        local expected_code = "HU_UNKNOWN_COMMAND"
        assert(rejected.code == expected_code and rejected.batch_id == nil)
    end
    assert(lifecycle_status(hotupgrade_handle).active_batch_id == nil)
end

local function creation_lifecycle_tests()
    local hotupgrade_handle = create_controller()
    -- 原生 kill 不经包装，退出通知必须释放尚未登记的创建记录。
    local killed = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 1)
    skynet.kill(killed)
    for _ = 1, 1000 do
        if lifecycle_status(hotupgrade_handle).pending_creations == 0 then
            break
        end
        skynet.sleep(1)
    end
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 0)
    local pending = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 1)
    lifecycle_blocked(hotupgrade_handle)
    assert(not skynet.call(pending, "lua", "init", {init_failure = true}).ok)
    local registered = create_worker_service()
    local unauthorized = skynet.call(registered, "lua", "cancel_creation",
        {service_handle = pending})
    assert(unauthorized.code == "HU_UNAUTHORIZED" and lifecycle_status(hotupgrade_handle).pending_creations == 1)
    assert(module_state.hotupgrade_api.cancel_service_creation(pending).ok)
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 0)
    assert(module_state.hotupgrade_api.cancel_service_creation(registered).code == "HU_SERVICE_ALREADY_REGISTERED")
    pending = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(module_state.hotupgrade_api.cancel_service_creation(pending).ok)

    -- Worker 的独立协程可在原生返回前发出登记，但不阻止 start 回调结束。
    local early = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker", "auto", "original_tail")
    assert(assert_original_state(early).service_handle == early and lifecycle_status(hotupgrade_handle).pending_creations == 0)
    -- 并发启动按各自真实 Service handle 关联；一项登记不能解除另一项的待登记屏障。
    local concurrent_early
    local concurrent_late
    skynet.fork(function()
        concurrent_early = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker",
            "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent_late = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    end)
    for _ = 1, 1000 do
        if concurrent_early and concurrent_late then
            break
        end
        skynet.sleep(1)
    end
    assert(concurrent_early and concurrent_late and concurrent_early ~= concurrent_late)
    assert_original_state(concurrent_early)
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 1)
    lifecycle_blocked(hotupgrade_handle)
    assert(skynet.call(concurrent_late, "lua", "init", {}).ok)
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 0)
    assert_original_state(concurrent_early)
    local rejected = wait_for_batch_phase(hotupgrade_handle, begin_update_batch(hotupgrade_handle, "unmatched_service"), "ABORTED")
    assert(rejected.error.code == "HU_TARGET_MISSING")
    local idle = lifecycle_status(hotupgrade_handle)
    assert(idle.pending_creations == 0 and idle.phase == "IDLE")
    for _, fixture in ipairs({
        {name = "hotupgrade_missing_service"},
        {name = "skynet_hotupgrade_worker", mode = "fail"},
    }) do
        local created, message = pcall(module_state.hotupgrade_api.newservice, fixture.name,
            fixture.mode)
        assert(not created and tostring(message):find("HU_SERVICE_CREATE_FAILED", 1, true))
        assert(lifecycle_status(hotupgrade_handle).pending_creations == 0)
        local rejected = wait_for_batch_phase(hotupgrade_handle, begin_update_batch(hotupgrade_handle, "unmatched_service"), "ABORTED")
        assert(rejected.error.code == "HU_TARGET_MISSING")
        local idle = lifecycle_status(hotupgrade_handle)
        assert(idle.pending_creations == 0 and idle.phase == "IDLE")
    end
    print("HOTUPGRADE_SKYNET_CREATION_LIFECYCLE_OK")
end

local function module_lifecycle_tests()
    local hotupgrade_handle = create_controller()
    local worker_service_handle = create_worker_service()
    assert(skynet.call(worker_service_handle, "lua", "declare_failure", {}))
    assert(lifecycle_status(hotupgrade_handle).pending_loads == 0)
    local loaded = false
    local concurrent_loaded = false
    skynet.fork(function()
        assert(skynet.call(worker_service_handle, "lua", "declare_slow", {}) == 1)
        loaded = true
    end)
    for _ = 1, 1000 do
        if lifecycle_status(hotupgrade_handle).pending_loads == 1 then
            break
        end
        skynet.sleep(1)
    end
    assert(lifecycle_status(hotupgrade_handle).pending_loads == 1)
    lifecycle_blocked(hotupgrade_handle)
    skynet.fork(function()
        assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 1)
        concurrent_loaded = true
    end)
    for _ = 1, 1000 do
        if loaded and concurrent_loaded then
            break
        end
        skynet.sleep(1)
    end
    assert(loaded and concurrent_loaded and lifecycle_status(hotupgrade_handle).pending_loads == 0)
    local extra_batch = begin_update_batch(hotupgrade_handle, "extra")
    assert(wait_for_batch_phase(hotupgrade_handle, extra_batch, "COMPLETED").target_service_count == 1)
    assert(read_worker_state(worker_service_handle).extra_value == 2)

    -- queue 排空期间仍接纳创建和首次声明，新目标使用旧文件并参与当前批次。
    hotupgrade_handle = create_controller()
    worker_service_handle = create_worker_service()
    skynet.fork(function()
        assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 100}).ok)
    end)
    while skynet.call(worker_service_handle, "lua", "holding", {}) == false do
        skynet.sleep(1)
    end
    local id = begin_update_batch(hotupgrade_handle, "module")
    local admitted_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(skynet.call(admitted_handle, "lua", "init", {}).ok)
    assert(read_worker_state(admitted_handle).module_value == 1)
    assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 2)
    local status = lifecycle_status(hotupgrade_handle)
    assert(status.pending_creations == 0 and status.pending_loads == 0 and status.active_batch_id == id)
    wait_for_batch_phase(hotupgrade_handle, id, "COMPLETED")
    assert(read_worker_state(admitted_handle).module_value == 2)
    assert(module_state.hotupgrade_api.cancel_service_creation(admitted_handle).code == "HU_SERVICE_ALREADY_REGISTERED")
    print("HOTUPGRADE_SKYNET_MODULE_LIFECYCLE_OK")
end

local function unique_lifecycle_tests()
    local hotupgrade_handle = create_controller()
    local global_ok, global_error = pcall(module_state.hotupgrade_api.uniqueservice, true, "skynet_hotupgrade_unique_a")
    assert(not global_ok and tostring(global_error):find("HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED", 1, true))
    local special_ok, special_error = pcall(module_state.hotupgrade_api.uniqueservice, "snaxd", "fixture")
    assert(not special_ok and tostring(special_error):find("HU_SPECIAL_SERVICE_UNSUPPORTED", 1, true))
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 0)

    local first
    local concurrent
    skynet.fork(function()
        first = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a",
            "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a",
            "auto", "original_tail")
    end)
    while not first or not concurrent do skynet.sleep(1) end
    assert(concurrent == first and module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a") == first)
    local second = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_b")
    assert(second ~= first)
    assert(module_state.hotupgrade_api.cancel_service_creation(second).ok)
    for _, mode in ipairs({"fail"}) do
        local ok = pcall(module_state.hotupgrade_api.uniqueservice, "skynet_hotupgrade_unique_b", mode)
        assert(not ok and lifecycle_status(hotupgrade_handle).pending_creations == 0)
    end
    second = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_b")
    local begun = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = "module"})
    assert(begun.ok and lifecycle_status(hotupgrade_handle).phase == "WAITING_CREATIONS")
    -- 排空期间既有唯一名直接复用，新唯一名也可完成创建和登记，并进入本批。
    assert(module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a") == first)
    local admitted = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_worker")
    assert(admitted ~= first and admitted ~= second)
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 2)
    assert(skynet.call(admitted, "lua", "init", {}).ok)
    assert(skynet.call(second, "lua", "init", {}).ok)
    assert(skynet.call(hotupgrade_handle, "hotupgrade", "unknown_command", {path = "module"}).code == "HU_UNKNOWN_COMMAND")
    wait_for_batch_phase(hotupgrade_handle, begun.batch_id, "COMPLETED")
    assert(read_worker_state(admitted).module_value == 2 and read_worker_state(second).module_value == 2)
    assert(module_state.hotupgrade_api.cancel_service_creation(admitted).code == "HU_SERVICE_ALREADY_REGISTERED")
    skynet.kill(first)
    local replacement = first
    for _ = 1, 1000 do
        skynet.sleep(1)
        replacement = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a", "auto", "original_tail")
        if replacement ~= first then break end
    end
    assert(replacement ~= first)
    assert(read_worker_state(replacement).module_value == 2)
    assert(module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a") == replacement)
    print("HOTUPGRADE_SKYNET_UNIQUE_LIFECYCLE_OK")
end

-- 原生 loader 对受管理和普通入口都执行相同 preload，并收到真实业务名及参数。
local function preload_contract_tests()
    local hotupgrade_handle = create_controller()
    skynet.setenv("preload", "./third_party/skynet-flywow/hotupgrade/tests/skynet_hotupgrade_preload.lua")
    local handles =
    {
        module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker"),
        module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a"),
        skynet.newservice("skynet_hotupgrade_worker"),
    }
    for index, worker_service_handle in ipairs(handles) do
        assert(skynet.call(worker_service_handle, "lua", "preload_seen", {}))
        if index < 3 then
            assert(module_state.hotupgrade_api.cancel_service_creation(worker_service_handle).ok)
        else
            skynet.kill(worker_service_handle)
        end
    end
    assert(lifecycle_status(hotupgrade_handle).pending_creations == 0)
    print("HOTUPGRADE_SKYNET_PRELOAD_CONTRACT_OK")
end

-- 显式 release 形成稳定的正常业务依赖，不依赖 sleep 碰撞 Prepare 时序。
local function drain_lifecycle_tests(group)
    local controller = create_controller()
    local hotupgrade = module_state.hotupgrade_api
    local function inspect(service_handle)
        return skynet.call(service_handle, "lua", "inspect", {})
    end
    local function wait_field(service_handle, field, value)
        for _ = 1, 1000 do
            if inspect(service_handle)[field] == value then return end
            skynet.sleep(1)
        end
        error("排空测试等待超时: " .. field)
    end

    local parent = hotupgrade.newservice("skynet_hotupgrade_drain")
    local completed_operation
    local peer
    if group == "drain_creation" then
        skynet.fork(function()
            completed_operation = skynet.call(parent, "lua", "init", {wait_init = true, init_depth = 2})
        end)
        wait_field(parent, "waiting", "init")
    else
        local config = group == "drain_queue" and {prepare_depth = 1}
            or group == "drain_new_failure" and {prepare_depth = 1, child_fail_before = true}
            or group == "drain_update_failure" and {prepare_depth = 1, child_fail_after = true} or {}
        assert(skynet.call(parent, "lua", "init", config).ok)
        if group == "drain_queue" or group == "drain_modules" then
            local command = group == "drain_queue" and "work" or "nested_load"
            skynet.fork(function()
                completed_operation = skynet.call(parent, "lua", command, {unique = true})
            end)
            wait_field(parent, "waiting", group == "drain_queue" and "queue" or "module")
        elseif group == "drain_late_module" then
            peer = hotupgrade.newservice("skynet_hotupgrade_drain")
            assert(skynet.call(peer, "lua", "init", {}).ok)
            skynet.fork(function()
                completed_operation = skynet.call(peer, "lua", "hold", {})
            end)
            wait_field(peer, "waiting", "queue")
        end
    end

    local id = begin_update_batch(controller, "drain_service")
    if group == "drain_creation" or group == "drain_modules" then
        assert(lifecycle_status(controller).phase == "WAITING_CREATIONS")
        assert(skynet.call(parent, "lua", "release", {}))
    elseif group == "drain_queue" then
        wait_field(parent, "paused", true)
        assert(skynet.call(parent, "lua", "release", {}))
    elseif group == "drain_late_module" then
        wait_field(peer, "paused", true)
        assert(inspect(parent).before_count == 1 and inspect(parent).paused)
        assert(skynet.call(parent, "lua", "declare", {}) == 1)
        assert(skynet.call(peer, "lua", "release", {}))
    end

    local failed = group == "drain_new_failure" or group == "drain_update_failure"
    local record = wait_for_batch_phase(controller, id, failed and "ABORTED" or "COMPLETED")
    local visited = {}
    local function check_tree(service_handle)
        assert(not visited[service_handle])
        visited[service_handle] = true
        local state = inspect(service_handle)
        assert(state.born_value == 1 and state.before_count == 1 and not state.paused)
        assert(state.value == (failed and 1 or 2))
        assert(state.equip == (failed and "刀" or "剑") and state.schema_version == (failed and 1 or 2))
        assert(state.attack == (failed and 100 or 120))
        for _, child in ipairs(state.children) do check_tree(child) end
    end
    check_tree(parent)
    if peer then check_tree(peer) end
    local target_count = 0
    for _ in pairs(visited) do target_count = target_count + 1 end
    assert(record.target_service_count == target_count)
    assert(record.succeeded_service_count == (failed and 0 or target_count))
    assert(record.failed_service_count == (failed and target_count or 0))
    local expected_targets = group == "drain_queue" and 4 or group == "drain_creation" and 3
        or group == "drain_modules" and 1 or 2
    assert(target_count == expected_targets)
    if group == "drain_creation" then
        assert(completed_operation and completed_operation.ok)
    elseif group == "drain_queue" then
        assert(completed_operation.value == 1 and completed_operation.extra == 1)
        assert(inspect(parent).extra == 2)
    elseif group == "drain_modules" then
        assert(completed_operation.extra == 1 and completed_operation.dependency == 1)
        assert(inspect(parent).extra == 2 and inspect(parent).dependency == 2)
    elseif group == "drain_late_module" then
        assert(completed_operation.value == 1 and inspect(parent).extra == 2)
    end
    local lifecycle = lifecycle_status(controller)
    assert(lifecycle.pending_creations == 0 and lifecycle.pending_loads == 0)
    print("HOTUPGRADE_SKYNET_DRAIN_OK " .. group)
end

local function run_test_group()
    local group = assert(os.getenv("HOTUPGRADE_TEST_GROUP"), "HOTUPGRADE_TEST_GROUP is required")
    local controller = nil
    local worker_service_handle = nil
    if group == "monitor_occupied" then
        local core = require "skynet.core"
        core.command("MONITOR", skynet.address(skynet.self()))
        local before = core.command("MONITOR")
        local config = require "hotupgrade_test_options"
        local rejected = skynet.call(module_state.hotupgrade_handle, "lua", "init",
            {patch_path = config.patch_path, root_path = config.root_path, service_path = config.service_path})
        assert(rejected.code == "HU_MONITOR_OCCUPIED")
        assert(core.command("MONITOR") == before)
        assert(skynet.call(module_state.hotupgrade_handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    elseif group == "source_headers" then
        controller = create_controller()
        local worker = create_worker_service()
        local native = require "flywow_hotupgrade_native"
        local config = require "hotupgrade_test_options"
        for index = 1, 4 do
            local path = "source_headers_" .. index
            local record = wait_for_batch_phase(controller, begin_update_batch(controller, path), "COMPLETED")
            assert(record.target_service_count == 1)
            local state = read_worker_state(worker)
            assert(state.module_value == 2 and state.level == 51 and not state.paused)
            for _, file in ipairs({"lualib/test_worker_logic.lua", "config/headers.lua"}) do
                assert(native.read_file(config.root_path, file) == native.read_file(config.patch_path, path .. "/" .. file))
            end
            assert(native.read_file(config.root_path, "service/skynet_hotupgrade_worker.patch") == false)
        end
        assert(read_worker_state(create_worker_service()).module_value == 2)
    elseif group == "exit_module_load" then
        controller = create_controller()
        local worker = create_worker_service()
        skynet.fork(function()
            -- kill 不承诺替正在执行的业务 RPC 返回结果；这里只验证 Controller 自有许可。
            pcall(skynet.call, worker, "lua", "declare_slow", {})
        end)
        for _ = 1, 1000 do
            if lifecycle_status(controller).pending_loads == 1 then break end
            skynet.sleep(1)
        end
        assert(lifecycle_status(controller).pending_loads == 1)
        skynet.kill(worker)
        for _ = 1, 1000 do
            if lifecycle_status(controller).pending_loads == 0 then break end
            skynet.sleep(1)
        end
        assert(lifecycle_status(controller).pending_loads == 0)
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED")
        assert(record.target_service_count == 0)
    elseif group:match("^exit_") or group:match("^kill_") then
        controller = create_controller()
        local survivor = create_worker_service()
        local command = group:sub(6)
        local exiting = create_worker_service({exit_command = command, kill = group:match("^kill_") ~= nil})
        -- 不限定 RPC 错误与退出通知次序；按已知结果尽力恢复并报告失败。
        local expected = command == "finish" and "RECOVERY_REQUIRED" or {ABORTED = true, RECOVERY_REQUIRED = true}
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), expected)
        assert(record.failed_service_count >= 1)
        local state = read_worker_state(survivor)
        if command == "finish" then
            assert(state.module_value == 2 and not state.paused)
            assert(lifecycle_status(controller).phase == "IDLE")
        else
            assert_original_state(survivor)
            if record.phase == "RECOVERY_REQUIRED" then
                assert(lifecycle_status(controller).phase == "IDLE")
                assert(record.error and record.error.code == "HU_RECOVERY_REQUIRED")
                local repaired = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED")
                assert(repaired.target_service_count == 1)
            else
                assert(lifecycle_status(controller).phase == "IDLE")
                -- 退出登记已删除，下一批不能继续向旧 handle 发送事务命令。
                local next_record = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED")
                assert(next_record.target_service_count == 1)
            end
        end
    elseif group:match("^drain_") then
        drain_lifecycle_tests(group)
    elseif group == "service_file" then
        controller = create_controller()
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        assert(native.read_file(root, "service/new_service.lua") == false)
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "service_file"), "COMPLETED")
        assert(record.target_service_count == 0 and not record.control_started)
        assert(assert(load(assert(native.read_file(root, "service/new_service.lua"))))().version == 2)
        assert(native.read_file(root, "service/skynet_hotupgrade_worker.patch") == false)
        local only_files = wait_for_batch_phase(controller, begin_update_batch(controller, "unmatched_module"), "COMPLETED")
        assert(only_files.target_service_count == 0)
        assert(read_worker_state(create_worker_service()).module_value == 2)
        print("HOTUPGRADE_SKYNET_SERVICE_FILE_OK")
    elseif group == "deployment" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        assert_original_state(worker_service_handle)
        assert(assert(load(old))("test_worker_logic", root .. "/lualib/test_worker_logic.lua").value() == 1)
        assert(native.read_file(root, "lualib/new/dependency.lua") == false)
        wait_for_batch_phase(controller, begin_update_batch(controller, "deployment"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).module_value == 2 and read_worker_state(worker_service_handle).equip == "剑")
        assert(read_worker_state(create_worker_service()).module_value == 2)
        assert(require("new.dependency").version == 2)
        assert(native.read_file(root, "service/skynet_hotupgrade_worker.patch") == false)
        print("HOTUPGRADE_SKYNET_DEPLOYMENT_OK")
    elseif group == "deploy_failure" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        skynet.fork(function() assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 20}).ok) end)
        while skynet.call(worker_service_handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = begin_update_batch(controller, "deploy_failure")
        while not read_worker_state(worker_service_handle).paused do skynet.sleep(1) end
        -- begin 的异步发布已冻结源码并准备旧文件；在 queue 排空窗口注入目标路径失效。
        assert(os.execute("mkdir " .. root .. "/service/z_blocked.lua"))
        local record = wait_for_batch_phase(controller, id, "ABORTED")
        assert(record.error.code == "HU_INVALID_PATH" and record.control_started
            and record.target_service_count == 1 and record.failed_service_count == 1 and lifecycle_status(controller).phase == "IDLE")
        assert_original_state(worker_service_handle)
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
        worker_service_handle = create_worker_service()
        local before = assert_original_state(worker_service_handle)
        assert(before.runtime_alias_identity and before.runtime_value == 1 and before.max_level == 100)
        assert(read_worker_state(worker_service_handle).runtime_value == 1 and read_worker_state(worker_service_handle).max_level == 100)
        assert(read_worker_state(worker_service_handle).package_value == 1 and read_worker_state(worker_service_handle).package_alias_identity)
        wait_for_batch_phase(controller, begin_update_batch(controller, "host_paths"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).runtime_value == 2 and read_worker_state(worker_service_handle).max_level == 200 and read_worker_state(worker_service_handle).runtime_alias_identity)
        assert(read_worker_state(worker_service_handle).package_value == 2 and read_worker_state(worker_service_handle).package_alias_identity)
        local nested_worker = create_worker_service()
        wait_for_batch_phase(controller, begin_update_batch(controller, "nested_service"), "COMPLETED")
        assert(read_worker_state(nested_worker).attack == 120)
        print("HOTUPGRADE_SKYNET_HOST_PATHS_OK")
    elseif group == "custom_paths" then
        controller = create_controller("actors")
        worker_service_handle = create_worker_service()
        wait_for_batch_phase(controller, begin_update_batch(controller, "custom_service"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).attack == 120)
        print("HOTUPGRADE_SKYNET_CUSTOM_PATHS_OK")
    elseif group == "patch_match" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local before = assert_original_state(worker_service_handle)
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old_source = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        local idle = lifecycle_status(controller)
        assert(idle.phase == "IDLE" and idle.active_batch_id == nil)
        assert(assert_original_state(worker_service_handle).marker_token == before.marker_token)
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)

        local fixtures = {
            {path = "../module", code = "HU_INVALID_PATH"},
            {path = "invalid", code = "HU_MODULE_SYNTAX"},
            {path = "invalid_patch", code = "HU_INVALID_PATCH"},
            {path = "invalid_service", code = "HU_MODULE_SYNTAX"},
            {path = "unmatched_service", code = "HU_TARGET_MISSING"},
        }
        for _, fixture in ipairs(fixtures) do
            local id = begin_update_batch(controller, fixture.path)
            local record = wait_for_batch_phase(controller, id, "ABORTED")
            local rejected = record.error
            assert(rejected.code == fixture.code and rejected.message and #rejected.message > 0)
            local status = skynet.call(controller, "hotupgrade", "status", {batch_id = id})
            assert(status.ok and status.record.phase == "ABORTED")
            assert(status.record.error.code == fixture.code and not status.record.control_started)
            assert(assert_original_state(worker_service_handle).marker_token == before.marker_token)
            assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)
            assert(status.lifecycle.phase == "IDLE")
        end
        assert(skynet.call(controller, "hotupgrade", "unknown_command", {path = "module"}).code == "HU_UNKNOWN_COMMAND")
        print("HOTUPGRADE_SKYNET_PATCH_MATCH_OK")
    elseif group == "identity_queue" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local before = assert_original_state(worker_service_handle)
        assert(skynet.call(worker_service_handle, "lua", "bump", {}).value == 8)
        local held = false
        skynet.fork(function()
            assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 15}).ok)
            held = true
        end)
        while skynet.call(worker_service_handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = begin_update_batch(controller, "combined")
        while not read_worker_state(worker_service_handle).paused do skynet.sleep(1) end
        local rejected = skynet.call(worker_service_handle, "lua", "hold", {ticks = 1})
        assert(not rejected.ok and rejected.code == "HU_UPGRADING")
        wait_for_batch_phase(controller, id, "COMPLETED")
        assert(held)
        local after = read_worker_state(worker_service_handle)
        assert(after.service_handle == worker_service_handle and after.state_identity and after.lua_state_identity and after.module_identity)
        assert(after.marker_token == before.marker_token)
        assert(after.equip == "剑" and after.level == 50 and after.schema_version == 2)
        assert(after.attack == 120 and after.save_identity)
        assert(after.module_value == 2 and after.cached_value == 1 and after.added and after.removed == nil)
        assert(skynet.call(worker_service_handle, "lua", "bump", {}).value == 9)
        print("HOTUPGRADE_SKYNET_IDENTITY_STATE_QUEUE_OK")
    elseif group == "registration_missing" then
        controller = create_controller()
        worker_service_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
        local registration_result = skynet.call(worker_service_handle, "lua", "init", {before_missing = true})
        assert(not registration_result.ok and registration_result.code == "HU_INVALID_OPTIONS")
        assert(module_state.hotupgrade_api.cancel_service_creation(worker_service_handle).ok)
        assert(lifecycle_status(controller).pending_creations == 0)
    elseif group == "prepare_false" or group == "prepare_error" then
        controller = create_controller()
        local config = {[group == "prepare_false" and "before_false" or "before_error"] = true}
        worker_service_handle = create_worker_service(config)
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), "ABORTED")
        assert(record.error.code == (group == "prepare_error" and "HU_PREPARE_FAILED" or "HU_SAFEPOINT_REQUIRED"))
        assert_original_state(worker_service_handle)
    elseif group == "optional_service" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        wait_for_batch_phase(controller, begin_update_batch(controller, "functions"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).equip == "刀" and read_worker_state(worker_service_handle).attack == 100)
        wait_for_batch_phase(controller, begin_update_batch(controller, "state_only"), "COMPLETED")
        local updated = read_worker_state(worker_service_handle)
        assert(updated.equip == "剑" and updated.level == 50 and updated.schema_version == 2)
        assert(updated.attack == 120 and updated.module_value == 1)
        assert(updated.obsolete == nil and updated.nested_count == 8 and updated.nested_retained == 23)
        assert(updated.nested_self_cycle and updated.nested_alias_identity and updated.root_cycle)
        assert(updated.rank_2 == 2 and updated.rank_3 == 3 and updated.mode_phase == "v2")
        assert(updated.replaced_value == "v2")
        print("HOTUPGRADE_SKYNET_OPTIONAL_SERVICE_PATCH_OK")
    elseif group == "state_shared" or group == "state_shared_failure" then
        controller = create_controller()
        local rejected = group == "state_shared_failure"
        worker_service_handle = create_worker_service({after_upgrade_failure = rejected})
        local before = assert_original_state(worker_service_handle)
        wait_for_batch_phase(controller, begin_update_batch(controller, "state_shared"), rejected and "ABORTED" or "COMPLETED")
        local after = read_worker_state(worker_service_handle)
        assert(after.state_identity and after.marker_token == before.marker_token and not after.paused)
        assert(after.merge_distinct and after.a_keep_a == 1 and after.b_keep_b == 2)
        assert(after.a_keep_b == nil and after.b_keep_a == nil)
        if rejected then
            assert(after.a_changed == nil and after.b_changed == nil)
            assert_original_state(worker_service_handle)
        else
            assert(after.a_changed == 3 and after.b_changed == 3)
        end
        assert(after.nested_alias_identity and after.root_cycle)
        print("HOTUPGRADE_SKYNET_STATE_SHARED_OK " .. group)
    elseif group == "declaration" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        assert(skynet.call(controller, "hotupgrade", "unknown_command", {path = "extra"}).code == "HU_UNKNOWN_COMMAND")
        assert(skynet.call(worker_service_handle, "lua", "check_declarations", {}))
        assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 1)
        assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 1)
        wait_for_batch_phase(controller, begin_update_batch(controller, "extra"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).extra_value == 2)
        assert(skynet.call(worker_service_handle, "hotupgrade", "update",
            {batch_id = "foreign", sequence = 999}).code == "HU_UNAUTHORIZED")
        print("HOTUPGRADE_SKYNET_DECLARATION_OK")
    elseif group == "bad_functions" or group == "stage_failure" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local patch_path = group == "bad_functions" and "bad_functions" or "stage_failure"
        local native = require "flywow_hotupgrade_native"
        local root = require("hotupgrade_test_options").root_path
        local old_source = assert(native.read_file(root, "lualib/test_worker_logic.lua"))
        wait_for_batch_phase(controller, begin_update_batch(controller, patch_path), "ABORTED")
        assert_original_state(worker_service_handle)
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
        worker_service_handle = create_worker_service(config)
        wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), expected)
        if group == "activation_custom_success" then
            assert(read_worker_state(worker_service_handle).attack == 120 and read_worker_state(worker_service_handle).nested_identity and read_worker_state(worker_service_handle).nested_count == 7)
        else
            assert_original_state(worker_service_handle)
            if group == "activation_custom_success_failure" then assert(read_worker_state(worker_service_handle).nested_identity) end
        end
        print("HOTUPGRADE_SKYNET_ACTIVATE_RESTORE_OK " .. group)
    elseif group == "multiple_targets" then
        controller = create_controller()
        local first = create_worker_service()
        local second = create_worker_service()
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED")
        assert(record.succeeded_service_count == 2 and read_worker_state(first).module_value == 2 and read_worker_state(second).module_value == 2)
        print("HOTUPGRADE_SKYNET_MULTIPLE_TARGETS_OK")
    elseif group == "partial" then
        controller = create_controller()
        local first = create_worker_service()
        local second = create_worker_service({after_upgrade_failure = true})
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), "ABORTED")
        assert(record.succeeded_service_count == 0 and record.failed_service_count == 2)
        assert_original_state(first)
        assert_original_state(second)
        assert(lifecycle_status(controller).phase == "IDLE")
        local new_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
        assert(module_state.hotupgrade_api.cancel_service_creation(new_handle).ok)
        print("HOTUPGRADE_SKYNET_PARTIAL_OK")
    elseif group == "new_modules" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local first = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules"), "COMPLETED")
        local first_state = read_worker_state(worker_service_handle)
        assert(first.succeeded_service_count == 1 and first_state.module_value == 42 and first_state.module_identity)
        assert(lifecycle_status(controller).pending_loads == 0)
        local next_batch = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules_followup"), "COMPLETED")
        assert(next_batch.succeeded_service_count == 1 and read_worker_state(worker_service_handle).module_value == 52)
        print("HOTUPGRADE_SKYNET_NEW_MODULES_OK")
    elseif group == "new_modules_concurrent_conflict" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        assert(skynet.call(worker_service_handle, "lua", "start_new_module_conflict", {}) == true)
        local failed = wait_for_batch_phase(controller,
            begin_update_batch(controller, "new_modules_concurrent"), "ABORTED")
        assert(failed.error.code == "HU_NEW_MODULE_FAILED")
        assert(failed.error.cause_code == "HU_MODULE_LOADING")
        local ordinary = skynet.call(worker_service_handle, "lua", "new_module_conflict_result", {})
        assert(not ordinary.ok and ordinary.message ~= "")
        assert(lifecycle_status(controller).pending_loads == 0)
        print("HOTUPGRADE_SKYNET_NEW_MODULES_CONCURRENT_CONFLICT_OK")
    elseif group == "new_modules_candidate_undeclared" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local root = require("hotupgrade_test_options").root_path
        local native = require "flywow_hotupgrade_native"
        local failed = wait_for_batch_phase(controller,
            begin_update_batch(controller, "new_modules_candidate_undeclared"), "ABORTED")
        assert(failed.error.code == "HU_MODULE_STAGE_FAILED")
        assert(failed.error.cause_code == "HU_NEW_MODULE_NOT_DECLARED")
        assert_original_state(worker_service_handle)
        assert(native.read_file(root, "lualib/hotupgrade_new_rules.lua") == false)
        assert(lifecycle_status(controller).pending_loads == 0)
        local next_batch = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules"), "COMPLETED")
        assert(next_batch.succeeded_service_count == 1 and read_worker_state(worker_service_handle).module_value == 42)
        print("HOTUPGRADE_SKYNET_NEW_MODULE_CANDIDATE_UNDECLARED_OK")
    elseif group == "new_modules_candidate_caught_error" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local failed = wait_for_batch_phase(controller,
            begin_update_batch(controller, "new_modules_candidate_caught_error"), "ABORTED")
        assert(failed.error.code == "HU_MODULE_STAGE_FAILED")
        assert(failed.error.cause_code == nil)
        assert(failed.error.message:find("injected unrelated candidate failure", 1, true))
        assert_original_state(worker_service_handle)
        print("HOTUPGRADE_SKYNET_NEW_MODULE_CAUGHT_ERROR_OK")
    elseif group == "new_modules_failure" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local root = require("hotupgrade_test_options").root_path
        local native = require "flywow_hotupgrade_native"
        local failed = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules_failure"), "ABORTED")
        assert(failed.error.code == "HU_MODULE_STAGE_FAILED")
        assert_original_state(worker_service_handle)
        local remaining_rules = native.read_file(root, "lualib/hotupgrade_new_rules.lua")
        assert(remaining_rules == false, "failed batch left new module file: " .. tostring(remaining_rules))
        assert(lifecycle_status(controller).pending_loads == 0)
        local next_batch = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules_followup"), "COMPLETED")
        assert(next_batch.succeeded_service_count == 1 and read_worker_state(worker_service_handle).module_value == 52)
        print("HOTUPGRADE_SKYNET_NEW_MODULES_FAILURE_CONTINUES_OK")
    elseif group == "management_abort" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        skynet.fork(function() assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 15}).ok) end)
        while skynet.call(worker_service_handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = begin_update_batch(controller, "combined")
        while not read_worker_state(worker_service_handle).paused do skynet.sleep(1) end
        local rejected = skynet.call(controller, "hotupgrade", "abort", {batch_id = id})
        assert(not rejected.ok and rejected.code == "HU_UNKNOWN_COMMAND")
        wait_for_batch_phase(controller, id, "COMPLETED")
        local after = read_worker_state(worker_service_handle)
        assert(after.module_value == 2 and after.equip == "剑" and not after.paused)
        print("HOTUPGRADE_SKYNET_MANAGEMENT_ABORT_REJECTED_OK")
    elseif group == "recovery_restore" or group == "recovery_module" then
        controller = create_controller()
        local config = group == "recovery_restore" and {custom = true, restore_failure = true} or {break_module = true}
        worker_service_handle = create_worker_service(config)
        wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), "RECOVERY_REQUIRED")
        assert(not read_worker_state(worker_service_handle).paused)
        assert(lifecycle_status(controller).phase == "IDLE")
        assert(skynet.call(worker_service_handle, "lua", "allow_next_upgrade", {}).ok)
        local repaired = wait_for_batch_phase(controller, begin_update_batch(controller, "repair"), "COMPLETED")
        assert(repaired.succeeded_service_count == 1 and not lifecycle_status(controller).recovery_required)
        local current = read_worker_state(worker_service_handle)
        assert(current.module_value == 3 and current.level == 60 and current.schema_version == 3 and not current.paused)
        assert(read_worker_state(create_worker_service()).module_value == 3)
        print("HOTUPGRADE_SKYNET_RECOVERY_REQUIRED_OK")
    else
        error("unknown HOTUPGRADE_TEST_GROUP: " .. tostring(group))
    end
    print("HOTUPGRADE_SKYNET_GROUP_OK " .. group)
end
skynet.start(function()
    module_state.hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    module_state.hotupgrade_api = require "flywow_hotupgrade"
    require "test_files"
    local ok, message = xpcall(run_test_group, debug.traceback)
    if not ok then
        print(message)
        print("HOTUPGRADE_SKYNET_FAILED")
    end
    skynet.abort()
end)
