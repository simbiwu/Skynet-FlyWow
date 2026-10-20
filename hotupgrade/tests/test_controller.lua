--- 只模拟控制面消息编排；目标 State 的真实提交由 Skynet 集成覆盖。
local hotupgrade_common = require "flywow_hotupgrade_common"
local module_state =
{
    pending_control_coroutines = {}, -- 测试替身排队的 Controller 控制面协程。
    last_control_command_by_handle = {}, -- 各目标最近收到的控制步骤。
    shared_environment = {}, -- 模拟 Skynet 跨 State 的只写一次环境。
    injected_control_failure = nil, -- 当前测试注入的目标和命令失败条件。
}
package.loaded.skynet =
{
    getenv = function(key) return module_state.shared_environment[key] end,
    setenv = function(key, value) module_state.shared_environment[key] = value end,
    self = function() return 99 end,
    fork = function(fn) module_state.pending_control_coroutines[#module_state.pending_control_coroutines + 1] = fn end,
    call = function(handle, protocol, command, request)
        assert(protocol == "hotupgrade" and request.sequence > 0)
        module_state.last_control_command_by_handle[handle] = command
        if module_state.injected_control_failure and module_state.injected_control_failure.handle == handle and module_state.injected_control_failure.command == command then
            return {ok = false, code = "HU_FIXTURE_FAILED", message = command}
        end
        return {ok = true}
    end,
}
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
assert(not controller.new({}).ok)
local c = new_controller()
for _, handle in ipairs({10, 20}) do
    assert(c:control("register", {service_module = "player", modules = {"lualib.test_worker_logic"},
        service_patch = false}, handle).ok)
end
assert(not c:control("register", {service_module = "player", modules = {}, service_patch = false}, 10).ok)
assert(c:control("register_module", {name = "extra"}, 10).ok)
assert(not c:control("register_module", {name = "extra"}, 30).ok)
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
        local rejected = c:control(command, {path = fixture.path}, 1)
        assert(not rejected.ok and rejected.code == "HU_TARGET_MISSING")
        assert(rejected.message:find(fixture.path .. "/" .. fixture.file, 1, true))
        assert(rejected.message:find(fixture.reason, 1, true))
        assert(next(module_state.last_control_command_by_handle) == nil and #module_state.pending_control_coroutines == pending_count and not c.active and c.sequence == sequence)
    end
end
-- 同一模块仍可匹配多个 Service，组合包中的 Service 脚本也必须被覆盖。
local combined = new_controller()
for _, handle in ipairs({30, 40}) do
    assert(combined:control("register", {service_module = "player", modules = {"lualib.test_worker_logic"},
        service_patch = true}, handle).ok)
end
for _, command in ipairs({"validate", "dry_run", "apply"}) do
    assert(combined:control(command, {path = "combined"}, 1).target_count == 2)
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
assert(paths:control("register",
    {service_module = "battle.worker", modules = {"config.settings", "lualib.battle.state_sync.runtime", "lualib.packages.demo.init"},
        service_patch = true}, 50).ok)
local loaded = paths:load({path = "host_paths"})
assert(loaded.ok and #loaded.patch.modules == 3)
assert(loaded.patch.modules[1].entry_file == "config/settings.lua")
assert(loaded.patch.modules[2].name == "lualib.battle.state_sync.runtime")
assert(paths:control("validate", {path = "nested_service"}, 1).ok)
local changed = new_controller("actors")
assert(changed:control("register",
    {service_module = "zone.player", modules = {}, service_patch = true}, 60).ok)
assert(changed:control("validate", {path = "custom_service"}, 1).ok)
for _, path in ipairs({"duplicate_module", "duplicate_service"}) do
    assert(paths:control("validate", {path = path}, 1).code == "HU_INVALID_PATCH")
end
print("HOTUPGRADE_CONTROLLER_PATHS_OK")

local function run(command)
    local answer = c:control(command or "apply", {path = "module"}, 1)
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
local started = c:control("apply", {path = "module"}, 1)
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
local bounded = new_controller()
for handle = 1, hotupgrade_common.MAX_TARGETS do
    assert(bounded:control("register", {service_module = "empty", modules = {}, service_patch = false}, handle).ok)
end
assert(bounded:control("register", {service_module = "empty", modules = {}, service_patch = false}, hotupgrade_common.MAX_TARGETS + 1).code
    == "HU_TARGET_LIMIT")
local names = {}
for index = 1, hotupgrade_common.MAX_MODULES do
    names[index] = "logic_" .. index
end
local limited = new_controller()
assert(limited:control("register", {service_module = "empty", modules = names, service_patch = false}, 1).ok)
assert(limited:control("register_module", {name = names[1]}, 1).ok)
assert(limited:control("register_module", {name = "overflow"}, 1).code == "HU_MODULE_LIMIT")
print("HOTUPGRADE_CONTROLLER_OK")
