--- 唯一控制 Service；宿主通过一次性 lua/init 交付配置。
local skynet = require "skynet"
local hotupgrade_controller = require "flywow_hotupgrade_controller"
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"
local controller_initialized = false -- 成功 init 后锁定配置；失败时保持 false 以允许重试。

skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID, pack = skynet.pack, unpack = skynet.unpack})

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, controller_config)
        local answer
        if command ~= "init" then
            answer = hotupgrade_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif controller_initialized then
            answer = hotupgrade_result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
        else
            answer = hotupgrade_controller.initialize(controller_config)
            if answer.ok then
                controller_initialized = true
                answer = hotupgrade_result.success()
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)

    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local answer
        if not controller_initialized then
            answer = hotupgrade_result.failure("HU_NOT_INITIALIZED", "宿主尚未完成 init")
        else
            local ok
            ok, answer = pcall(hotupgrade_controller.handle_command, hotupgrade_controller, command, request, source)
            if not ok then
                answer = hotupgrade_result.failure("HU_CONTROL_FAILED", tostring(answer))
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
