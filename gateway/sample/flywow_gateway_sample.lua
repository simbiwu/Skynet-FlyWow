--- 宿主样例：启动 Gateway，按同一连接发送 FrameJoin 响应与 FramePush，收到断开后停止进程。
local skynet = require "skynet"
require "skynet.manager"

local SAMPLE_HANDLER_SERVICE = ".flywow_gateway_sample_handler" -- 本进程注册的 handler 名称，显式传给 Gateway 配置。
local SAMPLE_PORT = assert(tonumber(os.getenv("FLYWOW_GATEWAY_SAMPLE_PORT"))) -- Shell 为本次运行选取的 loopback 端口。
local SAMPLE_MODE = assert(os.getenv("FLYWOW_GATEWAY_SAMPLE_MODE")) -- Shell 选定的 sample 传输模式。
local SAMPLE_TRANSPORT = SAMPLE_MODE == "websocket" and "websocket" or "tcp" -- 将样例启动模式映射为 Gateway 支持的传输名。

local module_state =
{
    gateway_service_handle = nil,   -- 本示例唯一 Gateway Service；由启动协程创建并供消息回调使用。
    connection_closed      = false, -- handler 收到断开通知后置位，驱动测试收尾协程退出。
    request_received       = false, -- 收到 FrameJoin 后置位，关闭前用于确认请求链路已执行。
}

skynet.start(function()
    skynet.name(SAMPLE_HANDLER_SERVICE, skynet.self())
    skynet.dispatch("lua", function(session, _, command, message)
        if command == "send_data" then
            assert(message.command_id == 1101 and message.data.scenario_id == 1)
            assert(message.data.battle_id == 0 and message.data.simulation_version == 1)
            module_state.request_received = true
            skynet.error("FLYWOW_GATEWAY_SAMPLE_REQUEST_RECEIVED mode=" .. SAMPLE_MODE)

            -- 同一连接先收到 FrameJoin 响应，再收到服务端主动 FramePush。
            skynet.send(module_state.gateway_service_handle, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch, -- 沿用请求的 Gateway 实例身份，拒绝旧实例消息。
                connection_id = message.connection_id, -- 沿用来源连接号，定向投递给同一客户端。
                command_id = 1101, -- 选择样例 schema 中的响应或 Push 消息类型。
                data = -- FrameJoin 的固定样例成功响应。
                {
                    code = "OK", -- 样例业务接纳结果。
                    battle_id = 42, -- 后续 Push 沿用的样例战斗编号。
                    seat_id = 1, -- 本连接分配的样例座位。
                },
            })

            skynet.send(module_state.gateway_service_handle, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch, -- 沿用请求的 Gateway 实例身份，拒绝旧实例消息。
                connection_id = message.connection_id, -- 沿用来源连接号，定向投递给同一客户端。
                command_id = 1103, -- 选择样例 schema 中的响应或 Push 消息类型。
                data = -- 请求响应后主动下发的样例状态。
                {
                    battle_id = 42, -- 与 FrameJoin 响应对应的战斗编号。
                    generation = 1, -- 当前样例的战斗代次。
                    code = "OK", -- 样例状态成功标记。
                },
            })
            skynet.error("FLYWOW_GATEWAY_SAMPLE_PUSH_SENT mode=" .. SAMPLE_MODE)
        elseif command == "gateway_disconnect" then
            module_state.connection_closed = true
        else
            error("unexpected Gateway command: " .. tostring(command))
        end

        if session ~= 0 then
            skynet.retpack(true)
        end
    end)

    module_state.gateway_service_handle = skynet.newservice("gateway/flywow_gateway")
    local gateway_config = {} -- 从宿主预设复制的启动配置副本，仅追加本 sample 的 handler/端口/传输设置。
    for key, value in pairs(require "gateway_frame_sync") do
        gateway_config[key] = value
    end
    gateway_config.handler_service = SAMPLE_HANDLER_SERVICE
    gateway_config.port = SAMPLE_PORT
    gateway_config.transport = SAMPLE_TRANSPORT
    gateway_config.max_clients = 4
    gateway_config.max_pending_handshakes = 4

    local gateway_start_result = skynet.call(module_state.gateway_service_handle, "lua", "start", gateway_config) -- Gateway start 的真实 RPC 结果，用于确认绑定地址、传输与命令索引。
    assert(gateway_start_result.address == "127.0.0.1" and gateway_start_result.port == SAMPLE_PORT)
    assert(gateway_start_result.transport == SAMPLE_TRANSPORT and gateway_start_result.command_count > 0)
    skynet.error("FLYWOW_GATEWAY_READY transport=" .. SAMPLE_TRANSPORT)
    print(string.format("Gateway 已监听 %s://%s:%d",
        SAMPLE_TRANSPORT == "websocket" and "ws" or "tcp",
        gateway_start_result.address,
        gateway_start_result.port))

    skynet.fork(function()
        for _ = 1, 2000 do
            if module_state.connection_closed then
                assert(module_state.request_received, "客户端关闭前没有发送 FrameJoin")
                assert(type(skynet.call(module_state.gateway_service_handle, "lua", "stop").closed_connections) == "number")
                print("Gateway 已停止并释放连接")
                print("FLYWOW_GATEWAY_SAMPLE_OK mode=" .. SAMPLE_MODE)
                io.stdout:flush()
                io.stderr:flush()
                os.exit(0)
            end
            skynet.sleep(1)
        end

        skynet.error("FLYWOW_GATEWAY_SAMPLE_FAILED: 等待客户端关闭超时")
        os.exit(1)
    end)
end)
