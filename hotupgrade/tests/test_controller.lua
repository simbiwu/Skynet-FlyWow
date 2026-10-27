-- 每个场景由独立 Lua 进程运行，因此 Controller 模块只初始化一次。
local fixture = require "test_controller_fixture"
local module_state = fixture.module_state
local controller = fixture.controller
local metadata = fixture.metadata
local initialize_controller = fixture.initialize_controller
local begin_deployment = fixture.begin_deployment
local publish = fixture.publish
local managed_register = fixture.managed_register
local register_module = fixture.register_module
local scenario = assert(arg[1], "需要测试场景名")

local function lifecycle_status(controller)
    return controller:handle_command("status", {}, 1).lifecycle
end

local scenarios = {}

scenarios["interleaved"] = function()
    local interleaved = initialize_controller()
    local created_by_owner = {}
    local registered_by_source = {}
    local creators = {}
    module_state.launch_hook = function() coroutine.yield() end
    for owner = 1, 2 do
        creators[owner] = coroutine.create(function()
            created_by_owner[owner] = interleaved:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, owner)
        end)
        assert(coroutine.resume(creators[owner]))
    end
    for _, source in ipairs({72, 73, 74}) do
        local waiter = coroutine.create(function()
            registered_by_source[source] = interleaved:handle_command("register", metadata, source)
        end)
        assert(coroutine.resume(waiter))
    end
    local waiting_batch = interleaved:handle_command("begin", {path = "module"}, 1)
    assert(waiting_batch.ok and lifecycle_status(interleaved).phase == "WAITING_CREATIONS")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    module_state.launch_service_handle = 73
    assert(coroutine.resume(creators[2]))
    assert(registered_by_source[73].ok and not registered_by_source[72] and not registered_by_source[74])
    assert(interleaved.pending_creation_count == 1 and lifecycle_status(interleaved).phase == "WAITING_CREATIONS")
    module_state.launch_service_handle = 72
    assert(coroutine.resume(creators[1]))
    assert(registered_by_source[72].ok and registered_by_source[74].code == "HU_CREATION_MISSING")
    assert(lifecycle_status(interleaved).phase == "COMPLETED" and interleaved.pending_creation_count == 0)
    assert(next(interleaved.service_creations) == nil and next(interleaved.service_registration_waiters) == nil)
    module_state.launch_hook = nil
end

