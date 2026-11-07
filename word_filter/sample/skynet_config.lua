-- 在真实 Skynet Lua State 中运行 WordFilter Lua/Native API。
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "word_filter_sample"
lualoader = "$FLYWOW_WORD_FILTER_SKYNET_ROOT/lualib/loader.lua"
luaservice = "./word_filter/sample/?.lua;"
    .. "$FLYWOW_WORD_FILTER_SKYNET_ROOT/service/?.lua"
lua_path = "$FLYWOW_WORD_FILTER_SKYNET_ROOT/lualib/?.lua;"
    .. "$FLYWOW_WORD_FILTER_SKYNET_ROOT/lualib/?/init.lua;"
    .. "./word_filter/lualib/?.lua"
lua_cpath = "$FLYWOW_WORD_FILTER_SKYNET_ROOT/luaclib/?.so;"
    .. "$FLYWOW_WORD_FILTER_NATIVE_DIR/?.so"
cpath = "$FLYWOW_WORD_FILTER_SKYNET_ROOT/cservice/?.so"
