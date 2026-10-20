--- 只模拟控制面消息编排；目标 State 的真实提交由 Skynet 集成覆盖。
local hotupgrade_common = require "flywow_hotupgrade_common"
local module_state =
{
    pending_control_coroutines = {}, -- 测试替身排队的 Controller 控制面协程。
    last_control_command_by_handle = {}, -- 各目标最近收到的控制步骤。
    shared_environment = {}, -- 模拟 Skynet 跨 State 的只写一次环境。
    launch_handle = nil, -- 原生创建替身将返回的真实 handle。
    launch_hook = nil, -- 在原生创建尚未返回时注入登记或启动失败。
    release_hook = nil, -- 在远端唯一服务终止 RPC 中模拟到达的登记消息。
    recovery_pending = false, -- 模拟仍持有目标 Guard。
    killed = {}, -- 验证只有创建者取消时才终止对应待登记 Service。
    injected_control_failure = nil, -- 当前测试注入的目标和命令失败条件。
}
package.loaded.skynet =
{
    getenv = function(key) return module_state.shared_environment[key] end,
    setenv = function(key, value) module_state.shared_environment[key] = value end,
    self = function() return 99 end,
    newservice = function(name, controller_handle, creation_id, service_name, ...)
        assert(name == "flywow_hotupgrade_bootstrap" and controller_handle == 99 and service_name == "fixture")
        if module_state.launch_hook then
            module_state.launch_hook(creation_id, ...)
        end
        return module_state.launch_handle
    end,
    wait = function() coroutine.yield() end,
    wakeup = function(co) assert(coroutine.resume(co)) end,
    kill = function(handle) module_state.killed[handle] = true end,
    fork = function(fn) module_state.pending_control_coroutines[#module_state.pending_control_coroutines + 1] = fn end,
    call = function(handle, protocol, command, request)
        if handle == ".service" and command == "MANAGED_RELEASE" then
            assert(protocol == "lua" and module_state.release_hook)
            module_state.release_hook()
            return true
        end
        if command == "deployment_status" then
            return {ok = true, pending = module_state.recovery_pending}
        end
        assert(protocol == "hotupgrade" and request.sequence > 0)
        module_state.last_control_command_by_handle[handle] = command
        if module_state.injected_control_failure and module_state.injected_control_failure.handle == handle and module_state.injected_control_failure.command == command then
            return {ok = false, code = "HU_FIXTURE_FAILED", message = command}
        end
        return {ok = true}
    end,
}
package.loaded["skynet.manager"] = true
-- 独立 Lua 不导出 Skynet 的 allocator 符号；真实 Native 由 test_files 在 Skynet 内覆盖。
package.loaded.flywow_hotupgrade_native =
{
    resolve = function(path, relative)
        return relative and path .. "/" .. relative or (path:gsub("/%.$", ""))
    end,
    list_lua = function(_root, path)
        local files =
        {
            module = {"lualib/test_worker_logic.lua"},
            combined = {"lualib/test_worker_logic.lua", "service/player.lua"},
            unmatched_module = {"lualib/test_worker_logic.lua", "lualib/missing_logic.lua"},
            unmatched_service = {"lualib/test_worker_logic.lua", "service/unused.lua"},
            host_paths = {"config/settings.lua", "lualib/battle/state_sync/runtime.lua",
                "lualib/packages/demo/init.lua"},
            nested_service = {"service/battle/worker.lua"},
            custom_service = {"actors/zone/player.lua"},
            duplicate_module = {"lualib/battle.worker.lua", "lualib/battle/worker.lua"},
            duplicate_service = {"service/battle.worker.lua", "service/battle/worker.lua"},
        }
        return files[path], {code = "HU_PATCH_EMPTY"}
    end,
}
local controller = require "flywow_hotupgrade_controller"
local function new_controller(service_dir)
    return assert(controller.new(
    {
        patch_root = "build/hotupgrade-tests/patches",
        root_path = "build/hotupgrade-tests/host",
        service_dir = service_dir or "service",
    }).controller)
end
local function begin_deployment(instance)
    local begun = instance:control("begin", {}, 1)
    assert(begun.ok)
    module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
    return begun.batch_id
end

local function publish(instance, command, request)
    if instance.phase == "FAILED_LOCKED" then
        assert(instance:control("resolve_deployment", {batch_id = instance.last.batch_id,
            confirmed = true, confirmation = "CONVERGED_CACHE_CLEARED"}, 1).ok)
    end
    request.batch_id = begin_deployment(instance)
    return instance:control(command, request, 1)
end

local function managed_register(instance, metadata, handle)
    module_state.launch_handle = handle
    local created = instance:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
    if not created.ok then
        return created
    end
    return instance:control("register", metadata, handle)
end

local function register_module(instance, name, handle)
    local allowed = instance:control("begin_module_load", {name = name}, handle)
    if not allowed.ok then
        return allowed
    end
    return instance:control("register_module", {name = name, permit_id = allowed.permit_id}, handle)
end

local metadata = {service_module = "player", modules = {"lualib.test_worker_logic"}, service_patch = false}
local lifecycle = new_controller()
local function blocked(instance)
    for _, command in ipairs({"validate", "dry_run", "apply"}) do
        local sequence = instance.sequence
        local calls = #module_state.pending_control_coroutines
        module_state.last_control_command_by_handle = {}
        local answer = instance:control(command, {path = "module"}, 1)
        assert(answer.code == (command == "validate" and "HU_LIFECYCLE_PENDING" or "HU_BATCH_MISSING") and answer.batch_id == nil)
        assert(instance.sequence == sequence and #module_state.pending_control_coroutines == calls)
        assert(next(module_state.last_control_command_by_handle) == nil and not instance.active)
    end
end

-- 原生调用挂起期间用内部创建身份关联早到登记；目标 handle 只取消息头，拒绝未知来源。
module_state.launch_handle = 70
module_state.launch_hook = function(creation_id)
    blocked(lifecycle)
    local early_metadata = {service_module = metadata.service_module, modules = metadata.modules,
        service_patch = metadata.service_patch, creation_id = creation_id}
    assert(lifecycle:control("register", metadata, 71).code == "HU_CREATION_MISSING")
    assert(lifecycle:control("register", early_metadata, 70).ok)
    assert(lifecycle:control("register", early_metadata, 70).code == "HU_DUPLICATE_SERVICE")
    blocked(lifecycle) -- 登记已完成，原生启动尚未返回仍持有屏障。
end
assert(lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).handle == 70)
module_state.launch_hook = nil
assert(lifecycle.creation_count == 0 and lifecycle.targets[70])
assert(lifecycle:control("validate", {path = "module"}, 1).ok)
assert(lifecycle:control("cancel_service_creation", {handle = 70}, 1).code == "HU_SERVICE_ALREADY_REGISTERED")

-- 原生返回早于登记；显式取消、初始化失败和创建失败均不留记录。
module_state.launch_handle = 80
assert(lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 2).handle == 80)
blocked(lifecycle)
assert(lifecycle:control("cancel_service_creation", {handle = 80}, 1).code == "HU_UNAUTHORIZED")
assert(not module_state.killed[80] and lifecycle.creation_count == 1)
assert(lifecycle:control("register", {service_module = "player", modules = {}, service_patch = false,
    creation_id = "foreign"}, 80).code == "HU_CREATION_MISSING")
