--- 职责：每个 Lua State 的 skynet.error 级别适配与 Logger 刷新接口。
--- Native Logger 负责写盘；本模块只解析、限长、过滤和异步转发，不持有文件。
--- 由 logger/lualib/flywow_logger_preload.lua 自动安装，业务不必逐个 require。
local skynet = require "skynet"

-- 保存 Skynet 原始日志入口：skynet.error 实际指向 Native 的 c.error，
-- c.error 会把文本消息投递给名为 logger 的 Service，最终进入 flywow_logger callback。
-- install() 会替换 skynet.error；适配器必须调用 original_error，不能再次调用
-- skynet.error，否则会重新进入适配器并造成递归。
local original_error = skynet.error

local logger = {}

-- 级别数值越大越严重；这个顺序同时用于最低等级过滤和 Native Logger 写盘。
local levels =
{
    debug  = 0,
    normal = 1,
    error  = 2,
}

local installed = false

-- Service 名称在登记消息中的最大长度；日志正文由 Native Logger 统一限制。
local max_service_name_size = 128

--- Logger 消息的第一个字符是命令，Native callback 按第一个字符选择处理分支：
--- L=日志，后面跟等级和正文；R=登记 Service 名称；U=注销 Service；
--- F=刷新日志文件。发送端直接拼接命令和正文，不增加额外协议前缀。
--- 把日志等级和正文拼成一个字符串后交给 Skynet 原始日志入口。
--- L+等级位于正文前面，Native callback 读取前两个字符；参数正文之间用一个空格。


--- 登记当前 Lua Service 的展示名称。
--- 这里集中把 Service 名称转换为 Logger 的 R 消息，让 Native Logger 映射 source handle。
---@param service_name string 已限制长度的 Service 名称
local function send_service_register(service_name)
    original_error("R" .. service_name)
end

--- 通知 Native Logger 当前 Service 即将退出。
--- 这里集中把退出动作转换为 Logger 的 U 消息，清理来源登记。
local function send_service_unregister()
    original_error("U")
end

--- 创建 Native Logger 的刷新请求。
--- 这里集中把刷新动作转换为 Logger 的 F 消息，调用方再通过 skynet.call 等待结果。
local function make_flush_request()
    return "F"
end

--- 解析 skynet.error 的最后一个等级参数并异步发送。
--- 未传等级默认 error；其余参数转成字符串后用一个空格连接。
local function make_adapter(minimum)
    return function(...) -- VARARG_ALLOWED WHY: 保持 skynet.error 的未知参数个数与 nil 兼容。
        -- 取出可选等级；等级参数不再作为正文发送。
        local args = table.pack(...)
        local level = levels[args[args.n]]
        if level ~= nil then
            args.n = args.n - 1
        else
            level = levels.error
        end

        if level < minimum then
            return
        end

        -- 先得到正文，再一次性拼成 L+等级+正文，避免 Skynet 多参数拼接产生额外空格。
        local parts = {}
        for i = 1, args.n do
            parts[i] = tostring(args[i])
        end

        local body = table.concat(parts, " ")
        original_error("L" .. tostring(level) .. body)
    end
end

--- 安装当前 Lua State 的适配；只在配置 logservice=flywow_logger 时生效，重复安装无副作用。
--- Service 名来自标准 loader 的 SERVICE_NAME；注销在正常 skynet.exit 时发送。
--- 不 yield，不修改其他 Service 的 Lua State；异常退出记录由有界登记表限制内存。
function logger.install()
    if installed then
        return
    end

    if skynet.getenv("logservice") ~= "flywow_logger" then
        return
    end

    -- 第一阶段：读取当前进程的最低日志级别。
    local configured_level = skynet.getenv("flywow_logger_level")
    local level_name = configured_level or "normal"
    local minimum = assert(levels[level_name], "invalid flywow_logger_level")

    -- 第二阶段：登记当前 Service，让 Native 日志包含可读名称和 source handle。
    local service_name = tostring(SERVICE_NAME or "unknown"):sub(1, max_service_name_size)
    send_service_register(service_name)

    -- 第三阶段：替换当前 Lua State 的入口，同时保存原始退出函数。
    skynet.error = make_adapter(minimum)

    local exit = skynet.exit
    --- 正常退出前注销名称；不等待 Logger，名称消息与本 Service 日志保持发送顺序。
    skynet.exit = function()
        -- 注销只清理 Logger 的来源登记，不等待 Logger，也不改变 Skynet 退出流程。
        send_service_unregister()
        return exit()
    end

    installed = true
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
