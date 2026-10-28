-- 每个场景由独立 Lua 进程运行，因此 Controller 模块只初始化一次。
local fixture = require "test_controller_fixture" -- 提供 Controller 替身、共享状态和发布/登记辅助函数。
local module_state = fixture.module_state -- 测试替身的注入点与操作记录，供场景检查调用顺序。
local controller = fixture.controller -- 共享 Controller 模块表，所有场景在独立进程内复用。
local metadata = fixture.metadata -- Worker 首次登记时提交的模块名和 Service 更新能力。
local initialize_controller = fixture.initialize_controller -- 按测试配置初始化共享 Controller。
local begin_deployment = fixture.begin_deployment -- 启动测试发布并返回 batch_id。
local publish = fixture.publish -- 发送 begin 管理命令并返回受理结果。
local managed_register = fixture.managed_register -- 通过受管理创建和真实 source 完成目标登记。
local register_module = fixture.register_module -- 通过许可协议向 Controller 登记普通模块。
local scenario = assert(arg[1], "需要测试场景名") -- 命令行选择本次独立运行的 Controller 场景。

local function lifecycle_status(controller)
    return controller:handle_command("status", {}, 1).value.lifecycle
end

local scenarios = {} -- 场景名到测试函数的映射，文件末尾只运行指定的一项。

scenarios["interleaved"] = function()
    -- 本场景 Controller；交错两次创建和多来源登记都由它协调。
    local interleaved = initialize_controller()
    -- 按创建者 source 保存各自的 newservice 返回结果。
    local created_by_owner = {}
    -- 按登记消息 source 保存早到登记的结果，区分真实创建 handle。
    local registered_by_source = {}
    -- 两个创建者协程的句柄，测试各自创建记录不会互相解除。
    local creators = {}
    module_state.launch_hook = function() coroutine.yield() end
    for owner = 1, 2 do
        creators[owner] = coroutine.create(function()
            created_by_owner[owner] = interleaved:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, owner)
        end)
        assert(coroutine.resume(creators[owner]))
    end
    for _, source in ipairs({72, 73, 74}) do
        -- 等待指定 source 的 register 协程；创建返回后才应完成。
        local waiter = coroutine.create(function() -- 等待批次或许可结束的协程。
            registered_by_source[source] = interleaved:handle_command("register", metadata, source)
        end)
        assert(coroutine.resume(waiter))
    end
    -- Service 创建还未返回 handle 时启动批次；该批次应等待创建完成，再决定是否继续。
    local waiting_batch = interleaved:handle_command("begin", {path = "module"}, 1)
    assert(waiting_batch.ok and lifecycle_status(interleaved).phase == "WAITING_CREATIONS")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    module_state.launch_service_handle = 73
    assert(coroutine.resume(creators[2]))
    assert(registered_by_source[73].ok and not registered_by_source[72] and not registered_by_source[74])
    assert(lifecycle_status(interleaved).pending_service_count == 1 and lifecycle_status(interleaved).phase == "WAITING_CREATIONS")
    module_state.launch_service_handle = 72
    assert(coroutine.resume(creators[1]))
    assert(registered_by_source[72].ok and registered_by_source[74].code == "HU_CREATION_MISSING")
    assert(lifecycle_status(interleaved).phase == "COMPLETED" and lifecycle_status(interleaved).pending_service_count == 0)
    assert(next(interleaved.service_creations) == nil and next(interleaved.service_registration_waiters) == nil)
    module_state.launch_hook = nil
end

