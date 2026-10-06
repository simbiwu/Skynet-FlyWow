--- 基础合同测试；使用固定 Lua 运行器，不启动业务 Service。
local result = require "flywow_hotupgrade_error"
local snapshot = require "flywow_hotupgrade_snapshot"
local transaction = require "flywow_hotupgrade_transaction"
local guard = require "flywow_hotupgrade_guard"
local module_patch = require "flywow_hotupgrade_module_patch"
local registry = require "flywow_hotupgrade_registry"
local migration = require "flywow_hotupgrade_migration"
local dependency = require "flywow_hotupgrade_dependency"

local cloned = snapshot.clone({schema_version = 1, nested = {value = 3}})
assert(cloned.ok)
local original = {x = {}}
local copied = snapshot.clone(original)
copied.value.x.value = 8
assert(original.x.value == nil)
local cycle = {}
cycle.self = cycle
assert(not snapshot.clone(cycle).ok)
assert(not snapshot.clone({f = function() end}).ok)
assert(not snapshot.clone({a = "abcdef"}, {max_bytes = 2}).ok)
assert(not result.execute(function() coroutine.yield() end).ok)
assert(not result.execute(function() while true do end end, 2000).ok)
assert(not result.initialize(function() while true do end end, 2000).ok)
assert(result.initialize(function() return true end, 2000).ok)

local txn = transaction.new("t1")
assert(not txn:move("PUBLISHED").ok)
for _, phase in ipairs({"VALIDATING", "PREPARING", "STAGING", "READY", "ACTIVATING", "PUBLISHED", "COMPLETED"}) do
    assert(txn:move(phase).ok)
end

local now = 0
local g = guard.new({now = function() return now end, sleep = function(ms) now = now + ms end})
assert(g:enter().ok)
assert(g:prepare_upgrade("t1").ok)
assert(not g:enter().ok)
assert(not g:wait_idle("t1", 20).ok)
assert(g:leave().ok)
assert(g:wait_idle("t1", 20).ok)
assert(not g:resume("stale").ok)
assert(g:resume("t1").ok)
assert(not g:run(function() error("failure") end).ok)
assert(g.active == 0)

local loaded = {a = {value = function() return 1 end}}
local held = loaded.a
local engine = module_patch.new({loaded = loaded})
local staged = engine:stage(
{
    {name = "a", source = 'local b = require "b"; local M = {}; function M.value() return b.value() end; return M', code_version = 2},
    {name = "b", action = "add", source = 'local M = {}; function M.value() return 2 end; return M', code_version = 1},
})
assert(staged.ok, staged.message)
assert(held.value() == 1 and loaded.b == nil)
assert(engine:commit(staged.stage).ok)
assert(held == loaded.a and held.value() == 2)
loaded.b.value = function() return 4 end
assert(held.value() == 4, "依赖必须绑定线上 table")
assert(engine:abort(staged.stage).ok)
assert(held.value() == 1 and loaded.b == nil)

local failed = engine:stage({{name = "a", source = "invalid lua ?"}})
assert(not failed.ok and held.value() == 1)
local good = engine:stage({{name = "a", source = "return {value=function() return 9 end}"}})
assert(good.ok)
assert(not engine:commit(good.stage, function() return false end).ok)
assert(held.value() == 1)

local stable = {counter = {value = 7, nested = {value = 3}}}
local stable_engine = module_patch.new({loaded = loaded, stable = stable})
local stable_stage = stable_engine:stage({{name = "a", source = [[
    local state = require "flywow_hotupgrade".stable_state("counter")
    return {value = function() state.value = state.value + 1; return state.value end}
]]}})
assert(stable_stage.ok and stable.counter.value == 7)
assert(stable_engine:commit(stable_stage.stage).ok)
assert(held.value() == 8 and stable.counter.value == 8)
assert(stable_engine:abort(stable_stage.stage).ok)
assert(held.value() == 1)
assert(not stable_engine:stage({{name = "a", source = [[
    local state = require "flywow_hotupgrade".stable_state("counter")
    state.nested.value = 99
    return {value = function() return 0 end}
]]}}).ok)
assert(stable.counter.nested.value == 3)

loaded.external = {mutate = function() stable.counter.value = 99 end}
local external_stage = stable_engine:stage({{name = "a", source = [[
    require "external".mutate()
    return {value = function() return 0 end}
]]}})
assert(not external_stage.ok and stable.counter.value == 8)
local external_closure = stable_engine:stage({{name = "a", source = [[
    local dependency = require "external"
    return {value = function() dependency.mutate(); return 99 end}
]]}})
assert(external_closure.ok)
assert(stable_engine:commit(external_closure.stage).ok)
assert(held.value() == 99 and stable.counter.value == 99)
assert(stable_engine:abort(external_closure.stage).ok)

local reg = registry.new()
assert(reg:register({key = "B", address = 11, generation = 1}).ok)
assert(reg:declare("A-old", {{target = "B", edge = "strong"}}).ok)
assert(reg:register({key = "B", address = 12, generation = 2, candidate = true}).ok)
assert(reg:publish("B", 1, 2).ok)
assert(reg:resolve("A-old", "B").record.address == 11)
assert(not reg:retire("B", 1).ok)
assert(not reg:resolve("unknown", "B").ok)
reg:release("A-old")
assert(reg:retire("B", 1).ok)
assert(reg:declare("A-new", {{target = "B", edge = "strong"}}).ok)
assert(reg:acquire("A-new", "B", "one").ok)
assert(reg:acquire("A-new", "B", "two").ok)
assert(reg:release_binding("A-new", "B", "one").ok)
assert(reg:release_binding("A-new", "B", "one").ok)
assert(reg:strong_count("B", 2) == 1)
assert(reg:release_binding("A-new", "B", "two").ok)
assert(reg:strong_count("B", 2) == 0)
assert(dependency.validate({A = {{target = "B", edge = "strong"}}, B = {{target = "A", edge = "weak"}}}).ok)
assert(not dependency.validate({A = {{target = "B", edge = "strong"}}, B = {{target = "A", edge = "strong"}}}).ok)

local chain = migration.resolve({{from = 1, to = 2, up = function(state)
    state.schema_version = 2
    state.extra = true
    return state
end}}, 1, 2)
assert(chain.ok)
local state = {schema_version = 1}
local upgraded = migration.apply(state, chain.chain, {})
assert(upgraded.ok and upgraded.value.extra and state.schema_version == 1)
assert(not migration.resolve({}, 1, 2).ok)
print("HOTUPGRADE_FOUNDATION_OK")
