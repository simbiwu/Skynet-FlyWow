--- 唯一控制 Service；宿主通过一次性 lua/init 交付配置。
local skynet = require "skynet" -- 注册协议和分发消息，提供当前 Service handle 与 RPC 返回。
local hotupgrade_controller = require "flywow_hotupgrade_controller" -- 持有唯一控制面状态并执行管理命令。
local flywow_result = require "flywow_result" -- 将入口校验和 Controller 异常转换为统一结果表。
local hotupgrade_common = require "flywow_hotupgrade_common" -- 提供 HotUpgrade 原生消息协议号。
local skynet_core = require "skynet.core" -- 查询并设置 Skynet 进程级退出监视器。
local controller_initialized = false -- 成功 init 后锁定配置；失败时保持 false 以允许重试。

skynet.register_protocol({name = "hotupgrade", id = hotupgrade_common.PROTOCOL_ID,
    pack = skynet.pack, unpack = skynet.unpack})
-- client 消息只用于通知 Service 退出，没有请求体，因此解包回调不返回参数。
skynet.register_protocol({name = "client", id = skynet.PTYPE_CLIENT, unpack = function() end})

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, controller_config)
        -- 当前 init 请求最终回复给宿主的结果，所有分支都在这里形成它。
        local answer
        if command ~= "init" then
            answer = flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif controller_initialized then
            answer = flywow_result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
        else
            -- MONITOR 是进程级单例；先查询，已有宿主监视器时不能覆盖。
            -- 进程当前的退出监视器；已被宿主占用时 HotUpgrade 不覆盖它。
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
        -- request 是解包后的管理/许可请求；source 来自消息头，Controller 用它核对创建者、登记者和当前更新目标。
        -- 当前管理请求最终返回给调用方的 FlyWowResult。
        local answer
        if not controller_initialized then
            answer = flywow_result.failure("HU_NOT_INITIALIZED", "宿主尚未完成 init")
        else
            -- Controller 命令调用是否正常返回，以及它产生的结果或异常。
            local command_succeeded, command_result = pcall(
                hotupgrade_controller.handle_command, hotupgrade_controller, command, request, source)
            if not command_succeeded then
                answer = flywow_result.failure("HU_CONTROL_FAILED", tostring(command_result))
            else
                answer = command_result
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