-- 原生创建已返回但业务尚未登记时，未知来源不能继续等这条业务登记。
scenarios["creation_returned"] = function()
    -- 创建返回/登记竞态场景使用的 Controller。
    local instance = initialize_controller()
    -- 原生创建请求最终结果；与业务 register 是否完成分开观察。
    local created -- 原生创建返回结果；与业务 register 的完成时间分开观察。
    -- 该来源没有对应的受管理创建记录；newservice 返回并完成 handle 索引后，register 必须立即以 HU_CREATION_MISSING 失败。
    local unknown -- 未知来源 register 的结果；handle 索引完成后应返回 HU_CREATION_MISSING，不再等待业务登记。
    module_state.launch_hook = function() coroutine.yield() end
    -- 模拟原始创建者的协程句柄。
    local creator = coroutine.create(function()
        created = instance:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    -- 模拟未知来源登记请求的协程句柄。
    local registrar = coroutine.create(function()
        unknown = instance:handle_command("register", metadata, 902)
    end)
    assert(coroutine.resume(creator))
    assert(coroutine.resume(registrar) and unknown == nil)
    instance:on_service_exit(903)
    assert(instance.early_exit_handles[903])

    -- handle 901 已返回但不登记：902 必须结束等待，903 的早退记录也不再可能匹配后续返回。
    module_state.launch_service_handle = 901
    assert(coroutine.resume(creator))
    module_state.launch_hook = nil
    assert(created.ok and lifecycle_status(instance).pending_service_count == 1)
    assert(unknown and unknown.code == "HU_CREATION_MISSING")
    assert(coroutine.status(registrar) == "dead")
    assert(next(instance.early_exit_handles) == nil)
    instance:on_service_exit(904)
    assert(next(instance.early_exit_handles) == nil)
    assert(instance:handle_command("register", metadata, 901).ok)

    -- 当前创建自身早退仍须匹配；退出记录处理完后才能清理剩余记录。
    module_state.launch_service_handle = 905
    module_state.launch_hook = function()
        instance:on_service_exit(905)
        instance:on_service_exit(906)
    end
    -- 在原生创建期间收到退出通知后的创建结果。
    local exited = instance:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    module_state.launch_hook = nil
    assert(exited.code == "HU_SERVICE_EXITED")
    assert(lifecycle_status(instance).pending_service_count == 0 and next(instance.early_exit_handles) == nil)
end

scenarios['lifecycle'] = function()
    -- 退出通知和许可清理场景共用的 Controller。
    local lifecycle = initialize_controller() -- 当前创建/加载门禁视图。
    -- 原生退出通知移除登记与加载许可；重复通知不会重复清理记录。
    assert(managed_register(lifecycle, metadata, 61).ok)
    -- Service 61 的在途模块许可；随后模拟 Service 退出消费它。
    local permit = lifecycle:handle_command("begin_module_load", {name = "lualib.exit_pending"}, 61) -- Controller 发给首次模块加载方的许可结果；后续登记必须携带其中的 permit_id。
    assert(permit.ok and lifecycle_status(lifecycle).pending_module_count == 1)
    assert(lifecycle.service_registrations[61].loading_modules["lualib.exit_pending"] == permit.value.permit_id)
    lifecycle:on_service_exit(61)
    assert(lifecycle.service_registrations[61] == nil)
    assert(lifecycle_status(lifecycle).pending_module_count == 0 and next(lifecycle.module_load_permits) == nil)
    lifecycle:on_service_exit(61)
    lifecycle:on_service_exit(999)
    assert(lifecycle_status(lifecycle).pending_module_count == 0 and lifecycle_status(lifecycle).pending_service_count == 0)

    -- 退出只删除匹配 handle 的唯一实例；保留批次快照并记录失败。
    assert(managed_register(lifecycle, metadata, 62).ok)
    lifecycle.unique_service_entries.fixture = {service_handle = 62}
    lifecycle.unique_service_entries.other = {service_handle = 63}
    -- 本批 Prepare 中的 Service 目标记录，用于观察退出后仍保留目标诊断。
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
    -- 目标更新时退出场景的发布受理结果。
    local begun_exit = lifecycle:handle_command("begin", {path = "module"}, 1)
    assert(begun_exit.ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(lifecycle).phase == "IDLE" and lifecycle.last_batch.phase == "RECOVERY_REQUIRED")
    lifecycle:on_service_exit(62)
    assert(lifecycle_status(lifecycle).phase == "IDLE" and lifecycle.service_registrations[62] == nil)
    module_state.control_hook = nil
    module_state.injected_control_failure = nil

    -- 非法 Service 名称请求前的原生创建次数；拒绝请求后必须不变。
    local launches_before_invalid_names = #module_state.launches
    for _, service_name in ipairs({"../fixture", "fixture//worker", "fixture/../worker", "/fixture"}) do
        for _, command in ipairs({"newservice", "uniqueservice"}) do
            -- 对非法 Service 名发出的 newservice/uniqueservice 拒绝结果。
            local rejected = lifecycle:handle_command(command, -- 查询指定批次得到的错误对象，验证失败码和诊断信息。
                {service_name = service_name, arguments = {n = 0}}, 1)
            assert(rejected.code == "HU_INVALID_REQUEST")
        end
    end
    assert(#module_state.launches == launches_before_invalid_names)
    module_state.launch_service_handle = 68
    -- 合法嵌套 Service 名创建结果；检查路径名按原值传给原生创建。
    local nested_creation = lifecycle:handle_command("newservice",
        {service_name = "battle/worker", arguments = {n = 0}}, 1)
    assert(nested_creation.ok and module_state.launches[#module_state.launches].name == "battle/worker")
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 68}, 1).ok)

    --- 尝试多个未知管理命令，并确认它们不创建批次或控制协程。
    ---@param instance table 本场景初始化的 Controller；本函数尝试多个不支持的管理命令并检查状态未改变。
local function blocked(instance)
        for _, command in ipairs({"unknown_command", "validate", "apply"}) do
            -- 未知命令处理前已排队的目标控制协程数，确认它没有启动控制步骤。
            local calls = #module_state.pending_control_coroutines
            module_state.last_control_command_by_service_handle = {}
            -- 未知命令的 Controller 结果，预期不触发 RPC 协程。
            local answer = instance:handle_command(command, {path = "module"}, 1) -- begin 请求的受理结果；测试继续推进对应后台批次。
            -- 未知管理命令的稳定错误码。
            local expected = "HU_UNKNOWN_COMMAND"
            assert(answer.code == expected and answer.value == nil)
            assert(#module_state.pending_control_coroutines == calls)
            assert(next(module_state.last_control_command_by_service_handle) == nil and not instance.active)
        end
    end

    -- 登记先到时协程挂起；只有原生返回的 Service handle 能解除等待，未知来源不能借用创建。
    module_state.launch_hook = function() coroutine.yield() end
    -- 原生返回前登记场景中创建者最终取得的结果。
    local early_created
    -- 登记先到场景中首个相同 handle 的登记结果。
    local early_registered
    -- 同一 handle 的重复 register 结果，只有一项登记应成功。
    local duplicate_registered
    -- 没有匹配创建记录的 source 的登记结果。
    local unknown_registered
    -- 先启动并让出原生创建调用的协程。
    local early_create = coroutine.create(function()
        early_created = lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    -- 提前发送合法 source register 并等待创建 handle 匹配的协程。
    local early_register = coroutine.create(function()
        early_registered = lifecycle:handle_command("register", metadata, 70)
    end)
    -- 并发重复登记相同 source 的协程。
    local duplicate_register = coroutine.create(function()
        duplicate_registered = lifecycle:handle_command("register", metadata, 70)
    end)
    -- 用未知 source 发起登记的协程。
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
    assert(early_created.value.service_handle == 70)
    assert((early_registered.ok and duplicate_registered.code == "HU_DUPLICATE_SERVICE")
        or (duplicate_registered.ok and early_registered.code == "HU_DUPLICATE_SERVICE"))
    assert(unknown_registered.code == "HU_CREATION_MISSING")
    assert(lifecycle_status(lifecycle).pending_service_count == 0 and lifecycle.service_registrations[70] and next(lifecycle.service_registration_waiters) == nil)
    -- 直接调用 load_patch 所需的测试批次输入；返回匹配后的目标列表。
    local batch = {patch_dir = "module"} -- 仅用于直接测试 load_patch 的批次输入，路径对应待测发布包。
    assert(lifecycle:load_patch(batch).ok and #batch.service_targets == 1)
    assert(lifecycle:handle_command("unknown_command", {path = "module"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 70}, 1).code == "HU_SERVICE_ALREADY_REGISTERED")

    -- 原生返回早于登记；显式取消、初始化失败和创建失败均不留记录。
    module_state.launch_service_handle = 80
    assert(lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).value.service_handle == 80)
    blocked(lifecycle)
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 80}, 1).code == "HU_UNAUTHORIZED")
    assert(not module_state.killed[80] and lifecycle_status(lifecycle).pending_service_count == 1)
    assert(lifecycle:handle_command("register", metadata, 80).ok and lifecycle_status(lifecycle).pending_service_count == 0)
    assert(lifecycle:handle_command("register", metadata, 81).code == "HU_CREATION_MISSING")
    -- 原生失败唤醒早到登记并释放记录，失败的来源不会进入 targets。
    -- 原生创建失败时早到 register 的返回结果。
    local failed_registration
    module_state.launch_hook = function()
        -- 等待待创建 Worker 的早到登记协程。
        local waiter = coroutine.create(function() -- 等待批次或许可结束的协程。
            failed_registration = lifecycle:handle_command("register", metadata, 81)
        end)
        assert(coroutine.resume(waiter) and failed_registration == nil)
        error("startup failed")
    end
    assert(lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_SERVICE_CREATE_FAILED")
    assert(failed_registration.code == "HU_CREATION_MISSING")
    assert(lifecycle_status(lifecycle).pending_service_count == 0 and not lifecycle.service_registrations[81] and next(lifecycle.service_registration_waiters) == nil)
    module_state.launch_hook = nil
    module_state.launch_service_handle = 82
    assert(lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).ok)
    assert(lifecycle:handle_command("register", {}, 82).code == "HU_INVALID_OPTIONS")
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 82}, 2).ok)
    assert(module_state.killed[82] and lifecycle_status(lifecycle).pending_service_count == 0)
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 82}, 2).code == "HU_CREATION_MISSING")

    local permit = lifecycle:handle_command("begin_module_load", {name = "extra"}, 70) -- Controller 发给首次模块加载方的许可结果；后续登记必须携带其中的 permit_id。
    assert(permit.ok)
    assert(lifecycle.service_registrations[70].loading_modules.extra == permit.value.permit_id)
    assert(lifecycle:handle_command("begin_module_load", {name = "extra"}, 70).code == "HU_MODULE_LOADING")
    blocked(lifecycle)
    local request = {name = "extra", permit_id = permit.value.permit_id} -- 提交给注册命令的模块名和许可编号；本测试用它验证登记通过后队列被唤醒。
    assert(lifecycle:handle_command("register_module", request, 80).code == "HU_UNAUTHORIZED")
    assert(lifecycle:handle_command("register_module", {name = "wrong", permit_id = permit.value.permit_id}, 70).code == "HU_MODULE_PERMIT_MISMATCH")
    assert(lifecycle_status(lifecycle).pending_module_count == 1)
    assert(lifecycle:handle_command("register_module", request, 70).ok and lifecycle_status(lifecycle).pending_module_count == 0)
    assert(lifecycle.service_registrations[70].loading_modules.extra == nil)
    assert(lifecycle.module_load_permits[permit.value.permit_id] == nil)
    assert(lifecycle:handle_command("register_module", request, 70).code == "HU_MODULE_PERMIT_MISSING")
    permit = lifecycle:handle_command("begin_module_load", {name = "cancelled"}, 70)
    assert(lifecycle:handle_command("cancel_module_load", {name = "cancelled", permit_id = permit.value.permit_id}, 70).ok)
    assert(lifecycle_status(lifecycle).pending_module_count == 0 and not lifecycle.service_registrations[70].modules.cancelled)
    assert(lifecycle.service_registrations[70].loading_modules.cancelled == nil)
    assert(lifecycle.module_load_permits[permit.value.permit_id] == nil)
    assert(lifecycle:handle_command("begin_module_load", {name = "extra"}, 90).code == "HU_SERVICE_NOT_REGISTERED")
    local started_lifecycle = publish(lifecycle, {path = "module"}) -- 本批 begin 的受理结果；其 batch_id 用于构造本批新模块登记请求。
    assert(started_lifecycle.ok)
    -- 只有 Update 起关闭门禁；在真实 Update 调用中挂起，验证后来的请求等待且不计数。
    module_state.control_hook = function(service_handle, command)
        if service_handle == 70 and command == "update" then coroutine.yield() end
    end
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle.active_batch.phase == "UPDATE")
    local new_module_request = {batch_id = started_lifecycle.value.batch_id, name = "lualib.new_rules"} -- 本批新增模块的登记请求；包含批次身份和模块名。
    assert(lifecycle:handle_command("register_new_module", new_module_request, 71).code == "HU_NEW_MODULE_NOT_ALLOWED")
    assert(lifecycle:handle_command("register_new_module", {batch_id = "stale", name = new_module_request.name}, 70).code
        == "HU_NEW_MODULE_NOT_ALLOWED")
    assert(lifecycle:handle_command("register_new_module", new_module_request, 70).ok)
    assert(lifecycle:handle_command("register_new_module", new_module_request, 70).ok)
    assert(lifecycle.service_registrations[70].modules[new_module_request.name])
    local queued_result -- 协程被唤醒后保存的许可/登记结果，供主测试断言。
    local queued = coroutine.create(function() -- 模拟并发调用许可接口的协程，测试批次开始后是否按合同等待。
        queued_result = lifecycle:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    end)
    module_state.launch_service_handle = 83
    assert(coroutine.resume(queued) and queued_result == nil)
    assert(lifecycle_status(lifecycle).pending_service_count == 0)
    assert(lifecycle:handle_command("register", metadata, 90).code == "HU_CREATION_MISSING")
    local queued_module -- 模块加载许可等待协程恢复后的结果。
    local module_waiter = coroutine.create(function() -- 等待模块许可的第二个协程，用于验证同名加载不会错误放行。
        queued_module = lifecycle:handle_command("begin_module_load", {name = "late"}, 70)
    end)
    assert(coroutine.resume(module_waiter) and queued_module == nil)
    local view = lifecycle:handle_command("status", {}, 1).value.lifecycle -- status 返回的生命周期视图，检查等待中的创建和加载数量。
    assert(view.pending_service_count == 0 and view.pending_module_count == 0 and view.active_batch_id == started_lifecycle.value.batch_id)
    module_state.control_hook = nil
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(queued_module.ok and lifecycle_status(lifecycle).pending_module_count == 1)
    assert(lifecycle:handle_command("register_module", {name = "late", permit_id = queued_module.value.permit_id}, 70).ok)
    assert(queued_result.ok and queued_result.value.service_handle == 83)
    assert(lifecycle:handle_command("cancel_service_creation", {service_handle = 83}, 1).ok)
    assert(lifecycle:handle_command("register_new_module", new_module_request, 70).code == "HU_NEW_MODULE_NOT_ALLOWED")
    assert(lifecycle:handle_command("status", {batch_id = "unknown"}, 1).code == "HU_BATCH_MISSING")
    print("HOTUPGRADE_CONTROLLER_LIFECYCLE_OK")
