--- 只模拟控制面消息编排；目标 State 的真实提交由 Skynet 集成覆盖。
local hotupgrade_common = require "flywow_hotupgrade_common"
local module_state =
{
    pending_control_coroutines     = {},    -- 测试替身排队的 Controller 控制面协程。
    last_control_command_by_handle = {},    -- 各目标最近收到的控制步骤。
    shared_environment             = {},    -- 模拟 Skynet 跨 State 的只写一次环境。
    launch_handle                  = nil,   -- 原生创建替身将返回的真实 handle。
    launch_hook                    = nil,   -- 在原生创建尚未返回时注入登记或启动失败。
    launches                       = {},    -- 记录实际进入原生创建的逻辑名和完整参数。
    killed                         = {},    -- 验证只有创建者取消时才终止对应待登记 Service。
    injected_patch_read_failure    = nil,   -- 包扫描后文件消失或读取失败的诊断。
    injected_read_failure          = nil,   -- 文件准备失败时不得开始运行时更新。
    injected_restore_failure       = false, -- 旧文件回写失败时必须锁定并保留错误。
    cache_failures                 = 0,     -- 缓存清理替身连续失败次数。
    file_contents                  = {},    -- Native 替身的正式文件，验证部署和恢复是否发生。
    operations                     = {},    -- 按时间记录目标协议、文件写入和缓存清理。
    injected_file_failure          = nil,   -- 指定写入失败的相对文件名。
    control_hook                   = nil,   -- 在目标 RPC 中暂停协调协程，验证运行中取消。
    injected_control_failure       = nil,   -- 当前测试注入的目标和命令失败条件。
}
package.loaded.skynet =
{
    cache = {clear = function()
        module_state.operations[#module_state.operations + 1] = "cache"
        if module_state.cache_failures > 0 then
            module_state.cache_failures = module_state.cache_failures - 1
            error("injected cache clear failure")
        end
    end},
    getenv = function(key) return module_state.shared_environment[key] end,
    setenv = function(key, value) module_state.shared_environment[key] = value end,
    self = function() return 99 end,
    newservice = function(name, ...)
        module_state.launches[#module_state.launches + 1] = {name = name, arguments = table.pack(...)}
        if module_state.launch_hook then
            module_state.launch_hook(...)
        end
        return module_state.launch_handle
    end,
    wait = function() coroutine.yield() end,
    wakeup = function(co) assert(coroutine.resume(co)) end,
    kill = function(handle) module_state.killed[handle] = true end,
    fork = function(fn)
        local co = coroutine.create(fn)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines + 1] = function()
            local ok, message = coroutine.resume(co)
            assert(ok, message)
        end
    end,
    call = function(handle, protocol, command, request)
        assert(protocol == "hotupgrade" and request.sequence > 0)
        module_state.operations[#module_state.operations + 1] = handle .. ":" .. command
        module_state.last_control_command_by_handle[handle] = command
        if module_state.control_hook then
            module_state.control_hook(handle, command)
        end
        if module_state.injected_control_failure and module_state.injected_control_failure.handle == handle and module_state.injected_control_failure.command == command then
            if module_state.injected_control_failure.unknown then
                error("injected RPC result unknown")
            end
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
    read_file = function(_root, path)
        if _root:find("/patches", 1, true) then
            if module_state.injected_patch_read_failure == "missing" then
                return false
            elseif module_state.injected_patch_read_failure == "error" then
                return nil, {code = "HU_FILE_READ_FAILED"}
            end
            local file = io.open(_root .. "/" .. path, "rb")
            if not file then return false end
            local source = file:read("*a")
            file:close()
            return source
        end
        if path == module_state.injected_read_failure then
            return nil, {code = "HU_FILE_READ_FAILED"}
        end
        return module_state.file_contents[path] or false
    end,
    replace_file = function(_root, path, source)
        module_state.operations[#module_state.operations + 1] = "file:" .. path
        if path == module_state.injected_file_failure
            or (module_state.injected_restore_failure and source == "old") then
            return nil, {code = "HU_FILE_DEPLOY_FAILED"}
        end
        module_state.file_contents[path] = source
        return true
    end,
    list_lua = function(_root, path)
        local files =
        {
            module = {"lualib/test_worker_logic.lua"},
            service_file = {"service/new_service.lua"},
            deploy_failure = {"lualib/a_added.lua", "lualib/test_worker_logic.lua", "service/z_blocked.lua"},
            combined = {"lualib/test_worker_logic.lua", "service/skynet_hotupgrade_worker.patch"},
            unmatched_module = {"lualib/test_worker_logic.lua", "lualib/missing_logic.lua"},
            unmatched_service = {"lualib/test_worker_logic.lua", "service/unused.patch"},
            host_paths = {"config/settings.lua", "lualib/battle/state_sync/runtime.lua",
                "lualib/packages/demo/init.lua"},
            nested_named_service = {"service/battle/worker.patch"},
            custom_named_service = {"actors/zone/player.patch"},
            duplicate_module = {"lualib/battle.worker.lua", "lualib/battle/worker.lua"},
            duplicate_service = {"service/battle.worker.patch", "service/battle/worker.patch"},
        }
        return files[path], {code = "HU_PATCH_EMPTY"}
    end,
}
local controller = require "flywow_hotupgrade_controller"
local function initialize_controller(service_path)
    local initialized = controller.initialize(
    {
        patch_path = "build/hotupgrade-tests/patches",
        root_path = "build/hotupgrade-tests/host",
        service_path = service_path or "service",
    })
    assert(initialized.ok, initialized.message)
    return controller
end
local function begin_deployment(instance, path, dry_run)
    local begun = instance:handle_command("begin", {path = path, dry_run = dry_run}, 1)
    assert(begun.ok)
    return begun.batch_id
end

local function publish(instance, dry_run, request)
    if instance.phase == "FAILED_LOCKED" then
        assert(instance:handle_command("resolve_deployment", {batch_id = instance.last_batch.batch_id,
            confirmed = true, confirmation = "CONVERGED_CACHE_CLEARED"}, 1).ok)
    end
    return instance:handle_command("begin", {path = request.path, dry_run = dry_run}, 1)
end

local function managed_register(instance, metadata, handle, service_name)
    service_name = service_name or "skynet_hotupgrade_worker"
    module_state.launch_handle = handle
    local created = instance:handle_command("newservice", {service_name = service_name, arguments = {n = 0}}, 1)
    if not created.ok then
        return created
    end
    assert(instance.creation_handles[handle].service_name == service_name)
    local registered = instance:handle_command("register", metadata, handle)
    if registered.ok then
        assert(instance.targets[handle].service_name == service_name)
    end
    return registered
end

local function register_module(instance, name, handle)
    local allowed = instance:handle_command("begin_module_load", {name = name}, handle)
    if not allowed.ok then
        return allowed
    end
    return instance:handle_command("register_module", {name = name, permit_id = allowed.permit_id}, handle)
end

local metadata = {modules = {"lualib.test_worker_logic"}, service_patch = false}

return
{
    module_state = module_state,
    controller = controller,
    metadata = metadata,
    initialize_controller = initialize_controller,
    begin_deployment = begin_deployment,
    publish = publish,
    managed_register = managed_register,
    register_module = register_module,
}
