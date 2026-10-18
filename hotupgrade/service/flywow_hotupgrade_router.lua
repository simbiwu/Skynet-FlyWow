--- 稳定路由 Service：暂停期间拒绝新请求并排空已接纳调用；控制面不代理业务流量。
local skynet = require "skynet"
local protocol = require "flywow_hotupgrade_protocol"
local router_module = require "flywow_hotupgrade_router"
local result = require "flywow_hotupgrade_error"
local controller_handle = tonumber(...) -- 启动参数传入的 Controller Service handle。
-- Router 本地调用排空最多等待 10 秒；单位换算为 Skynet 的 10 毫秒 tick。
local ROUTE_DRAIN_TIMEOUT_MS = 10000

local router = router_module.new() -- 当前 Router Service 独占的路由表与在途计数。

local function request(payload, source)
    return router:request(payload.origin_service_handle, payload.command, payload.payload, source)
end

local function pause(payload)
    local paused = router:pause(payload.origin_service_handle, payload.txn_id)
    if not paused.ok then
        return paused
    end
    -- active 统计已进入 Router 的调用直到 RPC 返回，避免暂停前的转发仍悬挂。
    local deadline = skynet.now() + math.ceil(ROUTE_DRAIN_TIMEOUT_MS / 10)
    while router.routes[payload.origin_service_handle].active > 0 do
        if skynet.now() >= deadline then
            return result.failure("HU_SAFEPOINT_TIMEOUT", "路由在途请求未完成")
        end
        skynet.sleep(1)
    end

    return result.success()
end

skynet.start(function()
    protocol.install_handler(function(command, payload, source)
        -- 业务请求沿稳定 Router 路由；只有启动时注入的控制面可修改绑定与暂停状态。
        if command == "request" then
            return request(payload, source)
        end
        if source ~= controller_handle then
            return result.failure("HU_UNAUTHORIZED", "路由控制来源不匹配")
        end

        if command == "bind" then
            return router:bind(payload.origin_service_handle, payload.record)
        end
        if command == "pause" then
            return pause(payload)
        end
        if command == "switch" then
            return router:switch(payload.origin_service_handle, payload.txn_id, payload.expected, payload.record)
        end
        if command == "resume" then
            return router:resume(payload.origin_service_handle, payload.txn_id)
        end
        if command == "abort" then
            return router:abort(payload.origin_service_handle, payload.txn_id)
        end
        return result.failure("HU_UNKNOWN_COMMAND", command)
    end)
end)
