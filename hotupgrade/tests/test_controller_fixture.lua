--- 只模拟控制面消息编排；目标 State 的真实提交由 Skynet 集成覆盖。
local hotupgrade_common = require "flywow_hotupgrade_common"
local module_state = -- 集中保存 Controller 替身的注入开关、模拟正式文件和调用顺序；只供单元测试使用。
{
    pending_control_coroutines     = {},    -- 测试替身排队的 Controller 控制面协程。
    last_control_command_by_service_handle = {},    -- 各目标最近收到的控制步骤。
    shared_environment             = {},    -- 模拟 Skynet 跨 State 的只写一次环境。
    launch_service_handle                  = nil,   -- 原生创建替身将返回的真实 Service handle。
    launch_hook                    = nil,   -- 在原生创建尚未返回时注入登记或启动失败。
    launches                       = {},    -- 记录实际进入原生创建的逻辑名和完整参数。
    killed                         = {},    -- 验证只有创建者取消时才终止对应待登记 Service。
    injected_patch_read_failure    = nil,   -- 包扫描后文件消失或读取失败的诊断。
    injected_read_failure          = nil,   -- 文件准备失败时不得开始运行时更新。
    injected_restore_failure       = false, -- 旧文件回写失败时保留恢复错误报告，不阻止后续发布。
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
        return module_state.launch_service_handle
    end,
    sleep = function(ticks) assert(ticks == 0) end, -- 单元场景无原生消息队列；真实调度交错由 Skynet 集成测试覆盖。
    wait = function() coroutine.yield() end,
    wakeup = function(co) assert(coroutine.resume(co)) end,
    kill = function(service_handle) module_state.killed[service_handle] = true end,
    fork = function(fn)
        -- 测试替身创建的后台控制协程；外层函数在测试推进时恢复它。
        local co = coroutine.create(fn)
        module_state.pending_control_coroutines[#module_state.pending_control_coroutines + 1] = function()
            -- 控制协程是否正常恢复，以及它抛出的错误；失败立即终止当前测试步骤。
            local ok, message = coroutine.resume(co)
            assert(ok, message)
        end
    end,
    call = function(service_handle, protocol, command, request)
        assert(protocol == "hotupgrade" and request.sequence > 0)
        module_state.operations[#module_state.operations + 1] = service_handle .. ":" .. command
        module_state.last_control_command_by_service_handle[service_handle] = command
        if module_state.control_hook then
            module_state.control_hook(service_handle, command, request)
        end
        if module_state.injected_control_failure and module_state.injected_control_failure.service_handle == service_handle and module_state.injected_control_failure.command == command then
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
            -- 当前 Patch 文件的二进制读取句柄；文件不存在时模拟原生返回 false。
            local file = io.open(_root .. "/" .. path, "rb")
            if not file then return false end
            -- 当前 Patch 文件的完整源码，返回给 Controller 的扫描替身。
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
        -- 各测试发布目录对应的相对 Lua/Patch 文件清单。
        local files =
        {
            module = {"lualib/test_worker_logic.lua"},
            draining = {"lualib/test_worker_logic.lua", "lualib/hotupgrade_extra.lua"},
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
            duplicate_service = {"service/battle/worker.patch", "service/battle/worker.patch"},
        }
        return files[path], {code = "HU_PATCH_EMPTY"}
    end,
}
-- 被测试的 Controller 单例；测试通过替身注入其 Skynet/Native 依赖。
local controller = require "flywow_hotupgrade_controller"
--- 初始化共享测试 Controller；可指定夹具里的 Service 入口目录。
---@param service_path? string 测试用 Service 目录；省略时使用标准 service 目录。
local function initialize_controller(service_path)
    -- Controller 初始化结果；失败时测试不能继续创建批次。
    local initialized = controller.initialize(
    {
        patch_path = "build/hotupgrade-tests/patches",
        root_path = "build/hotupgrade-tests/host",
        service_path = service_path or "service",
    })
    assert(initialized.ok, initialized.message)
    return controller
end
--- 让测试 Controller 接受指定发布目录，并返回这批发布的 ID。
---@param instance table initialize_controller 返回的测试 Controller；本函数调用它的 begin 命令。
---@param path string 测试替身登记的发布目录名；本函数将它放进 begin 请求。
local function begin_deployment(instance, path)
    -- 测试发布的受理结果；返回其中的 batch_id 用于后续断言。
    local begun = instance:handle_command("begin", {path = path}, 1)
    assert(begun.ok)
    return begun.value.batch_id
end

--- 把测试发布请求交给 Controller 的 begin 命令并返回受理结果。
---@param instance table initialize_controller 返回的测试 Controller；本函数通过它启动发布。
---@param request table 测试发布请求；本函数读取 request.path 作为发布目录。
local function publish(instance, request)
    return instance:handle_command("begin", {path = request.path}, 1)
end

--- 模拟受管理创建后由目标来源登记；沿用生产消息入口建立测试目标。
---@param instance table initialize_controller 创建的测试 Controller；本函数通过它完成受管理创建和目标登记。
---@param metadata table 测试目标提交的登记内容；包含 modules 模块名数组和 has_service_update 更新能力标记。
---@param service_handle integer 测试替身分配给目标 Service 的 handle；本函数用它作为 register 的消息来源。
---@param service_name? string 测试 Service 的入口名；省略时按 worker 入口登记目标。
---@return table Controller 的创建失败或登记结果
local function managed_register(instance, metadata, service_handle, service_name)
    -- launch_service_handle 控制创建替身的返回值；metadata 模拟目标 State 通过 register 提交的模块声明与更新能力。
    service_name = service_name or "skynet_hotupgrade_worker"
    module_state.launch_service_handle = service_handle
    -- Controller 的受管理创建结果；成功后才能模拟真实来源登记。
    local created = instance:handle_command("newservice", {service_name = service_name, arguments = {n = 0}}, 1)
    if not created.ok then
        return created
    end
    assert(instance.service_creations[service_handle].service_name == service_name)
    -- 目标登记结果；成功后断言 Controller 已按该 handle 保存实例。
    local registered = instance:handle_command("register", metadata, service_handle)
    if registered.ok then
        assert(instance.service_registrations[service_handle].service_name == service_name)
    end
    return registered
end

--- 为已登记测试目标完成一次模块许可申请与登记，返回实际协议结果。
---@param instance table initialize_controller 创建的测试 Controller；本函数通过它完成受管理创建和目标登记。
---@param name string 测试模块的统一名；本函数为它申请加载许可并登记到指定目标。
---@param service_handle integer managed_register 已登记目标的 handle；本函数以它作为模块登记 RPC 来源。
---@return table 许可失败结果或登记结果
local function register_module(instance, name, service_handle)
    -- 同一 Service 先取得 permit_id，再携带该 ID 登记；夹具沿用生产许可协议，避免直接改登记集合。
    local allowed = instance:handle_command("begin_module_load", {name = name}, service_handle)
    if not allowed.ok then
        return allowed
    end
    return instance:handle_command("register_module", {name = name, permit_id = allowed.value.permit_id}, service_handle)
end

-- 模拟目标 State 发送给 Controller 的初始模块声明和 Service 更新能力。
local metadata = {modules = {"lualib.test_worker_logic"}, has_service_update = false}

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