scenarios['lifecycle'] = function()
    local lifecycle = initialize_controller()
    -- 原生退出通知移除登记与加载许可，重复通知不重复减计数。
    assert(managed_register(lifecycle, metadata, 61).ok)
    local permit = lifecycle:handle_command("begin_module_load", {name = "lualib.exit_pending"}, 61)
    assert(permit.ok and lifecycle.pending_load_count == 1)
    lifecycle:on_service_exit(61)
    assert(lifecycle.service_registrations[61] == nil)
    assert(lifecycle.pending_load_count == 0 and next(lifecycle.module_load_permits) == nil)
    lifecycle:on_service_exit(61)
    lifecycle:on_service_exit(999)
    assert(lifecycle.pending_load_count == 0 and lifecycle.pending_creation_count == 0)

    -- 退出只删除匹配 handle 的唯一实例；保留批次快照并记录失败。
    assert(managed_register(lifecycle, metadata, 62).ok)
    lifecycle.unique_service_entries.fixture = {service_handle = 62}
    lifecycle.unique_service_entries.other = {service_handle = 63}
    local exited_service_target = {service_handle = 62}
    lifecycle.active_batch = {phase = "PREPARE", service_targets = {exited_service_target}}
    lifecycle:on_service_exit(62)
    assert(lifecycle.unique_service_entries.fixture == nil and lifecycle.unique_service_entries.other.service_handle == 63)
    assert(lifecycle.active_batch.service_targets[1] == exited_service_target and exited_service_target.exited)
    assert(lifecycle.active_batch.error.code == "HU_SERVICE_EXITED")
    lifecycle.active_batch = nil
    lifecycle.unique_service_entries.other = nil

    assert(managed_register(lifecycle, metadata, 62).ok)
    module_state.injected_control_failure = {service_handle = 62, command = "prepare", unknown = true}
    module_state.control_hook = function(_, command)
        if command == "abort" then error("target already exited") end
    end
    local begun_exit = lifecycle:handle_command("begin", {path = "module"}, 1)
    assert(begun_exit.ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(lifecycle).phase == "IDLE" and lifecycle.last_batch.phase == "RECOVERY_REQUIRED")
    lifecycle:on_service_exit(62)
    assert(lifecycle_status(lifecycle).phase == "IDLE" and lifecycle.service_registrations[62] == nil)
    module_state.control_hook = nil
    module_state.injected_control_failure = nil

    local launches_before_invalid_names = #module_state.launches
    for _, service_name in ipairs({"../fixture", "fixture//worker", "fixture/../worker", "/fixture"}) do
        for _, command in ipairs({"newservice", "uniqueservice"}) do
            local rejected = lifecycle:handle_command(command,
                {service_name = service_name, arguments = {n = 0}}, 1)
            assert(rejected.code == "HU_INVALID_REQUEST")
        end
    end
    assert(#module_state.launches == launches_before_invalid_names)
    module_state.launch_service_handle = 68
    local nested_creation = lifecycle:handle_command("newservice",
        {service_name = "battle/worker", arguments = {n = 0}}, 1)
    assert(nested_creation.ok and module_state.launches[#module_state.launches].name == "battle/worker")
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 68}, 1).ok)

    local function blocked(instance)
        for _, command in ipairs({"unknown_command", "validate", "apply"}) do
            local calls = #module_state.pending_control_coroutines
            module_state.last_control_command_by_service_handle = {}
            local answer = instance:handle_command(command, {path = "module"}, 1)
            local expected = "HU_UNKNOWN_COMMAND"
            assert(answer.code == expected and answer.batch_id == nil)
            assert(#module_state.pending_control_coroutines == calls)
            assert(next(module_state.last_control_command_by_service_handle) == nil and not instance.active)
        end
    end

    -- 登记先到时协程挂起；只有原生返回的 Service handle 能解除等待，未知来源不能借用创建。
    module_state.launch_hook = function() coroutine.yield() end
    local early_created
    local early_registered
    local duplicate_registered
    local unknown_registered
    local early_create = coroutine.create(function()
        early_created = lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    local early_register = coroutine.create(function()
        early_registered = lifecycle:handle_command("register", metadata, 70)
    end)
    local duplicate_register = coroutine.create(function()
        duplicate_registered = lifecycle:handle_command("register", metadata, 70)
    end)
    local unknown_register = coroutine.create(function()
        unknown_registered = lifecycle:handle_command("register", metadata, 71)
    end)
    assert(coroutine.resume(early_create))
    assert(coroutine.resume(early_register) and early_registered == nil)
    assert(coroutine.resume(duplicate_register) and duplicate_registered == nil)
    assert(coroutine.resume(unknown_register) and unknown_registered == nil)
    assert(lifecycle:handle_command("register", {}, 70).code == "HU_INVALID_OPTIONS")
    blocked(lifecycle)
    module_state.launch_service_handle = 70
    assert(coroutine.resume(early_create))
    module_state.launch_hook = nil
    assert(early_created.service_handle == 70)
    assert((early_registered.ok and duplicate_registered.code == "HU_DUPLICATE_SERVICE")
        or (duplicate_registered.ok and early_registered.code == "HU_DUPLICATE_SERVICE"))
    assert(unknown_registered.code == "HU_CREATION_MISSING")
    assert(lifecycle.pending_creation_count == 0 and lifecycle.service_registrations[70] and next(lifecycle.service_registration_waiters) == nil)
    local batch = {patch_path = "module"}
    assert(lifecycle:load_patch(batch).ok and #batch.service_targets == 1)
    assert(lifecycle:handle_command("unknown_command", {path = "module"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 70}, 1).code == "HU_SERVICE_ALREADY_REGISTERED")

    -- 原生返回早于登记；显式取消、初始化失败和创建失败均不留记录。
    module_state.launch_service_handle = 80
    assert(lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).service_handle == 80)
    blocked(lifecycle)
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 80}, 1).code == "HU_UNAUTHORIZED")
    assert(not module_state.killed[80] and lifecycle.pending_creation_count == 1)
    assert(lifecycle:handle_command("register", metadata, 80).ok and lifecycle.pending_creation_count == 0)
    assert(lifecycle:handle_command("register", metadata, 81).code == "HU_CREATION_MISSING")
    -- 原生失败唤醒早到登记并释放记录，失败的来源不会进入 targets。
    local failed_registration
    module_state.launch_hook = function()
        local waiter = coroutine.create(function()
            failed_registration = lifecycle:handle_command("register", metadata, 81)
        end)
        assert(coroutine.resume(waiter) and failed_registration == nil)
        error("startup failed")
    end
    assert(lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_SERVICE_CREATE_FAILED")
    assert(failed_registration.code == "HU_CREATION_MISSING")
    assert(lifecycle.pending_creation_count == 0 and not lifecycle.service_registrations[81] and next(lifecycle.service_registration_waiters) == nil)
    module_state.launch_hook = nil
    module_state.launch_service_handle = 82
    assert(lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).ok)
    assert(lifecycle:handle_command("register", {}, 82).code == "HU_INVALID_OPTIONS")
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 82}, 2).ok)
    assert(module_state.killed[82] and lifecycle.pending_creation_count == 0)
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 82}, 2).code == "HU_CREATION_MISSING")

    local permit = lifecycle:handle_command("begin_module_load", {name = "extra"}, 70)
    assert(permit.ok)
    assert(lifecycle:handle_command("begin_module_load", {name = "extra"}, 70).code == "HU_MODULE_LOADING")
    blocked(lifecycle)
    local request = {name = "extra", permit_id = permit.permit_id}
    assert(lifecycle:handle_command("register_module", request, 80).code == "HU_UNAUTHORIZED")
    assert(lifecycle:handle_command("register_module", {name = "wrong", permit_id = permit.permit_id}, 70).code == "HU_MODULE_PERMIT_MISMATCH")
    assert(lifecycle.pending_load_count == 1)
    assert(lifecycle:handle_command("register_module", request, 70).ok and lifecycle.pending_load_count == 0)
    assert(lifecycle:handle_command("register_module", request, 70).code == "HU_MODULE_PERMIT_MISSING")
    permit = lifecycle:handle_command("begin_module_load", {name = "cancelled"}, 70)
    assert(lifecycle:handle_command("cancel_module_load", {name = "cancelled", permit_id = permit.permit_id}, 70).ok)
    assert(lifecycle.pending_load_count == 0 and not lifecycle.service_registrations[70].modules.cancelled)
    assert(lifecycle:handle_command("begin_module_load", {name = "extra"}, 90).code == "HU_SERVICE_NOT_REGISTERED")
    local started_lifecycle = publish(lifecycle, {path = "module"})
    assert(started_lifecycle.ok)
    -- 只有 Update 起关闭门禁；在真实 Update 调用中挂起，验证后来的请求等待且不计数。
    module_state.control_hook = function(service_handle, command)
        if service_handle == 70 and command == "update" then coroutine.yield() end
    end
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle.active_batch.phase == "UPDATE")
    local new_module_request = {batch_id = started_lifecycle.batch_id, name = "lualib.new_rules"}
    assert(lifecycle:handle_command("register_new_module", new_module_request, 71).code == "HU_NEW_MODULE_NOT_ALLOWED")
    assert(lifecycle:handle_command("register_new_module", {batch_id = "stale", name = new_module_request.name}, 70).code
        == "HU_NEW_MODULE_NOT_ALLOWED")
    assert(lifecycle:handle_command("register_new_module", new_module_request, 70).ok)
    assert(lifecycle:handle_command("register_new_module", new_module_request, 70).ok)
    assert(lifecycle.service_registrations[70].modules[new_module_request.name])
    local queued_result
    local queued = coroutine.create(function()
        queued_result = lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    module_state.launch_service_handle = 83
    assert(coroutine.resume(queued) and queued_result == nil)
    assert(lifecycle.pending_creation_count == 0)
    assert(lifecycle:handle_command("register", metadata, 90).code == "HU_CREATION_MISSING")
    local queued_module
    local module_waiter = coroutine.create(function()
        queued_module = lifecycle:handle_command("begin_module_load", {name = "late"}, 70)
    end)
    assert(coroutine.resume(module_waiter) and queued_module == nil)
    local view = lifecycle:handle_command("status", {}, 1).lifecycle
    assert(view.pending_creations == 0 and view.pending_loads == 0 and view.active_batch_id == started_lifecycle.batch_id)
    module_state.control_hook = nil
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(queued_module.ok and lifecycle.pending_load_count == 1)
    assert(lifecycle:handle_command("register_module", {name = "late", permit_id = queued_module.permit_id}, 70).ok)
    assert(queued_result.ok and queued_result.service_handle == 83)
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 83}, 1).ok)
    assert(lifecycle:handle_command("register_new_module", new_module_request, 70).code == "HU_NEW_MODULE_NOT_ALLOWED")
    assert(lifecycle:handle_command("status", {batch_id = "unknown"}, 1).code == "HU_BATCH_MISSING")
    print("HOTUPGRADE_CONTROLLER_LIFECYCLE_OK")
