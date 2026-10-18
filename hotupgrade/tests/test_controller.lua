--- 控制面合同测试：使用确定性 Skynet/RPC 夹具，不验证真实调度器、数据库或部署权限。
local result = require "flywow_hotupgrade_error"
local registry = require "flywow_hotupgrade_registry"
local now = 0                -- Mock Skynet tick；sleep 推进该时钟以确定性驱动超时。
local on_sleep               -- 当前场景安装的 sleep 回调；nil 表示不注入额外行为。
local on_call                -- 当前场景安装的 HotUpgrade RPC 响应回调；nil 时使用默认成功结果。
local forked = {}            -- 暂存 mock fork 回调，由测试显式推进协程顺序。
local killed = {}            -- mock kill 收到的实例集合，用于核对清理行为。
local next_instance_handle = 200 -- mock launch 分配的下一个 handle 起点。
local skynet =
{
    self = function() return 100 end,
    now = function() return now end,
    sleep = function(ticks)
        now = now + ticks
        if on_sleep then on_sleep() end
    end,
    launch = function()
        next_instance_handle = next_instance_handle + 1
        return next_instance_handle
    end,
    kill = function(instance_handle) killed[instance_handle] = true end,
    fork = function(fn) forked[#forked + 1] = fn end,
    call = function(target_handle, protocol_name, command, request)
        assert(protocol_name == "hotupgrade")
        return on_call and on_call(target_handle, command, request) or result.success()
    end,
    request = function(message)
        return
        {
            select = function(self, timeout_ticks)
                assert(type(timeout_ticks) == "number")
                local answer = on_call and on_call(message[1], message[3], message[4])
                    or result.success()
                self.timeout = false
                local returned = false
                return function()
                    if returned then return nil end
                    returned = true
                    return message, answer
                end, nil, nil, self
            end,
        }
    end,
}
local protocol = {install_handler = function() end}
local patch = {patch_id = "fixture", modules = {}, services = {worker = {}}}
package.loaded.skynet = skynet
package.loaded["skynet.manager"] = {}
package.loaded.flywow_hotupgrade_protocol = protocol
package.loaded.flywow_hotupgrade_patch = {load = function() return result.success({patch = patch}) end}
package.loaded.flywow_hotupgrade_history =
{
    open = function()
        local history = {records = {}}
        function history:append(record)
            self.records[record.txn_id] = record
            return result.success()
        end
        return result.success({history = history})
    end,
}
local hotupgrade = require "flywow_hotupgrade"
assert(hotupgrade.apply_modules == nil, "模块更新只通过注册 Service 的控制面执行")
local controller_module = require "flywow_hotupgrade_controller"
local function controller()
    return controller_module.new({patch_root = "fixture", history_path = "fixture"}).controller
end
local function metadata(instance_handle)
    return {service_type = "worker", origin_service_handle = 999, instance_handle = instance_handle,
        modules = {}, capabilities = {}, router_handle = 20}
end

-- 等待 bind 时 Registry 不可见，重复注册也不能覆盖绑定；失败后不留下半注册记录。
local c = controller()
on_call = function(_, command)
    assert(command == "bind")
    assert(next(c.registry.targets) == nil)
    assert(c:control("validate", {path = "fixture"}, 1).code == "HU_TARGET_MISSING")
    assert(c:register(metadata(10), 10).code == "HU_DUPLICATE_SERVICE")
    return result.failure("HU_ROUTE_CONFLICT", "fixture")
end
assert(not c:register(metadata(10), 10).ok)
assert(next(c.registry.targets) == nil and next(c.sources) == nil)
on_call = nil
assert(c:register(metadata(10), 10).ok)
local origin_service_handle = 10
local old = c.registry.targets[origin_service_handle]
assert(old.origin_service_handle == 10 and old.instance_handle == 10)

local txn = {id = "100:1",
    patch = {patch_id = "fixture", modules = {{name = "new_module", source = "return {}"}}},
    targets = {}, success = 0, failed = 0}
local function target()
    local value = {old = old, spec = {
        service = {source = "fixture", entry_file = "services/worker.lua"}}}
    txn.targets = {value}
    return value
end
local last_instance_handle -- 当前替换场景观察到的候选 handle。
local last_request     -- 候选提交的注册请求，用于核对字段与身份来源。
on_sleep = function()
    local instance_handle, startup = next(c.bootstraps)
    if not instance_handle or startup.answer then return end
    last_instance_handle = instance_handle
    assert(not c:control("bootstrap", {}, 999).ok)
    local bootstrap = c:control("bootstrap", {}, instance_handle).bootstrap
    assert(bootstrap.modules == txn.patch.modules and bootstrap.context.bootstrap_token == nil)
    assert(c.history.records[txn.id].participants[1].starting_instance_handle == instance_handle)
    local request = metadata(instance_handle)
    for field, value in pairs(bootstrap.context) do request[field] = value end
    request.candidate = nil
    assert(not c:register(request, instance_handle).ok)
    request.candidate = true
    request.origin_service_handle = 999
    assert(not c:register(request, instance_handle).ok)
    request.origin_service_handle = old.origin_service_handle
    assert(c:register(request, instance_handle).ok)
    assert(c.registry.targets[origin_service_handle] == old, "候选注册不能提前发布")
    assert(c:register(request, instance_handle).code == "HU_DUPLICATE_SERVICE")
    last_request = request
    assert(c:control("candidate_ready",
        {answer = result.failure("HU_CREATE_FAILED", "注册后失败")}, instance_handle).ok)
end
assert(not c:create_candidate(txn, target()).ok)
assert(killed[last_instance_handle] and c.sources[last_instance_handle] == nil and c.registry.targets[origin_service_handle] == old)
assert(not c:control("candidate_ready", {answer = result.success()}, last_instance_handle).ok)
assert(not c:control("bootstrap", {}, last_instance_handle).ok)
assert(not c:register(last_request, last_instance_handle).ok, "窗口关闭后迟到候选注册不能成为初代")
-- 替换失败后可以重新启动候选。
assert(not c:create_candidate(txn, target()).ok and c.registry.targets[origin_service_handle] == old)

-- 未报告就绪和主动 abort 都终止候选、关闭窗口；不依赖真实时钟。
on_sleep = nil
local began = now
assert(not c:create_candidate(txn, target()).ok)
assert(now - began == 1000 and killed[next_instance_handle] and next(c.bootstraps) == nil)
on_sleep = function() txn.cancelled = true end
assert(c:create_candidate(txn, target()).code == "HU_ABORT_REQUESTED")
assert(killed[next_instance_handle] and next(c.bootstraps) == nil)
on_sleep = nil

-- 成功 ready 也必须先注册；发布前当前索引不变，销毁只清理候选 source。
txn.cancelled = nil
on_sleep = function()
    local instance_handle = next(c.bootstraps)
    local bootstrap = c:control("bootstrap", {}, instance_handle).bootstrap
    local request = metadata(instance_handle)
    for field, value in pairs(bootstrap.context) do request[field] = value end
    assert(c:register(request, instance_handle).ok)
    assert(c:control("candidate_ready", {answer = result.success()}, instance_handle).ok)
    assert(not c:control("candidate_ready", {answer = result.success()}, instance_handle).ok)
end
local ready_target = target()
assert(c:create_candidate(txn, ready_target).ok)
local ready_instance_handle = ready_target.new.instance_handle
assert(c.registry.targets[origin_service_handle] == old and c.sources[ready_instance_handle])
assert(c:abort_target(txn, ready_target).ok and c.sources[ready_instance_handle] == nil)
on_sleep = function()
    local instance_handle = next(c.bootstraps)
    assert(c:control("candidate_ready", {answer = result.success()}, instance_handle).ok)
end
assert(not c:create_candidate(txn, target()).ok, "未注册不能只凭 ready 成功")
assert(killed[next_instance_handle] and c.registry.targets[origin_service_handle] == old)
on_sleep = nil

-- 完整替换控制链：候选不收到 Stage/Activate，所有控制请求只携带本步骤数据。
local function replacement_flow(fail_at, dry_run, fail_decision)
    local owner = controller()
    local previous = {instance_handle = 10, service_type = "worker",
        origin_service_handle = 10, router_handle = 20,
        modules = {}, capabilities = {export_state = true}}
    assert(owner.registry:register(previous).ok)
    owner.sources[10] = previous
    local next_record = {instance_handle = 30, service_type = "worker",
        origin_service_handle = 10, router_handle = 20,
        candidate = true, modules = {}, capabilities = {import_state = true}}
    owner.create_candidate = function(_, _, selected)
        selected.new = next_record
        return result.success()
    end
    if fail_decision then
        local append = owner.history.append
        local poisoned = false
        owner.history.append = function(history, record)
            if record.phase == "PUBLISH_DECIDED" then
                poisoned = true
                return result.failure("HU_HISTORY_WRITE_FAILED", "injected decision failure")
            end
            if poisoned then return result.failure("HU_RECOVERY_REQUIRED", "history poisoned") end
            return append(history, record)
        end
    end
    local calls = {}
    on_call = function(target_instance_handle, command, request)
        calls[#calls + 1] = instance_handle .. ":" .. command
        assert(request.patch == nil)
        assert(command ~= "stage" and command ~= "activate")
        if command == fail_at then return result.failure("HU_RPC_TIMEOUT", "fixture") end
        if command == "export" then return result.success({value = {count = 7}}) end
        if command == "import" then assert(request.state.count == 7) end
        if command == "switch" then
            assert(owner.history.records["flow"].phase == "PUBLISH_DECIDED")
            assert(owner.registry.targets[origin_service_handle] == previous)
        end
        return result.success()
    end
    local transaction = {id = "100:2", patch = {patch_id = "fixture", modules = {}},
        targets = {{old = previous, spec = {service = {source = "fixture", entry_file = "services/worker.lua"}}}},
        success = 0, failed = 0}
    local answer = owner:run(transaction, dry_run)
    on_call = nil
    return owner, previous, next_record, calls, answer
end
local published, previous, next_record, calls, answer = replacement_flow()
assert(answer.ok and published.registry.targets[origin_service_handle] == next_record and not next_record.candidate)
assert(published.sources[10] == nil)
assert(table.concat(calls, ",") == "20:pause,10:prepare,10:export,30:import,30:health,20:switch,30:finish,20:resume,10:retire")
local rejected, retained, _, rejected_calls, failed = replacement_flow("import")
assert(not failed.ok and rejected.registry.targets[origin_service_handle] == retained)
assert(killed[30] and table.concat(rejected_calls, ","):match("10:abort,20:abort$"))
assert(rejected.history.records.flow.phase == "ABORTED")
local dry, dry_old, _, dry_calls, dry_answer = replacement_flow(nil, true)
assert(dry_answer.ok and dry.registry.targets[origin_service_handle] == dry_old)
assert(dry.history.records.flow.phase == "DRY_RUN_COMPLETED")
assert(not table.concat(dry_calls, ","):find("switch", 1, true))
local uncertain, _, _, uncertain_calls, uncertain_answer = replacement_flow("finish")
assert(not uncertain_answer.ok and uncertain.recovery_required)
assert(uncertain.history.records.flow.phase == "RECOVERY_REQUIRED")
assert(not table.concat(uncertain_calls, ","):find("10:abort", 1, true))
assert(not table.concat(uncertain_calls, ","):find("20:resume", 1, true))

local unhealthy, health_old, _, health_calls, health_answer = replacement_flow("health")
assert(not health_answer.ok and unhealthy.registry.targets[origin_service_handle] == health_old)
assert(table.concat(health_calls, ","):match("10:abort,20:abort$"))
local undecided, undecided_old, _, undecided_calls, undecided_answer = replacement_flow(nil, false, true)
assert(not undecided_answer.ok and undecided.recovery_required)
assert(undecided.registry.targets[origin_service_handle] == undecided_old)
assert(not table.concat(undecided_calls, ","):find("switch", 1, true))
assert(table.concat(undecided_calls, ","):match("10:abort,20:abort$"))
local retirement, _, _, retirement_calls, retirement_answer = replacement_flow("retire")
assert(not retirement_answer.ok and retirement.recovery_required and retirement.sources[10])
assert(retirement.registry.targets[origin_service_handle].instance_handle == 30)
assert(not table.concat(retirement_calls, ","):find("10:abort", 1, true))

-- 发布后的失败和历史失败都阻止其它目标发起新发布。
local recovering = controller()
recovering.run_target = function(_, transaction)
    transaction.commit_decided = true
    return result.failure("HU_RECOVERY_REQUIRED", "fixture")
end
local transaction = {id = "100:1", patch = {patch_id = "fixture"},
    targets = {{old = old, spec = {}}}, success = 0, failed = 0}
assert(not recovering:run(transaction, false).ok)
assert(recovering.recovery_required)
assert(recovering:load({path = "fixture"}).code == "HU_RECOVERY_REQUIRED")
local failed_history = controller()
failed_history.history.append = function() return result.failure("HU_HISTORY_WRITE_FAILED", "fixture") end
assert(not failed_history:record(transaction, "ACTIVATING").ok)
assert(failed_history.recovery_required and transaction.persistence_error)

-- 后台事务结束后，只保留历史，不再保留冻结源码；未决事务仍保留恢复上下文。
local finished = controller()
finished.load = function() return result.success({patch = {patch_id = "fixture"}, targets = {}}) end
local started = finished:apply({path = "fixture"}, 1, true)
assert(started.ok and finished.active and finished.active.id == started.txn_id)
assert(finished:apply({path = "fixture"}, 1, false).code == "HU_UPGRADE_BUSY")
forked[#forked]()
assert(finished.active == nil)
assert(finished.history.records[started.txn_id].phase == "DRY_RUN_COMPLETED")

-- 公共 require 登记失败后可重试；不会因本地先置位永久丢失模块声明。
local declarations = 0
on_call = function(_target_instance_handle, command)
    if command == "register_module" then
        declarations = declarations + 1
        if declarations == 1 then return result.failure("HU_RPC_FAILED", "fixture") end
    end
    return result.success()
end
assert(hotupgrade.register_service({controller_handle = 100, service_type = "fixture", adapter = {dispatch = function() end}}).ok)
package.loaded.fixture_module = {}
assert(not pcall(hotupgrade.require, "fixture_module"))
assert(hotupgrade.require("fixture_module") == package.loaded.fixture_module)
assert(hotupgrade.require("fixture_module") == package.loaded.fixture_module and declarations == 2)
-- Runtime 按实例身份、控制来源和完成序号拒绝错误或迟到请求。
local service_runtime = require("flywow_hotupgrade_runtime").new(
    {controller_handle = 100, instance_handle = 100, adapter = {dispatch = function() end}}) -- 被测初代 Service 的本地 Runtime。
assert(service_runtime:control("prepare", {instance_handle = 101, txn_id = "100:1"}, 100).code == "HU_STALE_INSTANCE")
assert(service_runtime:control("prepare", {instance_handle = 100, txn_id = "100:1"}, 999).code == "HU_UNAUTHORIZED")
assert(service_runtime:control("invoke", {instance_handle = 100}, 999).code == "HU_UNAUTHORIZED")
local request = {instance_handle = 100, txn_id = "100:1", timeout_ms = 100}
assert(service_runtime:control("prepare", request, 100).ok)
assert(service_runtime:control("abort", request, 100).ok)
assert(service_runtime:control("prepare", request, 100).code == "HU_STALE_TRANSACTION")

local update = {instance_handle = 100, txn_id = "100:2", timeout_ms = 100}
assert(service_runtime:control("finish", update, 100).code == "HU_PHASE_INVALID")
assert(service_runtime:control("prepare", update, 100).ok)
update.modules = {{name = "fixture_module", source = "return {value = function() return 2 end}"}}
assert(service_runtime:control("stage", update, 100).ok)
assert(service_runtime:control("activate", update, 100).ok)
assert(service_runtime:control("finish", update, 100).ok)
assert(service_runtime:control("finish", update, 100).ok)
assert(service_runtime.phase == "RUNNING" and service_runtime.guard.owner == nil and service_runtime.txn == nil)
assert(service_runtime.phase == "RUNNING" and package.loaded.fixture_module.value() == 2)

local imported -- 候选 import_state 写入的夹具状态，由 healthcheck 读取。
local candidate_runtime = require("flywow_hotupgrade_runtime").new(
{
    controller_handle = 100, instance_handle = 200,
    candidate = true, router_handle = 20,
    adapter = {import_state = function(value) imported = value end,
        healthcheck = function() return imported.count == 42 end},
}) -- 候选 Service 的本地 Runtime，供状态导入和健康检查断言使用。
assert(candidate_runtime.guard:prepare_upgrade("candidate").ok)
local candidate_request = {instance_handle = 200, txn_id = "100:3", timeout_ms = 100}
assert(not candidate_runtime:control("health", candidate_request, 100).ok)
assert(not candidate_runtime:control("stage", candidate_request, 100).ok)
assert(not candidate_runtime:control("activate", candidate_request, 100).ok)
candidate_request.state = {count = 42}
assert(candidate_runtime:control("import", candidate_request, 100).ok)
assert(candidate_runtime.phase == "QUIESCED")
local healthcheck = candidate_runtime.adapter.healthcheck
candidate_runtime.adapter.healthcheck = function() end
assert(candidate_runtime:control("health", candidate_request, 100).code == "HU_HOOK_REJECTED")
candidate_runtime.adapter.healthcheck = healthcheck
assert(candidate_runtime:control("health", candidate_request, 100).ok)
assert(candidate_runtime:control("finish", candidate_request, 100).ok)
assert(candidate_runtime:control("finish", candidate_request, 100).ok)
assert(candidate_runtime.phase == "RUNNING" and not candidate_runtime.options.candidate)
assert(candidate_runtime.guard.owner == nil and candidate_runtime.txn == nil)
print("HOTUPGRADE_CONTROLLER_CONTRACT_OK")
