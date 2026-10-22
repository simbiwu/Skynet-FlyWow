--- 普通 Lua 状态图、模块身份、状态迁移与安全点失败合同。
local patch = require "flywow_hotupgrade_module_patch"
local graph = {nested = {count = 7}}
graph.self = graph
graph.shared = graph.nested
local snapshot = patch.copy_state(graph)
assert(snapshot ~= graph and snapshot.self == snapshot and snapshot.shared == snapshot.nested)
snapshot.nested.count = 8
assert(graph.nested.count == 7)
patch.restore_state(graph, snapshot)
assert(graph.self == graph and graph.nested.count == 8 and graph.shared == graph.nested)
assert(not pcall(patch.copy_state, {resource = io.stdout}))
assert(not pcall(patch.copy_state, setmetatable({}, {})))

local old_state = {count = 7} -- 故意导出私有表本身，验证框架额外隔离。
local live =
{
    value = function() return old_state.count end,
    export_state = function() return old_state end,
    import_state = function(state) old_state = state end,
    removed = true,
}
local cached = live.value
package.loaded.logic = live
local source = [[
local count = 0
return {
    value = function() return count + 1 end,
    export_state = function() return {count = count} end,
    import_state = function(state)
        count = state.count
        state.count = 999
    end,
    added = 42,
}
]]
local staged = patch.stage({{name = "logic", source = source}})
assert(staged.ok, staged.message)
assert(live.value() == 7 and old_state.count == 7)
assert(patch.commit(staged.stage).ok)
assert(package.loaded.logic == live and live.value() == 8 and cached() == 7)
assert(live.added == 42 and live.removed == nil)
assert(patch.abort(staged.stage).ok)
assert(live.value == cached and live.removed and live.added == nil)

local failed = patch.stage({{name = "logic", source = "error('stage failed')"}})
assert(not failed.ok and live.value() == 7)
failed = patch.stage({{name = "logic", source = "return {value=function() return 3 end}"}})
assert(not failed.ok and live.value() == 7)
staged = patch.stage({{name = "logic", source = source}})
assert(staged.ok and patch.commit(staged.stage).ok)
package.loaded.logic = {}
assert(patch.abort(staged.stage).code == "HU_RECOVERY_REQUIRED")
package.loaded.logic = live
assert(patch.abort(staged.stage).ok)
-- 无状态模块不需要钩子；多模块中一个 Stage 失败不能提前安装其他模块。
local simple = {value = function() return 1 end}
package.loaded.a = simple
package.loaded.b = {value = function() return 1 end}
local rejected = patch.stage({
    {name = "a", source = "return {value = function() return 2 end}"},
    {name = "b", source = "error('second module failed')"},
})
assert(not rejected.ok and simple.value() == 1)
package.loaded.a = {export_state = function() return {} end}
assert(not patch.stage({{name = "a", source = "return {}"}}).ok)
package.loaded.a = {
    value = function() return 1 end,
    export_state = function() return {} end,
    import_state = function() end,
}
assert(not patch.stage({{name = "a", source = [[return {
    value = function() return 2 end,
    export_state = function() return {} end,
    import_state = function() error("import failed") end,
}]]}}).ok)
local retried = patch.stage({{name = "a", source = [[return {
    value = function() return 2 end,
    export_state = function() return {} end,
    import_state = function() end,
}]]}})
assert(retried.ok and patch.abort(retried.stage).ok)
-- 嵌套配置、辅助函数、共享与循环图均按完整新版本安装；回滚必须找回原引用。
local old_config = {max_level = 50, items = {sword = {attack = 10}}}
local old_helper = {calculate = function(value) return value end}
local nested_live = {config = old_config, helper = old_helper, removed = true}
local nested_name = "hotupgrade_nested_fixture"
assert(package.loaded[nested_name] == nil)
package.loaded[nested_name] = nested_live
local nested_source = [[
local M = {}
M.config = {max_level = 100, items = {sword = {attack = 20}}, [1] = "index", [false] = true}
M.config.self = M.config
M.alias = M.config.items
M.helper = {calculate = function(value) return value * 2 end}
function M.get_max_level() return M.config.max_level end
return M
]]
local nested_stage = patch.stage({{name = nested_name, source = nested_source}})
assert(nested_stage.ok, nested_stage.message)
assert(nested_live.config == old_config and old_config.max_level == 50)
assert(patch.commit(nested_stage.stage).ok)
assert(package.loaded[nested_name] == nested_live and nested_live.config ~= old_config)
assert(nested_live.config.max_level == 100 and nested_live.config.items.sword.attack == 20)
assert(nested_live.config.self == nested_live.config and nested_live.alias == nested_live.config.items)
assert(nested_live.config[1] == "index" and nested_live.config[false] == true)
assert(nested_live.helper.calculate(3) == 6 and nested_live.get_max_level() == 100)
assert(nested_live.removed == nil and old_config.max_level == 50)
assert(patch.abort(nested_stage.stage).ok)
assert(package.loaded[nested_name] == nested_live and nested_live.config == old_config)
assert(nested_live.helper == old_helper and nested_live.removed and nested_live.alias == nil)
assert(nested_live.get_max_level == nil)

