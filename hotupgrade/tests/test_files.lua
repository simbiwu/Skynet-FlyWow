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
local c = controller -- 后续场景共用的已初始化 Controller 单例。
--- 用可控的虚拟 handle 创建并登记一个测试 Service，供文件扫描场景匹配目标。
---@param instance table 已初始化的测试 Controller；本函数向它发送 newservice 和 register。
---@param service_handle integer 测试替身指定的 Service handle；用于模拟原生创建返回值和登记消息来源。
---@param metadata table 测试 Service 登记的模块名及更新能力；本函数原样提交给 register。
---@param service_name string 测试 Service 入口名；本函数把它放进 newservice 请求。
local function register_fixture(instance, service_handle, metadata, service_name)
    local skynet = require "skynet" -- 替换 newservice，让 Controller 获得可控的虚拟 handle。
    local original_newservice = skynet.newservice -- 保存原生创建函数，避免影响后续测试。
    skynet.newservice = function() return service_handle end
    local created = instance:handle_command("newservice", -- 创建登记窗口；随后用 service_handle 模拟真实来源。
        {service_name = service_name, arguments = {n = 0}}, 1)
    skynet.newservice = original_newservice
    assert(created.ok and instance.service_creations[service_handle].service_name == service_name)
    local registered = instance:handle_command("register", metadata, service_handle) -- 目标携带创建时获得的真实 handle 登记。
    assert(registered.ok and instance.service_registrations[service_handle].service_name == service_name)
    return registered
end
assert(register_fixture(c, 10, {modules = {"lualib.test_worker_logic"},
    has_service_update = true}, "battle/worker").ok)
assert(c:load_patch({patch_dir = "module"}).ok)
assert(not c:load_patch({patch_dir = "invalid"}).ok)
for _, path in ipairs({"../module", "/module", "module/../module", "module//lualib",
    "module/", "module/./lualib", "module\\lualib", "module" .. string.char(0)}) do
    assert(not hotupgrade_native.list_lua(root, path), path)
end

for _, path in ipairs({"duplicate_module"}) do
    assert(c:load_patch({patch_dir = path}).code == "HU_INVALID_PATCH")
end
local many_files = assert(hotupgrade_native.list_lua(root, "count_unlimited")) -- 用于确认扫描不因文件数量达到 1024 而截断。
assert(#many_files == 1025)
assert(#assert(hotupgrade_native.list_lua(root, "file_unlimited")) == 1)
assert(#assert(hotupgrade_native.list_lua(root, "total_unlimited")) == 9)
-- Lua Controller 也必须读取完整源码；未登记普通 .lua 现在可直接进入部署集合。
for _, path in ipairs({"count_unlimited", "file_unlimited", "total_unlimited"}) do
    assert(c:load_patch({patch_dir = path}).ok)
end
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
assert(register_fixture(c, 20,
    {modules = {}, has_service_update = true}, "skynet_hotupgrade_worker").ok)
assert(c:load_patch({patch_dir = "custom_service_files"}).ok)
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