end

scenarios['matching'] = function()
    assert(not controller.initialize({}).ok)
    local c = initialize_controller() -- 本段测试使用的 Controller 单例，后续所有命令都发给它。
    module_state.launch_service_handle = 9
    local named_creation = c:handle_command("newservice", -- 带嵌套 Service 名和启动参数的创建结果，验证参数会原样转发。
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
    local batch = {patch_dir = "module"} -- 仅用于直接测试 load_patch 的批次输入，路径对应待测发布包。
    assert(c:load_patch(batch).ok and #batch.service_targets == 2)
    -- 未登记模块只部署；一次性 Service .patch 仍须匹配。
    local unmatched = {patch_dir = "unmatched_module"}
    assert(c:load_patch(unmatched).ok and #unmatched.service_targets == 2 and #unmatched.files == 2)
    module_state.last_control_command_by_service_handle = {}
    local accepted = publish(c, {path = "unmatched_service"}) -- begin 接受发布后的结果，包含后续查询所需的 batch_id。
    assert(accepted.ok and accepted.value.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    local rejected = c:handle_command("status", {batch_id = accepted.value.batch_id}, 1).value.record.error -- 查询指定批次得到的错误对象，验证失败码和诊断信息。
    assert(rejected.code == "HU_TARGET_MISSING" and rejected.message:find("service/unused.patch", 1, true))
    assert(next(module_state.last_control_command_by_service_handle) == nil and lifecycle_status(c).phase == "IDLE")
    assert(c.last_batch.phase == "ABORTED")
    -- 同一模块仍可匹配多个 Service，组合包中的 Service 脚本也必须覆盖所有目标。

    local unsupported = c:load_patch({patch_dir = "combined"}) -- 直接调用 load_patch 得到的协议拒绝结果。
    assert(unsupported.code == "HU_SERVICE_PATCH_UNSUPPORTED")
    assert(unsupported.message:find("combined/service/skynet_hotupgrade_worker.patch", 1, true))

    --- 发布普通模块并手动推进替身协程，返回该批终态记录。
    local function publish_and_complete_module_batch()
        local answer = publish(c, {path = "module"}) -- begin 请求的受理结果；测试继续推进对应后台批次。
        assert(answer.ok)
        assert(not c:handle_command("apply", {path = "module"}, 1).ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        return c:handle_command("status", {batch_id = answer.value.batch_id}, 1)
    end
    local status = publish_and_complete_module_batch() -- Controller status 返回的批次视图，用来断言阶段和目标结果。
    assert(status.value.record.phase == "COMPLETED" and status.value.record.succeeded_service_count == 2
        and status.value.record.target_service_count == 2 and #status.value.record.service_results == 2
        and module_state.last_control_command_by_service_handle[20] == "finish")
    module_state.injected_control_failure = {service_handle = 20, command = "update"}
    status = publish_and_complete_module_batch()
    assert(status.value.record.phase == "ABORTED" and status.value.record.succeeded_service_count == 0
        and status.value.record.failed_service_count == 2 and #status.value.record.service_results == 2)
    assert(lifecycle_status(c).phase == "IDLE" and module_state.last_control_command_by_service_handle[10] == "abort")
    assert(module_state.last_control_command_by_service_handle[20] == "abort")
    module_state.injected_control_failure = nil
    module_state.operations = {}
    local started = publish(c, {path = "module"}) -- 开始执行的批次受理结果；后续用于验证管理端 abort 被拒绝。
    module_state.control_hook = function(_handle, command)
        if command == "prepare" then coroutine.yield() end
    end
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(lifecycle_status(c).phase == "APPLYING" and #module_state.operations == 1)
    assert(module_state.operations[1] == "10:prepare")
    local active_before_abort = c.active_batch -- 管理端 abort 前仍在运行的批次记录，确认拒绝请求没有改变它。
    assert(c:handle_command("abort", {batch_id = started.value.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(c.active_batch == active_before_abort and #module_state.operations == 1)
    module_state.control_hook = function(_handle, command)
        assert(command == "prepare" or command == "update" or command == "finish")
        assert(c:handle_command("abort", {batch_id = started.value.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
        assert(c.active_batch == active_before_abort)
    end
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c:handle_command("status", {batch_id = started.value.batch_id}, 1).value.record.phase == "COMPLETED")
    assert(table.concat(module_state.operations, ",") == "10:prepare,20:prepare,file:lualib/test_worker_logic.lua,cache,10:update,20:update,10:finish,20:finish")
    assert(c:handle_command("abort", {batch_id = started.value.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    module_state.control_hook = nil
    module_state.injected_control_failure = {service_handle = 10, command = "finish"}
    status = publish_and_complete_module_batch()
    assert(status.value.recovery_required and status.value.record.phase == "RECOVERY_REQUIRED")
    assert(not c:handle_command("apply", {path = "module"}, 1).ok)
    assert(not c:handle_command("history", {}, 1).ok)
    -- 仅保留活动批次和最近终态；更早批次不能继续查询。
    assert(c:handle_command("status", {batch_id = "99:1"}, 1).code == "HU_BATCH_MISSING")
    -- 恢复失败仅报告，不再阻止创建、声明和下一批发布。
    assert(lifecycle_status(c).phase == "IDLE")
    local allowed_after_failure = c:handle_command("begin_module_load", {name = "late"}, 10) -- 恢复失败后申请下一次模块加载许可的结果；应仍可获准。
    assert(allowed_after_failure.ok)
    assert(c:handle_command("cancel_module_load", {name = "late", permit_id = allowed_after_failure.value.permit_id}, 10).ok)
    module_state.injected_control_failure = nil

    local waiting = c -- 正在等待 Service 创建或模块加载完成的 Controller，用于测试入口门禁。
    module_state.launch_service_handle = 84
    assert(waiting:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
    local begun = waiting:handle_command("begin", {path = "module"}, 1) -- 等待期间提交的批次受理结果；用于检查是否暂缓开始。
    assert(begun.ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    assert(waiting:handle_command("begin", {path = "module"}, 1).code == "HU_UPGRADE_BUSY")
    assert(waiting:handle_command("unknown_command", {}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:handle_command("register", metadata, 84).ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    assert(waiting:handle_command("abort", {batch_id = "stale"}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting:handle_command("abort", {batch_id = begun.value.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting.active_batch.batch_id == begun.value.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.last_batch.phase == "COMPLETED")

    -- 管理端不能取消批次；创建者仍可取消未登记 Service，使排空自然完成。
    module_state.launch_service_handle = 86
    local pending_creation = waiting:handle_command("newservice", -- 批次等待时新 Service 创建请求的结果。
        {service_name = "fixture", arguments = {n = 0}}, 1)
    assert(pending_creation.ok)
    local pending_batch = waiting:handle_command("begin", {path = "module"}, 1) -- 有创建仍在途时提交的批次受理结果。
    assert(pending_batch.ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.active_batch.waiter)
    assert(waiting:handle_command("abort", {batch_id = pending_batch.value.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(waiting.active_batch.batch_id == pending_batch.value.batch_id and lifecycle_status(waiting).pending_service_count == 1)
    assert(waiting:handle_command("cancel_service_creation", {service_handle = 86}, 1).ok)
    assert(waiting.last_batch.phase == "COMPLETED" and lifecycle_status(waiting).pending_service_count == 0)

    local allowed = waiting:handle_command("begin_module_load", {name = "later"}, 84) -- 生命周期窗口开放时模块首次加载许可的结果。
    assert(allowed.ok)
    local module_batch = waiting:handle_command("begin", {path = "module"}, 1) -- 等待许可后启动的批次，用于确认排队工作已继续。
    assert(module_batch.ok and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(waiting.active_batch.waiter and lifecycle_status(waiting).phase == "WAITING_CREATIONS")
    assert(waiting:handle_command("register_module", {name = "later", permit_id = allowed.value.permit_id}, 84).ok)
    assert(lifecycle_status(waiting).phase == "COMPLETED")

    -- begin 后仍接纳创建；完成登记后才能进行整包检查，失败前没有目标控制命令。
    local failed_batch = begin_deployment(waiting, "unmatched_service")
    module_state.launch_service_handle = 85
    local admitted_creation = waiting:handle_command("newservice", -- 门禁重新开放后新的 Service 创建结果。
        {service_name = "fixture", arguments = {n = 0}}, 1)
    assert(admitted_creation.value.service_handle == 85 and lifecycle_status(waiting).pending_service_count == 1)
    assert(waiting:handle_command("register", metadata, 85).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    local failed = waiting:handle_command("status", {batch_id = failed_batch}, 1) -- 失败批次的查询结果，供后续确认错误和状态。
    assert(failed.value.record.error.code == "HU_TARGET_MISSING")
    assert(lifecycle_status(waiting).phase == "IDLE" and waiting.service_registrations[85])

    -- preload 由原生启动处理；Controller 不拒绝、不改写目标名或启动参数。
    module_state.shared_environment.preload = "fixture_preload.lua"
    module_state.launch_service_handle = 89
    for _, command in ipairs({"newservice", "uniqueservice"}) do
        local created = waiting:handle_command(command, {service_name = "fixture", arguments = table.pack("head", nil, "tail")}, 1) -- 传给测试命令的 Service 创建结果。
        assert(created.value.service_handle == 89)
        local launch = module_state.launches[#module_state.launches] -- Native 创建替身最近记录的启动名与完整位置参数。
        assert(launch.name == "fixture" and launch.arguments.n == 3 and launch.arguments[3] == "tail")
        assert(waiting:handle_command("cancel_service_creation", {service_handle = 89}, 1).ok)
    end
    module_state.shared_environment.preload = nil
    print("HOTUPGRADE_CONTROLLER_DEPLOYMENT_OK")
end

scenarios['combined'] = function()
    local combined = initialize_controller() -- 包含模块与 Service 更新的 Controller 实例。
    for _, service_handle in ipairs({30, 40}) do
        assert(managed_register(combined, {modules = {"lualib.test_worker_logic"},
            has_service_update = true}, service_handle).ok)
    end
    local answer = publish(combined, {path = "combined"}) -- begin 请求的受理结果；测试继续推进对应后台批次。
    assert(answer.ok and answer.value.batch_id)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    local status = combined:handle_command("status", {batch_id = combined.last_batch.batch_id}, 1).value.record -- Controller status 返回的批次视图，用来断言阶段和目标结果。
    assert(status.succeeded_service_count == 2 and status.target_service_count == 2)
end

scenarios['paths'] = function()
    local paths = initialize_controller() -- 以特殊 service_path 初始化的 Controller，用于验证路径映射。
    assert(managed_register(paths,
        {modules = {"config.settings", "lualib.battle.state_sync.runtime", "lualib.packages.demo.init"},
            has_service_update = true}, 50, "battle/worker").ok)
    local batch = {patch_dir = "host_paths"} -- 仅用于直接测试 load_patch 的批次输入，路径对应待测发布包。
    assert(paths:load_patch(batch).ok and #batch.modules == 3)
    assert(batch.files[1].host_relative_path == "config/settings.lua")
    assert(batch.modules[1].name == "config.settings")
    for _, module_patch in ipairs(batch.modules) do
        for key in pairs(module_patch) do
            assert(key == "name" or key == "source")
        end
    end
    assert(batch.modules[2].name == "lualib.battle.state_sync.runtime")
    local nested_batch = {patch_dir = "nested_named_service"} -- 含 service/battle/worker.patch 的本批目标记录。
    assert(paths:load_patch(nested_batch).ok)
    assert(nested_batch.service_patches["battle/worker"].patch_relative_path == "service/battle/worker.patch")

    for _, path in ipairs({"duplicate_module", "duplicate_service"}) do
        assert(paths:load_patch({patch_dir = path}).code == "HU_INVALID_PATCH")
    end
    local zero = paths:handle_command("begin", {path = "module"}, 1) -- 空目标批次的 begin 返回值，确认无目标时直接完成。
    assert(paths:handle_command("status", {batch_id = zero.value.batch_id}, 1).value.record.target_service_count == 0)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(paths.last_batch.service_targets == nil)
    assert(paths:handle_command("status", {batch_id = zero.value.batch_id}, 1).value.record.target_service_count == 0)

end

scenarios['custom_paths'] = function()
    local changed = initialize_controller("actors") -- service_path 为 actors 的 Controller，用于核对自定义 Service 目录。
    assert(managed_register(changed,
        {modules = {}, has_service_update = true}, 60, "zone/player").ok)
    assert(changed:load_patch({patch_dir = "custom_named_service"}).ok)
end

scenarios['unique'] = function()
    local unique = initialize_controller() -- 当前唯一 Service 并发创建场景的 Controller。
    local first_unique -- 第一条 uniqueservice 请求的完成结果。
    local second_unique -- 重复 uniqueservice 请求得到的结果，应复用同一 Service handle。
    local first_co = coroutine.create(function() -- 先发起唯一 Service 创建的协程。
        first_unique = unique:handle_command("uniqueservice", {service_name = "fixture", arguments = table.pack("first", nil, "last")}, 1)
    end)
    module_state.launch_hook = function() coroutine.yield() end
    local launch_count = #module_state.launches -- 重复请求开始前 Native 创建调用数，用于确认仅创建一次。
    assert(coroutine.resume(first_co))
    local duplicate_co = coroutine.create(function() -- 并发重复请求协程，应等待第一次创建并返回同一 handle。
        second_unique = unique:handle_command("uniqueservice", {service_name = "fixture", arguments = table.pack("ignored")}, 2)
    end)
    assert(coroutine.resume(duplicate_co) and first_unique == nil and second_unique == nil)
    assert(#module_state.launches == launch_count + 1)
    local forwarded = module_state.launches[#module_state.launches].arguments -- Native 替身收到的启动参数，验证 nil 参数位置没有丢失。
    assert(forwarded.n == 3 and forwarded[1] == "first" and forwarded[2] == nil and forwarded[3] == "last")
    module_state.launch_service_handle = 90
    module_state.launch_hook = nil
    assert(coroutine.resume(first_co))
    assert(first_unique.value.service_handle == 90 and second_unique.value.service_handle == 90 and lifecycle_status(unique).pending_service_count == 1)
    assert(unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1).value.service_handle == 90)
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
    assert(lifecycle_status(unique).pending_service_count == 0 and not unique.unique_service_entries.fixture)
    module_state.launch_hook = nil
    module_state.launch_service_handle = 91
    assert(unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 1).value.service_handle == 91)
    assert(unique:handle_command("register", metadata, 91).ok)
    local unique_batch = begin_deployment(unique, "missing") -- 没有匹配目标的唯一 Service 批次身份。
    assert(unique:handle_command("uniqueservice", {service_name = "fixture", arguments = {n = 0}}, 2).value.service_handle == 91)
    local new_unique -- 新唯一 Service 请求在批次期间等待后的返回结果。
    local unique_waiter = coroutine.create(function() -- 批次期间等待唯一 Service 创建完成的协程。
        new_unique = unique:handle_command("uniqueservice", {service_name = "fixture_other", arguments = {n = 0}}, 2)
    end)
    launch_count = #module_state.launches
    module_state.launch_service_handle = 92
    assert(coroutine.resume(unique_waiter) and new_unique.value.service_handle == 92)
    assert(#module_state.launches == launch_count + 1 and lifecycle_status(unique).pending_service_count == 1)
    assert(unique:handle_command("cancel_service_creation", {service_handle = 92}, 2).ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(unique:handle_command("status", {batch_id = unique_batch}, 1).value.record.error.code == "HU_PATCH_EMPTY")
    assert(lifecycle_status(unique).phase == "IDLE" and lifecycle_status(unique).pending_service_count == 0)

    launch_count = #module_state.launches
    assert(unique:handle_command("uniqueservice", {global = true}, 1).code == "HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED")
    for _, command in ipairs({"newservice", "uniqueservice"}) do
        assert(unique:handle_command(command, {service_name = "snaxd", arguments = {n = 0}}, 1).code == "HU_SPECIAL_SERVICE_UNSUPPORTED")
    end
    assert(#module_state.launches == launch_count and lifecycle_status(unique).pending_service_count == 0)

    assert(managed_register(unique, metadata, 93).ok)
    local failed_id = begin_deployment(unique, "unmatched_service") -- 无法匹配目标的失败批次身份。
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(unique:handle_command("status", {batch_id = failed_id}, 1).value.record.error.code == "HU_TARGET_MISSING")
    assert(lifecycle_status(unique).phase == "IDLE" and unique.last_batch.error.code == "HU_TARGET_MISSING")
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
    assert(lifecycle_status(unique).phase == "IDLE" and unique.last_batch.error.details.recovery_error.code == "HU_FIXTURE_FAILED")
    module_state.control_hook = nil
    module_state.injected_control_failure = nil
    print("HOTUPGRADE_CONTROLLER_LOCAL_UNIQUE_OK")
end

-- 逐轮补齐创建记录和模块声明；每批只读取一次源码，旧目标不重复 Prepare。
scenarios['draining'] = function()
    local c = initialize_controller() -- 本段测试使用的 Controller 单例，后续所有命令都发给它。
    assert(managed_register(c, metadata, 10).ok)
    assert(managed_register(c, {modules = {}, has_service_update = false}, 20).ok)
    local native = require "flywow_hotupgrade_native" -- 替换文件扫描函数的 Native 测试模块。
    local original_list = native.list_lua -- 保存的真实扫描函数，测试结束后恢复。
    local scans = 0 -- 文件扫描调用次数，用于确认批次只读取一次文件列表。
    native.list_lua = function(...)
        scans = scans + 1
        return original_list(...)
    end
    local queued_unique = {} -- 批次开始后排队的唯一 Service 请求记录。
    local queued_permit -- 在批次过程中等待的模块许可结果。
    local launches_at_update -- 第一个 Update 发生时的创建调用数，验证部署前入口关闭。
    local prepared_service_target -- Prepare 和后续 Update 必须沿用同一个目标记录。
    module_state.control_hook = function(service_handle, command, request)
        if command == "prepare" and service_handle == 10 then
            assert(c.active_batch.phase == "PREPARE")
            assert(c.active_batch.target_service_count == nil)
            assert(c:handle_command("status", {batch_id = c.active_batch.batch_id}, 1).value.record.target_service_count == #c.active_batch.service_targets)
            prepared_service_target = c.active_batch.service_targets[1]
            assert(managed_register(c, metadata, 30).ok)
            assert(managed_register(c, {modules = {}, has_service_update = false}, 31, "unaffected").ok)
            assert(register_module(c, "lualib.hotupgrade_extra", 10).ok)
            assert(register_module(c, "lualib.hotupgrade_extra", 20).ok)
        elseif command == "prepare" and service_handle == 30 then
            assert(c:handle_command("status", {batch_id = c.active_batch.batch_id}, 1).value.record.target_service_count == 3)
            module_state.launch_service_handle = 40
            assert(c:handle_command("uniqueservice",
                {service_name = "child", arguments = {n = 0}}, 30).value.service_handle == 40)
            assert(c:handle_command("register", metadata, 40).ok)
        elseif command == "update" and service_handle == 10 then
            assert(c.active_batch.service_targets[1] == prepared_service_target)
            assert(#request.modules == 2 and lifecycle_status(c).pending_service_count == 0 and lifecycle_status(c).pending_module_count == 0)
            for _, module_patch in ipairs(request.modules) do
                assert(module_patch.old_source == nil and module_patch.touched == nil)
            end
            launches_at_update = #module_state.launches
            for index = 1, 2 do
                local waiter = coroutine.create(function() -- 等待批次或许可结束的协程。
                    queued_unique[index] = c:handle_command("uniqueservice",
                        {service_name = "late", arguments = {n = 0}}, 10)
                end)
                assert(coroutine.resume(waiter) and not queued_unique[index])
            end
            local waiter = coroutine.create(function() -- 等待批次或许可结束的协程。
                queued_permit = c:handle_command("begin_module_load", {name = "late"}, 10)
            end)
            assert(coroutine.resume(waiter) and queued_permit == nil)
            assert(c.unique_service_entries.late == nil and #module_state.launches == launches_at_update)
            module_state.launch_service_handle = 50
        end
    end
    local id = begin_deployment(c, "draining") -- 当前批次身份，用于状态查询和取消尝试。
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.last_batch.batch_id == id and c.last_batch.phase == "COMPLETED")
    local status = c:handle_command("status", {batch_id = id}, 1).value.record -- Controller status 返回的批次视图，用来断言阶段和目标结果。
    assert(status.target_service_count == 4 and status.succeeded_service_count == 4 and scans == 1)
    assert(c.last_batch.service_targets == nil and c.last_batch.target_service_count == 4)
    local prepares = {} -- 记录每个目标 Prepare 操作的序列，验证目标进入顺序。
    for _, operation in ipairs(module_state.operations) do
        local service_handle = operation:match("^(%d+):prepare$") -- 从目标协议记录中提取的 Service handle。
        if service_handle then prepares[service_handle] = (prepares[service_handle] or 0) + 1 end
    end
    for _, service_handle in ipairs({10, 20, 30, 40}) do
        assert(prepares[tostring(service_handle)] == 1)
    end
    assert(not prepares["31"] and queued_unique[1].value.service_handle == 50
        and queued_unique[2].value.service_handle == 50)
    assert(#module_state.launches == launches_at_update + 1 and queued_permit.ok)
    assert(c:handle_command("register_module",
        {name = "late", permit_id = queued_permit.value.permit_id}, 10).ok)
    assert(c:handle_command("cancel_service_creation", {service_handle = 50}, 10).ok)
    assert(lifecycle_status(c).pending_service_count == 0 and lifecycle_status(c).pending_module_count == 0 and next(c.lifecycle_gate_waiters) == nil)
end

scenarios['drain_abort_rejected'] = function()
    local c = initialize_controller() -- 本段测试使用的 Controller 单例，后续所有命令都发给它。
    assert(managed_register(c, metadata, 10).ok)
    module_state.control_hook = function(service_handle, command)
        if service_handle == 10 and command == "prepare" then
            module_state.launch_service_handle = 30
            assert(c:handle_command("newservice", {service_name = "child", arguments = {n = 0}}, 10).ok)
        end
    end
    local id = begin_deployment(c, "module") -- 当前批次身份，用于状态查询和取消尝试。
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.active_batch.phase == "PREPARE" and c.active_batch.waiter and lifecycle_status(c).pending_service_count == 1)
    local active_before_abort = c.active_batch -- 管理端 abort 前仍在运行的批次记录，确认拒绝请求没有改变它。
    assert(c:handle_command("abort", {batch_id = id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(c.active_batch == active_before_abort and lifecycle_status(c).pending_service_count == 1)
    assert(table.concat(module_state.operations, ",") == "10:prepare")
    assert(c:handle_command("cancel_service_creation", {service_handle = 30}, 10).ok)
    assert(c.last_batch.phase == "COMPLETED" and lifecycle_status(c).pending_service_count == 0)
    assert(table.concat(module_state.operations, ",") == "10:prepare,file:lualib/test_worker_logic.lua,cache,10:update,10:finish")
end

scenarios['drain_unsupported'] = function()
    local c = initialize_controller() -- 本段测试使用的 Controller 单例，后续所有命令都发给它。
    assert(managed_register(c, {modules = metadata.modules, has_service_update = true}, 10).ok)
    module_state.control_hook = function(service_handle, command)
        if service_handle == 10 and command == "prepare" then
            assert(managed_register(c, metadata, 30).ok)
        end
    end
    local id = begin_deployment(c, "combined") -- 当前批次身份，用于状态查询和取消尝试。
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(c.last_batch.batch_id == id and c.last_batch.error.code == "HU_SERVICE_PATCH_UNSUPPORTED")
    assert(c.last_batch.phase == "ABORTED" and lifecycle_status(c).phase == "IDLE")
    assert(table.concat(module_state.operations, ",") == "10:prepare,10:abort")
end

scenarios['drain_new_failure'] = function()
    local c = initialize_controller() -- 本段测试使用的 Controller 单例，后续所有命令都发给它。
    assert(managed_register(c, metadata, 10).ok)
    module_state.control_hook = function(service_handle, command)
        if service_handle == 10 and command == "prepare" then
            assert(managed_register(c, metadata, 30).ok)
            module_state.injected_control_failure = {service_handle = 30, command = "prepare"}
        end
    end
    begin_deployment(c, "module")
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    local status = c:handle_command("status", {batch_id = c.last_batch.batch_id}, 1).value.record -- Controller status 返回的批次视图，用来断言阶段和目标结果。
    assert(status.phase == "ABORTED" and status.failed_service_count == 2)
    assert(table.concat(module_state.operations, ",") == "10:prepare,30:prepare,30:abort,10:abort")
end

scenarios['resources'] = function()
    local ordered = initialize_controller() -- 记录 Controller 文件部署、缓存清理和 Update 次序的测试实例。
    for _, service_handle in ipairs({101, 102, 103}) do
        assert(managed_register(ordered, metadata, service_handle).ok)
    end
    -- 扫描到文件后 Native 返回 false/nil 均异步失败；均不得触及目标。
    for _, failure in ipairs({"missing", "error"}) do
        module_state.injected_patch_read_failure = failure
        module_state.operations = {}
        local accepted = publish(ordered, {path = "module"}) -- begin 接受发布后的结果，包含后续查询所需的 batch_id。
        assert(accepted.ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        local record = ordered:handle_command("status", {batch_id = accepted.value.batch_id}, 1).value.record -- 本批 status 返回的结果记录，包含目标数、错误和终态。
        assert(record.phase == "ABORTED" and #module_state.operations == 0)
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
    local before_failure = module_state.file_contents["lualib/test_worker_logic.lua"] -- 部署失败前正式 Lua 文件内容的快照，恢复后需与它一致。
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
                local lifecycle = lifecycle_status(ordered) -- 当前创建/加载门禁视图。
                assert(lifecycle.phase == "APPLYING" and lifecycle.recovery_required)
            end
        end
        assert(publish(ordered, {path = "module"}).ok)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        local status = ordered:handle_command("status", {batch_id = ordered.last_batch.batch_id}, 1).value.record -- Controller status 返回的批次视图，用来断言阶段和目标结果。
        assert(lifecycle_status(ordered).phase == "IDLE" and status.succeeded_service_count == 2 and status.failed_service_count == 1)
        assert(table.concat(module_state.operations, ",") ==
            "101:prepare,102:prepare,103:prepare,file:lualib/test_worker_logic.lua,cache,101:update,102:update,103:update,101:finish,102:finish,103:finish")
        assert(module_state.file_contents["lualib/test_worker_logic.lua"])
        module_state.injected_control_failure = nil
        module_state.control_hook = nil
    end

    local deployment = ordered -- 用于逐项注入正式文件部署故障的 Controller。
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
    local rejected_file = publish(deployment, {path = "module"}) -- 注入文件写入失败后 begin 的返回结果。
    assert(rejected_file.ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    assert(deployment.last_batch.error.code == "HU_FILE_READ_FAILED" and lifecycle_status(deployment).phase == "IDLE")
    assert(#module_state.operations == 0)
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
    assert(deployment.last_batch.error.details.original_error.code == "HU_FILE_DEPLOY_FAILED")
    assert(deployment.last_batch.error.details.recovery_error.code == "HU_FILE_DEPLOY_FAILED")
    module_state.injected_restore_failure = false
    module_state.injected_file_failure = nil
    local files_only = deployment -- 只有正式文件部署、不匹配业务模块的 Controller 场景。
    local started_files = publish(files_only, {path = "service_file"}) -- 只部署正式文件批次的受理结果。
    assert(started_files.ok and started_files.value.batch_id)
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

local run_test_scenario = assert(scenarios[scenario], "未知 Controller 测试场景: " .. scenario) -- 从命令行场景名解析出的测试函数；最后统一执行并报告结果。
run_test_scenario()
print("HOTUPGRADE_CONTROLLER_SCENARIO_OK " .. scenario)
