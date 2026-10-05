--- 职责：真实 Skynet 验证等级、子 Service 自动接入和刷新。
--- 由 integration_test.py 启动；测试以已刷新文件判断结果。
local skynet = require "skynet.manager"
local logger = require "flywow_logger"

--- 启动入口先发送日志，再等待刷新确认；延迟结束进程以完成调度。
skynet.start(function()
    skynet.error("PROBE_DEBUG", "debug")
    skynet.error("PROBE_NORMAL", "normal")
    skynet.error("PROBE_ERROR")
    skynet.error("PROBE_NIL", nil, "normal")
    skynet.error("PROBE_LONG " .. string.rep("x", 9000), "normal")
    skynet.error("PROBE_LINE\nsecond", "normal")
    local worker = skynet.newservice("logger_child")
    assert(skynet.call(worker, "lua", "ready"))
    assert(skynet.launch("flywow_logger_probe_native"))
    logger.flush()
    skynet.sleep(120)
    skynet.abort()
end)
