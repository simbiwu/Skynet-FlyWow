--- 唯一控制 Service；宿主通过一次性 lua/init 交付配置。
local skynet = require "skynet"
local controller_module = require "flywow_hotupgrade_controller"
local result = require "flywow_hotupgrade_error"
local controller -- init 成功后持有；失败允许宿主修正配置后重试。

skynet.register_protocol({name = "hotupgrade", id = 20, pack = skynet.pack, unpack = skynet.unpack})

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, options)
        local answer
        if command ~= "init" then
            answer = result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif controller then
            answer = result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
        else
            local opened = controller_module.new(options)
            answer = opened
            if opened.ok then
                controller = opened.controller
                answer = result.success()
            end
        end
        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local answer
        if not controller then
            answer = result.failure("HU_NOT_INITIALIZED", "宿主尚未完成 init")
        else
            local ok
            ok, answer = pcall(controller.control, controller, command, request, source)
            if not ok then
                answer = result.failure("HU_CONTROL_FAILED", tostring(answer))
            end
        end
        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
