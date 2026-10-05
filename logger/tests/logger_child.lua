--- 职责：验证 newservice 自动适配与名称登记；仅用于独立测试。
local skynet = require "skynet"

--- ready 回复前产生日志，父 Service 收到回复后执行最终刷新。
skynet.start(function()
    skynet.error("PROBE_CHILD", "normal")
    skynet.dispatch("lua", function()
        skynet.retpack(true)
    end)
end)
