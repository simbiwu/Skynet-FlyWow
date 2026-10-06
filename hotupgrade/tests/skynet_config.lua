--- 热更集成测试配置：从宿主 server 工作目录运行，不启用业务网络。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "skynet_hotupgrade"
lualoader = "./third_party/skynet/lualib/loader.lua"
luaservice = "./third_party/skynet-flywow/hotupgrade/service/?.lua;"
    .. "./third_party/skynet-flywow/hotupgrade/tests/?.lua;./third_party/skynet/service/?.lua"
lua_path = "./third_party/skynet/lualib/?.lua;./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/hotupgrade/lualib/?.lua;"
    .. "./third_party/skynet-flywow/hotupgrade/tests/?.lua"
lua_cpath = "./third_party/skynet/luaclib/?.so;./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so"
