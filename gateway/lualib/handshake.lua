--- 职责：管理 Gateway 连接的 P-256 挑战握手状态、并发名额和绝对期限。
--- 边界：FlyWow Gateway Runtime Module；不写 Socket、不创建 Service/协程、不处理业务消息。
--- 生命周期：模块在当前 Service 内独占 pending 计数；Gateway connection record 为每条连接保存 HandshakeContext 表，本模块通过该表追踪握手阶段并引用对应 Native 密码 userdata。
--- 失败：可预期失败返回 FlyWowResult；Native Lua Binding 的 nil/error record 在本模块转换为稳定结果。
local flywow_result = require "flywow_result"
local flywow_common = require "flywow_common"

local CLIENT_HELLO_SIZE = 67 -- 类型、版本与非压缩 P-256 公钥组成的完整 HELLO。
local CLIENT_PROOF_SIZE = 33 -- 类型与 HMAC-SHA256 组成的完整客户端证明。
local CLIENT_HELLO_TYPE = 1 -- 本连接首次应用握手消息的类型。
local HANDSHAKE_VERSION = 1 -- 框架握手版本，与业务 Envelope 版本独立。
local MAX_TIMEOUT_MS = 0x80000000 * 10 -- 半个 32 位 Skynet tick 周期，换算为毫秒。

local M = {}
local module_state =
{
    crypto_module = nil, -- 当前 Service 注入的 Native 密码模块。
    read_tick = nil, -- 当前 Service 注入的 tick 时钟。
    max_pending = nil, -- 同时占用的握手名额上限。
    timeout_ms = nil, -- 从 accept 起算的绝对期限，单位毫秒。
    pending = 0, -- accept 占用、release_context 释放；init 不重置活动名额。
}

---@class HandshakeContext
--- Gateway connection record 为单条连接保存的握手状态表。
---@field phase "hello"|"proof"|"confirm"|"ready"|"closed" 当前握手阶段。
---@field started integer 绝对起始 tick；消息不会刷新总期限。
---@field crypto_context userdata|nil M.receive 在 HELLO 成功后保存的 Native userdata；它持有 proof key 和 transcript 摘要，M.close 负责关闭并清空。

---@class HandshakeOutput
---@field response_bytes string 当前阶段需写回客户端的完整握手消息。
---@field needs_confirmation boolean true 表示 SERVER_READY 写成功后还须提交 ready。

--- 初始化当前 Service 的握手模块；从 Gateway start 接收 Native 接口、时钟、名额上限和期限。
---@param handshake_config table 含 crypto/now/max_pending/timeout_ms；期限由 Gateway 以毫秒传入。
---@return FlyWowResult<nil> 成功表示当前 Service 握手配置已就绪；配置无效时返回 HANDSHAKE_CONFIG_INVALID。
function M.init(handshake_config)
    if type(handshake_config) ~= "table" then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "handshake config must be a table"
        )
    end

    -- 配置表形状有效后读取各依赖；下面验证 Native 接口、时钟和资源边界。
    local candidate_crypto_module = handshake_config.crypto -- Gateway 注入的 Native 模块表；创建连接 userdata 并提供 verify/close。
    local candidate_read_tick = handshake_config.now -- Gateway 注入的 10ms tick 时钟；每次读取当前值。
    local candidate_max_pending = handshake_config.max_pending -- 本 Service 可同时持有的握手上下文数量上限。
    local candidate_timeout_ms = handshake_config.timeout_ms -- 从 accept 起算的握手总期限，单位为毫秒。
    if type(candidate_crypto_module) ~= "table" or
        type(candidate_crypto_module.create_context) ~= "function" or
        type(candidate_read_tick) ~= "function" then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "crypto.create_context and now function are required"
        )
    end
    if math.type(candidate_max_pending) ~= "integer" or candidate_max_pending < 1 then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "max_pending must be a positive integer"
        )
    end
    if math.type(candidate_timeout_ms) ~= "integer" or candidate_timeout_ms < 1 or
        candidate_timeout_ms >= MAX_TIMEOUT_MS then
        return flywow_result.failure(
            "HANDSHAKE_CONFIG_INVALID",
            "timeout_ms must be a positive integer shorter than half a Skynet clock cycle"
        )
    end

    -- 依赖全部通过校验后发布配置；Gateway 只在接受连接前初始化，不重置活动名额。
    module_state.crypto_module, module_state.read_tick = candidate_crypto_module, candidate_read_tick
    module_state.max_pending, module_state.timeout_ms = candidate_max_pending, candidate_timeout_ms
    return flywow_result.success()
end

