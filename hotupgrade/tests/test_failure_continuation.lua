--- 失败报告后释放本批占用；下一批以失败后现场为基准。
local scenario = assert(arg[1])
local function lifecycle_status(controller)
    return controller:handle_command("status", {}, 1).lifecycle
end

if scenario == "controller" then
    local fixture = require "test_controller_fixture"
    local state = fixture.module_state
    local controller = fixture.initialize_controller()
    assert(fixture.managed_register(controller, fixture.metadata, 10).ok)
    state.injected_control_failure = {service_handle = 10, command = "update"}
    state.control_hook = function(_, command)
        if command == "abort" then error("injected rollback failure") end
    end
    assert(controller:handle_command("begin", {path = "module"}, 1).ok)
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.last_batch.phase == "RECOVERY_REQUIRED")
    assert(controller.last_batch.error.original_error and controller.last_batch.error.recovery_error)
    state.injected_control_failure = nil
    state.control_hook = function(_, command)
        if command == "prepare" or command == "update" then
            local lifecycle = lifecycle_status(controller)
            assert(lifecycle.phase == "APPLYING" and lifecycle.recovery_required)
        end
    end
    local next_batch = controller:handle_command("begin", {path = "module"}, 1)
    assert(next_batch.ok, next_batch.code)
    assert(lifecycle_status(controller).recovery_required) -- 新批次进行中仍保留最近终态的诊断。
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.last_batch.phase == "COMPLETED" and not lifecycle_status(controller).recovery_required)
elseif scenario == "diagnostic" then
    local fixture = require "test_controller_fixture"
    local controller = fixture.initialize_controller()
    local state = fixture.module_state
    assert(fixture.managed_register(controller, fixture.metadata, 10).ok)
    local skynet = require "skynet"
    local original_call = skynet.call
    skynet.call = function(handle, protocol, command, request)
        if command == "update" then return {ok = false, code = "HU_RECOVERY_REQUIRED", message = "reported recovery failure"} end
        return original_call(handle, protocol, command, request)
    end
    assert(controller:handle_command("begin", {path = "module"}, 1).ok)
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.last_batch.phase == "RECOVERY_REQUIRED" and lifecycle_status(controller).recovery_required)
    assert(lifecycle_status(controller).phase == "IDLE")
    skynet.call = original_call
    assert(controller:handle_command("begin", {path = "module"}, 1).ok)
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.last_batch.phase == "COMPLETED")
elseif scenario == "management_abort" then
    local fixture = require "test_controller_fixture"
    local state = fixture.module_state
    local controller = fixture.initialize_controller()
    state.launch_service_handle = 10
    assert(controller:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
    local begun = controller:handle_command("begin", {path = "module"}, 1)
    assert(begun.ok and controller.pending_creation_count == 1)
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.active_batch.waiter)
    assert(controller:handle_command("abort", {batch_id = begun.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(controller.active_batch.batch_id == begun.batch_id and controller.pending_creation_count == 1)
    assert(controller:handle_command("cancel_service_creation", {service_handle = 10}, 1).ok)
    assert(controller.last_batch.phase == "COMPLETED" and controller.active_batch == nil)
    assert(controller.pending_creation_count == 0)
elseif scenario == "module" then
    local patch = require "flywow_hotupgrade_module_patch"
    local live = {value = 1}
    package.loaded.continuation_logic = live
    local staged = patch.stage({{name = "continuation_logic", source = "return {value = 2}"}})
    assert(staged.ok and patch.commit(staged.stage).ok)
    package.loaded.continuation_logic = {}
    assert(patch.abort(staged.stage).code == "HU_RECOVERY_REQUIRED")
    -- 宿主修正缓存后，下一批不能仍被上一批 Stage 阻塞。
    package.loaded.continuation_logic = live
    local next_stage = patch.stage({{name = "continuation_logic", source = "return {value = 3}"}})
    assert(next_stage.ok, next_stage.code)
    assert(patch.commit(next_stage.stage).ok and live.value == 3)
    assert(patch.abort(next_stage.stage).ok and live.value == 2)
elseif scenario == "service" then
    local receiver
    local answer
    package.loaded.skynet = {
        uniqueservice = function() return 99 end,
        register_protocol = function() end,
        dispatch = function(_, callback) receiver = callback end,
        retpack = function(value) answer = value end,
        call = function() return {ok = true} end,
    }
    package.loaded["skynet.require"] = {}
    package.loaded.flywow_hotupgrade_native = {}
    local hotupgrade = require "flywow_hotupgrade"
    local state = {count = 1}
    local malformed = false
    assert(hotupgrade.register_service({
        before_upgrade = function()
            if malformed then
                return setmetatable({}, {__index = function() error("injected control exception") end})
            end
            return true
        end,
        after_upgrade = function() return state.count == 3 end,
        service_update = {
            state = state, functions = {},
            snapshot = function(value) return {count = value.count} end,
            restore = function() error("injected rollback failure") end,
        },
    }).ok)
    local function command(name, sequence, count)
        receiver(1, 99, name, {
            batch_id = "continuation:" .. sequence, sequence = sequence, modules = {},
            service_source = "return function(state) return {update_state = function() state.count = " .. count .. " end} end",
        })
        return answer
    end
    assert(command("prepare", 1, 2).ok)
    assert(not command("update", 1, 2).ok)
    local aborted = command("abort", 1, 2)
    assert(aborted.code == "HU_RECOVERY_REQUIRED", aborted.code)
    assert(not hotupgrade.patching and state.count == 2)
    assert(command("prepare", 2, 3).ok)
    assert(command("update", 2, 3).ok)
    assert(command("finish", 2, 3).ok and state.count == 3 and not hotupgrade.patching)
    malformed = true
    assert(not command("prepare", 3, 3).ok and not hotupgrade.patching)
    malformed = false
    assert(command("prepare", 4, 3).ok and command("update", 4, 3).ok)
    assert(command("finish", 4, 3).ok and not hotupgrade.patching)
else
    error("unknown scenario: " .. scenario)
end
print("HOTUPGRADE_FAILURE_CONTINUATION_OK " .. scenario)
