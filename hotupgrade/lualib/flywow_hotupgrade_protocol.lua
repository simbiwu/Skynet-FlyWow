--- 当前 Lua State 的 HotUpgrade Skynet 协议注册与消息分发。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local M = {}

-- 每个 Lua State 加载本模块时注册协议；仅有界等待使用 skynet.request/select，其余请求直接 skynet.call。
skynet.register_protocol(
{
    name = "hotupgrade", id = 20,
    pack = skynet.pack, unpack = skynet.unpack,
})

--- 安装 HotUpgrade 消息处理器；source 保持 Skynet 消息头提供的发送方 handle。
---@param handler function 接收 command/request/source 并返回 result；允许 yield。
function M.install_handler(handler)
    skynet.dispatch("hotupgrade", function(session, source, command, request)
        local ok, answer = pcall(handler, command, request, source)
        if not ok then
            answer = result.failure("HU_CONTROL_FAILED", tostring(answer))
        end
        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end

return M
