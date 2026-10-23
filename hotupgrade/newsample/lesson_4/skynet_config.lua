local framework_root = "./third_party/skynet-flywow"
local runtime_root = framework_root .. "/build/hotupgrade-newsample/lesson_4"

thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "main"

lualoader = "./third_party/skynet/lualib/loader.lua"

luaservice = framework_root .. "/hotupgrade/service/?.lua;"
    .. framework_root .. "/hotupgrade/newsample/lesson_4/?.lua;"
    .. runtime_root .. "/host/service/?.lua;"
    .. "./third_party/skynet/service/?.lua"

lua_path = runtime_root .. "/host/?.lua;"
    .. runtime_root .. "/host/lualib/?.lua;"
    .. runtime_root .. "/host/lualib/?/init.lua;"
    .. "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. framework_root .. "/hotupgrade/lualib/?.lua"

lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. framework_root .. "/build/native/?.so"

cpath = "./third_party/skynet/cservice/?.so"