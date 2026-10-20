local skynet = require "skynet"
require "skynet.manager"
local handler = ".flywow_gateway_sample_handler"
local port = assert(tonumber(os.getenv("FLYWOW_GATEWAY_SAMPLE_PORT")))
local gateway, closed, received
skynet.start(function()
    skynet.name(handler, skynet.self())
    skynet.dispatch("lua", function(session, _, command, message)
        if command == "send_data" then
            assert(message.command_id == 1101 and message.data.scenario_id == 1)
            assert(message.data.battle_id == 0 and message.data.simulation_version == 1)
            received = true
            skynet.error("FLYWOW_GATEWAY_SAMPLE_REQUEST_RECEIVED")
            skynet.send(gateway, "lua", "send_data",
            {
                gateway_epoch = message.gateway_epoch,
                connection_id = message.connection_id,
                command_id = message.command_id,
                data = {code = "OK", battle_id = 42, seat_id = 1},
            })
        elseif command == "gateway_disconnect" then
            closed = true
        else
            error("unexpected Gateway command: " .. tostring(command))
        end
        if session ~= 0 then skynet.retpack(true) end
    end)
    gateway = skynet.newservice("gateway/flywow_gateway")
    local config = {}
    for key, value in pairs(require "gateway_frame_sync") do config[key] = value end
    config.handler_service, config.port, config.transport = handler, port, "websocket"
    config.max_clients, config.max_pending_handshakes = 4, 4
    local started = skynet.call(gateway, "lua", "start", config)
    assert(started.address == "127.0.0.1" and started.port == port)
    assert(started.transport == "websocket" and started.command_count > 0)
    print(string.format("Gateway 已监听 ws://%s:%d", started.address, started.port))
    skynet.fork(function()
        for _ = 1, 2000 do
            if closed then
                assert(received, "客户端关闭前没有收到 FrameJoin")
                assert(type(skynet.call(gateway, "lua", "stop").closed_connections) == "number")
                print("Gateway 已停止并释放连接")
                print("FLYWOW_GATEWAY_SAMPLE_OK")
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