end

scenarios['matching'] = function()
    assert(not controller.initialize({}).ok)
    local c = initialize_controller()
    module_state.launch_service_handle = 9
    local named_creation = c:handle_command("newservice",
        {service_name = "player_service", arguments = {n = 0}}, 1)
    assert(named_creation.ok and c.service_creations[9].service_name == "player_service")
    assert(c:handle_command("cancel_service_creation", {service_handle = 9}, 1).ok)
    for _, service_handle in ipairs({10, 20}) do
        assert(managed_register(c, {modules = {"lualib.test_worker_logic"},
            has_service_update = false}, service_handle).ok)
    end
    assert(c:handle_command("register", {modules = {}, has_service_update = false}, 10).code == "HU_DUPLICATE_SERVICE")
    assert(c:handle_command("register", {modules = {}, has_service_update = 1}, 30).code == "HU_INVALID_OPTIONS")
    assert(register_module(c, "extra", 10).ok)
    assert(not register_module(c, "extra", 30).ok)
    local batch = {patch_path = "module"}
    assert(c:load_patch(batch).ok and #batch.service_targets == 2)
    -- 未登记模块只部署；一次性 Service .patch 仍须匹配。
    local unmatched = {patch_path = "unmatched_module"}
    assert(c:load_patch(unmatched).ok and #unmatched.service_targets == 2 and #unmatched.files == 2)
    module_state.last_control_command_by_service_handle = {}
    local accepted = publish(c, {path = "unmatched_service"})
    assert(accepted.ok and accepted.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    local rejected = c:handle_command("status", {batch_id = accepted.batch_id}, 1).record.error
    assert(rejected.code == "HU_TARGET_MISSING" and rejected.message:find("service/unused.patch", 1, true))
    assert(next(module_state.last_control_command_by_service_handle) == nil and lifecycle_status(c).phase == "IDLE")
    assert(c.last_batch.phase == "ABORTED" and not c.last_batch.control_started)
    -- 同一模块仍可匹配多个 Service，组合包中的 Service 脚本也必须覆盖所有目标。

    local unsupported = c:load_patch({patch_path = "combined"})
    assert(unsupported.code == "HU_SERVICE_PATCH_UNSUPPORTED")
    assert(unsupported.message:find("combined/service/skynet_hotupgrade_worker.patch", 1, true))

    local function publish_and_complete_module_batch()
        local answer = publish(c, {path = "module"})
        assert(answer.ok)
        assert(not c:handle_command("apply", {path = "module"}, 1).ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        return c:handle_command("status", {batch_id = answer.batch_id}, 1)
    end
    local status = publish_and_complete_module_batch()
    assert(status.record.phase == "COMPLETED" and status.record.succeeded_service_count == 2
        and status.record.target_service_count == 2 and #status.record.service_results == 2
        and module_state.last_control_command_by_service_handle[20] == "finish")
    module_state.injected_control_failure = {service_handle = 20, command = "update"}
    status = publish_and_complete_module_batch()
    assert(status.record.phase == "ABORTED" and status.record.succeeded_service_count == 0
        and status.record.failed_service_count == 2 and #status.record.service_results == 2)
    assert(lifecycle_status(c).phase == "IDLE" and module_state.last_control_command_by_service_handle[10] == "abort")
    assert(module_state.last_control_command_by_service_handle[20] == "abort")
    module_state.injected_control_failure = nil
    module_state.operations = {}
    local started = publish(c, {path = "module"})
    module_state.control_hook = function(_handle, command)
        if command == "prepare" then coroutine.yield() end
    end
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(c).phase == "APPLYING" and #module_state.operations == 1)
    assert(module_state.operations[1] == "10:prepare")
    local active_before_abort = c.active_batch
    assert(c:handle_command("abort", {batch_id = started.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(c.active_batch == active_before_abort and #module_state.operations == 1)
    module_state.control_hook = function(_handle, command)
        assert(command == "prepare" or command == "update" or command == "finish")
        assert(c:handle_command("abort", {batch_id = started.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
        assert(c.active_batch == active_before_abort)
    end
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c:handle_command("status", {batch_id = started.batch_id}, 1).record.phase == "COMPLETED")
    assert(table.concat(module_state.operations, ",") == "10:prepare,20:prepare,file:lualib/test_worker_logic.lua,cache,10:update,20:update,10:finish,20:finish")
    assert(c:handle_command("abort", {batch_id = started.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    module_state.control_hook = nil
    module_state.injected_control_failure = {service_handle = 10, command = "finish"}
    status = publish_and_complete_module_batch()
    assert(status.recovery_required and status.record.phase == "RECOVERY_REQUIRED")
    assert(not c:handle_command("apply", {path = "module"}, 1).ok)
    assert(not c:handle_command("history", {}, 1).ok)
    -- 仅保留活动批次和最近终态；更早批次不能继续查询。
    assert(c:handle_command("status", {batch_id = "99:1"}, 1).code == "HU_BATCH_MISSING")
    -- 恢复失败仅报告，不再阻止创建、声明和下一批发布。
    assert(lifecycle_status(c).phase == "IDLE")
    local allowed_after_failure = c:handle_command("begin_module_load", {name = "late"}, 10)
    assert(allowed_after_failure.ok)
    assert(c:handle_command("cancel_module_load", {name = "late", permit_id = allowed_after_failure.permit_id}, 10).ok)
    module_state.injected_control_failure = nil

    local waiting = c
    module_state.launch_service_handle = 84
    assert(waiting:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
    local begun = waiting:handle_command("begin", {path = "module"}, 1)
    assert(begun.ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    assert(waiting:handle_command("begin", {path = "module"}, 1).code == "HU_UPGRADE_BUSY")
    assert(waiting:handle_command("unknown_command", {}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:handle_command("register", metadata, 84).ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    assert(waiting:handle_command("abort", {batch_id = "stale"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:handle_command("abort", {batch_id = begun.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting.active_batch.batch_id == begun.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.last_batch.phase == "COMPLETED")

    -- 管理端不能取消批次；创建者仍可取消未登记 Service，使排空自然完成。
    module_state.launch_service_handle = 86
    local pending_creation = waiting:handle_command("newservice",
        {service_name = "fixture", arguments = {n = 0}}, 1)
    assert(pending_creation.ok)
    local pending_batch = waiting:handle_command("begin", {path = "module"}, 1)
    assert(pending_batch.ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.active_batch.waiter)
    assert(waiting:handle_command("abort", {batch_id = pending_batch.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting.active_batch.batch_id == pending_batch.batch_id and waiting.pending_creation_count == 1)
    assert(waiting:handle_command("cancel_service_creation", {service_handle = 86}, 1).ok)
    assert(waiting.last_batch.phase == "COMPLETED" and waiting.pending_creation_count == 0)

    local allowed = waiting:handle_command("begin_module_load", {name = "later"}, 84)
    assert(allowed.ok)
    local module_batch = waiting:handle_command("begin", {path = "module"}, 1)
    assert(module_batch.ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.active_batch.waiter and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    assert(waiting:handle_command("register_module", {name = "later", permit_id = allowed.permit_id}, 84).ok)
    assert(lifecycle_status(waiting).phase == "COMPLETED")

    -- begin 后仍接纳创建；完成登记后才能进行整包检查，失败前没有目标控制命令。
    local failed_batch = begin_deployment(waiting, "unmatched_service")
    module_state.launch_service_handle = 85
    local admitted_creation = waiting:handle_command("newservice",
        {service_name = "fixture", arguments = {n = 0}}, 1)
    assert(admitted_creation.service_handle == 85 and waiting.pending_creation_count == 1)
    assert(waiting:handle_command("register", metadata, 85).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    local failed = waiting:handle_command("status", {batch_id = failed_batch}, 1)
    assert(failed.record.error.code == "HU_TARGET_MISSING" and not failed.record.control_started)
    assert(lifecycle_status(waiting).phase == "IDLE" and waiting.service_registrations[85])

    -- preload 由原生启动处理；Controller 不拒绝、不改写目标名或启动参数。
    module_state.shared_environment.preload = "fixture_preload.lua"
    module_state.launch_service_handle = 89
    for _, command in ipairs({"newservice", "uniqueservice"}) do
        local created = waiting:handle_command(command, {service_name = "fixture", arguments = table.pack("head", nil, "tail")}, 1)
        assert(created.service_handle == 89)
        local launch = module_state.launches[#module_state.launches]
        assert(launch.name == "fixture" and launch.arguments.n == 3 and launch.arguments[3] == "tail")
        assert(waiting:handle_command("cancel_service_creation", {service_handle = 89}, 1).ok)
    end
    module_state.shared_environment.preload = nil
    print("HOTUPGRADE_CONTROLLER_DEPLOYMENT_OK")
end

scenarios['combined'] = function()
    local combined = initialize_controller()
    for _, service_handle in ipairs({30, 40}) do
        assert(managed_register(combined, {modules = {"lualib.test_worker_logic"},
            has_service_update = true}, service_handle).ok)
    end
    local answer = publish(combined, {path = "combined"})
    assert(answer.ok and answer.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(combined.last_batch.succeeded_service_count == 2 and combined.last_batch.target_service_count == 2)
end

scenarios['paths'] = function()
    local paths = initialize_controller()
    assert(managed_register(paths,
        {modules = {"config.settings", "lualib.battle.state_sync.runtime", "lualib.packages.demo.init"},
            has_service_update = true}, 50, "battle/worker").ok)
    local batch = {patch_path = "host_paths"}
    assert(paths:load_patch(batch).ok and #batch.modules == 3)
    assert(batch.modules[1].entry_file == "config/settings.lua")
    assert(batch.modules[2].name == "lualib.battle.state_sync.runtime")
    assert(paths:load_patch({patch_path = "nested_named_service"}).ok)

    for _, path in ipairs({"duplicate_module", "duplicate_service"}) do
        assert(paths:load_patch({patch_path = path}).code == "HU_INVALID_PATCH")
    end
end

scenarios['custom_paths'] = function()
    local changed = initialize_controller("actors")
    assert(managed_register(changed,
        {modules = {}, has_service_update = true}, 60, "zone/player").ok)
    assert(changed:load_patch({patch_path = "custom_named_service"}).ok)
end

scenarios['unique'] = function()
    local unique = initialize_controller()
    local first_unique
    local second_unique
    local first_co = coroutine.create(function()
        first_unique = unique:handle_command("uniqueservice", {service_name = "fixture", arguments = table.pack("first", nil, "last")}, 1)
    end)
    module_state.launch_hook = function() coroutine.yield() end
    local launch_count = #module_state.launches
    assert(coroutine.resume(first_co))
    local duplicate_co = coroutine.create(function()
        second_unique = unique:handle_command("uniqueservice", {service_name = "fixture", arguments = table.pack("ignored")}, 2)
    end)
    assert(coroutine.resume(duplicate_co) and first_unique == nil and second_unique == nil)
    assert(#module_state.launches == launch_count + 1)
    local forwarded = module_state.launches[#module_state.launches].arguments
    assert(forwarded.n == 3 and forwarded[1] == "first" and forwarded[2] == nil and forwarded[3] == "last")
    module_state.launch_service_handle = 90
    module_state.launch_hook = nil
    assert(coroutine.resume(first_co))
    assert(first_unique.service_handle == 90 and second_unique.service_handle == 90 and unique.pending_creation_count == 1)
    assert(unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1).service_handle == 90)
    assert(unique:handle_command("cancel_service_creation", {service_handle = 90}, 2).code == "HU_UNAUTHORIZED")
    assert(unique:handle_command("cancel_service_creation", {service_handle = 90}, 1).ok and not unique.unique_service_entries.fixture)

    -- 在途失败让所有等待者返回同一错误，释放预留后允许重试。
    first_unique, second_unique = nil, nil
    module_state.launch_hook = function()
        coroutine.yield()
        error("startup failed")
    end
    first_co = coroutine.create(function()
        first_unique = unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    duplicate_co = coroutine.create(function()
        second_unique = unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 2)
    end)
    assert(coroutine.resume(first_co) and coroutine.resume(duplicate_co))
    assert(coroutine.resume(first_co))
    assert(first_unique.code == "HU_SERVICE_CREATE_FAILED" and second_unique.code == first_unique.code)
    assert(unique.pending_creation_count == 0 and not unique.unique_service_entries.fixture)
    module_state.launch_hook = nil
    module_state.launch_service_handle = 91
    assert(unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1).service_handle == 91)
    assert(unique:handle_command("register", metadata, 91).ok)
    local unique_batch = begin_deployment(unique, "missing")
    assert(unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 2).service_handle == 91)
    local new_unique
    local unique_waiter = coroutine.create(function()
        new_unique = unique:handle_command("uniqueservice", {service_name = "fixture_other", arguments = {n = 0}}, 2)
    end)
    launch_count = #module_state.launches
    module_state.launch_service_handle = 92
    assert(coroutine.resume(unique_waiter) and new_unique.service_handle == 92)
    assert(#module_state.launches == launch_count + 1 and unique.pending_creation_count == 1)
    assert(unique:handle_command("cancel_service_creation", {service_handle = 92}, 2).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(unique:handle_command("status", {batch_id = unique_batch}, 1).record.error.code == "HU_PATCH_EMPTY")
    assert(lifecycle_status(unique).phase == "IDLE" and unique.pending_creation_count == 0)

    launch_count = #module_state.launches
    assert(unique:handle_command("uniqueservice", {global = true}, 1).code == "HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED")
    for _, command in ipairs({"newservice", "uniqueservice"}) do
        assert(unique:handle_command(command, {service_name = "snaxd", arguments = {n = 0}}, 1).code == "HU_SPECIAL_SERVICE_UNSUPPORTED")
    end
    assert(#module_state.launches == launch_count and unique.pending_creation_count == 0)

    assert(managed_register(unique, metadata, 93).ok)
    local failed_id = begin_deployment(unique, "unmatched_service")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(unique:handle_command("status", {batch_id = failed_id}, 1).record.error.code == "HU_TARGET_MISSING")
    assert(lifecycle_status(unique).phase == "IDLE" and unique.last_batch.error.code == "HU_TARGET_MISSING" and not unique.last_batch.control_started)
    module_state.injected_control_failure = {service_handle = 93, command = "update"}
    assert(publish(unique, {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(unique).phase == "IDLE" and unique.last_batch.error.code == "HU_FIXTURE_FAILED")
    module_state.injected_control_failure = {service_handle = 93, command = "update"}
    module_state.control_hook = function(service_handle, command)
        if service_handle == 93 and command == "abort" then
            module_state.injected_control_failure = {service_handle = 93, command = "abort"}
        end
    end
    assert(publish(unique, {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(unique).phase == "IDLE" and unique.last_batch.error.recovery_error.code == "HU_FIXTURE_FAILED")
    module_state.control_hook = nil
    module_state.injected_control_failure = nil
    print("HOTUPGRADE_CONTROLLER_LOCAL_UNIQUE_OK")
end

-- 逐轮补齐创建链和模块声明；源码只冻结一次，旧目标的 Prepare 不重复。
scenarios['draining'] = function()
    local c = initialize_controller()
    assert(managed_register(c, metadata, 10).ok)
    assert(managed_register(c, {modules = {}, has_service_update = false}, 20).ok)
    local native = require "flywow_hotupgrade_native"
    local original_list = native.list_lua
    local scans = 0
    native.list_lua = function(...)
        scans = scans + 1
        return original_list(...)
    end
    local queued_unique = {}
    local queued_permit
    local launches_at_update
    local prepared_service_target -- Prepare 和后续 Update 必须沿用同一个目标记录。
    module_state.control_hook = function(service_handle, command, request)
        if command == "prepare" and service_handle == 10 then
            assert(c.active_batch.phase == "PREPARE")
            prepared_service_target = c.active_batch.service_targets[1]
            assert(managed_register(c, metadata, 30).ok)
            assert(managed_register(c, {modules = {}, has_service_update = false}, 31, "unaffected").ok)
            assert(register_module(c, "lualib.hotupgrade_extra", 10).ok)
            assert(register_module(c, "lualib.hotupgrade_extra", 20).ok)
        elseif command == "prepare" and service_handle == 30 then
            module_state.launch_service_handle = 40
            assert(c:handle_command("uniqueservice",
                {service_name = "child", arguments = {n = 0}}, 30).service_handle == 40)
            assert(c:handle_command("register", metadata, 40).ok)
        elseif command == "update" and service_handle == 10 then
            assert(c.active_batch.service_targets[1] == prepared_service_target)
            assert(#request.modules == 2 and c.pending_creation_count == 0 and c.pending_load_count == 0)
            for _, module_patch in ipairs(request.modules) do
                assert(module_patch.old_source == nil and module_patch.touched == nil)
            end
            launches_at_update = #module_state.launches
            for index = 1, 2 do
                local waiter = coroutine.create(function()
                    queued_unique[index] = c:handle_command("uniqueservice",
                        {service_name = "late", arguments = {n = 0}}, 10)
                end)
                assert(coroutine.resume(waiter) and not queued_unique[index])
            end
            local waiter = coroutine.create(function()
                queued_permit = c:handle_command("begin_module_load", {name = "late"}, 10)
            end)
            assert(coroutine.resume(waiter) and queued_permit == nil)
            assert(c.unique_service_entries.late == nil and #module_state.launches == launches_at_update)
            module_state.launch_service_handle = 50
        end
    end
    local id = begin_deployment(c, "draining")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.last_batch.batch_id == id and c.last_batch.phase == "COMPLETED")
    assert(c.last_batch.target_service_count == 4 and c.last_batch.succeeded_service_count == 4 and scans == 1)
    local prepares = {}
    for _, operation in ipairs(module_state.operations) do
        local service_handle = operation:match("^(%d+):prepare$")
        if service_handle then prepares[service_handle] = (prepares[service_handle] or 0) + 1 end
    end
    for _, service_handle in ipairs({10, 20, 30, 40}) do
        assert(prepares[tostring(service_handle)] == 1)
    end
    assert(not prepares["31"] and queued_unique[1].service_handle == 50
        and queued_unique[2].service_handle == 50)
    assert(#module_state.launches == launches_at_update + 1 and queued_permit.ok)
    assert(c:handle_command("register_module",
        {name = "late", permit_id = queued_permit.permit_id}, 10).ok)
    assert(c:handle_command("cancel_service_creation", {service_handle = 50}, 10).ok)
    assert(c.pending_creation_count == 0 and c.pending_load_count == 0 and next(c.lifecycle_gate_waiters) == nil)
end

scenarios['drain_abort_rejected'] = function()
    local c = initialize_controller()
    assert(managed_register(c, metadata, 10).ok)
    module_state.control_hook = function(service_handle, command)
        if service_handle == 10 and command == "prepare" then
            module_state.launch_service_handle = 30
            assert(c:handle_command("newservice", {service_name = "child", arguments = {n = 0}}, 10).ok)
        end
    end
    local id = begin_deployment(c, "module")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.active_batch.phase == "PREPARE" and c.active_batch.waiter and c.pending_creation_count == 1)
    local active_before_abort = c.active_batch
    assert(c:handle_command("abort", {batch_id = id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(c.active_batch == active_before_abort and c.pending_creation_count == 1)
    assert(table.concat(module_state.operations, ",") == "10:prepare")
    assert(c:handle_command("cancel_service_creation", {service_handle = 30}, 10).ok)
    assert(c.last_batch.phase == "COMPLETED" and c.pending_creation_count == 0)
    assert(table.concat(module_state.operations, ",") == "10:prepare,file:lualib/test_worker_logic.lua,cache,10:update,10:finish")
end

scenarios['drain_unsupported'] = function()
    local c = initialize_controller()
    assert(managed_register(c, {modules = metadata.modules, has_service_update = true}, 10).ok)
    module_state.control_hook = function(service_handle, command)
        if service_handle == 10 and command == "prepare" then
            assert(managed_register(c, metadata, 30).ok)
        end
    end
    local id = begin_deployment(c, "combined")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.last_batch.batch_id == id and c.last_batch.error.code == "HU_SERVICE_PATCH_UNSUPPORTED")
    assert(c.last_batch.phase == "ABORTED" and lifecycle_status(c).phase == "IDLE")
    assert(table.concat(module_state.operations, ",") == "10:prepare,10:abort")
end

scenarios['drain_new_failure'] = function()
    local c = initialize_controller()
    assert(managed_register(c, metadata, 10).ok)
    module_state.control_hook = function(service_handle, command)
        if service_handle == 10 and command == "prepare" then
            assert(managed_register(c, metadata, 30).ok)
            module_state.injected_control_failure = {service_handle = 30, command = "prepare"}
        end
    end
    begin_deployment(c, "module")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.last_batch.phase == "ABORTED" and c.last_batch.failed_service_count == 2)
    assert(table.concat(module_state.operations, ",") == "10:prepare,30:prepare,30:abort,10:abort")
end

scenarios['resources'] = function()
    local ordered = initialize_controller()
    for _, service_handle in ipairs({101, 102, 103}) do
        assert(managed_register(ordered, metadata, service_handle).ok)
    end
    -- 扫描到文件后 Native 返回 false/nil 均异步失败；均不得触及目标。
    for _, failure in ipairs({"missing", "error"}) do
        module_state.injected_patch_read_failure = failure
        module_state.operations = {}
        local accepted = publish(ordered, {path = "module"})
        assert(accepted.ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        local record = ordered:handle_command("status", {batch_id = accepted.batch_id}, 1).record
        assert(record.phase == "ABORTED" and not record.control_started and #module_state.operations == 0)
        assert(record.error.code == (failure == "missing" and "HU_FILE_NOT_FOUND" or "HU_FILE_READ_FAILED"))
        assert(record.error.message:find("module/lualib/test_worker_logic.lua", 1, true))
    end
    module_state.injected_patch_read_failure = nil
    module_state.operations = {}
    assert(publish(ordered, {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(table.concat(module_state.operations, ",") ==
        "101:prepare,102:prepare,103:prepare,file:lualib/test_worker_logic.lua,cache,101:update,102:update,103:update,101:finish,102:finish,103:finish")
    module_state.operations = {}
    local before_failure = module_state.file_contents["lualib/test_worker_logic.lua"]
    module_state.injected_control_failure = {service_handle = 103, command = "update"}
    assert(publish(ordered, {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(table.concat(module_state.operations, ",") ==
        "101:prepare,102:prepare,103:prepare,file:lualib/test_worker_logic.lua,cache,101:update,102:update,103:update,file:lualib/test_worker_logic.lua,cache,103:abort,102:abort,101:abort")
    assert(module_state.file_contents["lualib/test_worker_logic.lua"] == before_failure)
    assert(ordered.last_batch.phase == "ABORTED" and lifecycle_status(ordered).phase == "IDLE")
    module_state.injected_control_failure = nil
    for _, unknown in ipairs({false, true}) do
        module_state.operations = {}
        module_state.injected_control_failure = {service_handle = 102, command = "finish", unknown = unknown}
        module_state.control_hook = function(service_handle, command)
            if service_handle == 103 and command == "finish" then
                local lifecycle = lifecycle_status(ordered)
                assert(lifecycle.phase == "APPLYING" and lifecycle.recovery_required)
            end
        end
        assert(publish(ordered, {path = "module"}).ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        assert(lifecycle_status(ordered).phase == "IDLE" and ordered.last_batch.succeeded_service_count == 2 and ordered.last_batch.failed_service_count == 1)
        assert(table.concat(module_state.operations, ",") ==
            "101:prepare,102:prepare,103:prepare,file:lualib/test_worker_logic.lua,cache,101:update,102:update,103:update,101:finish,102:finish,103:finish")
        assert(module_state.file_contents["lualib/test_worker_logic.lua"])
        module_state.injected_control_failure = nil
        module_state.control_hook = nil
    end

    local deployment = ordered
    assert(managed_register(deployment, metadata, 104).ok)
    module_state.file_contents = {["lualib/test_worker_logic.lua"] = "old"}
    module_state.injected_file_failure = "service/z_blocked.lua"
    assert(publish(deployment, {path = "deploy_failure"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(deployment).phase == "IDLE" and deployment.last_batch.phase == "ABORTED")
    assert(module_state.file_contents["lualib/test_worker_logic.lua"] == "old")
    assert(module_state.file_contents["lualib/a_added.lua"] == nil)
    assert(module_state.last_control_command_by_service_handle[104] == "abort")
    module_state.injected_file_failure = nil
    -- 文件准备和缓存清理失败均保留具体诊断；恢复失败只报告错误，不阻止后续发布。
    module_state.injected_read_failure = "lualib/test_worker_logic.lua"
    module_state.operations = {}
    local rejected_file = publish(deployment, {path = "module"})
    assert(rejected_file.ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(deployment.last_batch.error.code == "HU_FILE_READ_FAILED" and lifecycle_status(deployment).phase == "IDLE")
    assert(#module_state.operations == 0 and not deployment.last_batch.control_started)
    module_state.injected_read_failure = nil
    module_state.file_contents = {["lualib/test_worker_logic.lua"] = "old"}
    module_state.operations = {}
    module_state.cache_failures = 1
    assert(publish(deployment, {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(deployment).phase == "IDLE" and deployment.last_batch.phase == "ABORTED")
    assert(deployment.last_batch.error.code == "HU_CACHE_CLEAR_FAILED" and not lifecycle_status(deployment).recovery_required)
    assert(module_state.file_contents["lualib/test_worker_logic.lua"] == "old")
    assert(table.concat(module_state.operations, ",") ==
        "101:prepare,102:prepare,103:prepare,104:prepare,file:lualib/test_worker_logic.lua,cache,"
        .. "file:lualib/test_worker_logic.lua,cache,104:abort,103:abort,102:abort,101:abort")

    module_state.injected_file_failure = "service/z_blocked.lua"
    module_state.injected_restore_failure = true
    assert(publish(deployment, {path = "deploy_failure"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(deployment).phase == "IDLE" and lifecycle_status(deployment).recovery_required)
    assert(deployment.last_batch.error.original_error.code == "HU_FILE_DEPLOY_FAILED")
    assert(deployment.last_batch.error.recovery_error.code == "HU_FILE_DEPLOY_FAILED")
    module_state.injected_restore_failure = false
    module_state.injected_file_failure = nil
    local files_only = deployment
    local started_files = publish(files_only, {path = "service_file"})
    assert(started_files.ok and started_files.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(files_only.last_batch.phase == "COMPLETED" and files_only.last_batch.target_service_count == 0 and module_state.file_contents["service/new_service.lua"])

    -- 保留移除固定容量上限前的边界验证；各目标仍属于同一模块级 Controller。
    local module_names = {}
    for index = 1, 1025 do
        module_names[index] = "logic_" .. index
    end
    assert(managed_register(deployment,
        {modules = module_names, has_service_update = false}, 20000).ok)
    assert(register_module(deployment, "beyond_previous_limit", 20000).ok)
    for service_handle = 10000, 11024 do
        assert(managed_register(deployment,
            {modules = {}, has_service_update = false}, service_handle).ok)
    end
    print("HOTUPGRADE_CONTROLLER_RESOURCE_OK")
end

local run_test_scenario = assert(scenarios[scenario], "未知 Controller 测试场景: " .. scenario)
run_test_scenario()
print("HOTUPGRADE_CONTROLLER_SCENARIO_OK " .. scenario)
