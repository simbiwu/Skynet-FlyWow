-- 从 Server 根目录启动 Navigation 示例 Service。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "navigation_sample"
lualoader = "./third_party/skynet/lualib/loader.lua"
luaservice = "./third_party/skynet-flywow/navigation/sample/?.lua;"
    .. "./third_party/skynet/service/?.lua"
lua_path = "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./lualib/?.lua;"
    .. "./third_party/skynet-flywow/navigation/lualib/?.lua"
lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so"