--- 释放连接占用的握手名额和 Native 密码对象；重复调用不改变计数。
---@param context HandshakeContext|nil 当前连接的独占记录；终态不占名额，活动记录的 Native 对象由此关闭。
---@param final_phase "ready"|"closed" 释放资源后提交的 ready 或 closed 终态。
---@return nil 不返回业务值；已释放或 nil context 都是幂等完成。
local function release_context(context, final_phase)
    if type(context) ~= "table" or context.phase == "ready" or context.phase == "closed" then
        return
    end

    -- 只有活动阶段占用名额；先提交终态，重复 close 即由阶段拒绝二次释放。
    context.phase = final_phase
    module_state.pending = module_state.pending - 1
    if context.crypto_context then
        context.crypto_context:close()
        context.crypto_context = nil
    end
end

--- Gateway 关闭连接时释放尚未完成的握手；重复关闭不重复归还名额。
---@param context HandshakeContext|nil 当前连接持有的握手上下文。
---@return nil 资源释放完成，无业务返回值。
function M.close(context)
    release_context(context, "closed")
end

--- Gateway 登记新连接前申请握手名额；必须先 init，成功记录当前 tick，尚不生成密钥。
---@return FlyWowResult<HandshakeContext> 成功 value 为新 context；容量耗尽返回 HANDSHAKE_CAPACITY。
function M.accept()
    if module_state.pending >= module_state.max_pending then
        return flywow_result.failure(
            "HANDSHAKE_CAPACITY",
            "pending handshake capacity reached"
        )
    end

    -- 有容量时创建新的 hello context 并把名额交给该连接。
    module_state.pending = module_state.pending + 1
    return flywow_result.success(
    {
        phase   = "hello", -- hello/proof/confirm 阶段占用 pending；终态不占名额。
        started = module_state.read_tick(), -- 握手绝对起点；后续消息不能刷新期限。
        crypto_context = nil, -- 收到合法 HELLO 后创建的 Native userdata；跨调用保存证明密钥和 transcript 摘要，私钥由 challenge 构建函数局部持有。
    })
end

--- 检查握手总期限；通过 common 的 elapsed_ms 处理回绕并按毫秒判断。
---@param context HandshakeContext|nil accept 建立的记录；读取 phase 与 started，终态不再检查期限。
---@return boolean 是否已超过握手绝对期限。
function M.expired(context)
    if type(context) ~= "table" or context.phase == "ready" or context.phase == "closed" then
        return false
    end

    -- common.elapsed_ms 处理 tick 回绕并返回毫秒；握手期限始终以配置毫秒保存。
    local elapsed_ms = flywow_common.elapsed_ms(context.started, module_state.read_tick()) -- 从 accept 起算的回绕安全时长，单位毫秒。
    return elapsed_ms >= module_state.timeout_ms
end

--- 返回当前握手阶段的精确帧体长度；TCP 在读取 body 前使用。
---@param context HandshakeContext|nil 连接保存的记录；只按 phase 给 TCP 提供当前允许读取的帧体长度。
---@return integer hello 为 67、proof 为 33；其它或无效阶段返回 0。
function M.expected_size(context)
    if type(context) ~= "table" then
        return 0
    end

    -- TCP 先读取当前阶段的固定帧长，非法或终态阶段不会读取业务 body。
    if context.phase == "hello" then
        return CLIENT_HELLO_SIZE
    end

    -- HELLO 响应返回后，下一条合法帧必须是 CLIENT_PROOF。
    if context.phase == "proof" then
        return CLIENT_PROOF_SIZE
    end
    return 0
end

