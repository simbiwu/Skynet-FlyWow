--- 职责：管理 Gateway 连接的 P-256 挑战握手状态、并发名额和绝对期限。
--- 边界：FlyWow Gateway Runtime Module；不写 Socket、不创建 Service/协程、不处理业务消息。
--- 生命周期：manager 独占 pending 计数；每条连接 context 持有一个名额和临时 Native userdata。
--- 失败：可预期失败返回 FlyWowResult；Native Lua Binding 的 nil/error record 在本模块转换为稳定结果。
local flywow_result = require "flywow_result"

local M = {}

---@class HandshakeContext
---@field phase "hello"|"proof"|"confirm"|"ready"|"closed" 当前握手阶段。
---@field started integer 绝对起始 tick；消息不会刷新总期限。
---@field held boolean 是否占用 pending 握手名额。
---@field crypto table|nil Native userdata；私钥和 secret 不进入 Lua 字符串。

---@class HandshakeManager
---@field accept fun(): FlyWowResult<HandshakeContext>
---@field expected_size fun(context: HandshakeContext): integer
---@field receive fun(handshake_input: table): FlyWowResult<HandshakeOutput>
---@field confirm fun(context: HandshakeContext): FlyWowResult<nil>
---@field ready fun(context: HandshakeContext): boolean
---@field expired fun(context: HandshakeContext): boolean
---@field close fun(context: HandshakeContext): nil

---@class HandshakeOutput
---@field response_bytes string 当前阶段需写回客户端的完整握手消息。
---@field needs_confirmation boolean true 表示 SERVER_READY 写成功后还须提交 ready。