for _, invalid_source in ipairs({
    "return setmetatable({}, {})",
    "return {[1] = true}",
    "return {config = setmetatable({}, {})}",
    "return {config = {inner = setmetatable({}, {})}}",
    "return {config = {[{}] = true}}",
    "return {config = {resource = io.stdout}}",
    "return {config = {worker = coroutine.create(function() end)}}",
    "local M = {}; M.config = {deep = {root = M}}; return M",
    "return {config = 100}",
}) do
    local invalid = patch.stage({{name = nested_name, source = invalid_source}})
    assert(not invalid.ok)
    assert(package.loaded[nested_name] == nested_live and nested_live.config == old_config)
    assert(nested_live.helper == old_helper and nested_live.removed)
end
local root_reference = patch.stage({{name = nested_name,
    source = "local M = {}; M.config = {root = M}; return M"}})
assert(not root_reference.ok and root_reference.message:find("根导出表", 1, true))
-- 成功 finish 后，下一次 Stage 也能够校验并回滚已经在线的嵌套循环图。
nested_stage = patch.stage({{name = nested_name, source = nested_source}})
assert(nested_stage.ok and patch.commit(nested_stage.stage).ok)
assert(patch.finish(nested_stage.stage).ok)
local installed_config = nested_live.config
nested_stage = patch.stage({{name = nested_name, source = "return {config = {max_level = 200}}"}})
assert(nested_stage.ok and patch.commit(nested_stage.stage).ok)
assert(nested_live.helper == nil and nested_live.config.max_level == 200)
assert(patch.abort(nested_stage.stage).ok)
assert(nested_live.config == installed_config and nested_live.config.self == installed_config)
assert(nested_live.helper.calculate(3) == 6)
package.loaded[nested_name] = nil
-- 独立 Lua 验证首次声明的本地事务：许可先于模块执行，失败回退缓存/来源/声明并释放许可。
local original_path = package.path
package.path = "build/hotupgrade-tests/host/lualib/?.lua;" .. package.path
local original_require = require
local permits = {}
local permit_sequence = 0
local begin_count = 0
local fail_registration = false
local unique_calls = 0
local last_loaded_value
local forwarded = {}
local control_dispatch
local control_answer
package.loaded.skynet =
{
    uniqueservice = function(name)
        assert(name == "flywow_hotupgrade_service")
        unique_calls = unique_calls + 1
        return 99
    end,
    register_protocol = function() end,
    dispatch = function(protocol, callback)
        assert(protocol == "hotupgrade")
        control_dispatch = callback
    end,
    retpack = function(answer) control_answer = answer end,
    pack = function() end,
    unpack = function() end,
    getenv = function() return "build/hotupgrade-tests/host" end,
    call = function(hotupgrade_service_handle, _protocol, command, request)
        assert(hotupgrade_service_handle == 99)
        if command == "register" then
            return {ok = true}
        elseif command == "newservice" or command == "uniqueservice" then
            forwarded[command] = request
            return {ok = true, service_handle = command == "newservice" and 101 or 102}
        elseif command == "cancel_service_creation" then
            forwarded.cancel = request
            return {ok = true}
        elseif command == "begin_module_load" then
            begin_count = begin_count + 1
            permit_sequence = permit_sequence + 1
            local id = tostring(permit_sequence)
            permits[id] = request.name
            return {ok = true, permit_id = id}
        elseif command == "register_module" then
            assert(permits[request.permit_id] == request.name)
            assert(package.loaded.hotupgrade_extra == package.loaded[request.name])
            last_loaded_value = package.loaded.hotupgrade_extra
            if fail_registration == "rpc" then
                error("injected registration RPC failure")
            elseif fail_registration == "register" then
                return {ok = false, message = "injected registration failure"}
            end
            permits[request.permit_id] = nil
            return {ok = true}
        elseif command == "cancel_module_load" then
            assert(permits[request.permit_id] == request.name)
            permits[request.permit_id] = nil
            return {ok = true}
        end
        error("unexpected mock command: " .. command)
    end,
}
package.loaded["skynet.require"] = {require = original_require}
package.loaded.flywow_hotupgrade_native = {resolve = function(path) return path end}
local hotupgrade = require "flywow_hotupgrade"
assert(unique_calls == 1)
assert(hotupgrade.newservice("fixture_service", "first", nil, "last") == 101)
assert(forwarded.newservice.service_name == "fixture_service")
assert(forwarded.newservice.arguments.n == 3 and forwarded.newservice.arguments[1] == "first"
    and forwarded.newservice.arguments[2] == nil and forwarded.newservice.arguments[3] == "last")