--- Gateway 收到完整 HELLO/PROOF 后调用，返回待写响应；Native 普通失败映射为握手错误并释放资源。
--- 只进行同步密码运算，不 I/O、不 yield；依赖违反固定合同产生的意外错误由 Gateway 会话边界清理。
---@param context HandshakeContext accept 建立的独占记录；读取 phase/started，更新 phase 与 crypto_context。
---@param bytes string 当前完整握手帧；只在本次同步处理期间借用。
---@return FlyWowResult<HandshakeOutput> 成功 value 含 response_bytes/needs_confirmation；失败时释放连接握手资源。
function M.receive(context, bytes)
    -- context 由 Gateway 为来源连接独占保存；bytes 是本次同步处理期间借用的完整帧。
    if type(context) ~= "table" or context.phase == "ready" or context.phase == "closed" then
        return flywow_result.failure(
            "HANDSHAKE_STATE",
            "handshake context is not active"
        )
    end

    -- 先拒绝已过期连接，再验证帧长，避免为无效消息调用 Native。
    if M.expired(context) then
        M.close(context)
        return flywow_result.failure(
            "HANDSHAKE_TIMEOUT",
            "absolute handshake deadline expired"
        )
    end

    -- 有效握手连接仍须发送当前阶段规定的完整帧。
    if type(bytes) ~= "string" or #bytes ~= M.expected_size(context) then
        M.close(context)
        return flywow_result.failure(
            "HANDSHAKE_FRAME",
            "frame length does not match the current handshake stage"
        )
    end

    -- HELLO 阶段验证协议头并创建该连接的 Native 密码上下文。
    if context.phase == "hello" then
        if bytes:byte(1) ~= CLIENT_HELLO_TYPE or bytes:byte(2) ~= HANDSHAKE_VERSION then
            M.close(context)
            return flywow_result.failure(
                "HANDSHAKE_VERSION",
                "unsupported handshake message type or version"
            )
        end

        -- 固定 Binding 成功返回 userdata 和挑战，普通失败返回 nil 与错误记录；意外异常由会话边界处理。
        local crypto_context, challenge_or_error = module_state.crypto_module.create_context(bytes) -- 密码对象及挑战；失败时第二项是 Native 诊断。
        if not crypto_context then
            M.close(context)
            local native_error = challenge_or_error -- Binding 返回的 code/message；保留给 Gateway 记录实际失败原因。
            return flywow_result.failure(
                "HANDSHAKE_CRYPTO",
                "Native failed to create the challenge",
                {
                    native_code = native_error.code, -- Native 指出的具体密码操作失败码。
                    native_message = native_error.message, -- 不含密钥或输入字节的 Native 诊断文本。
                }
            )
        end

        -- Native 成功后把 userdata 交给连接 context，再推进到 proof 阶段。
        context.crypto_context = crypto_context
        context.phase = "proof"
        return flywow_result.success(
        {
            response_bytes = challenge_or_error, -- 发送给客户端的 SERVER_CHALLENGE bytes。
            needs_confirmation = false, -- challenge 后仍等待 CLIENT_PROOF，尚不能开放业务。
        })
    end

    -- proof 阶段校验客户端 HMAC；成功只生成 READY，Socket 写入仍由 Gateway 决定。
    if context.phase == "proof" then
        local ready_bytes, native_error = context.crypto_context:verify(bytes) -- 完整 SERVER_READY；失败时第二项为 Native 的 code/message。
        if not ready_bytes then
            M.close(context)
            return flywow_result.failure(
                "HANDSHAKE_PROOF",
                "Native rejected the client proof",
                {
                    native_code = native_error.code, -- 区分证明不匹配与底层密码操作失败。
                    native_message = native_error.message, -- 交给 Gateway 日志的失败原因，不含证明字节。
                }
            )
        end

        -- 客户端证明通过后等待 Gateway 写出 SERVER_READY，再提交 ready。
        context.phase = "confirm"
        return flywow_result.success(
        {
            response_bytes = ready_bytes, -- 发送给客户端的 SERVER_READY 证明 bytes。
            needs_confirmation = true, -- 仅 transport 写成功后 Gateway 才能提交 ready。
        })
    end

    -- 非 hello/proof 阶段的消息不可继续；释放名额和 Native key。
    M.close(context)
    return flywow_result.failure(
        "HANDSHAKE_STATE",
        "message is not valid in the current handshake phase"
    )
end

--- Gateway 将 SERVER_READY 提交给本地传输后调用，复核期限、归还名额并开放业务；不表示对端已收到。
--- 本函数不 I/O、不 yield；会话只能在本次写成功后调用，不能提前确认。
---@param context HandshakeContext receive 已推进到 confirm 的记录；检查 phase/started，释放 crypto_context 并提交 ready。
---@return FlyWowResult<nil> 成功表示 ready 已提交；阶段错误或期限过期时返回失败结果。
function M.confirm(context)
    if type(context) ~= "table" or context.phase ~= "confirm" then
        return flywow_result.failure(
            "HANDSHAKE_STATE",
            "handshake is not waiting for transport confirmation"
        )
    end

    -- SERVER_READY 已写出后仍检查绝对期限，过期连接不能进入业务阶段。
    if M.expired(context) then
        M.close(context)
        return flywow_result.failure(
            "HANDSHAKE_TIMEOUT",
            "absolute handshake deadline expired"
        )
    end

    -- 确认仍有效后释放 Native 对象和名额，直接提交 ready 终态。
    release_context(context, "ready")
    return flywow_result.success()
end

--- 返回是否允许当前连接进入业务收发。
---@param context HandshakeContext|nil Gateway 为连接保存的握手上下文。
---@return boolean 当前阶段是否为 ready。
function M.ready(context)
    return type(context) == "table" and context.phase == "ready"
end

return M
