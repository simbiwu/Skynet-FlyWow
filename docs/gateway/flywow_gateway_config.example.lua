-- 职责：提供 FlyWow Gateway 宿主配置的可复制示例。
-- 边界：Host Configuration Example；由宿主复制为 server/config/gateway.lua 后按部署修改。
-- 输入/输出：协议生成物路径、传输参数和资源上限 -> flywow_gateway Service 的默认配置 table。
-- 生命周期：每个 Gateway Service 在 start 命令中读取一次；运行中不热重载。
-- 不负责：不创建 Service、不生成 .proto/.pb/registry、不保存 handler Service handle。
--
-- 配置调用链：
--   1. 宿主 composition root 调用 skynet.newservice("flywow_gateway")。
--   2. 宿主调用 skynet.call(gateway, "lua", "start", options)。
--   3. flywow_gateway Service 在 start 内部 require("config.gateway")。
--   4. 本文件中的默认值与 start 的顶层 options 浅合并、校验并复制。
--   5. Gateway 加载 descriptor_path、require registry_module，然后监听配置的地址和端口。
--
-- 复制与启动示例：
--   cp server/third_party/skynet-flywow/docs/gateway/flywow_gateway_config.example.lua \
--      server/config/gateway.lua
--   # 按宿主目录和协议修改 descriptor_path、registry_module、port 等字段。
--   skynet.call(gateway, "lua", "start",
--   {
--       handler_service = query_service,
--   })
--
-- 运行时调用者和时机：
--   flywow_gateway Service 是本配置的唯一运行时读取者；每个 Service/Lua State 各自读取一次。
--   handler_service 是 start 调用方提供的运行时 Service handle，不能写入静态配置。
--   start 失败时配置、协议产物或资源上限校验失败会直接返回错误，不发布 Gateway 就绪状态。
--   当前没有配置热重载；修改文件后必须重启对应 Gateway Service。
--
-- 协议生成顺序（在 Server 仓库根目录执行）：
--   1. 编辑唯一协议源：shared/protocol/navigation_query.proto
--   2. 生成 FileDescriptorSet：
--      bash server/protocol/build_server_descriptor.sh
--      输出：shared/protocol/generated/server/navigation_query.pb
--   3. 生成 Gateway command registry：
--      python3 server/third_party/skynet-flywow/tools/generate_gateway_registry.py \
--          --proto shared/protocol/navigation_query.proto \
--          --output server/lualib/gateway/protocol/navigation_registry.lua
--   4. 运行时只加载第 2、3 步的生成物，不解析 .proto，不在 Service 启动时生成协议文件。
--
-- registry_module 的内容：
--   generate_gateway_registry.py 从 service/rpc 及其 command_id 注释生成 command 到
--   request/response 类型的映射。例如 // command_id=1001 的 QueryCell RPC 会生成
--   commands[1001] = { name = "QueryCell", request_type = ..., response_type = ... }。
--   command_id 重复、缺失、越界或 request/response 不是同一 proto 中的 message 时构建失败。
--
-- 路径基准：descriptor_path 是运行时文件路径，按 Server 进程启动工作目录解析；
-- registry_module 是 Lua require 名称，不写 .lua，必须落在 lua_path 可搜索的目录中。
return
{
    -- 监听地址；由宿主部署决定。127.0.0.1 只接受本机连接，外部接入需显式配置绑定地址。
    host                          = "127.0.0.1",
    -- 监听端口；Lua integer，合法范围 1..65535；多个实例不能占用同一地址端口。
    port                          = 19001,
    -- 监听队列上限；Lua integer，合法范围 1..65535；不等于 max_clients。
    backlog                       = 128,
    -- 传输类型；只能是 tcp 或 websocket；一个 Gateway Service 生命周期内固定一种类型。
    transport                     = "tcp",
    -- WebSocket 子协议；当前只支持 ws。TLS/WSS 必须由宿主前置终止。
    websocket_protocol            = "ws",

    -- protoc 生成的 FileDescriptorSet；Gateway 用它加载 Envelope/request/response 类型。
    -- 它不是 .proto 源文件，也不是 registry；文件必须在 start 时可读。
    descriptor_path               = "../shared/protocol/generated/server/navigation_query.pb",
    -- FlyWow 生成的 Lua command registry；require 名称不带 .lua。
    registry_module               = "gateway.protocol.navigation_registry",
    -- Envelope 协议兼容版本；Client、descriptor 和 registry 必须来自同一协议发布版本。
    protocol_version              = 3,

    -- 当前 Gateway 实例的在线连接上限，包含尚未完成握手的连接；合法范围 1..1000000。
    max_clients                   = 1024,
    -- 待握手连接上限；合法范围 1..max_clients，超过后拒绝新握手，避免握手资源无界增长。
    max_pending_handshakes        = 128,
    -- 握手总期限，单位为 Skynet 10ms tick；1000 表示约 10 秒，合法范围 1..360000。
    handshake_timeout_ticks       = 1000,
    -- TCP 定长读取或 WebSocket Upgrade 的单次读取期限，单位为 10ms tick。
    read_timeout_ticks            = 3000,
    -- WebSocket 完整消息之间的空闲期限，单位为 10ms tick。
    idle_timeout_ticks            = 30000,
    -- 单个业务 Envelope 最大字节数；TCP uint16 framing 上限为 65535。
    max_frame_bytes               = 65535,
    -- 单连接业务帧速率上限；固定一秒窗口，超限关闭来源连接。
    max_requests_per_second       = 200,
    -- 当前 Gateway 实例所有连接的业务帧速率上限；固定一秒窗口，超限关闭来源连接。
    max_total_requests_per_second = 10000,
    -- 写缓冲告警关闭阈值，单位 KB；慢连接达到阈值后关闭，限制内存增长。
    write_warning_close_kb        = 1024,
}
