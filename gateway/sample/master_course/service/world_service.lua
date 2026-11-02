--- 课程宿主：启动一个 Gateway、处理新手村进入、单播/广播并观察连接关闭。
local skynet = require "skynet"
require "skynet.manager"

local HANDLER_NAME = ".gateway_course_world" -- Gateway 异步投递业务消息使用的固定本地 Service 名。
local COMMAND_ENTER_WORLD = 1001 -- EnterWorldRequest/EnterWorldResponse 使用同一个 command。
local COMMAND_NOTICE = 1002 -- SystemNoticeResponse 只允许服务器主动下发。
local state =
{
    gateway = nil, -- 本 Service 创建的 Gateway handle；所有出站消息都发送到它。
    players = {}, -- Gateway 逻辑 connection_id -> 已进入新手村的 player_id；收到 disconnect 时删除。
    online_count = 0, -- 本课程新手村已进入且未断开的玩家数。
    disconnected = 0, -- 本轮实际完成进入后又收到 disconnect 的玩家数；达到 2 用于结束样例。
}

--- 将一个业务 Response 或 Push 异步交给 Gateway；是否真正写到网络由 Gateway 决定。
---@param epoch string 入站请求给出的当前 Gateway 实例身份；广播也要使用它。
---@param connection_id integer 正数表示指定连接，0 表示向本 Gateway 全部 ready 连接广播。
---@param command_id integer Registry 中定义了 response_type 的命令编号。
---@param data table 本次响应或公告消息的 Protobuf 字段 table。
---@return nil 只提交 Skynet 异步消息，不等待客户端回包。
local function send_to_gateway(epoch, connection_id, command_id, data)
    skynet.send(state.gateway, "lua", "send_data",
    {
        gateway_epoch = epoch, -- Gateway 用于拒绝上一轮实例的迟到消息。
        connection_id = connection_id, -- 此处不是底层 Socket fd。
        command_id    = command_id, -- 决定响应数据采用哪一种 protobuf 类型。
        data          = data, -- 由 Gateway 编码并填入 Envelope.body。
    })
end

--- Gateway 解出 EnterWorldRequest 后调用；业务记录只在当前 WorldService Lua State 中保存。
---@param request table Gateway 发来的记录，使用 gateway_epoch、connection_id、command_id、data。
---@return nil 发送业务响应；第二个玩家入场时额外发送单播和广播。
local function on_enter_world(request)
    if request.command_id ~= COMMAND_ENTER_WORLD or type(request.data) ~= "table" then
        skynet.error("COURSE_UNEXPECTED_COMMAND")
        return
    end

    -- 验证课程玩家输入并确认当前连接尚未建立玩家映射。
    local player_id = request.data.player_id -- 从 Protobuf 解码出来的演示玩家编号，并非鉴权身份。
    local connection_id = request.connection_id -- 当前 Gateway 分配的逻辑连接编号。
    if (player_id ~= 1001 and player_id ~= 1002) or state.players[connection_id] then
        skynet.error("COURSE_INVALID_PLAYER ", tostring(player_id))
        return
    end

    -- 业务 Service 只记录玩家与逻辑连接的对应，不持有也不操作网络 Socket。
    state.players[connection_id] = player_id
    state.online_count = state.online_count + 1
    skynet.error("COURSE_ENTER player=", player_id, " connection=", connection_id,
        " online=", state.online_count)

    send_to_gateway(request.gateway_epoch, connection_id, COMMAND_ENTER_WORLD,
    {
        player_id    = player_id, -- 说明本次完成进入的是哪一名演示玩家。
        scene_id     = 7, -- 固定的新手村场景编号。
        online_count = state.online_count, -- 此请求完成时的在线人数快照。
    })

    if player_id == 1002 then
        -- B 入场后先向 B 单播；随后向本 Gateway 的两条 ready 连接广播。
        send_to_gateway(request.gateway_epoch, connection_id, COMMAND_NOTICE,
        {
            content = "欢迎玩家1002", -- 只有 B 能收到的定向消息。
        })
        send_to_gateway(request.gateway_epoch, 0, COMMAND_NOTICE,
        {
            content = "新手村已开放", -- 连接编号 0 是广播约定，不是玩家 0。
        })

        -- 给出站消息留下一个小的可观察窗口，然后使用 Gateway 公开 close 命令断开 B。
        local epoch = request.gateway_epoch -- 延迟回调必须沿用收到 B 请求时的 Gateway 实例身份。
        local target_id = connection_id -- 延迟回调仅操作 B 的逻辑连接，不能拿 Socket fd 当身份。
        skynet.timeout(30, function()
            skynet.send(state.gateway, "lua", "close",
            {
                gateway_epoch = epoch, -- 拒绝旧 Gateway 实例的迟到关闭命令。
                connection_id = target_id, -- 仅要求 Gateway 关闭玩家 B 的连接。
            })
            skynet.error("COURSE_CLOSE_B_REQUESTED")
        end)
    end
