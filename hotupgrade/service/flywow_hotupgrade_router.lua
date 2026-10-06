--- 稳定路由 Service：持有排队回应，目标换代后继续投递；控制面不代理业务流量。
local skynet = require "skynet"
local rpc = require "flywow_hotupgrade_rpc"
local router_module = require "flywow_hotupgrade_router"
local result = require "flywow_hotupgrade_error"
local controller = tonumber(...)

local router = router_module.new(
{
    fork = skynet.fork, now = function() return skynet.now() * 10 end,
    deliver = function(record, command, payload)
        return rpc.call(record.address, "invoke",
            {generation = record.generation, instance_id = record.instance_id,
                command = command, payload = payload}, 10000)
    end,
})

local function request(payload)
    local caller = coroutine.running()
    local done, answer = false, nil
    local admitted = router:submit(payload.key, payload.command, payload.payload, function(value)
        answer, done = value, true
        skynet.wakeup(caller)
    end, payload.policy or "reject")
    if not admitted.ok then return admitted end
    if not done then skynet.wait(caller) end
    return answer
end

local function pause(payload)
    local paused = router:pause(payload.key, payload.txn_id)
    if not paused.ok then return paused end
    local deadline = skynet.now() + 1000
    while router.routes[payload.key].active > 0 do
        if skynet.now() >= deadline then return result.failure("HU_SAFEPOINT_TIMEOUT", "路由在途请求未完成") end
        skynet.sleep(1)
    end
    return result.success()
end

skynet.start(function()
    rpc.install(function(command, payload, source)
        if command == "request" then return request(payload) end
        if source ~= controller then return result.failure("HU_UNAUTHORIZED", "路由控制来源不匹配") end
        if command == "bind" then return router:bind(payload.key, payload.record) end
        if command == "pause" then return pause(payload) end
        if command == "switch" then return router:switch(payload.key, payload.txn_id, payload.expected, payload.record) end
        if command == "resume" then return router:resume(payload.key, payload.txn_id) end
        if command == "abort" then return router:abort(payload.key, payload.txn_id) end
        if command == "query" then return router:query(payload.key) end
        return result.failure("HU_UNKNOWN_COMMAND", command)
    end)
end)
