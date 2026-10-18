--- 稳定 Router 的路由绑定、暂停拒绝、实例切换和撤销合同。
local router_module = require "flywow_hotupgrade_router"
local router = router_module.new() -- 此测试独占的路由状态，贯穿绑定、切换与撤销断言。

assert(router:bind("x", {instance_handle = 1}).ok)
assert(router:pause("x", "t").ok)
local paused = router:request("x", "read", {}, 10)
assert(not paused.ok and paused.code == "HU_ROUTE_PAUSED")
assert(router:switch("x", "t", 1, {instance_handle = 2}).ok)
assert(router:resume("x", "t").ok)
assert(router.routes.x.record.instance_handle == 2)

-- 未提交时撤销暂停只恢复服务，不改变当前路由实例。
assert(router:pause("x", "u").ok)
assert(router:abort("x", "u").ok)
assert(router.routes.x.record.instance_handle == 2)
assert(not router:switch("x", "stale", 2, {instance_handle = 3}).ok)
print("HOTUPGRADE_ROUTER_OK")
