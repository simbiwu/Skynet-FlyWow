--- 失败报告后释放本批占用；下一批以失败后现场为基准。
local scenario = assert(arg[1]) -- 命令行选择本文件要验证的恢复场景。
local function lifecycle_status(controller)
    return controller:handle_command("status", {}, 1).value.lifecycle
end

if scenario == "controller" then
    local fixture = require "test_controller_fixture" -- 本场景用于注入 Controller 失败并推进后续批次的替身。
    -- fixture.module_state 是替身的故障配置和调度记录；它不是被热更业务 Service 的私有 state。
    local state = fixture.module_state
    local controller = fixture.initialize_controller() -- 当前恢复场景独立使用的 Controller 实例。
    assert(fixture.managed_register(controller, fixture.metadata, 10).ok)
    state.injected_control_failure = {service_handle = 10, command = "update"}
    state.control_hook = function(_, command)
        if command == "abort" then error("injected rollback failure") end
    end
    assert(controller:handle_command("begin", {path = "module"}, 1).ok)
    -- 驱动 begin 排队的协调协程；批次在 yield 时暂停，由许可或创建完成后的唤醒继续。
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.last_batch.phase == "RECOVERY_REQUIRED")
    assert(controller.last_batch.error.details.original_error and controller.last_batch.error.details.recovery_error)
    state.injected_control_failure = nil
    state.control_hook = function(_, command)
        if command == "prepare" or command == "update" then
            local lifecycle = lifecycle_status(controller) -- 当前恢复诊断视图；新控制步骤不应被它挡住。
            assert(lifecycle.phase == "APPLYING" and lifecycle.recovery_required)
        end
    end
    local next_batch = controller:handle_command("begin", {path = "module"}, 1) -- 恢复失败后新批次的受理结果。
    assert(next_batch.ok, next_batch.code)
    assert(lifecycle_status(controller).recovery_required) -- 新批次进行中仍保留最近终态的诊断。
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.last_batch.phase == "COMPLETED" and not lifecycle_status(controller).recovery_required)
elseif scenario == "diagnostic" then
    local fixture = require "test_controller_fixture" -- 本场景用于注入 Controller 失败并推进后续批次的替身。
    local controller = fixture.initialize_controller() -- 当前恢复场景独立使用的 Controller 实例。
    -- fixture.module_state 是替身的故障配置和调度记录；它不是被热更业务 Service 的私有 state。
    local state = fixture.module_state
    assert(fixture.managed_register(controller, fixture.metadata, 10).ok)
    local skynet = require "skynet" -- 临时替换 call，以模拟目标已报告恢复错误。
    local original_call = skynet.call -- 保存真实测试环境函数，场景结束后恢复。
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
    local fixture = require "test_controller_fixture" -- 本场景用于注入 Controller 失败并推进后续批次的替身。
    -- fixture.module_state 是替身的故障配置和调度记录；它不是被热更业务 Service 的私有 state。
    local state = fixture.module_state
    local controller = fixture.initialize_controller() -- 当前恢复场景独立使用的 Controller 实例。
    state.launch_service_handle = 10
    assert(controller:handle_command("newservice", {service_name = "fixture", arguments = {n = 0}}, 1).ok)
    local begun = controller:handle_command("begin", {path = "module"}, 1) -- 受理后等待 Service 创建登记完成的批次。
    assert(begun.ok and lifecycle_status(controller).pending_service_count == 1)
    state.pending_control_coroutines[#state.pending_control_coroutines]()
    assert(controller.active_batch.waiter)
    assert(controller:handle_command("abort", {batch_id = begun.value.batch_id}, 1).code == "HU_UNKNOWN_COMMAND")
    assert(controller.active_batch.batch_id == begun.value.batch_id and lifecycle_status(controller).pending_service_count == 1)
    assert(controller:handle_command("cancel_service_creation", {service_handle = 10}, 1).ok)
    assert(controller.last_batch.phase == "COMPLETED" and controller.active_batch == nil)
    assert(lifecycle_status(controller).pending_service_count == 0)
elseif scenario == "module" then
    local patch = require "flywow_hotupgrade_module_patch" -- 被测模块 Stage/Commit/Abort 接口。
    local live = {value = 1} -- package.loaded 中代表当前线上导出表的对象。
    package.loaded.continuation_logic = live
    local staged = patch.stage({{name = "continuation_logic", source = "return {value = 2}"}}) -- 提交后故意破坏缓存以触发恢复失败。
    assert(staged.ok and patch.commit(staged.value.stage).ok)
    package.loaded.continuation_logic = {}
    assert(patch.abort(staged.value.stage).code == "HU_RECOVERY_REQUIRED")
    -- 宿主修正缓存后，下一批不能仍被上一批 Stage 阻塞。
    package.loaded.continuation_logic = live
    local next_stage = patch.stage({{name = "continuation_logic", source = "return {value = 3}"}}) -- 下一次热更按当前 live 内容创建新候选。
    assert(next_stage.ok, next_stage.code)
    assert(patch.commit(next_stage.value.stage).ok and live.value == 3)
    assert(patch.abort(next_stage.value.stage).ok and live.value == 2)
elseif scenario == "service" then
    local receiver -- register_service 安装的控制消息回调，由 command 驱动。
    local answer -- retpack 替身捕获的最近一次命令返回值。
    package.loaded.skynet = {
        uniqueservice = function() return 99 end,
        register_protocol = function() end,
        dispatch = function(_, callback) receiver = callback end,
        retpack = function(value) answer = value end,
        call = function() return {ok = true} end,
    }
    package.loaded["skynet.require"] = {}
    package.loaded.flywow_hotupgrade_native = {}
    local hotupgrade = require "flywow_hotupgrade" -- 被测 Service 侧热更 API。
    local state = {count = 1} -- 模拟业务私有状态，Update 改写，Abort 恢复失败时保留现场。
    local malformed = false -- 控制 before_upgrade 是否返回会抛错的对象。
    assert(hotupgrade.register_service({
        before_upgrade = function()
            if malformed then
                error("injected control exception")
            end
            return true
        end,
        after_upgrade = function() return state.count == 3 end,
        service_update = {
            state = state, functions = {},
            snapshot = function(value) return require("flywow_result").success({count = value.count}) end,
            restore = function() error("injected rollback failure") end,
        },
    }).ok)
    --- 向模拟 Service 发送指定批次命令；Update Patch 将 state.count 改为 count，供后续恢复场景断言。
    ---@param name string 要发送的控制命令
    ---@param sequence integer 本批控制序号
    ---@param count integer Patch 写入 Service 私有状态的值
    ---@return table 模拟 Controller 返回的命令结果
    local function command(name, sequence, count)
        -- receiver 是登记时安装的控制消息回调，answer 由 retpack 替身捕获；使用 99 模拟已确认的 Controller 来源。
        receiver(1, 99, name, {
            batch_id = "continuation:" .. sequence, sequence = sequence, modules = {},
            service_patch_source = "return function(state) return {update_state = function() state.count = " .. count .. " end} end",
        })
        return answer
    end
    assert(command("prepare", 1, 2).ok)
    assert(not command("update", 1, 2).ok)
    local aborted = command("abort", 1, 2) -- 内部失败恢复 Abort 的结果，验证错误会被报告。
    assert(aborted.code == "HU_RECOVERY_REQUIRED", aborted.code)
    assert(not hotupgrade.patching and state.count == 2)
    assert(command("prepare", 2, 3).ok)
    assert(command("update", 2, 3).ok)
    assert(command("finish", 2, 3).ok and state.count == 3 and not hotupgrade.patching)
    malformed = true
    assert(not command("prepare", 3, 3).ok and hotupgrade.patching)
    assert(command("abort", 3, 3).ok and not hotupgrade.patching)
    malformed = false
    assert(command("prepare", 4, 3).ok and command("update", 4, 3).ok)
    assert(command("finish", 4, 3).ok and not hotupgrade.patching)
else
    error("unknown scenario: " .. scenario)
end
print("HOTUPGRADE_FAILURE_CONTINUATION_OK " .. scenario)
