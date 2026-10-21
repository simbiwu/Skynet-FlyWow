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

local scenarios = {}

scenarios["interleaved"] = function()
    local interleaved = initialize_controller()
    local created_by_owner = {}
    local registered_by_source = {}
    local creators = {}
    module_state.launch_hook = function() coroutine.yield() end
    for owner = 1, 2 do
        creators[owner] = coroutine.create(function()
            created_by_owner[owner] = interleaved:control("newservice", {service_name = "fixture", arguments = {n = 0}}, owner)
        end)
        assert(coroutine.resume(creators[owner]))
    end
    for _, source in ipairs({72, 73, 74}) do
        local waiter = coroutine.create(function()
            registered_by_source[source] = interleaved:control("register", metadata, source)
        end)
        assert(coroutine.resume(waiter))
    end
    local waiting_batch = interleaved:control("begin", {}, 1)
    assert(waiting_batch.ok and interleaved.phase == "WAITING_CREATIONS")
    module_state.launch_handle = 73
    assert(coroutine.resume(creators[2]))
    assert(registered_by_source[73].ok and not registered_by_source[72] and not registered_by_source[74])
    assert(interleaved.creation_count == 1 and interleaved.phase == "WAITING_CREATIONS")
    module_state.launch_handle = 72
    assert(coroutine.resume(creators[1]))
    assert(registered_by_source[72].ok and registered_by_source[74].code == "HU_CREATION_MISSING")
    assert(interleaved.phase == "DEPLOYING" and interleaved.creation_count == 0)
    assert(next(interleaved.creation_handles) == nil and next(interleaved.registration_waiters) == nil)
    module_state.launch_hook = nil
end

