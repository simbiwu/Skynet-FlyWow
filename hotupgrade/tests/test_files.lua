--- 在真实 Skynet 内验证递归扫描、路径安全及无数量/字节硬上限。
local hotupgrade_native = require "flywow_hotupgrade_native" -- 调用真实 Native 文件扫描、读取和替换接口。
local controller = require "flywow_hotupgrade_controller" -- 被测 Controller，用于核对 Lua 层配置和包扫描。
local config = require "hotupgrade_test_options" -- 集成启动脚本提供的临时宿主与 Patch 根目录。
local root = config.patch_path -- 当前测试发布包根目录，扫描路径均相对它解析。
-- Controller 同时需要真实宿主根和发布包根；service_path 指定业务 Service 文件所在目录。
local controller_config =
{
    patch_path = config.patch_path,
    root_path = config.root_path,
    service_path = "actors/zone",
}
assert(hotupgrade_native.append_sync == nil)
local paths = assert(hotupgrade_native.list_lua(root, "module")) -- module 包中的普通 Lua 文件列表。
assert(#paths == 1 and paths[1] == "lualib/test_worker_logic.lua")
local hotupgrade = require "flywow_hotupgrade" -- 用于确认控制面初始化前普通模块加载入口关闭。
local early_ok, early_error = pcall(hotupgrade.require, "test_worker_logic") -- 初始化前调用的成功标志和拒绝原因。
assert(not early_ok and tostring(early_error):find("HU_NOT_INITIALIZED", 1, true))
assert(not controller.initialize({}).ok)
assert(controller.initialize(controller_config).ok)
for _, path in ipairs({"../module", "/module", "module/../module", "module//lualib",
    "module/", "module/./lualib", "module\\lualib", "module" .. string.char(0)}) do
    assert(not hotupgrade_native.list_lua(root, path), path)
end

local many_files = assert(hotupgrade_native.list_lua(root, "count_unlimited")) -- 用于确认扫描不因文件数量达到 1024 而截断。
assert(#many_files == 1025)
assert(#assert(hotupgrade_native.list_lua(root, "file_unlimited")) == 1)
assert(#assert(hotupgrade_native.list_lua(root, "total_unlimited")) == 9)
-- 大文件应被完整读取；夹具比此前 2 MiB 的单文件限制多一个字节。
assert(#assert(hotupgrade_native.read_file(root, "file_unlimited/large.lua")) == 2 * 1024 * 1024 + 1)
local other_root = config.root_path .. "/another" -- 与已解析宿主根不同的目录，用来验证配置不一致会被拒绝。
assert(os.execute("mkdir -p " .. other_root .. "/service"))
local conflicting = controller.initialize({patch_path = root, root_path = other_root, service_path = "service"}) -- 错误根目录配置的校验结果。
assert(not conflicting.ok and conflicting.code == "HU_INVALID_OPTIONS")
assert(require("skynet").getenv(require("flywow_hotupgrade_common").ROOT_PATH_ENV)
    == hotupgrade_native.resolve(config.root_path))

-- 文件、子目录和被选定的 Patch 目录本身都不能用符号链接绕过检查。
assert(os.execute("mkdir -p " .. root .. "/link_holder"))
for _, link in ipairs({
    {path = root .. "/module/lualib/linked.lua", target = "test_worker_logic.lua", patch = "module"},
    {path = root .. "/module/linked", target = "lualib", patch = "module"},
    {path = root .. "/linked_patch", target = "module", patch = "linked_patch"},
    {path = root .. "/link_holder/service", target = "../module/lualib", patch = "link_holder"},
}) do
    assert(os.execute("ln -s " .. link.target .. " " .. link.path))
    local listed = hotupgrade_native.list_lua(root, link.patch) -- 符号链接目标应被拒绝，不能进入文件清单。
    assert(os.remove(link.path))
    assert(listed == nil)
end

-- 特殊文件和 Controller 的非法目录配置同样在启动热更前拒绝。
local fifo = root .. "/module/special"
assert(os.execute("mkfifo " .. fifo))
assert(not hotupgrade_native.list_lua(root, "module"))
assert(os.remove(fifo))
for _, service_path in ipairs({"../service", "/service", "service/../service", "service/"}) do
    local rejected = controller.initialize( -- 非法 Service 目录配置的初始化结果。
    {
        patch_path = root, root_path = config.root_path, service_path = service_path,
    })
    assert(not rejected.ok and rejected.code == "HU_INVALID_PATH")
end
local service_link = config.root_path .. "/service_link" -- 指向真实 service 目录的链接，用于验证入口路径拒绝符号链接。
assert(os.execute("ln -s service " .. service_link))
local rejected = controller.initialize({patch_path = root, root_path = config.root_path, service_path = "service_link"}) -- 指向符号链接目录时必须拒绝初始化。
assert(os.remove(service_link))
assert(not rejected.ok and rejected.code == "HU_INVALID_PATH")
local file_path = "native_files/nested/value.lua" -- Native 测试用的宿主相对文件路径，依次覆盖创建、覆盖和删除。
assert(hotupgrade_native.read_file(config.root_path, file_path) == false)
assert(hotupgrade_native.replace_file(config.root_path, file_path, "old"))
assert(hotupgrade_native.read_file(config.root_path, file_path) == "old")
assert(hotupgrade_native.replace_file(config.root_path, file_path, "new"))
assert(hotupgrade_native.read_file(config.root_path, file_path) == "new")
assert(hotupgrade_native.replace_file(config.root_path, file_path))
assert(hotupgrade_native.read_file(config.root_path, file_path) == false)
for _, path in ipairs({"../outside.lua", "/outside.lua", "native_files//x.lua", "native_files/../x.lua"}) do
    assert(hotupgrade_native.read_file(config.root_path, path) == nil)
    assert(hotupgrade_native.replace_file(config.root_path, path, "bad") == nil)
end
local link = config.root_path .. "/native_files/link.lua" -- 指向普通文件的链接，读写 API 都必须拒绝它。
assert(os.execute("ln -s nested/value.lua " .. link))
assert(hotupgrade_native.read_file(config.root_path, "native_files/link.lua") == nil)
assert(hotupgrade_native.replace_file(config.root_path, "native_files/link.lua", "bad") == nil)
assert(os.remove(link))
assert(os.execute("mkdir -p " .. config.root_path .. "/native_files/directory.lua"))
assert(hotupgrade_native.replace_file(config.root_path, "native_files/directory.lua", "bad") == nil)
print("HOTUPGRADE_FILES_OK")
