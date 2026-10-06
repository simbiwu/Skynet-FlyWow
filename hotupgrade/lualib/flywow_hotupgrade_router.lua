--- 稳定路由 owner 的有界入口；队列属于 owner，替换目标时不迁移调用方 coroutine。
local result = require "flywow_hotupgrade_error"
local snapshot = require "flywow_hotupgrade_snapshot"
local M = {}
local Router = {}
Router.__index = Router

---@param options table deliver(record,command,payload)/fork(fn)/now()/max_queue/max_bytes
---@return table 路由 owner 独占
function M.new(options)
    return setmetatable({options = options, routes = {}, queue_count = 0, queue_bytes = 0}, Router)
end

---@param key string 逻辑身份
---@param record table 地址、代际及版本
---@return flywow_hotupgrade_result
function Router:bind(key, record)
    if self.routes[key] then return result.failure("HU_ROUTE_EXISTS", key) end
    self.routes[key] = {current = record, queue = {}, active = 0}
    return result.success()
end

---@param key string 逻辑身份
---@return flywow_hotupgrade_result
function Router:query(key)
    local route = self.routes[key]
    if not route then return result.failure("HU_TARGET_MISSING", key) end
    return result.success({record = route.current, paused = route.owner ~= nil})
end

---@param key string 逻辑身份
---@param txn_id string 暂停 owner
---@return flywow_hotupgrade_result
function Router:pause(key, txn_id)
    local route = self.routes[key]
    if not route then return result.failure("HU_TARGET_MISSING", key) end
    if route.owner and route.owner ~= txn_id then return result.failure("HU_UPGRADE_BUSY", key) end
    route.owner = txn_id
    route.saved = route.saved or route.current
    return result.success()
end

---@param key string 逻辑身份
---@param txn_id string owner
---@param expected integer 旧代际
---@param record table 新目标
---@return flywow_hotupgrade_result
function Router:switch(key, txn_id, expected, record)
    local route = self.routes[key]
    if not route or route.owner ~= txn_id or route.current.generation ~= expected then
        return result.failure("HU_ROUTE_SWITCH_FAILED", key)
    end
    route.current = record
    return result.success()
end

local function queued(router, route, command, payload, reply)
    local cloned = snapshot.clone(payload)
    if not cloned.ok then return cloned end
    local maximum = router.options.max_queue or 256
    local byte_limit = router.options.max_bytes or 1024 * 1024
    if router.queue_count >= maximum or router.queue_bytes + cloned.bytes > byte_limit then
        return result.failure("HU_QUEUE_OVERFLOW", "入口队列超限")
    end
    route.queue[#route.queue + 1] = {command = command, payload = cloned.value,
        reply = reply, bytes = cloned.bytes, admitted = router.options.now()}
    router.queue_count = router.queue_count + 1
    router.queue_bytes = router.queue_bytes + cloned.bytes
    return result.success({queued = true})
end

--- reply 属于稳定 owner，恰好回应一次；暂停时可 queue 或明确 reject。
---@param key string 逻辑目标
---@param command string 宿主命令
---@param payload any 可序列化 record
---@param reply function 结果回调，由 owner 持有
---@param policy? string queue/reject
---@return flywow_hotupgrade_result
function Router:submit(key, command, payload, reply, policy)
    local route = self.routes[key]
    if not route then return result.failure("HU_TARGET_MISSING", key) end
    if route.owner or route.draining then
        if policy ~= "queue" then return result.failure("HU_UPGRADING", key) end
        return queued(self, route, command, payload, reply)
    end
    route.active = route.active + 1
    local record = route.current
    self.options.fork(function()
        local ok, answer = pcall(self.options.deliver, record, command, payload)
        route.active = route.active - 1
        reply(ok and answer or result.failure("HU_DELIVERY_FAILED", tostring(answer)))
    end)
    return result.success()
end

function Router:flush(route)
    while not route.owner and #route.queue > 0 do
        local item = table.remove(route.queue, 1)
        self.queue_count = self.queue_count - 1
        self.queue_bytes = self.queue_bytes - item.bytes
        if self.options.now() - item.admitted > (self.options.queue_timeout_ms or 10000) then
            item.reply(result.failure("HU_QUEUE_TIMEOUT", "排队请求已过期"))
        else
            route.active = route.active + 1
            local ok, answer = pcall(self.options.deliver, route.current, item.command, item.payload)
            route.active = route.active - 1
            item.reply(ok and answer or result.failure("HU_DELIVERY_FAILED", tostring(answer)))
        end
    end
    route.draining = false
end

---@param key string 逻辑目标
---@param txn_id string owner
---@return flywow_hotupgrade_result
function Router:resume(key, txn_id)
    local route = self.routes[key]
    if not route or route.owner ~= txn_id then return result.failure("HU_STALE_TRANSACTION", key) end
    route.owner, route.saved = nil, nil
    route.draining = true
    self.options.fork(function() self:flush(route) end)
    return result.success()
end

---@param key string 逻辑目标
---@param txn_id string owner
---@return flywow_hotupgrade_result
function Router:abort(key, txn_id)
    local route = self.routes[key]
    if not route or route.owner ~= txn_id then return result.failure("HU_STALE_TRANSACTION", key) end
    route.current = route.saved
    return self:resume(key, txn_id)
end

return M
