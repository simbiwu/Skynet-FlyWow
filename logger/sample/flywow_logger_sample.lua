-- 通过业务日志入口写入两条日志，并等待 Logger 刷新完成。
local skynet = require "skynet"
local logger = require "flywow_logger"

skynet.start(function()
    skynet.error("FLYWOW_LOGGER_SAMPLE_NORMAL", "normal")
    skynet.error("FLYWOW_LOGGER_SAMPLE_ERROR")
    logger.flush()

    print("FLYWOW_LOGGER_SAMPLE_OK")
    io.stdout:flush()
    io.stderr:flush()
    os.exit(0)
end)
