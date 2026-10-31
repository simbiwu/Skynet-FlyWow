local skynet = require "skynet"
require "skynet.manager"

skynet.start(function()
    -- Gateway 会向该本地服务名发送 send_data/gateway_disconnect。
    skynet.name(".gateway_course_world", skynet.self())
    skynet.dispatch("lua", function(session, _, command)
        skynet.error("课程暂未处理业务消息：", command)
        if session ~= 0 then
            skynet.retpack(true)
        end
    end)

    local gateway = skynet.newservice("gateway/flywow_gateway")
    local transport = os.getenv("GATEWAY_COURSE_TRANSPORT") or "websocket"
    local port = tonumber(os.getenv("GATEWAY_COURSE_PORT")) or 19221
    local config =
    {
        host            = "127.0.0.1", -- 课程仅对本机开放。
        port            = port, -- Shell 本次指定的监听端口。
        transport       = transport, -- 当前 Gateway 固定为 TCP 或 WebSocket。
        handler_service = ".gateway_course_world", -- 已注册的业务接收 Service。
        descriptor_path = "./third_party/skynet-flywow/gateway/sample/master_course/generated/world.pb", -- 启动时读取的类型描述文件。
        registry_module = "world_registry", -- 构建脚本生成的命令表模块名。
        protocol_version = 4, -- 当前示例 Envelope 兼容版本。
        max_clients      = 4, -- 足以接入两个玩家的连接容量。
    }

    -- start 是同步 RPC；该协程可能等待，业务收发才使用异步 send。
    local result = skynet.call(gateway, "lua", "start", config)
    if not result.ok then
        skynet.error("COURSE_START_FAILED ", result.code, " ", result.message)
        skynet.abort()
        return
    end
    skynet.error("COURSE_GATEWAY_READY transport=", result.value.transport,
        " port=", result.value.port, " commands=", result.value.command_count)
end)