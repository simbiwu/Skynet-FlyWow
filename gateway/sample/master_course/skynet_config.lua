thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "world_service"
lualoader = "./third_party/skynet/lualib/loader.lua"

luaservice = "./third_party/skynet-flywow/gateway/service/?.lua;"
    .. "./third_party/skynet-flywow/gateway/sample/master_course/service/?.lua;"
    .. "./third_party/skynet/service/?.lua"

lua_path = "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/common/lualib/?.lua;"
    .. "./third_party/skynet-flywow/gateway/lualib/?.lua;"
    .. "./third_party/skynet-flywow/gateway/sample/master_course/generated/?.lua"

lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. "./third_party/lua-protobuf-runtime/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so"