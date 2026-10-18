--- 测试旧实例入口；测试上下文通过显式 init 请求交付。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local initialized = false -- 测试 Service 的 init 一次性状态；成功创建后置 true。

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, options)
        local answer
        if command ~= "init" then
            answer = result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif initialized then
            answer = result.failure("HU_ALREADY_INITIALIZED", "测试 Service 已初始化")
        elseif type(options) ~= "table" or type(options.controller_handle) ~= "number" then
            answer = result.failure("HU_INVALID_OPTIONS", "init 需要 Controller handle")
        else
            local ok, message = pcall(function() require("test_worker_factory")(options) end)
            if ok then
                initialized = true
                answer = result.success()
            else
                answer = result.failure("HU_CREATE_FAILED", tostring(message))
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
