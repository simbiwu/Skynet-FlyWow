--- 职责：管理通用连接的P-256随机挑战握手；与Socket、Protobuf、登录和业务无关。
--- 边界：FlyWow Runtime Module；输入消息/时钟，输出待发送消息、ready或稳定错误。
--- 生命周期：manager拥有pending计数；每连接context只在握手期间持有native敏感对象。
--- 不负责：不写Socket、不创建Service/协程、不建立账号会话、不加密业务包头。
local M = {}

---@class HandshakeContext
---@field phase "hello"|"proof"|"confirm"|"ready"|"closed" 当前握手阶段。
---@field started integer 绝对起始 tick；消息不会刷新总期限。
---@field held boolean 是否占用 pending 握手名额。
---@field crypto table|nil Native userdata；私钥和 secret 不进入 Lua 字符串。

---@class HandshakeManager
---@field accept fun(): HandshakeContext|nil, string|nil
---@field expected_size fun(context: HandshakeContext): integer
---@field receive fun(handshake_input: table): string|nil, string|nil, boolean|nil
---@field confirm fun(context: HandshakeContext): boolean
---@field ready fun(context: HandshakeContext): boolean
---@field expired fun(context: HandshakeContext): boolean
---@field close fun(context: HandshakeContext): nil

--- 创建握手管理器；具名参数crypto/now显式注入，timeout_ticks单位10ms，max_pending为并发上限。
--- 返回manager；分配少量Lua状态，不执行I/O/yield。无效配置由调用方启动校验。
---@param handshake_config table 握手配置；crypto/now/max_pending/timeout_ticks 由启动阶段注入。
---@return HandshakeManager 只拥有 pending 握手状态；不执行 I/O 或 yield。
function M.new(handshake_config)
    local crypto = assert(handshake_config.crypto)               -- 宿主注入的 Native 密码接口，所有握手共用只读入口。
    local read_tick = assert(handshake_config.now)               -- 宿主时钟函数；每次调用读取当前 tick，不缓存时间值。
    local max_pending = assert(handshake_config.max_pending)     -- 当前 manager 同时持有的握手名额上限。
    local timeout_ticks = assert(handshake_config.timeout_ticks) -- 从 accept 起算的握手总期限，单位为 10ms tick。

    assert(math.type(max_pending) == "integer" and max_pending > 0)
    assert(math.type(timeout_ticks) == "integer" and timeout_ticks > 0 and timeout_ticks < 0x80000000)

    local pending = 0                                            -- 当前 manager 占用的握手名额；accept 增加，close 幂等释放。
    local manager = {}

    --- 释放当前握手占用；幂等，清理native对象；context由Gateway独占，不执行I/O/yield。
    ---@param context HandshakeContext|nil Gateway 为连接持有的上下文；本方法释放其名额及 Native 对象。
    ---@return nil 幂等释放 pending 名额和 native crypto。
    function manager.close(context)
        if not context or not context.held then
            return
        end

        -- 先归还本连接占用的名额，重复 close 此后不会再次递减计数。
        context.held = false
        pending = pending - 1

        -- Native 对象可能在 hello 解析前尚未创建；已创建时立即擦除其密钥。
        if context.crypto then
            context.crypto:close()
            context.crypto = nil
        end

        -- 完成握手的连接保留 ready 标记，其他关闭路径禁止继续处理输入。
        if context.phase ~= "ready" then
            context.phase = "closed"
        end
    end

    --- 接纳一个待握手连接；返回context或nil/容量错误，不分配密钥，不执行I/O/yield。
    ---@return HandshakeContext|nil context；容量耗尽时为 nil。
    ---@return string|nil error_code；成功时为 nil。
    function manager.accept()
        if pending >= max_pending then
            return nil, "HANDSHAKE_CAPACITY"
        end

        -- 通过容量检查后才占用名额，并把新连接放入 hello 阶段。
        pending = pending + 1
        return
        {
            phase   = "hello",     -- hello/proof/confirm/ready/closed，只由本manager改变。
            started = read_tick(), -- 握手起点，消息不能刷新总期限。
            held    = true,        -- pending令牌，只释放一次。
            crypto  = nil,         -- native userdata；私钥/secret不进入Lua string。
        }
    end

    --- 检查绝对握手期限；不修改状态，不执行I/O/yield，支持Skynet tick回绕。
    ---@param context HandshakeContext|nil 要检查的握手上下文。
    ---@return boolean 是否超过绝对握手期限。
    function manager.expired(context)
        return context ~= nil and context.held and
            (read_tick() - context.started) % 0x100000000 >= timeout_ticks
    end

    --- 提供当前阶段允许的精确帧长度；TCP必须在读取body前使用，不由网络长度决定分配。
    ---@param context HandshakeContext 当前握手阶段。
    ---@return integer 当前阶段允许读取的精确帧长度；未知阶段返回0。
    function manager.expected_size(context)
        -- CLIENT_HELLO 包含类型与版本各 1 字节，以及 65 字节非压缩 P-256 公钥。
        if context.phase == "hello" then
            return 67
        end

        -- CLIENT_PROOF 包含 1 字节类型和 32 字节 HMAC；这里只报告长度，不验证证明。
        if context.phase == "proof" then
            return 33
        end

        return 0
    end

    --- handshake_input.context为Gateway独占状态，handshake_input.bytes为当前帧只读字节；
    --- 处理一条完整握手消息；成功返回bytes/nil/是否待确认，失败返回nil/错误并释放context。
    --- Native错误只映射稳定码，不暴露EVP详情；不I/O/yield，不缓存提前业务包。
    ---@param handshake_input table 包含 context 与当前完整 frame bytes；调用方拥有 bytes。
    ---@return string|nil response_bytes；成功时的握手响应。
    ---@return string|nil error_code；失败时的稳定错误码。
    ---@return boolean|nil needs_confirmation；仅最后一条响应需要确认时为 true。
    function manager.receive(handshake_input)
        local context = handshake_input.context -- Gateway 为来源连接保存的独占状态，本次按 phase 推进。
        local bytes   = handshake_input.bytes   -- 当前完整握手帧；仅在本次同步处理期间借用。

        if manager.expired(context) then
            manager.close(context)
            return nil, "HANDSHAKE_TIMEOUT"
        end

        -- 按当前握手阶段的固定长度拒绝异常帧，避免继续处理错位消息。
        if type(bytes) ~= "string" or #bytes ~= manager.expected_size(context) then
            manager.close(context)
            return nil, "HANDSHAKE_FRAME"
        end

        -- hello 阶段解析客户端公钥并派生临时挑战状态，随后进入 proof。
        if context.phase == "hello" then
            if bytes:byte(1) ~= 1 or bytes:byte(2) ~= 1 then
                manager.close(context)
                return nil, "HANDSHAKE_VERSION"
            end

            local ok, native, response = pcall(crypto.new, bytes)
            if not ok then
                manager.close(context)
                return nil, "HANDSHAKE_CRYPTO"
            end
            context.crypto = native
            context.phase = "proof"
            return response
        end

        -- proof 阶段验证客户端证明；SERVER_READY 仍须由 Gateway 成功写出后确认。
        if context.phase == "proof" then
            local ok, response = pcall(context.crypto.verify, context.crypto, bytes)
            if not ok then
                manager.close(context)
                return nil, "HANDSHAKE_PROOF"
            end
            context.phase = "confirm"
            return response, nil, true
        end

        -- 不属于已支持阶段的输入不能推进状态，释放资源并返回稳定错误码。
        manager.close(context)
        return nil, "HANDSHAKE_STATE"
    end

    --- 发送SERVER_READY成功后提交ready；失败由Gateway调用close，无I/O/yield。
    ---@param context HandshakeContext 已进入 confirm 阶段的上下文。
    ---@return boolean 是否提交为 ready；成功后释放 pending 名额。
    function manager.confirm(context)
        if context.phase ~= "confirm" or manager.expired(context) then
            return false
        end

        context.phase = "ready"
        manager.close(context)
        return true
    end

    --- 返回是否允许业务收发；无状态变化，不I/O/yield。
    ---@param context HandshakeContext|nil 要检查的上下文。
    ---@return boolean 是否允许进入业务收发。
    function manager.ready(context)
        return context ~= nil and context.phase == "ready"
    end

    return manager
end

return M
