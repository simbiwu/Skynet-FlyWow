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
---@field receive fun(input: table): string|nil, string|nil, boolean|nil
---@field confirm fun(context: HandshakeContext): boolean
---@field ready fun(context: HandshakeContext): boolean
---@field expired fun(context: HandshakeContext): boolean
---@field close fun(context: HandshakeContext): nil

--- 创建握手管理器；具名参数crypto/now显式注入，timeout_ticks单位10ms，max_pending为并发上限。
--- 返回manager；分配少量Lua状态，不执行I/O/yield。无效配置由调用方启动校验。
---@param options table 握手配置；crypto/now/max_pending/timeout_ticks 由启动阶段注入。
---@return HandshakeManager 只拥有 pending 握手状态；不执行 I/O 或 yield。
function M.new(options)
    local crypto = assert(options.crypto)
    local now = assert(options.now)
    local max_pending = assert(options.max_pending)
    local timeout_ticks = assert(options.timeout_ticks)
    assert(math.type(max_pending) == "integer" and max_pending > 0)
    assert(math.type(timeout_ticks) == "integer" and timeout_ticks > 0 and timeout_ticks < 0x80000000)
    local pending = 0
    local manager = {}

    --- 释放当前握手占用；幂等，清理native对象；context由Gateway独占，不执行I/O/yield。
    ---@param context HandshakeContext 当前连接的握手上下文；manager 独占。
    ---@return nil 幂等释放 pending 名额和 native crypto。
    function manager.close(context)
        if not context or not context.held then
            return
        end

        context.held = false
        pending = pending - 1

        if context.crypto then
            context.crypto:close()
            context.crypto = nil
        end

        if context.phase ~= "ready" then
            context.phase = "closed"
        end
    end

    --- 接纳一个待握手连接；返回context或nil/容量错误，不分配密钥，不执行I/O/yield。
    ---@return HandshakeContext|nil context 或容量错误；成功时占用一个 pending 名额。
    function manager.accept()
        if pending >= max_pending then
            return nil, "HANDSHAKE_CAPACITY"
        end

        pending = pending + 1
        return
        {
            phase   = "hello", -- hello/proof/confirm/ready/closed，只由本manager改变。
            started = now(), -- 握手起点，消息不能刷新总期限。
            held    = true, -- pending令牌，只释放一次。
            crypto  = nil, -- native userdata；私钥/secret不进入Lua string。
        }
    end

    --- 检查绝对握手期限；不修改状态，不执行I/O/yield，支持Skynet tick回绕。
    ---@param context HandshakeContext|nil 要检查的握手上下文。
    ---@return boolean 是否超过绝对握手期限。
    function manager.expired(context)
        return context and context.held and
            (now() - context.started) % 0x100000000 >= timeout_ticks
    end

    --- 提供当前阶段允许的精确帧长度；TCP必须在读取body前使用，不由网络长度决定分配。
    ---@param context HandshakeContext 当前握手阶段。
    ---@return integer 当前阶段允许读取的精确帧长度；未知阶段返回0。
    function manager.expected_size(context)
        if context.phase == "hello" then
            return 67
        end

        if context.phase == "proof" then
            return 33
        end

        return 0
    end

    --- input.context为Gateway独占状态，input.bytes为当前帧只读字节；
    --- 处理一条完整握手消息；成功返回bytes/nil/是否待确认，失败返回nil/错误并释放context。
    --- Native错误只映射稳定码，不暴露EVP详情；不I/O/yield，不缓存提前业务包。
    ---@param input table 包含 context 与当前完整 frame bytes；调用方拥有 bytes。
    ---@return string|nil, string|nil, boolean|nil 响应帧、稳定错误码、是否等待确认。
    function manager.receive(input)
        local context = input.context
        local bytes   = input.bytes
        if manager.expired(context) then
            manager.close(context)
            return nil, "HANDSHAKE_TIMEOUT"
        end

        if type(bytes) ~= "string" or #bytes ~= manager.expected_size(context) then
            manager.close(context)
            return nil, "HANDSHAKE_FRAME"
        end
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
        if context.phase == "proof" then
            local ok, response = pcall(context.crypto.verify, context.crypto, bytes)
            if not ok then
                manager.close(context)
                return nil, "HANDSHAKE_PROOF"
            end
            context.phase = "confirm"
            return response, nil, true
        end
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
