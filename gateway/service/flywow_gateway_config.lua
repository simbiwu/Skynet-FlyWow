local skynet = require "skynet"
local flywow_result = require "flywow_result"
local M = {}

--- 校验有界整数配置；调用方需要区分成功值与配置错误。
---@param config_value number|string|nil 宿主传入的候选配置值。
---@param config_name string 错误详情中指出的配置字段。
---@param min_value integer 合法范围下界，含端点。
---@param max_value integer 合法范围上界，含端点。
---@return FlyWowResult<integer> 成功 value 为整数；类型或范围错误返回 GATEWAY_CONFIG_INVALID。
function M.validate_integer_config(config_value, config_name, min_value, max_value)
    if type(config_value) ~= "number" or math.type(config_value) ~= "integer" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            config_name .. " must be an integer",
            { field = config_name }
        )
    end
    if config_value < min_value or config_value > max_value then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            config_name .. " is outside the allowed range",
            { field = config_name, minimum = min_value, maximum = max_value }
        )
    end

    return flywow_result.success(config_value)
end

--- 校验并复制宿主配置；运行期间 Gateway 不再读取调用方可变 table。
---@param startup_config GatewayStartConfig 宿主传入的完整启动配置；本函数只读取配置字段。
---@return FlyWowResult<GatewayStartConfig> 成功 value 为已验证副本；字段无效时返回 GATEWAY_CONFIG_INVALID。
function M.normalize_config(startup_config)
    if type(startup_config) ~= "table" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "gateway start config must be a table"
        )
    end

    -- 只有 nil 使用默认监听地址；显式 false 等错误值仍交给类型检查拒绝。
    local host = startup_config.host
    if host == nil then
        host = "127.0.0.1"
    end
    if type(host) ~= "string" or host == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "host must be a non-empty address",
            { field = "host" }
        )
    end

    -- 先选定本实例运行期间不变的传输类型，再校验其余配置。
    local transport = startup_config.transport
    if transport == nil then
        transport = "tcp"
    end
    if transport ~= "tcp" and transport ~= "websocket" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "unsupported gateway transport",
            { field = "transport", value = tostring(transport) }
        )
    end

    -- 数值配置按原有次序逐项校验，首个失败结果直接作为启动结果返回。
    local normalized =
    {
        host = host, -- 已校验的监听地址；只影响当前 Gateway。
        transport = transport, -- 已校验且运行期不可切换的 TCP/WebSocket 传输。
    }

    -- 连接配额由宿主按部署资源显式分配；Lua integer 本身是唯一数值表示上界。
    local validation_result = M.validate_integer_config(startup_config.max_clients, "max_clients", 1, math.maxinteger)
    if not validation_result.ok then
        return validation_result
    end

    -- 保存宿主分配的接纳配额，供每次 accept 在创建连接状态前检查。
    normalized.max_clients = validation_result.value

    -- port 和 protocol_version 必须由宿主显式提供。
    validation_result = M.validate_integer_config(startup_config.port, "port", 1, 65535)
    if not validation_result.ok then
        return validation_result
    end

    -- 记录宿主要求的监听端口。
    normalized.port = validation_result.value

    -- Worker 数量由启动配置覆盖；缺省时使用当前 Skynet Node 的 thread 数。
    local worker_count = startup_config.worker_count
    local node_thread_value = skynet.getenv("thread")
    local node_thread_count = tonumber(node_thread_value)
    if not node_thread_count or math.type(node_thread_count) ~= "integer" or node_thread_count < 1 then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "Skynet thread must be a positive integer",
            { field = "thread", value = tostring(node_thread_value) }
        )
    end
    if worker_count == nil then-- Skynet 环境变量以字符串提供，因此先转成 Lua 整数再验证。
        worker_count = node_thread_count
    end
    local worker_count_result = M.validate_integer_config(
        worker_count,
        "worker_count",
        1,
        node_thread_count
    )
    if not worker_count_result.ok then
        return worker_count_result
    end
    normalized.worker_count = worker_count_result.value

    -- protocol_version 必须显式提供，沿用相同的整数边界合同。
    validation_result = M.validate_integer_config(startup_config.protocol_version, "protocol_version", 1, 0xffffffff)
    if not validation_result.ok then
        return validation_result
    end

    -- 记录 Envelope 版本，供消息入口和出站编码使用。
    normalized.protocol_version = validation_result.value

    local candidate = startup_config.read_timeout_ms
    if candidate == nil then
        candidate = 30000
    end

    -- 仅缺省时补默认值；显式输入原样交给下方整数边界校验。
    validation_result = M.validate_integer_config(candidate, "read_timeout_ms", 1, math.maxinteger)
    if not validation_result.ok then
        return validation_result
    end

    -- 保存 TCP 读取与 WebSocket Upgrade 的毫秒期限。
    normalized.read_timeout_ms = validation_result.value

    candidate = startup_config.idle_timeout_ms
    if candidate == nil then
        candidate = 300000
    end

    -- 仅缺省时补默认值；显式输入原样交给下方整数边界校验。
    validation_result = M.validate_integer_config(candidate, "idle_timeout_ms", 1, math.maxinteger)
    if not validation_result.ok then
        return validation_result
    end

    -- 保存完整客户端消息之间的毫秒空闲期限。
    normalized.idle_timeout_ms = validation_result.value

    candidate = startup_config.handshake_timeout_ms
    if candidate == nil then
        candidate = 10000
    end

    -- 仅缺省时补默认值；显式输入原样交给下方整数边界校验。
    validation_result = M.validate_integer_config(candidate, "handshake_timeout_ms", 1, math.maxinteger)
    if not validation_result.ok then
        return validation_result
    end

    -- 保存从连接登记起算的握手毫秒期限。
    normalized.handshake_timeout_ms = validation_result.value

    -- 协议文件与 handler 名称由宿主组合根提供，必须是非空字符串。
    normalized.handler_service = startup_config.handler_service
    if type(normalized.handler_service) ~= "string" or normalized.handler_service == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "handler_service must be a non-empty Skynet service name",
            { field = "handler_service" }
        )
    end

    -- Descriptor 路径指向宿主生成的协议描述文件，缺失时无法初始化 Codec。
    normalized.descriptor_path = startup_config.descriptor_path
    if type(normalized.descriptor_path) ~= "string" or normalized.descriptor_path == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "descriptor_path is required",
            { field = "descriptor_path" }
        )
    end

    -- Registry 模块由宿主按当前课程选择，缺失时 Gateway 无法解析命令。
    normalized.registry_module = startup_config.registry_module
    if type(normalized.registry_module) ~= "string" or normalized.registry_module == "" then
        return flywow_result.failure(
            "GATEWAY_CONFIG_INVALID",
            "registry_module is required",
            { field = "registry_module" }
        )
    end

    return flywow_result.success(normalized)
end

return M