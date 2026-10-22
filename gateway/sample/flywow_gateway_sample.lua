local skynet = require "skynet"
require "skynet.manager"

local SAMPLE_HANDLER_SERVICE = ".flywow_gateway_sample_handler"
local SAMPLE_PORT = assert(tonumber(os.getenv("FLYWOW_GATEWAY_SAMPLE_PORT")))
local SAMPLE_MODE = assert(os.getenv("FLYWOW_GATEWAY_SAMPLE_MODE"))
local SAMPLE_TRANSPORT = SAMPLE_MODE == "websocket" and "websocket" or "tcp"

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
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
                command_id = 1101,
                data = {code = "OK", battle_id = 42, seat_id = 1},
            })
            skynet.send(module_state.gateway_service_handle, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
                command_id = 1103,
                data = {battle_id = 42, generation = 1, code = "OK"},
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
    local gateway_config = {}
    for key, value in pairs(require "gateway_frame_sync") do
        gateway_config[key] = value
    end
    gateway_config.handler_service = SAMPLE_HANDLER_SERVICE
    gateway_config.port = SAMPLE_PORT
    gateway_config.transport = SAMPLE_TRANSPORT
    gateway_config.max_clients = 4
    gateway_config.max_pending_handshakes = 4

    local gateway_start_result = skynet.call(module_state.gateway_service_handle, "lua", "start", gateway_config)
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
