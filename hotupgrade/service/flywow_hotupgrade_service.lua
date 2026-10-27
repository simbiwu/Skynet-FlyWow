--- 唯一控制 Service；宿主通过一次性 lua/init 交付配置。
local skynet = require "skynet"
local hotupgrade_controller = require "flywow_hotupgrade_controller"
local flywow_result = require "flywow_result"
local hotupgrade_common = require "flywow_hotupgrade_common"
local skynet_core = require "skynet.core"
local controller_initialized = false -- 成功 init 后锁定配置；失败时保持 false 以允许重试。

skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID, pack = skynet.pack, unpack = skynet.unpack})
skynet.register_protocol({name = "client", id = skynet.PTYPE_CLIENT, unpack = function() end})

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, controller_config)
        local answer
        if command ~= "init" then
            answer = flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif controller_initialized then
            answer = flywow_result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
        else
            -- MONITOR 是进程级单例；先查询，已有宿主监视器时不能覆盖。
            local monitor = skynet_core.command("MONITOR")
            if monitor then
                answer = flywow_result.failure("HU_MONITOR_OCCUPIED", "进程退出监视器已被占用: " .. monitor)
            else
                answer = hotupgrade_controller.initialize(controller_config)
                if answer.ok then
                    skynet_core.command("MONITOR", skynet.address(skynet.self()))
                    controller_initialized = true
                    answer = flywow_result.success()
                end
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)

    -- 原生退出通知没有请求载荷；消息头 source 是已退出的真实 Service handle。
    skynet.dispatch("client", function(_session, source)
        if controller_initialized then
            hotupgrade_controller:on_service_exit(source)
            -- kill 不一定返回 RPC 错误；原生 term 解除本 State 对退出目标的调用等待。
            skynet.term(source)
        end
    end)

    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local answer
        if not controller_initialized then
            answer = flywow_result.failure("HU_NOT_INITIALIZED", "宿主尚未完成 init")
        else
            local ok
            ok, answer = pcall(hotupgrade_controller.handle_command, hotupgrade_controller, command, request, source)
            if not ok then
                answer = flywow_result.failure("HU_CONTROL_FAILED", tostring(answer))
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