end

--- Gateway 摘除连接后通知宿主；只清理由本业务 Service 保存的玩家关系。
---@param message table 读取 Gateway 发来的 connection_id 和 gateway_epoch；本例只有一个 Gateway 实例。
---@return nil 未进入的握手失败连接不影响业务在线人数。
local function on_disconnect(message)
    local player_id = state.players[message.connection_id] -- 可能不存在：握手阶段的失败连接同样会通知断开。
    if not player_id then
        return
    end

    -- 只在该连接此前进入过业务后更新在线与收尾计数。
    state.players[message.connection_id] = nil
    state.online_count = state.online_count - 1
    state.disconnected = state.disconnected + 1
    skynet.error("COURSE_DISCONNECT player=", player_id,
        " online=", state.online_count)
end

skynet.start(function()
    -- 先注册 handler，再创建和启动 Gateway；否则请求可能没有接收方。
    skynet.name(HANDLER_NAME, skynet.self())
    skynet.dispatch("lua", function(session, _, command, message)
        if command == "send_data" then
            on_enter_world(message)
        elseif command == "gateway_disconnect" then
            on_disconnect(message)
        else
            skynet.error("COURSE_UNEXPECTED_SERVICE_MESSAGE ", tostring(command))
        end

        if session ~= 0 then
            skynet.retpack(true)
        end
    end)

    state.gateway = skynet.newservice("gateway/flywow_gateway")
    local transport = os.getenv("GATEWAY_COURSE_TRANSPORT") or "websocket" -- Shell 选择本次使用 WS 或 TCP。
    local port = tonumber(os.getenv("GATEWAY_COURSE_PORT")) or 19221 -- 宿主选取的本地端口。
    local config =
    {
        host                          = "127.0.0.1", -- 仅允许本机连接。
        port                          = port, -- 本轮 Gateway 监听端口。
        transport                     = transport, -- 每个实例只使用一种 transport。
        handler_service               = HANDLER_NAME, -- 此 Service 已注册的本地名字。
        descriptor_path               = "./third_party/skynet-flywow/gateway/sample/master_course/generated/world.pb", -- 当前课程构建的 descriptor。
        registry_module               = "world_registry", -- 当前课程生成的 Lua Registry。
        protocol_version              = 4, -- Envelope 的业务协议版本。
        max_clients                   = 4, -- 本例最多同时接入 4 个客户端。
        max_requests_per_second       = tonumber(os.getenv("GATEWAY_COURSE_RPS")) or 200, -- 故障实验可缩小接纳速率。
        idle_timeout_ms              = tonumber(os.getenv("GATEWAY_COURSE_IDLE_MS")) or 300000, -- 完整业务消息空闲期限，单位毫秒。
    }

    -- 这是等待 Gateway 返回 Result 的控制面 call；它与请求处理阶段的 send 不同。
    local result = skynet.call(state.gateway, "lua", "start", config)
    if not result.ok then
        skynet.error("COURSE_START_FAILED ", result.code, " ", result.message)
        skynet.abort()
        return
    end
    skynet.error("COURSE_GATEWAY_READY transport=", result.value.transport,
        " port=", result.value.port, " commands=", result.value.command_count)

    -- 两位已经进入过新手村的玩家均断开后，走 Gateway 正式 stop 合同并结束课程进程。
    skynet.fork(function()
        for _ = 1, 300 do
            if state.disconnected == 2 then
                local stop_result = skynet.call(state.gateway, "lua", "stop") -- 停止 listener，返回本次关闭连接数量。
                if not stop_result.ok then
                    skynet.error("COURSE_STOP_FAILED ", stop_result.code)
                    os.exit(1)
                end
                skynet.error("COURSE_GATEWAY_OK closed=", stop_result.value.closed_connections)
                io.stdout:flush()
                io.stderr:flush()
                os.exit(0)
            end
            skynet.sleep(10)
        end
        skynet.error("COURSE_TIMEOUT_WAITING_FOR_TWO_DISCONNECTS")
        os.exit(1)
    end)
end)
