-- 职责：由 proto CommandId 和 Request/Response 消息生成的 FlyWow Gateway command registry。
-- 边界：Build Artifact；运行时只读加载，不手工注册 command。
-- 输入/输出：CommandId + 可选 XxxRequest/XxxResponse -> Envelope command 映射。
-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。
-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。
local command_ids =
{
    ENTER_WORLD = 1001, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
    SYSTEM_NOTICE = 1002, -- 宿主可用此名称引用 proto 中分配的稳定命令号。
}
return
{
    envelope_type = ".battle.transport.v1.Envelope", -- lua-protobuf 解码和编码外层 Envelope 时使用。
    command_ids   = command_ids, -- 宿主业务代码按协议枚举名称引用命令号。
    commands      = -- Gateway 按 Envelope.command 选择消息类型。
    {
        [1001] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = ".flywow.gateway.course.EnterWorldRequest", -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".flywow.gateway.course.EnterWorldResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
        [1002] = -- ID 来自 proto CommandId，作为 commands 的唯一查询键。
        {
            request_type  = nil, -- Gateway 用于解码该命令的入站 Request；nil 表示客户端不能发送此命令。
            response_type = ".flywow.gateway.course.SystemNoticeResponse", -- Gateway 用于编码该命令的服务端 Response；nil 表示该命令没有响应消息。
        },
    },
}
