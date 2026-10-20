-- 在真实 Skynet Lua State 中运行 WordFilter Lua/Native API。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "word_filter_sample"
lualoader = "./third_party/skynet/lualib/loader.lua"
luaservice = "./third_party/skynet-flywow/word_filter/sample/?.lua;"
    .. "./third_party/skynet/service/?.lua"
lua_path = "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/word_filter/lualib/?.lua"
lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet/cservice/?.so"