assert(lifecycle:control("register", metadata, 80).ok and lifecycle.creation_count == 0)
assert(lifecycle:control("register", metadata, 81).code == "HU_CREATION_MISSING")
for _, early_register in ipairs({false, true}) do
    module_state.launch_handle = 81
    module_state.launch_hook = function(creation_id)
        if early_register then
            local early_metadata = {service_module = metadata.service_module, modules = metadata.modules,
                service_patch = metadata.service_patch, creation_id = creation_id}
            assert(lifecycle:control("register", early_metadata, 81).ok)
        end
        error("startup failed")
    end
    assert(lifecycle:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_SERVICE_CREATE_FAILED")
    assert(lifecycle.creation_count == 0 and not lifecycle.targets[81])
end
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
assert(lifecycle:control("begin_module_load", {name = "late"}, 70).code == "HU_UPGRADE_BUSY")
local view = lifecycle:control("status", {}, 1).lifecycle
assert(view.pending_creations == 0 and view.pending_module_loads == 0 and view.active_batch_id == started_lifecycle.batch_id)
module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
assert(queued_result.ok and queued_result.handle == 83)
assert(lifecycle:control("cancel_service_creation", {handle = 83}, 1).ok)
assert(lifecycle:control("status", {batch_id = "unknown"}, 1).code == "HU_BATCH_MISSING")
print("HOTUPGRADE_CONTROLLER_LIFECYCLE_OK")

assert(not controller.new({}).ok)
local c = new_controller()
for _, handle in ipairs({10, 20}) do
    assert(managed_register(c, {service_module = "player", modules = {"lualib.test_worker_logic"},
        service_patch = false}, handle).ok)
end
assert(c:control("register", {service_module = "player", modules = {}, service_patch = false}, 10).code == "HU_DUPLICATE_SERVICE")
assert(register_module(c, "extra", 10).ok)
assert(not register_module(c, "extra", 30).ok)
assert(not c:control("validate", {path = "module", selector = {percent = 0.5}}, 1).ok)
assert(c:control("validate", {path = "module"}, 1).target_count == 2)
-- 三种入口必须在整包匹配失败时拒绝启动，连 prepare 都不能发给已匹配目标。
for _, fixture in ipairs({
    {path = "unmatched_module", file = "lualib/missing_logic.lua", reason = "声明模块"},
    {path = "unmatched_service", file = "service/unused.lua", reason = "service_module"},
}) do
    for _, command in ipairs({"validate", "dry_run", "apply"}) do
        module_state.last_control_command_by_handle = {}
        local pending_count = #module_state.pending_control_coroutines
        local sequence = c.sequence
        local rejected = command == "validate" and c:control(command, {path = fixture.path}, 1)
            or publish(c, command, {path = fixture.path})
        assert(not rejected.ok and rejected.code == "HU_TARGET_MISSING")
        assert(rejected.message:find(fixture.path .. "/" .. fixture.file, 1, true))
        assert(rejected.message:find(fixture.reason, 1, true))
        assert(next(module_state.last_control_command_by_handle) == nil and not c.active)
        if c.phase == "FAILED_LOCKED" then
            assert(c:control("resolve_deployment", {batch_id = c.last.batch_id,
                confirmed = true, confirmation = "CONVERGED_CACHE_CLEARED"}, 1).ok)
        end
    end
end
-- 同一模块仍可匹配多个 Service，组合包中的 Service 脚本也必须被覆盖。
local combined = new_controller()
for _, handle in ipairs({30, 40}) do
    assert(managed_register(combined, {service_module = "player", modules = {"lualib.test_worker_logic"},
        service_patch = true}, handle).ok)
end
for _, command in ipairs({"validate", "dry_run", "apply"}) do
    local answer = command == "validate" and combined:control(command, {path = "combined"}, 1)
        or publish(combined, command, {path = "combined"})
    assert(answer.target_count == 2)
    if command ~= "validate" then
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
        assert(combined.last.success == 2)
    end
end
local unsupported = c:control("validate", {path = "combined"}, 1)
assert(unsupported.code == "HU_SERVICE_PATCH_UNSUPPORTED")
assert(unsupported.message:find("combined/service/player.lua", 1, true))
-- 路径映射保留宿主目录前缀，Service 目录可更换并支持多级类型名。
local paths = new_controller()
assert(managed_register(paths,
    {service_module = "battle.worker", modules = {"config.settings", "lualib.battle.state_sync.runtime", "lualib.packages.demo.init"},
        service_patch = true}, 50).ok)
local loaded = paths:load({path = "host_paths"})
assert(loaded.ok and #loaded.patch.modules == 3)
assert(loaded.patch.modules[1].entry_file == "config/settings.lua")
assert(loaded.patch.modules[2].name == "lualib.battle.state_sync.runtime")
assert(paths:control("validate", {path = "nested_service"}, 1).ok)
local changed = new_controller("actors")
assert(managed_register(changed,
    {service_module = "zone.player", modules = {}, service_patch = true}, 60).ok)
assert(changed:control("validate", {path = "custom_service"}, 1).ok)
for _, path in ipairs({"duplicate_module", "duplicate_service"}) do
    assert(paths:control("validate", {path = path}, 1).code == "HU_INVALID_PATCH")
end
print("HOTUPGRADE_CONTROLLER_PATHS_OK")

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
assert(status.record.phase == "PARTIAL" and status.record.success == 1 and status.record.failed == 1)
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
-- 失败门禁与恢复核验：宿主确认不能越过尚未恢复的目标 Guard。
assert(c.phase == "FAILED_LOCKED")
assert(c:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_DEPLOYMENT_BLOCKED")
assert(c:control("begin", {}, 1).code == "HU_DEPLOYMENT_BLOCKED")
local recovery = {batch_id = c.last.batch_id, confirmed = true, confirmation = "CONVERGED_CACHE_CLEARED"}
module_state.recovery_pending = true
assert(c:control("resolve_deployment", recovery, 1).code == "HU_RECOVERY_REQUIRED")
module_state.recovery_pending = false
assert(c:control("resolve_deployment", recovery, 1).ok and c.phase == "IDLE")

local waiting = new_controller()
module_state.launch_handle = 84
assert(waiting:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
local begun = waiting:control("begin", {}, 1)
assert(begun.ok and waiting.phase == "WAITING_CREATIONS")
assert(waiting:control("begin", {}, 1).code == "HU_UPGRADE_BUSY")
assert(waiting:control("apply", {batch_id = begun.batch_id, path = "module"}, 1).code == "HU_LIFECYCLE_PENDING")
assert(waiting:control("register", metadata, 84).ok and waiting.phase == "DEPLOYING")
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
assert(waiting:control("dry_run", {batch_id = module_batch.batch_id, path = "module"}, 1).code == "HU_DEPLOYMENT_PHASE")
module_state.pending_control_coroutines[#module_state.pending_control_coroutines]()
assert(waiting.phase == "DRY_RUN_COMPLETED")

-- 部署后校验失败也锁定；排队者必须收到失败，不能静默重试启动。
local failed_batch = begin_deployment(waiting)
local denied_creation
local denied_waiter = coroutine.create(function()
    denied_creation = waiting:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1)
end)
assert(coroutine.resume(denied_waiter) and denied_creation == nil)
assert(waiting:control("apply", {batch_id = failed_batch, path = "unmatched_module"}, 1).code == "HU_TARGET_MISSING")
assert(waiting.phase == "FAILED_LOCKED" and denied_creation.code == "HU_DEPLOYMENT_BLOCKED")
assert(waiting:control("resolve_deployment", {batch_id = failed_batch, confirmed = true,
    confirmation = "CONVERGED_CACHE_CLEARED"}, 1).ok)

-- 远端唯一服务取消在 yield 前占有取消状态，迟到登记不得变成已登记死目标。
module_state.launch_handle = 85
assert(waiting:control("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
waiting.creation_handles[85].unique_name = "fixture"
module_state.release_hook = function()
    assert(waiting:control("register", metadata, 85).code == "HU_CREATION_CANCELLED")
    assert(waiting.creation_count == 1 and not waiting.targets[85])
end
assert(waiting:control("cancel_service_creation", {handle = 85}, 1).ok)
assert(waiting.creation_count == 0 and not waiting.targets[85])
module_state.release_hook = nil

-- preload 拒绝早于实际启动及创建计数；测试环境可直接撤销共享环境替身。
module_state.shared_environment.preload = "fixture_preload.lua"
module_state.launch_hook = function() error("preload must reject before native launch") end
for _, command in ipairs({"newservice", "uniqueservice"}) do
    assert(waiting:control(command, {service_name = "fixture", arguments = {n = 0}}, 1).code == "HU_PRELOAD_UNSUPPORTED")
    assert(waiting.creation_count == 0)
end
module_state.launch_hook = nil
module_state.shared_environment.preload = nil
print("HOTUPGRADE_CONTROLLER_DEPLOYMENT_OK")

local bounded = new_controller()
for handle = 1, hotupgrade_common.MAX_TARGETS do
    assert(managed_register(bounded, {service_module = "empty", modules = {}, service_patch = false}, handle).ok)
end
assert(managed_register(bounded, {service_module = "empty", modules = {}, service_patch = false}, hotupgrade_common.MAX_TARGETS + 1).code
    == "HU_TARGET_LIMIT")
local names = {}
for index = 1, hotupgrade_common.MAX_MODULES do
    names[index] = "logic_" .. index
end
local limited = new_controller()
assert(managed_register(limited, {service_module = "empty", modules = names, service_patch = false}, 1).ok)
assert(register_module(limited, names[1], 1).ok)
assert(register_module(limited, "overflow", 1).code == "HU_MODULE_LIMIT")
print("HOTUPGRADE_CONTROLLER_OK")
