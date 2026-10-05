--- 职责：仅启动 WordFilter 的 Skynet 集成测试，无业务 Server、无监听端口。
--- 配置由 Skynet 启动时读取；所有路径以宿主 server/ 工作目录为基准。
--- CTest 从 word_filter/native/CMakeLists.txt 设置工作目录并负责测试超时。

thread = 4 --- OS Worker 数量，用于验证不同 Lua Service 的独立调用。
harbor = 0 --- 使用 Skynet 本地模式，不启用跨节点通信。

bootstrap = "snlua bootstrap"  --- 固定 Skynet 引导入口。
start     = "skynet_word_filter" --- 集成测试启动者，测试结束后退出整个测试进程。

lualoader = "./third_party/skynet/lualib/loader.lua" --- 加载固定 Skynet Lua Service。
luaservice = "./third_party/skynet-flywow/word_filter/tests/?.lua;./third_party/skynet/service/?.lua"

--- 普通 Lua 搜索路径包含 Skynet 和 WordFilter Wrapper；不引入其它业务模块。
lua_path = "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. "./third_party/skynet-flywow/word_filter/lualib/?.lua"

--- require 的 Lua Native Binding 与 Skynet 原生 Service 使用不同搜索字段。
lua_cpath = "./third_party/skynet/luaclib/?.so;./third_party/skynet-flywow/build/native/?.so"
cpath     = "./third_party/skynet/cservice/?.so"
