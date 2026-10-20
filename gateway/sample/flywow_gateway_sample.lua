local skynet = require "skynet"
require "skynet.manager"

local handler = ".flywow_gateway_sample_handler"
local port = assert(tonumber(os.getenv("FLYWOW_GATEWAY_SAMPLE_PORT")))
local mode = assert(os.getenv("FLYWOW_GATEWAY_SAMPLE_MODE"))
local transport = mode == "websocket" and "websocket" or "tcp"
local gateway
local closed
local received

skynet.start(function()
    skynet.name(handler, skynet.self())
    skynet.dispatch("lua", function(session, _, command, message)
        if command == "send_data" then
            assert(message.command_id == 1101 and message.data.scenario_id == 1)
            assert(message.data.battle_id == 0 and message.data.simulation_version == 1)
            received = true
            skynet.error("FLYWOW_GATEWAY_SAMPLE_REQUEST_RECEIVED mode=" .. mode)

            -- 同一连接先收到 FrameJoin 响应，再收到服务端主动 FramePush。
            skynet.send(gateway, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
                command_id = 1101,
                data = {code = "OK", battle_id = 42, seat_id = 1},
            })
            skynet.send(gateway, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
                command_id = 1103,
                data = {battle_id = 42, generation = 1, code = "OK"},
            })
            skynet.error("FLYWOW_GATEWAY_SAMPLE_PUSH_SENT mode=" .. mode)
        elseif command == "gateway_disconnect" then
            closed = true
        else
            error("unexpected Gateway command: " .. tostring(command))
        end

        if session ~= 0 then
            skynet.retpack(true)
        end
    end)

    gateway = skynet.newservice("gateway/flywow_gateway")
    local config = {}
    for key, value in pairs(require "gateway_frame_sync") do
        config[key] = value
    end
    config.handler_service = handler
    config.port = port
    config.transport = transport
    config.max_clients = 4
    config.max_pending_handshakes = 4

    local started = skynet.call(gateway, "lua", "start", config)
    assert(started.address == "127.0.0.1" and started.port == port)
    assert(started.transport == transport and started.command_count > 0)
    skynet.error("FLYWOW_GATEWAY_READY transport=" .. transport)
    print(string.format("Gateway 已监听 %s://%s:%d",
        transport == "websocket" and "ws" or "tcp",
        started.address,
        started.port))

    skynet.fork(function()
        for _ = 1, 2000 do
            if closed then
                assert(received, "客户端关闭前没有发送 FrameJoin")
                assert(type(skynet.call(gateway, "lua", "stop").closed_connections) == "number")
                print("Gateway 已停止并释放连接")
                print("FLYWOW_GATEWAY_SAMPLE_OK mode=" .. mode)
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
