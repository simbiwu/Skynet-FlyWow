--- 路由 owner 保持存活时的暂停、换代、溢出、撤销和有序恢复。
local router_module = require "flywow_hotupgrade_router"
local pending, seen = {}, {}
local now = 0
local router = router_module.new(
{
    now = function() return now end,
    fork = function(fn) pending[#pending + 1] = fn end,
    deliver = function(record, command, payload)
        seen[#seen + 1] = record.generation .. ":" .. payload
        return {ok = true}
    end,
    max_queue = 2,
})
assert(router:bind("x", {generation = 1}).ok)
assert(router:pause("x", "t").ok)
assert(router:submit("x", "x", "a", function() end, "queue").ok)
assert(router:submit("x", "x", "b", function() end, "queue").ok)
assert(not router:submit("x", "x", "c", function() end, "queue").ok)
assert(#seen == 0)
assert(router:switch("x", "t", 1, {generation = 2}).ok)
assert(router:resume("x", "t").ok)
pending[1]()
assert(table.concat(seen, ",") == "2:a,2:b")
assert(router.queue_bytes == 0 and router.queue_count == 0)
assert(router:pause("x", "u").ok)
assert(router:switch("x", "u", 2, {generation = 3}).ok)
assert(router:abort("x", "u").ok)
assert(router:query("x").record.generation == 2)
print("HOTUPGRADE_ROUTER_OK")
