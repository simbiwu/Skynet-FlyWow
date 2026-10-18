--- 基础合同测试；使用固定 Lua 运行器，不启动业务 Service。
local result = require "flywow_hotupgrade_error"
local guard = require "flywow_hotupgrade_guard"
local module_patch = require "flywow_hotupgrade_module_patch"
local registry = require "flywow_hotupgrade_registry"

-- 纯 Lua 隔离执行器验证裸 yield 和预算；不据此声称能撤销 Skynet API 的调度注册。
assert(not result.execute(function()
    coroutine.yield()
end).ok)
assert(not result.execute(function()
    while true do
    end
end, 2000).ok)
assert(not result.initialize(function()
    while true do
    end
end, 2000).ok)
assert(result.initialize(function()
    return true
end, 2000).ok)

-- Guard 通过可控时钟验证安全点等待、超时和异常后的计数恢复。
local now = 0 -- Guard 测试使用的毫秒时钟；sleep 通过累加推进时间。
local g = guard.new(
{
    now = function()
        return now
    end,
    sleep = function(ms)
        now = now + ms
    end,
})
assert(g:enter().ok)
assert(g:prepare_upgrade("t1").ok)
assert(not g:enter().ok)
assert(not g:wait_idle("t1", 20).ok)
assert(g:leave().ok)
assert(g:wait_idle("t1", 20).ok)
assert(not g:resume("stale").ok)
assert(g:resume("t1").ok)
assert(not g:run(function()
    error("failure")
end).ok)
assert(g.active == 0)

-- Registry 只保留当前实例；候选不入表，发布按旧实例身份比较。
local reg = registry.new()
local initial = {origin_service_handle = 10, instance_handle = 11}
local candidate = {origin_service_handle = 10, instance_handle = 12, candidate = true}
assert(reg:register(initial).ok)
assert(not reg:register(candidate).ok and reg.targets[10] == initial)
assert(not reg:publish(10, 10, candidate).ok)
assert(reg:publish(10, 11, candidate).ok)
assert(reg.targets[10] == candidate and not candidate.candidate)
assert(not reg:publish(10, 11, candidate).ok)

-- 原地更新只替换已加载模块；业务状态通过参数传入，保留稳定导出表身份。
local loaded =
{
    a = {value = function(state) return state.count end, removed = true},
    b = {value = function() return 1 end},
}
local held, cached_function = loaded.a, loaded.a.value
local business = {count = 7}
local engine = module_patch.new({loaded = loaded})
local function update(source)
    return engine:stage({{name = "a", source = source}})
end
local staged = update([[return {value = function(state) return state.count + 1 end}]])
assert(staged.ok and held.value(business) == 7)
assert(not update("return {}").ok, "未完成的 Stage 不可被覆盖")
assert(engine:commit(staged.stage).ok)
assert(held == loaded.a and held.value(business) == 8 and held.removed == nil)
assert(cached_function(business) == 7, "缓存的函数不会被自动替换")
assert(business.count == 7, "框架不复制或迁移 Service 状态")
assert(engine:abort(staged.stage).ok and engine:abort(staged.stage).ok)
assert(held.value(business) == 7 and held.removed == true)

-- 所有模块通过加载检查后才允许安装；任一文件失败不能修改其它模块。
assert(not engine:stage({
    {name = "a", source = "return {value = function() return 9 end}"},
    {name = "b", source = "error('load failure')"},
}).ok)
assert(held.value(business) == 7 and loaded.b.value() == 1)
assert(not update("invalid lua ?").ok)
assert(not update("return false").ok)
assert(not update("return setmetatable({}, {})").ok)
assert(not update("return {state = {count = 1}}").ok)
assert(not update("return {value = 3}").ok)
assert(not engine:stage({{name = "missing", source = "return {}"}}).ok)
assert(not engine:stage({{name = "a", source = "return {}"},
    {name = "a", source = "return {}"}}).ok)
assert(not engine:stage({[2] = {name = "a", source = "return {}"}}).ok)

loaded.stateful = {state = {count = 1}}
assert(not engine:stage({{name = "stateful", source = "return {}"}}).ok)
assert(loaded.stateful.state.count == 1, "旧模块持有的业务状态不能被静默删除")

-- 同一更新内的依赖始终持有原线上表；全部安装后才执行新业务代码。
local paired = engine:stage({
    {name = "a", source = 'local b = require "b"; return {value = function() return b.value() end}'},
    {name = "b", source = "return {value = function() return 6 end}"},
})
assert(paired.ok and held.value(business) == 7 and loaded.b.value() == 1)
assert(engine:commit(paired.stage).ok and held.value() == 6)
assert(engine:abort(paired.stage).ok and held.value(business) == 7 and loaded.b.value() == 1)

-- postcheck 是现有控制面的受信检查：拒绝或异常均恢复完整旧导出集合。
for _, check in ipairs({function() return false end, function() error("rejected") end}) do
    local candidate = update("return {value = function() return 9 end}")
    assert(candidate.ok and not engine:commit(candidate.stage, check).ok)
    assert(held.value(business) == 7 and held.removed == true)
end

-- 依赖只引用已有模块表；模块加载不调用依赖，后续业务通过表取得当前函数。
loaded.hotupgrade_fixture_dependency = loaded.b
local dependency = update([[local b = require "hotupgrade_fixture_dependency"
    return {value = function() return b.value() end}]])
assert(dependency.ok and engine:commit(dependency.stage).ok)
assert(held.value() == 1)
loaded.b.value = function() return 4 end
assert(held.value() == 4)
assert(engine:finish(dependency.stage).ok)
assert(next(dependency.stage.old) == nil and next(dependency.stage.entries) == nil)
assert(not engine:abort(dependency.stage).ok, "发布后回滚必须重新应用旧代码")
loaded.hotupgrade_fixture_dependency = nil

-- 连续更新和旧文件回滚都保留同一导出表，不依赖历史候选表或私有状态代理。
for _, value in ipairs({2, 3, 1}) do
    local candidate = update("return {value = function() return " .. value .. " end}")
    assert(candidate.ok and engine:commit(candidate.stage).ok)
    assert(engine:finish(candidate.stage).ok)
    assert(loaded.a == held and held.value() == value)
end
print("HOTUPGRADE_FOUNDATION_OK")
