--- 唯一控制 Service；宿主通过一次性 lua/init 交付配置。
local skynet = require "skynet" -- 注册控制协议、分发 RPC，并向调用方回复处理结果。
local hotupgrade_controller = require "flywow_hotupgrade_controller" -- 保存热更批次和 Service 登记记录。
local flywow_result = require "flywow_result" -- 构造协议回复中的成功或失败结果。
local hotupgrade_common = require "flywow_hotupgrade_common" -- 提供 HotUpgrade 原生消息协议号。
local skynet_core = require "skynet.core" -- 查询并设置 Skynet 进程级退出监视器。
local controller_initialized = false -- 只有初始化成功后才接收管理命令；失败时宿主可重试 init。

skynet.register_protocol(
{
    name   = "hotupgrade",                 -- Controller 与目标 Service 用此协议传递控制命令。
    id     = hotupgrade_common.PROTOCOL_ID, -- 双方共同注册的协议编号。
    pack   = skynet.pack,                   -- 使用 Skynet 的原生序列化函数。
    unpack = skynet.unpack,                 -- 使用 Skynet 的原生反序列化函数。
})
-- client 消息只用于通知 Service 退出，没有请求体，因此解包回调不返回参数。
skynet.register_protocol(
{
    name   = "client",           -- 接收 Skynet 发来的进程退出通知。
    id     = skynet.PTYPE_CLIENT, -- 使用 Skynet 预定义的 client 消息类型。
    unpack = function() end,     -- MONITOR 退出通知没有请求体需要解包。
})

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, controller_config)
        -- 该 init RPC 的唯一回复值；参数错误、重复初始化和初始化结果都在这里返回。
        local answer
        if command ~= "init" then
            answer = flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif controller_initialized then
            answer = flywow_result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
        else
            -- MONITOR 是进程级单例；宿主已设置时不能用 HotUpgrade 的地址覆盖。
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
        -- request 是解包后的管理/许可内容；source 是消息发送方 handle，Controller 用它核对请求权限。
        -- Controller 返回 FlyWowResult；校验失败、命令失败和成功结果最终都通过它回复调用方。
        local answer
        if not controller_initialized then
            answer = flywow_result.failure("HU_NOT_INITIALIZED", "宿主尚未完成 init")
        else
            -- Controller 命令可能抛出意外异常；协议入口将异常转换为失败回复。
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
