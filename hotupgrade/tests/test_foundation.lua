--- 普通 Lua 状态图、模块身份、状态迁移与 Guard 失败合同。
local patch = require "flywow_hotupgrade_module_patch"
local guard = require "flywow_hotupgrade_guard"
local now = 0
local gate = guard.new({now = function() return now end, sleep = function(ms) now = now + ms end})
assert(gate:enter().ok)
assert(gate:prepare_upgrade("busy").ok)
assert(not gate:enter().ok and not gate:wait_idle("busy", 20).ok)
assert(gate:leave().ok and gate:wait_idle("busy", 20).ok)
assert(not gate:resume("wrong").ok and gate:resume("busy").ok)
assert(not gate:run(function() error("business failure") end).ok and gate.active == 0)

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
local loaded = {logic = live}
local engine = patch.new({loaded = loaded})
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
local staged = engine:stage({{name = "logic", source = source}})
assert(staged.ok, staged.message)
assert(live.value() == 7 and old_state.count == 7)
assert(engine:commit(staged.stage).ok)
assert(loaded.logic == live and live.value() == 8 and cached() == 7)
assert(live.added == 42 and live.removed == nil)
assert(engine:abort(staged.stage).ok)
assert(live.value == cached and live.removed and live.added == nil)

local failed = engine:stage({{name = "logic", source = "error('stage failed')"}})
assert(not failed.ok and live.value() == 7 and not engine.active)
failed = engine:stage({{name = "logic", source = "return {value=function() return 3 end}"}})
assert(not failed.ok and live.value() == 7)
staged = engine:stage({{name = "logic", source = source}})
assert(staged.ok and engine:commit(staged.stage).ok)
loaded.logic = {}
assert(engine:abort(staged.stage).code == "HU_RECOVERY_REQUIRED")
loaded.logic = live
assert(engine:abort(staged.stage).ok)
-- 无状态模块不需要钩子；多模块中一个 Stage 失败不能提前安装其他模块。
local simple = {value = function() return 1 end}
local more = patch.new({loaded = {a = simple, b = {value = function() return 1 end}}})
local rejected = more:stage({
    {name = "a", source = "return {value = function() return 2 end}"},
    {name = "b", source = "error('second module failed')"},
})
assert(not rejected.ok and simple.value() == 1 and not more.active)
local missing = patch.new({loaded = {a = {export_state = function() return {} end}}})
assert(not missing:stage({{name = "a", source = "return {}"}}).ok)
local broken = patch.new({loaded = {a = {
    value = function() return 1 end,
    export_state = function() return {} end,
    import_state = function() end,
}}})
assert(not broken:stage({{name = "a", source = [[return {
    value = function() return 2 end,
    export_state = function() return {} end,
    import_state = function() error("import failed") end,
}]]}}).ok)
assert(not broken.active)
print("HOTUPGRADE_FOUNDATION_OK")