assert(hotupgrade.uniqueservice("fixture_unique", "one", nil, "three") == 102)
assert(forwarded.uniqueservice.service_name == "fixture_unique" and not forwarded.uniqueservice.global)
assert(forwarded.uniqueservice.arguments.n == 3 and forwarded.uniqueservice.arguments[2] == nil)
assert(hotupgrade.uniqueservice(true, "global_name", "arg") == 102)
assert(forwarded.uniqueservice.global and forwarded.uniqueservice.service_name == "global_name")
assert(forwarded.uniqueservice.arguments.n == 1 and forwarded.uniqueservice.arguments[1] == "arg")
assert(hotupgrade.cancel_service_creation(101).ok and forwarded.cancel.service_handle == 101)
assert(unique_calls == 1, "controller lookup happens exactly once per Lua State")
local rejected_registration = hotupgrade.register_service({service_module = "fixture"})
assert(not rejected_registration.ok and rejected_registration.code == "HU_INVALID_OPTIONS")
local registration = {}
local missing_before_upgrade = hotupgrade.register_service(registration)
assert(not missing_before_upgrade.ok and missing_before_upgrade.code == "HU_INVALID_OPTIONS")
registration.before_upgrade = function() return true end
assert(hotupgrade.register_service(registration).ok)
local function target_control(command, sequence)
    control_dispatch(1, 99, command, {batch_id = "fixture:" .. sequence, sequence = sequence})
    return control_answer
end
registration.before_upgrade = function() return false end
assert(target_control("prepare", 1).code == "HU_SAFEPOINT_REQUIRED" and hotupgrade.patching)
assert(target_control("abort", 1).ok and not hotupgrade.patching)
registration.before_upgrade = function() error("unsafe") end
assert(target_control("prepare", 2).code == "HU_PREPARE_FAILED" and hotupgrade.patching)
assert(target_control("abort", 2).ok and not hotupgrade.patching)
registration.before_upgrade = function()
    assert(hotupgrade.patching)
    coroutine.yield()
    return {ok = true}
end
local preparing = coroutine.create(function() assert(target_control("prepare", 3).ok) end)
assert(coroutine.resume(preparing) and hotupgrade.patching)
assert(target_control("update", 3).code == "HU_SAFEPOINT_REQUIRED")
assert(coroutine.resume(preparing))
local update_steps = {}
local original_stage = patch.stage
local original_commit = patch.commit
patch.stage = function(entries)
    update_steps[#update_steps + 1] = "stage"
    return original_stage(entries)
end
patch.commit = function(stage)
    update_steps[#update_steps + 1] = "commit"
    return original_commit(stage)
end
registration.after_upgrade = function()
    update_steps[#update_steps + 1] = "after_upgrade"
    return true
end
assert(target_control("update", 4).ok and hotupgrade.patching)
patch.stage = original_stage
patch.commit = original_commit
registration.after_upgrade = nil
assert(table.concat(update_steps, ",") == "stage,commit,after_upgrade")
assert(target_control("finish", 4).ok and not hotupgrade.patching)
assert(target_control("abort", 4).ok and not hotupgrade.patching)
registration.before_upgrade = function() return true end
assert(target_control("prepare", 5).ok and target_control("update", 5).ok)
local original_finish = patch.finish
patch.finish = function() return {ok = false, code = "HU_FIXTURE_FINISH_FAILED"} end
assert(target_control("finish", 5).code == "HU_FIXTURE_FINISH_FAILED" and hotupgrade.patching)
patch.finish = original_finish
assert(target_control("abort", 5).ok and not hotupgrade.patching)
assert(target_control("stage", 6).code == "HU_UNKNOWN_COMMAND")
assert(target_control("activate", 6).code == "HU_UNKNOWN_COMMAND")
for _, failure in ipairs({"execute", "path", "register", "rpc"}) do
    _G.require = function(name)
        assert(next(permits), "实际模块执行前必须已取得许可")
        if failure == "execute" then
            package.loaded[name] = {}
            error("injected module failure")
        end
        local value, path = original_require(name)
        return value, failure == "path" and "other.lua" or path
    end
    fail_registration = failure
    local loaded_ok = pcall(hotupgrade.require, "hotupgrade_extra")
    _G.require = original_require
    assert(not loaded_ok and next(permits) == nil)
    assert(package.loaded.hotupgrade_extra == nil and package.loaded["lualib.hotupgrade_extra"] == nil)
end
-- 登记失败后新增的来源记录也必须撤销；不能把留下的表当成合法既有缓存。
package.loaded.hotupgrade_extra = last_loaded_value
local loaded_ok, load_error = pcall(hotupgrade.require, "hotupgrade_extra")
assert(not loaded_ok and tostring(load_error):find("HU_INVALID_PATH", 1, true))
assert(package.loaded.hotupgrade_extra == last_loaded_value and next(permits) == nil)
package.loaded.hotupgrade_extra = nil
fail_registration = false
local declarations_before = begin_count
local extra = hotupgrade.require("hotupgrade_extra")
assert(extra.value() == 1 and begin_count == declarations_before + 1 and next(permits) == nil)
assert(hotupgrade.require("hotupgrade_extra") == extra and begin_count == declarations_before + 1)
assert(package.loaded["lualib.hotupgrade_extra"] == extra)
package.path = original_path
print("HOTUPGRADE_FOUNDATION_LIFECYCLE_OK")
print("HOTUPGRADE_FOUNDATION_OK")
