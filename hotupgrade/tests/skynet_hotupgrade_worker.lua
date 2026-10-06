--- 测试旧实例入口，由 fixture factory 统一建立接入合同。
local skynet = require "skynet"
local controller, service_id, router = ...
skynet.start(function()
    require("test_worker_factory")(
    {
        controller = tonumber(controller), service_type = "worker",
        service_id = tonumber(service_id), generation = 1, code_version = 1, state_version = 1,
        dependencies = {},
        router_handle = tonumber(router),
    })
end)
