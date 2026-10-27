--- 从 Server 工作目录启动示例；运行根目录由脚本传入，Skynet 搜索路径沿用集成测试合同。
local sample_root = "./third_party/skynet-flywow/build/hotupgrade-sample"
local framework_root = "./third_party/skynet-flywow"

thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "flywow_hotupgrade_sample"
lualoader = "./third_party/skynet/lualib/loader.lua"
luaservice = framework_root .. "/hotupgrade/service/?.lua;"
    .. framework_root .. "/hotupgrade/sample/?.lua;"
    .. sample_root .. "/host/service/?.lua;"
    .. "./third_party/skynet/service/?.lua"
lua_path = sample_root .. "/host/?.lua;"
    .. sample_root .. "/host/lualib/?.lua;"
    .. sample_root .. "/host/lualib/?/init.lua;"
    .. "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. framework_root .. "/common/lualib/?.lua;"
    .. framework_root .. "/hotupgrade/lualib/?.lua"
lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so"
