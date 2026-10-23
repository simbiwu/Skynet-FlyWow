--- 职责：每个 Lua State 的 skynet.error 级别适配与 Logger 刷新接口。
--- Native Logger 负责写盘；本模块只解析、限长、过滤和异步转发，不持有文件。
--- 由 logger/lualib/flywow_logger_preload.lua 自动安装，业务不必逐个 require。
local skynet = require "skynet"

-- 与 logger/native/flywow_logger.h 的 kCommand* 常量保持一致；这些字符是 Lua/Native 共用的内部消息合同。
local LOGGER_COMMAND_LOG = "L"
local LOGGER_COMMAND_REGISTER = "R"
local LOGGER_COMMAND_UNREGISTER = "U"
local LOGGER_COMMAND_FLUSH = "F"

-- 数值与 Native LogLevel 枚举对应；越大越严重，并参与本地过滤和 Native 写盘等级识别。
local LOG_LEVELS =
{
    debug  = 0, -- 对应 Native LogLevel::kDebug，最低严重等级。
    normal = 1, -- 对应 Native LogLevel::kNormal，常规运行日志。
    error  = 2, -- 对应 Native LogLevel::kError，错误日志且为默认等级。
}

-- 与 Native kMaxServiceNameSize 保持相同上限；两种语言各自校验自己的消息入口。
local MAX_SERVICE_NAME_SIZE = 128

-- 保存 Skynet 原始日志入口，避免替换后适配器递归调用自身。
local ORIGINAL_ERROR = skynet.error
local logger = {}
local logger_is_installed = false -- 当前 State 完成入口替换后置 true，后续 install 直接返回。

--- 登记当前 Lua Service 的展示名称。
--- 这里集中把 Service 名称转换为 Logger 的 R 消息，让 Native Logger 映射 source handle。
---@param service_name string 已限制长度的 Service 名称
local function send_service_register(service_name)
    ORIGINAL_ERROR(LOGGER_COMMAND_REGISTER .. service_name)
end

--- 通知 Native Logger 当前 Service 即将退出。
--- 这里集中把退出动作转换为 Logger 的 U 消息，清理来源登记。
local function send_service_unregister()
    ORIGINAL_ERROR(LOGGER_COMMAND_UNREGISTER)
end

--- 创建 Native Logger 的刷新请求。
--- 这里集中把刷新动作转换为 Logger 的 F 消息，调用方再通过 skynet.call 等待结果。
local function make_flush_request()
    return LOGGER_COMMAND_FLUSH
end

--- 解析 skynet.error 的最后一个等级参数并异步发送。
--- 未传等级默认 error；其余参数转成字符串后用一个空格连接。
--- Native 消息格式为命令字符、等级数字、正文；等级与正文之间不插入分隔符。
local function make_adapter(min_level)
    return function(...) -- VARARG_ALLOWED WHY: 保持 skynet.error 的未知参数个数与 nil 兼容。
        -- 取出可选等级；等级参数不再作为正文发送。
        local log_arguments = table.pack(...)
        local level = LOG_LEVELS[log_arguments[log_arguments.n]]
        if level ~= nil then
            log_arguments.n = log_arguments.n - 1
        else
            level = LOG_LEVELS.error
        end

        if level < min_level then
            return
        end

        -- 先得到正文，再一次性拼成 L+等级+正文，避免 Skynet 多参数拼接产生额外空格。
        local parts = {}
        for i = 1, log_arguments.n do
            parts[i] = tostring(log_arguments[i])
        end

        local body = table.concat(parts, " ")
        ORIGINAL_ERROR(LOGGER_COMMAND_LOG .. tostring(level) .. body)
    end
end

--- 安装当前 Lua State 的适配；只在配置 logservice=flywow_logger 时生效，重复安装无副作用。
--- Service 名来自标准 loader 的 SERVICE_NAME；注销在正常 skynet.exit 时发送。
--- 不 yield，不修改其他 Service 的 Lua State；异常退出记录由有界登记表限制内存。
function logger.install()
    if logger_is_installed then
        return
    end

    if skynet.getenv("logservice") ~= "flywow_logger" then
        return
    end

    -- 第一阶段：读取当前进程的最低日志级别。
    local configured_level = skynet.getenv("flywow_logger_level")
    local level_name = configured_level or "normal"
    local min_level = assert(LOG_LEVELS[level_name], "invalid flywow_logger_level")

    -- 第二阶段：登记当前 Service，让 Native 日志包含可读名称和 source handle。
    local service_name = tostring(SERVICE_NAME or "unknown"):sub(1, MAX_SERVICE_NAME_SIZE)
    send_service_register(service_name)

    -- 第三阶段：替换当前 Lua State 的入口，同时保存原始退出函数。
    skynet.error = make_adapter(min_level)

    local original_exit = skynet.exit
    --- 正常退出前注销名称；不等待 Logger，名称消息与本 Service 日志保持发送顺序。
    skynet.exit = function()
        -- 注销只清理 Logger 的来源登记，不等待 Logger，也不改变 Skynet 退出流程。
        send_service_unregister()
        return original_exit()
    end

    logger_is_installed = true
end

--- 刷新 Logger 已接收的日志；唯一全局发现是 Skynet 标准 .logger 启动链名字。
--- 返回 true，写盘失败抛错误；会 yield，业务先停止生产日志再调用，不能替代全进程静止屏障。
---@return boolean
function logger.flush()
    if skynet.getenv("logservice") ~= "flywow_logger" then
        return true
    end

    if not skynet._proto.text then
        skynet.register_protocol
        {
            name   = "text",
            id     = skynet.PTYPE_TEXT,
            pack   = function(text) return text end,
            unpack = skynet.tostring,
        }
    end

    -- flush 是唯一需要等待 Logger 响应的路径；普通日志仍然是异步投递。
    local result = skynet.call(".logger", "text", make_flush_request())
    assert(result == "OK", "FlyWow Logger flush failed")
    return true
end

return logger