--- 创建握手管理器；从 Gateway start 接收 Native 接口、时钟、名额上限和期限。
---@param handshake_config table 含 crypto/now/max_pending/timeout_ticks；值由 Gateway 已校验配置注入。
---@return FlyWowResult<HandshakeManager> 成功 value 为 manager；配置无效时返回 HANDSHAKE_CONFIG_INVALID。
function M.new(handshake_config)
    if type(handshake_config) ~= "table" then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "handshake config must be a table"
        )
    end

    -- 配置表形状有效后读取各依赖；下面验证 Native 接口、时钟和资源边界。
    local crypto = handshake_config.crypto -- Gateway 注入的 Native 密码接口，提供 new 与 userdata verify/close。
    local read_tick = handshake_config.now -- Gateway 注入的 10ms tick 时钟；每次读取当前值。
    local max_pending = handshake_config.max_pending -- 本 manager 可同时持有的握手上下文数量上限。
    local timeout_ticks = handshake_config.timeout_ticks -- 从 accept 起算的握手总期限，单位为 10ms tick。
    if type(crypto) ~= "table" or type(crypto.new) ~= "function" or
        type(read_tick) ~= "function" then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "crypto.new and now function are required"
        )
    end
    if math.type(max_pending) ~= "integer" or max_pending < 1 then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "max_pending must be a positive integer"
        )
    end
    if math.type(timeout_ticks) ~= "integer" or timeout_ticks < 1 or
        timeout_ticks >= 0x80000000 then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "timeout_ticks must be in [1, 0x7fffffff]"
        )
    end

    -- 依赖和上限全部通过后才创建独占 manager 状态。
    local pending = 0 -- 当前 manager 占用的握手名额；accept 增加，close 幂等释放。
    local manager = {} -- 暴露状态机方法；pending 计数仅由该 manager 实例持有。

    --- 释放连接占用的握手名额和 Native 密码对象；重复调用不改变计数。
    ---@param context HandshakeContext|nil Gateway 为连接持有的独占握手上下文。
    ---@return nil 不返回业务值；已释放或 nil context 都是幂等完成。
    function manager.close(context)
        if type(context) ~= "table" or not context.held then
            return
        end

        -- 已持有名额的 context 只释放一次，再关闭其 Native userdata。
        context.held = false
        pending = pending - 1
        if context.crypto then
            context.crypto:close()
            context.crypto = nil
        end

        -- ready context 保留最终阶段标记；其他关闭连接转为 closed。
        if context.phase ~= "ready" then
            context.phase = "closed"
        end
    end

    --- 为新连接申请一个握手名额；成功时创建 hello 阶段 context。
    ---@return FlyWowResult<HandshakeContext> 成功 value 为新 context；容量耗尽返回 HANDSHAKE_CAPACITY。
    function manager.accept()
        if pending >= max_pending then
            return flywow_result.failure(
                "HANDSHAKE_CAPACITY",
                "pending handshake capacity reached"
            )
        end

        -- 有容量时创建新的 hello context 并把名额交给该连接。
        pending = pending + 1
        return flywow_result.success(
        {
            phase   = "hello", -- 只由本 manager 推进的握手阶段。
            started = read_tick(), -- 握手绝对起点；后续消息不能刷新期限。
            held    = true, -- 本连接占有的 pending 令牌，只由 close 释放一次。
            crypto  = nil, -- Native userdata 在验证 HELLO 后创建，持有临时私钥和派生密钥。
        })
    end

    --- 检查握手总期限；tick 回绕时仍按无符号差计算。
    ---@param context HandshakeContext|nil 由 accept 返回、由 Gateway 连接记录持有的上下文。
    ---@return boolean context 仍占用名额且已超过绝对期限时为 true。
    function manager.expired(context)
        return type(context) == "table" and context.held and
            (read_tick() - context.started) % 0x100000000 >= timeout_ticks
    end

    --- 返回当前握手阶段的精确帧体长度；TCP 在读取 body 前使用。
    ---@param context HandshakeContext|nil Gateway 为当前连接保存的握手上下文。
    ---@return integer hello 为 67、proof 为 33；其它或无效阶段返回 0。
    function manager.expected_size(context)
        if type(context) ~= "table" then
            return 0
        end

        -- TCP 先读取当前阶段的固定帧长，非法或终态阶段不会读取业务 body。
        if context.phase == "hello" then
            return 67
        end

        -- HELLO 响应返回后，下一条合法帧必须是 CLIENT_PROOF。
        if context.phase == "proof" then
            return 33
        end
        return 0
    end

    --- 校验并推进一条完整握手帧；Native 的 nil/error record 在此映射为稳定结果码。
    ---@param handshake_input table 含 context 与 bytes；context 由 Gateway 持有，bytes 是本帧借用字节。
    ---@return FlyWowResult<HandshakeOutput> 成功 value 含 response_bytes/needs_confirmation；失败时释放连接握手资源。
    function manager.receive(handshake_input)
        if type(handshake_input) ~= "table" then
            return flywow_result.failure(
                "HANDSHAKE_INPUT_INVALID",
                "handshake input must be a table"
            )
        end

        -- 输入容器有效后读取连接独占状态和本次借用帧。
        local context = handshake_input.context -- Gateway 为来源连接保存的独占状态，本次按 phase 推进。
        local bytes = handshake_input.bytes -- 当前完整握手帧；仅在本次同步处理期间借用。
        if type(context) ~= "table" or not context.held then
            return flywow_result.failure(
                "HANDSHAKE_STATE",
                "handshake context is not active"
            )
        end

        -- 先拒绝已过期连接，再验证帧长，避免为无效消息调用 Native。
        if manager.expired(context) then
            manager.close(context)
            return flywow_result.failure(
                "HANDSHAKE_TIMEOUT",
                "absolute handshake deadline expired"
            )
        end

        -- 有效握手连接仍须发送当前阶段规定的完整帧。
        if type(bytes) ~= "string" or #bytes ~= manager.expected_size(context) then
            manager.close(context)
            return flywow_result.failure(
                "HANDSHAKE_FRAME",
                "frame length does not match the current handshake stage"
            )
        end

        -- HELLO 阶段验证协议头并创建该连接的 Native 密码上下文。
        if context.phase == "hello" then
            if bytes:byte(1) ~= 1 or bytes:byte(2) ~= 1 then
                manager.close(context)
                return flywow_result.failure(
                    "HANDSHAKE_VERSION",
                    "unsupported handshake message type or version"
                )
            end

            -- Binding 可能抛 Lua 错误，也可能返回 nil/error record；两种形式在此统一处理。
            local call_succeeded, native_or_error, challenge_or_error =
                pcall(crypto.new, bytes)
            if not call_succeeded or native_or_error == nil or
                type(challenge_or_error) ~= "string" then
                manager.close(context)
                local native_error = call_succeeded and challenge_or_error or native_or_error
                return flywow_result.failure(
                    "HANDSHAKE_CRYPTO",
                    "Native failed to create the challenge",
                    {
                        native_code = type(native_error) == "table" and native_error.code or nil, -- Lua Binding 提供的机器可读失败码。
                        -- 保留 Native 诊断文本，供日志定位握手错误。
                        native_message = type(native_error) == "table" and native_error.message or
                            tostring(native_error), -- Binding 原始错误文本只用于定位握手失败。
                    }
                )
            end

            -- Native 成功后把 userdata 交给连接 context，再推进到 proof 阶段。
            context.crypto = native_or_error
            context.phase = "proof"
            return flywow_result.success(
            {
                response_bytes = challenge_or_error, -- 发送给客户端的 SERVER_CHALLENGE bytes。
                needs_confirmation = false, -- challenge 后仍等待 CLIENT_PROOF，尚不能开放业务。
            })
        end

        -- proof 阶段验证客户端 HMAC；只有 SERVER_READY 写出后才允许进入 ready。
        -- HELLO 响应返回后，下一条合法帧必须是 CLIENT_PROOF。
        if context.phase == "proof" then
            if type(context.crypto) ~= "userdata" then
                manager.close(context)
                return flywow_result.failure(
                    "HANDSHAKE_STATE",
                    "Native handshake context is missing"
                )
            end

            -- 验证失败会清理 Native key；保留 Native 错误码供诊断。
            local call_succeeded, ready_or_error, native_error =
                pcall(context.crypto.verify, context.crypto, bytes)
            if not call_succeeded or ready_or_error == nil or type(ready_or_error) ~= "string" then
                manager.close(context)
                local failure = call_succeeded and native_error or ready_or_error -- Native nil/error record 或 Binding 抛出的异常。
                return flywow_result.failure(
                    "HANDSHAKE_PROOF",
                    "Native rejected the client proof",
                    {
                        native_code = type(failure) == "table" and failure.code or nil, -- Lua Binding 提供的机器可读失败码。
                        -- 保留 Native 诊断文本，供日志定位证明错误。
                        native_message = type(failure) == "table" and failure.message or
                            tostring(failure), -- Binding 原始错误文本只用于定位证明失败。
                    }
                )
            end

            -- 客户端证明通过后等待 Gateway 写出 SERVER_READY，再提交 ready。
            context.phase = "confirm"
            return flywow_result.success(
            {
                response_bytes = ready_or_error, -- 发送给客户端的 SERVER_READY 证明 bytes。
                needs_confirmation = true, -- 仅 transport 写成功后 Gateway 才能提交 ready。
            })
        end

        -- 非 hello/proof 阶段的消息不可继续；释放名额和 Native key。
        manager.close(context)
        return flywow_result.failure(
            "HANDSHAKE_STATE",
            "message is not valid in the current handshake phase"
        )
    end

    --- SERVER_READY 写出成功后提交 ready 并归还 pending 名额。
    ---@param context HandshakeContext Gateway 当前连接的独占握手上下文。
    ---@return FlyWowResult<nil> 成功表示 ready 已提交；阶段错误或期限过期时返回失败结果。
    function manager.confirm(context)
        if type(context) ~= "table" or not context.held or context.phase ~= "confirm" then
            return flywow_result.failure(
                "HANDSHAKE_STATE",
                "handshake is not waiting for transport confirmation"
            )
        end

        -- 先拒绝已过期连接，再验证帧长，避免为无效消息调用 Native。
        if manager.expired(context) then
            manager.close(context)
            return flywow_result.failure(
                "HANDSHAKE_TIMEOUT",
                "absolute handshake deadline expired"
            )
        end

        -- 确认仍有效后开放业务，并通过幂等 close 归还 pending 名额。
        context.phase = "ready"
        manager.close(context)
        return flywow_result.success()
    end

    --- 返回是否允许当前连接进入业务收发。
    ---@param context HandshakeContext|nil Gateway 为连接保存的握手上下文。
    ---@return boolean context 阶段为 ready 时为 true。
    function manager.ready(context)
        return type(context) == "table" and context.phase == "ready"
    end

    return flywow_result.success(manager)
end

return M
