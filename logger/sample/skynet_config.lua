-- 从 Server 根目录启动；所有输出落在 FlyWow build 下的隔离目录。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "flywow_logger_sample"
lualoader = "./third_party/skynet/lualib/loader.lua"
luaservice = "./third_party/skynet-flywow/logger/sample/?.lua;"
    .. "./third_party/skynet/service/?.lua"
lua_path = "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./third_party/skynet/luaclib/?.so"
cpath = "./third_party/skynet/cservice/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
logservice = "flywow_logger"
logger = "./third_party/skynet-flywow/build/logger-sample/logs"
flywow_logger_level = "debug"
flywow_logger_console = true
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