scenarios['lifecycle'] = function()
    local lifecycle = initialize_controller()
    local function blocked(instance)
        for _, command in ipairs({"unknown_command", "validate", "dry_run", "apply"}) do
            local calls = #module_state.pending_control_coroutines
            module_state.last_control_command_by_handle = {}
            local answer = instance:control(command, {path = "module"}, 1)
            local expected = (command == "unknown_command" or command == "validate")
                and "HU_UNKNOWN_COMMAND" or "HU_BATCH_MISSING"
            assert(answer.code == expected and answer.batch_id == nil)
            assert(#module_state.pending_control_coroutines == calls)
            assert(next(module_state.last_control_command_by_handle) == nil and not instance.active)
        end
    end

    -- 登记先到时协程挂起；只有原生返回的 handle 能解除等待，未知来源不能借用创建。
    module_state.launch_hook = function() coroutine.yield() end
    local early_created
    local early_registered
    local duplicate_registered
    local unknown_registered
    local early_create = coroutine.create(function()
        early_created = lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    local early_register = coroutine.create(function()
        early_registered = lifecycle:control("register", metadata, 70)
    end)
    local duplicate_register = coroutine.create(function()
        duplicate_registered = lifecycle:control("register", metadata, 70)
    end)
    local unknown_register = coroutine.create(function()
        unknown_registered = lifecycle:control("register", metadata, 71)
    end)
    assert(coroutine.resume(early_create))
    assert(coroutine.resume(early_register) and early_registered == nil)
    assert(coroutine.resume(duplicate_register) and duplicate_registered == nil)
    assert(coroutine.resume(unknown_register) and unknown_registered == nil)
    assert(lifecycle:control("register", {}, 70).code == "HU_INVALID_OPTIONS")
    blocked(lifecycle)
    module_state.launch_handle = 70
    assert(coroutine.resume(early_create))
    module_state.launch_hook = nil
    assert(early_created.handle == 70)
    assert((early_registered.ok and duplicate_registered.code == "HU_DUPLICATE_SERVICE")
        or (duplicate_registered.ok and early_registered.code == "HU_DUPLICATE_SERVICE"))
    assert(unknown_registered.code == "HU_CREATION_MISSING")
    assert(lifecycle.creation_count == 0 and lifecycle.targets[70] and next(lifecycle.registration_waiters) == nil)
    local lifecycle_patch = lifecycle:load({path = "module"})
    assert(lifecycle_patch.ok and #lifecycle_patch.targets == 1)
    assert(lifecycle:control("unknown_command", {path = "module"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(lifecycle:control("cancel_service_creation", {handle = 70}, 1).code == "HU_SERVICE_ALREADY_REGISTERED")

    -- 原生返回早于登记；显式取消、初始化失败和创建失败均不留记录。
    module_state.launch_handle = 80
    assert(lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).handle == 80)
    blocked(lifecycle)
    assert(lifecycle:control("cancel_service_creation", {handle = 80}, 1).code == "HU_UNAUTHORIZED")
    assert(not module_state.killed[80] and lifecycle.creation_count == 1)
    assert(lifecycle:control("register", metadata, 80).ok and lifecycle.creation_count == 0)
    assert(lifecycle:control("register", metadata, 81).code == "HU_CREATION_MISSING")
    -- 原生失败唤醒早到登记并释放记录，失败的来源不会进入 targets。
    local failed_registration
    module_state.launch_hook = function()
        local waiter = coroutine.create(function()
            failed_registration = lifecycle:control("register", metadata, 81)
        end)
        assert(coroutine.resume(waiter) and failed_registration == nil)
        error("startup failed")
    end
    assert(lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_SERVICE_CREATE_FAILED")
    assert(failed_registration.code == "HU_CREATION_MISSING")
    assert(lifecycle.creation_count == 0 and not lifecycle.targets[81] and next(lifecycle.registration_waiters) == nil)
    module_state.launch_hook = nil
    module_state.launch_handle = 82
    assert(lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).ok)
    assert(lifecycle:control("register", {}, 82).code == "HU_INVALID_OPTIONS")
    assert(lifecycle:control("cancel_service_creation", {handle = 82}, 2).ok)
    assert(module_state.killed[82] and lifecycle.creation_count == 0)
    assert(lifecycle:control("cancel_service_creation", {handle = 82}, 2).code == "HU_CREATION_MISSING")

    local permit = lifecycle:control("begin_module_load", {name = "extra"}, 70)
    assert(permit.ok)
    assert(lifecycle:control("begin_module_load", {name = "extra"}, 70).code == "HU_MODULE_LOADING")
    blocked(lifecycle)
    local request = {name = "extra", permit_id = permit.permit_id}
    assert(lifecycle:control("register_module", request, 80).code == "HU_UNAUTHORIZED")
    assert(lifecycle:control("register_module", {name = "wrong", permit_id = permit.permit_id}, 70).code == "HU_MODULE_PERMIT_MISMATCH")
    assert(lifecycle.module_load_count == 1)
    assert(lifecycle:control("register_module", request, 70).ok and lifecycle.module_load_count == 0)
    assert(lifecycle:control("register_module", request, 70).code == "HU_MODULE_PERMIT_MISSING")
    permit = lifecycle:control("begin_module_load", {name = "cancelled"}, 70)
    assert(lifecycle:control("cancel_module_load", {name = "cancelled", permit_id = permit.permit_id}, 70).ok)
    assert(lifecycle.module_load_count == 0 and not lifecycle.targets[70].modules.cancelled)
    assert(lifecycle:control("begin_module_load", {name = "extra"}, 90).code == "HU_SERVICE_NOT_REGISTERED")
    local started_lifecycle = publish(lifecycle, "apply", {path = "module"})
    assert(started_lifecycle.ok)
    local queued_result
    local queued = coroutine.create(function()
        queued_result = lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    module_state.launch_handle = 83
    assert(coroutine.resume(queued) and queued_result == nil)
    assert(lifecycle.creation_count == 0)
    assert(lifecycle:control("register", metadata, 90).code == "HU_CREATION_MISSING")
    local queued_module
    local module_waiter = coroutine.create(function()
        queued_module = lifecycle:control("begin_module_load", {name = "late"}, 70)
    end)
    assert(coroutine.resume(module_waiter) and queued_module == nil)
    local view = lifecycle:control("status", {}, 1).lifecycle
    assert(view.pending_creations == 0 and view.pending_module_loads == 0 and view.active_batch_id == started_lifecycle.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(queued_module.ok and lifecycle.module_load_count == 1)
    assert(lifecycle:control("register_module", {name = "late", permit_id = queued_module.permit_id}, 70).ok)
    assert(queued_result.ok and queued_result.handle == 83)
    assert(lifecycle:control("cancel_service_creation", {handle = 83}, 1).ok)
    assert(lifecycle:control("status", {batch_id = "unknown"}, 1).code == "HU_BATCH_MISSING")
    print("HOTUPGRADE_CONTROLLER_LIFECYCLE_OK")
end

scenarios['matching'] = function()
    assert(not controller.initialize({}).ok)
    local c = initialize_controller()
    for _, handle in ipairs({10, 20}) do
        assert(managed_register(c, {service_module = "player", modules = {"lualib.test_worker_logic"},
            service_patch = false}, handle).ok)
    end
    assert(c:control("register", {service_module = "player", modules = {}, service_patch = false}, 10).code == "HU_DUPLICATE_SERVICE")
    assert(register_module(c, "extra", 10).ok)
    assert(not register_module(c, "extra", 30).ok)
    local module_patch = c:load({path = "module"})
    assert(module_patch.ok and #module_patch.targets == 2)
    assert(not c:load({path = "module", selector = {percent = 0.5}}).ok)
    -- 未登记模块只部署；一次性 Service .patch 仍须匹配。
    local unmatched = c:load({path = "unmatched_module"})
    assert(unmatched.ok and #unmatched.targets == 2 and #unmatched.patch.files == 2)
    for _, command in ipairs({"dry_run", "apply"}) do
        module_state.last_control_command_by_handle = {}
        local rejected = publish(c, command, {path = "unmatched_service"})
        assert(rejected.code == "HU_TARGET_MISSING" and rejected.message:find("service/unused.patch", 1, true))
        assert(next(module_state.last_control_command_by_handle) == nil and c.phase == "IDLE")
        assert(c.last.phase == "ABORTED" and not c.last.control_started)
    end
    -- 同一模块仍可匹配多个 Service，组合包中的 Service 脚本也必须覆盖所有目标。

    local unsupported = c:load({path = "combined"})
    assert(unsupported.code == "HU_SERVICE_PATCH_UNSUPPORTED")
    assert(unsupported.message:find("combined/service/player.patch", 1, true))

    local function run(command)
        local answer = publish(c, command or "apply", {path = "module"})
        assert(answer.ok)
        assert(not c:control("apply", {path = "module"}, 1).ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        return c:control("status", {batch_id = answer.batch_id}, 1)
    end
    local status = run()
    assert(status.record.phase == "COMPLETED" and status.record.success == 2 and module_state.last_control_command_by_handle[20] == "finish")
    module_state.injected_control_failure = {handle = 20, command = "activate"}
    status = run()
    assert(status.record.phase == "ABORTED" and status.record.success == 0 and status.record.failed == 2)
    assert(c.phase == "IDLE" and module_state.last_control_command_by_handle[10] == "abort")
    assert(module_state.last_control_command_by_handle[20] == "abort")
    module_state.injected_control_failure = nil
    status = run("dry_run")
    assert(status.record.phase == "DRY_RUN_COMPLETED" and module_state.last_control_command_by_handle[10] == "abort")
    local started = publish(c, "apply", {path = "module"})
    assert(c:control("abort", {batch_id = started.batch_id}, 1).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c:control("status", {batch_id = started.batch_id}, 1).record.phase == "ABORTED")
    module_state.injected_control_failure = {handle = 10, command = "finish"}
    status = run()
    assert(status.recovery_required and status.record.phase == "RECOVERY_REQUIRED")
    assert(not c:control("apply", {path = "module"}, 1).ok)
    assert(not c:control("history", {}, 1).ok)
    -- 持有容量和只保留最近终态的合同，不能靠清空查询记录绕过恢复门禁。
    assert(c:control("status", {batch_id = "99:1"}, 1).code == "HU_BATCH_MISSING")
    -- 恢复命令只接受管理者明确确认，不发送目标状态 RPC 或替代实际恢复。
    assert(c.phase == "FAILED_LOCKED")
    assert(c:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_DEPLOYMENT_BLOCKED")
    assert(c:control("begin_module_load", {name = "late"}, 10).code == "HU_DEPLOYMENT_BLOCKED")
    assert(c:control("begin", {}, 1).code == "HU_DEPLOYMENT_BLOCKED")
    assert(c:control("resolve_deployment", {batch_id = c.last.batch_id, confirmed = true,
        confirmation = "UNCHANGED"}, 1).code == "HU_RECOVERY_CONFIRMATION_REQUIRED")
    module_state.last_control_command_by_handle = {}
    assert(c:control("resolve_deployment", {batch_id = c.last.batch_id, confirmed = true,
        confirmation = "CONVERGED_CACHE_CLEARED"}, 1).ok)
    assert(c.phase == "IDLE" and next(module_state.last_control_command_by_handle) == nil)

    local waiting = c
    module_state.launch_handle = 84
    assert(waiting:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
    local begun = waiting:control("begin", {}, 1)
    assert(begun.ok and waiting.phase == "WAITING_CREATIONS")
    assert(waiting:control("unknown_command", {path = "invalid"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:control("begin", {}, 1).code == "HU_UPGRADE_BUSY")
    assert(waiting:control("apply", {batch_id = begun.batch_id, path = "module"}, 1).code == "HU_LIFECYCLE_PENDING")
    assert(waiting:control("register", metadata, 84).ok and waiting.phase == "DEPLOYING")
    assert(waiting:control("unknown_command", {path = "invalid"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:control("apply", {batch_id = "stale", path = "module"}, 1).code == "HU_BATCH_MISSING")
    assert(waiting:control("resolve_deployment", {batch_id = begun.batch_id}, 1).code == "HU_RECOVERY_CONFIRMATION_REQUIRED")
    assert(waiting:control("resolve_deployment", {batch_id = begun.batch_id, confirmed = true, confirmation = "UNCHANGED"}, 1).ok)

    -- begin 同样等待既有模块许可；只有登记完成后才能固定升级目标。
    local allowed = waiting:control("begin_module_load", {name = "later"}, 84)
    assert(allowed.ok)
    local module_batch = waiting:control("begin", {}, 1)
    assert(module_batch.ok and waiting.phase == "WAITING_CREATIONS")
    assert(waiting:control("register_module", {name = "later", permit_id = allowed.permit_id}, 84).ok)
    assert(waiting.phase == "DEPLOYING")
    assert(waiting:control("dry_run", {batch_id = module_batch.batch_id, path = "module"}, 1).ok)
    assert(waiting:control("unknown_command", {path = "invalid"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:control("dry_run", {batch_id = module_batch.batch_id, path = "module"}, 1).code == "HU_DEPLOYMENT_PHASE")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.phase == "DRY_RUN_COMPLETED")

    -- 检查失败尚未改变文件/运行时，解除屏障并允许排队创建正常继续。
    local failed_batch = begin_deployment(waiting)
    local queued_creation
    module_state.launch_handle = 85
    local queued_waiter = coroutine.create(function()
        queued_creation = waiting:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    assert(coroutine.resume(queued_waiter) and queued_creation == nil)
    assert(waiting:control("apply", {batch_id = failed_batch, path = "unmatched_service"}, 1).code == "HU_TARGET_MISSING")
    assert(waiting.phase == "IDLE" and queued_creation.handle == 85)
    assert(waiting.last.error.code == "HU_TARGET_MISSING" and not waiting.last.control_started)
    assert(waiting:control("cancel_service_creation", {handle = 85}, 1).ok)

    -- preload 由原生启动处理；Controller 不拒绝、不改写目标名或启动参数。
    module_state.shared_environment.preload = "fixture_preload.lua"
    module_state.launch_handle = 89
    for _, command in ipairs({"newservice", "uniqueservice"}) do
        local created = waiting:control(command, {service_name = "fixture", arguments = table.pack("head", nil, "tail")}, 1)
        assert(created.handle == 89)
        local launch = module_state.launches[#module_state.launches]
        assert(launch.name == "fixture" and launch.arguments.n == 3 and launch.arguments[3] == "tail")
        assert(waiting:control("cancel_service_creation", {handle = 89}, 1).ok)
    end
    module_state.shared_environment.preload = nil
    print("HOTUPGRADE_CONTROLLER_DEPLOYMENT_OK")
end

scenarios['combined'] = function()
    local combined = initialize_controller()
    for _, handle in ipairs({30, 40}) do
        assert(managed_register(combined, {service_module = "player", modules = {"lualib.test_worker_logic"},
            service_patch = true}, handle).ok)
    end
    for _, command in ipairs({"dry_run", "apply"}) do
        local answer = publish(combined, command, {path = "combined"})
        assert(answer.ok and answer.target_count == 2)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        assert(combined.last.success == 2)
    end
end

scenarios['paths'] = function()
    local paths = initialize_controller()
    assert(managed_register(paths,
        {service_module = "battle.worker", modules = {"config.settings", "lualib.battle.state_sync.runtime", "lualib.packages.demo.init"},
            service_patch = true}, 50).ok)
    local loaded = paths:load({path = "host_paths"})
    assert(loaded.ok and #loaded.patch.modules == 3)
    assert(loaded.patch.modules[1].entry_file == "config/settings.lua")
    assert(loaded.patch.modules[2].name == "lualib.battle.state_sync.runtime")
    assert(paths:load({path = "nested_service"}).ok)

    for _, path in ipairs({"duplicate_module", "duplicate_service"}) do
        assert(paths:load({path = path}).code == "HU_INVALID_PATCH")
    end
end

scenarios['custom_paths'] = function()
    local changed = initialize_controller("actors")
    assert(managed_register(changed,
        {service_module = "zone.player", modules = {}, service_patch = true}, 60).ok)
    assert(changed:load({path = "custom_service"}).ok)
end

scenarios['unique'] = function()
    local unique = initialize_controller()
    local first_unique
    local second_unique
    local first_co = coroutine.create(function()
        first_unique = unique:control("uniqueservice", {service_name = "fixture", arguments = table.pack("first", nil, "last")}, 1)
    end)
    module_state.launch_hook = function() coroutine.yield() end
    local launch_count = #module_state.launches
    assert(coroutine.resume(first_co))
    local duplicate_co = coroutine.create(function()
        second_unique = unique:control("uniqueservice", {service_name = "fixture", arguments = table.pack("ignored")}, 2)
    end)
    assert(coroutine.resume(duplicate_co) and first_unique == nil and second_unique == nil)
    assert(#module_state.launches == launch_count + 1)
    local forwarded = module_state.launches[#module_state.launches].arguments
    assert(forwarded.n == 3 and forwarded[1] == "first" and forwarded[2] == nil and forwarded[3] == "last")
    module_state.launch_handle = 90
    module_state.launch_hook = nil
    assert(coroutine.resume(first_co))
    assert(first_unique.handle == 90 and second_unique.handle == 90 and unique.creation_count == 1)
    assert(unique:control("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1).handle == 90)
    assert(unique:control("cancel_service_creation", {handle = 90}, 2).code == "HU_UNAUTHORIZED")
    assert(unique:control("cancel_service_creation", {handle = 90}, 1).ok and not unique.unique_services.fixture)

    -- 在途失败让所有等待者返回同一错误，释放预留后允许重试。
    first_unique, second_unique = nil, nil
    module_state.launch_hook = function()
        coroutine.yield()
        error("startup failed")
    end
    first_co = coroutine.create(function()
        first_unique = unique:control("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    duplicate_co = coroutine.create(function()
        second_unique = unique:control("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 2)
    end)
    assert(coroutine.resume(first_co) and coroutine.resume(duplicate_co))
    assert(coroutine.resume(first_co))
    assert(first_unique.code == "HU_SERVICE_CREATE_FAILED" and second_unique.code == first_unique.code)
    assert(unique.creation_count == 0 and not unique.unique_services.fixture)
    module_state.launch_hook = nil
    module_state.launch_handle = 91
    assert(unique:control("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1).handle == 91)
    assert(unique:control("register", metadata, 91).ok)
    local unique_batch = begin_deployment(unique)
    assert(unique:control("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 2).handle == 91)
    local new_unique
    local unique_waiter = coroutine.create(function()
        new_unique = unique:control("uniqueservice", {service_name = "fixture_other", arguments = {n = 0}}, 2)
    end)
    launch_count = #module_state.launches
    assert(coroutine.resume(unique_waiter) and new_unique == nil and #module_state.launches == launch_count)
    module_state.launch_handle = 92
    assert(unique:control("dry_run", {batch_id = unique_batch, path = "missing"}, 1).code == "HU_PATCH_EMPTY")
    assert(unique.phase == "IDLE" and new_unique.handle == 92 and unique.creation_count == 1)
    assert(unique:control("cancel_service_creation", {handle = 92}, 2).ok)

    launch_count = #module_state.launches
    assert(unique:control("uniqueservice", {global = true}, 1).code == "HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED")
    for _, command in ipairs({"newservice", "uniqueservice"}) do
        assert(unique:control(command, {service_name = "snaxd", arguments = {n = 0}}, 1).code == "HU_SPECIAL_SERVICE_UNSUPPORTED")
    end
    assert(#module_state.launches == launch_count and unique.creation_count == 0)

    local dry = unique
    assert(managed_register(dry, metadata, 93).ok)
    local dry_id = begin_deployment(dry)
    assert(dry:control("dry_run", {batch_id = dry_id, path = "unmatched_service"}, 1).code == "HU_TARGET_MISSING")
    assert(dry.phase == "IDLE" and dry.last.error.code == "HU_TARGET_MISSING" and not dry.last.control_started)
    module_state.injected_control_failure = {handle = 93, command = "stage"}
    assert(publish(dry, "dry_run", {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(dry.phase == "IDLE" and dry.last.error.code == "HU_FIXTURE_FAILED")
    module_state.injected_control_failure = {handle = 93, command = "abort"}
    assert(publish(dry, "dry_run", {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(dry.phase == "FAILED_LOCKED" and dry.last.error.recovery_error.code == "HU_FIXTURE_FAILED")
    module_state.injected_control_failure = nil
    print("HOTUPGRADE_CONTROLLER_LOCAL_UNIQUE_OK")
end

scenarios['resources'] = function()
    local ordered = initialize_controller()
    for _, handle in ipairs({101, 102, 103}) do
        assert(managed_register(ordered, metadata, handle).ok)
    end
    module_state.operations = {}
    assert(publish(ordered, "apply", {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(table.concat(module_state.operations, ",") ==
        "101:prepare,102:prepare,103:prepare,101:stage,102:stage,103:stage,101:activate,102:activate,103:activate,file:lualib/test_worker_logic.lua,cache,101:finish,102:finish,103:finish")
    module_state.operations = {}
    local before_dry = module_state.file_contents["lualib/test_worker_logic.lua"]
    assert(publish(ordered, "dry_run", {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(table.concat(module_state.operations, ",") ==
        "101:prepare,102:prepare,103:prepare,101:stage,102:stage,103:stage,101:activate,102:activate,103:activate,103:abort,102:abort,101:abort")
    assert(module_state.file_contents["lualib/test_worker_logic.lua"] == before_dry)
    module_state.injected_control_failure = {handle = 102, command = "finish"}
    assert(publish(ordered, "apply", {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(ordered.phase == "FAILED_LOCKED" and ordered.last.success == 2 and ordered.last.failed == 1)
    assert(module_state.last_control_command_by_handle[101] == "finish"
        and module_state.last_control_command_by_handle[103] == "finish")
    module_state.injected_control_failure = nil
    assert(ordered:control("resolve_deployment", {batch_id = ordered.last.batch_id, confirmed = true,
        confirmation = "CONVERGED_CACHE_CLEARED"}, 1).ok)

    local deployment = ordered
    assert(managed_register(deployment, metadata, 104).ok)
    module_state.file_contents = {["lualib/test_worker_logic.lua"] = "old"}
    module_state.injected_file_failure = "service/z_blocked.lua"
    assert(publish(deployment, "apply", {path = "deploy_failure"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(deployment.phase == "IDLE" and deployment.last.phase == "ABORTED")
    assert(module_state.file_contents["lualib/test_worker_logic.lua"] == "old")
    assert(module_state.file_contents["lualib/a_added.lua"] == nil)
    assert(module_state.last_control_command_by_handle[104] == "abort")
    module_state.injected_file_failure = nil
    -- 文件准备和缓存清理失败均保留具体诊断；恢复失败才锁定。
    module_state.injected_read_failure = "lualib/test_worker_logic.lua"
    module_state.operations = {}
    local rejected_file = publish(deployment, "apply", {path = "module"})
    assert(rejected_file.code == "HU_FILE_READ_FAILED" and deployment.phase == "IDLE")
    assert(#module_state.operations == 0 and not deployment.last.control_started)
    module_state.injected_read_failure = nil
    module_state.file_contents = {["lualib/test_worker_logic.lua"] = "old"}
    module_state.cache_failures = 1
    assert(publish(deployment, "apply", {path = "module"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(deployment.phase == "IDLE" and deployment.last.error.code == "HU_CACHE_CLEAR_FAILED")
    assert(module_state.file_contents["lualib/test_worker_logic.lua"] == "old")

    module_state.injected_file_failure = "service/z_blocked.lua"
    module_state.injected_restore_failure = true
    assert(publish(deployment, "apply", {path = "deploy_failure"}).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(deployment.phase == "FAILED_LOCKED" and deployment.recovery_required)
    assert(deployment.last.error.original_error.code == "HU_FILE_DEPLOY_FAILED")
    assert(deployment.last.error.recovery_error.code == "HU_FILE_DEPLOY_FAILED")
    module_state.injected_restore_failure = false
    module_state.injected_file_failure = nil
    local files_only = deployment
    local started_files = publish(files_only, "apply", {path = "service_file"})
    assert(started_files.ok and started_files.target_count == 0)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(files_only.last.phase == "COMPLETED" and module_state.file_contents["service/new_service.lua"])

    -- 保留移除固定容量上限前的边界验证；各目标仍属于同一模块级 Controller。
    local module_names = {}
    for index = 1, 1025 do
        module_names[index] = "logic_" .. index
    end
    assert(managed_register(deployment,
        {service_module = "empty", modules = module_names, service_patch = false}, 20000).ok)
    assert(register_module(deployment, "beyond_previous_limit", 20000).ok)
    for handle = 10000, 11024 do
        assert(managed_register(deployment,
            {service_module = "empty", modules = {}, service_patch = false}, handle).ok)
    end
    print("HOTUPGRADE_CONTROLLER_RESOURCE_OK")
end

local run = assert(scenarios[scenario], "未知 Controller 测试场景: " .. scenario)
run()
print("HOTUPGRADE_CONTROLLER_SCENARIO_OK " .. scenario)
