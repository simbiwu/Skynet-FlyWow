-- 配置只引用运行脚本导出的绝对路径，不依赖某个固定的 Server 目录布局。
-- Skynet 配置加载器先展开字符串中的 $变量名；配置运行环境没有 os，因此这里不能调用 os.getenv。
-- run.sh 提供的 Skynet 根目录，供加载器、Service 和 Native 搜索路径拼接。
local skynet_root = "$FLYWOW_MASTER_SKYNET_ROOT"
-- run.sh 提供的 FlyWow 框架根目录，供 HotUpgrade 服务、模块和 Native 库加载。
local framework_root = "$FLYWOW_MASTER_FRAMEWORK_ROOT"
-- run.sh 提供的课程脚本目录，Skynet 从这里加载 main.lua。
local course_root = "$FLYWOW_MASTER_COURSE_ROOT"
-- run.sh 创建的可写运行夹具目录，包含本次运行的 host 和 patches。
local runtime_root = "$FLYWOW_MASTER_RUNTIME_ROOT"

thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "main"
lualoader = skynet_root .. "/lualib/loader.lua"

luaservice = framework_root .. "/hotupgrade/service/?.lua;"
    .. course_root .. "/?.lua;"
    .. runtime_root .. "/host/service/?.lua;"
    .. skynet_root .. "/service/?.lua"

lua_path = runtime_root .. "/host/?.lua;"
    .. runtime_root .. "/host/lualib/?.lua;"
    .. runtime_root .. "/host/lualib/?/init.lua;"
    .. skynet_root .. "/lualib/?.lua;"
    .. skynet_root .. "/lualib/?/init.lua;"
    .. framework_root .. "/common/lualib/?.lua;"
    .. framework_root .. "/hotupgrade/lualib/?.lua"

lua_cpath = skynet_root .. "/luaclib/?.so;"
    .. framework_root .. "/build/native/?.so"

cpath = skynet_root .. "/cservice/?.so"
