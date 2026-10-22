--- 在真实 Skynet 内验证递归扫描、路径安全及无数量/字节硬上限。
local hotupgrade_native = require "flywow_hotupgrade_native"
local controller = require "flywow_hotupgrade_controller"
local config = require "hotupgrade_test_options"
local root = config.patch_path
local controller_config =
{
    patch_path = config.patch_path,
    root_path = config.root_path,
    service_path = "actors/zone",
}
assert(hotupgrade_native.append_sync == nil)
local paths = assert(hotupgrade_native.list_lua(root, "module"))
assert(#paths == 1 and paths[1] == "lualib/test_worker_logic.lua")
local hotupgrade = require "flywow_hotupgrade"
local early_ok, early_error = pcall(hotupgrade.require, "test_worker_logic")
assert(not early_ok and tostring(early_error):find("HU_NOT_INITIALIZED", 1, true))
assert(not controller.initialize({}).ok)
assert(controller.initialize(controller_config).ok)
local c = controller
-- 此文件只测扫描/路径；以原生创建替身为虚拟目标建立合法的待登记记录。
local function register_fixture(instance, service_handle, metadata, service_name)
    local skynet = require "skynet"
    local original_newservice = skynet.newservice
    skynet.newservice = function() return service_handle end
    local created = instance:handle_command("newservice",
        {service_name = service_name, arguments = {n = 0}}, 1)
    skynet.newservice = original_newservice
    assert(created.ok and instance.creation_handles[service_handle].service_name == service_name)
    local registered = instance:handle_command("register", metadata, service_handle)
    assert(registered.ok and instance.targets[service_handle].service_name == service_name)
    return registered
end
assert(register_fixture(c, 10, {modules = {"lualib.test_worker_logic"},
    has_service_update = true}, "battle.worker").ok)
assert(c:load_patch({path = "module"}).ok)
assert(not c:load_patch({path = "invalid"}).ok)
for _, path in ipairs({"../module", "/module", "module/../module", "module//lualib",
    "module/", "module/./lualib", "module\\lualib", "module" .. string.char(0)}) do
    assert(not hotupgrade_native.list_lua(root, path), path)
end

for _, path in ipairs({"duplicate_module", "duplicate_custom_service"}) do
    assert(c:load_patch({path = path}).code == "HU_INVALID_PATCH")
end
local many_files = assert(hotupgrade_native.list_lua(root, "count_unlimited"))
assert(#many_files == 1025)
assert(#assert(hotupgrade_native.list_lua(root, "file_unlimited")) == 1)
assert(#assert(hotupgrade_native.list_lua(root, "total_unlimited")) == 9)
-- Lua Controller 也必须读取完整源码；未登记普通 .lua 现在可直接进入部署集合。
for _, path in ipairs({"count_unlimited", "file_unlimited", "total_unlimited"}) do
    assert(c:load_patch({path = path}).ok)
end
local other_root = config.root_path .. "/another"
assert(os.execute("mkdir -p " .. other_root .. "/service"))
local conflicting = controller.initialize({patch_path = root, root_path = other_root, service_path = "service"})
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
    local listed = hotupgrade_native.list_lua(root, link.patch)
    assert(os.remove(link.path))
    assert(listed == nil)
end

-- 特殊文件和 Controller 的非法目录配置同样在启动事务前拒绝。
local fifo = root .. "/module/special"
assert(os.execute("mkfifo " .. fifo))
assert(not hotupgrade_native.list_lua(root, "module"))
assert(os.remove(fifo))
for _, service_path in ipairs({"../service", "/service", "service/../service", "service/"}) do
    local rejected = controller.initialize(
    {
        patch_path = root, root_path = config.root_path, service_path = service_path,
    })
    assert(not rejected.ok and rejected.code == "HU_INVALID_PATH")
end
local service_link = config.root_path .. "/service_link"
assert(os.execute("ln -s service " .. service_link))
local rejected = controller.initialize({patch_path = root, root_path = config.root_path, service_path = "service_link"})
assert(os.remove(service_link))
assert(not rejected.ok and rejected.code == "HU_INVALID_PATH")
assert(register_fixture(c, 20,
    {modules = {}, has_service_update = true}, "skynet_hotupgrade_worker").ok)
assert(c:load_patch({path = "custom_service_files"}).ok)
local file_path = "native_files/nested/value.lua"
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
local link = config.root_path .. "/native_files/link.lua"
assert(os.execute("ln -s nested/value.lua " .. link))
assert(hotupgrade_native.read_file(config.root_path, "native_files/link.lua") == nil)
assert(hotupgrade_native.replace_file(config.root_path, "native_files/link.lua", "bad") == nil)
assert(os.remove(link))
assert(os.execute("mkdir -p " .. config.root_path .. "/native_files/directory.lua"))
assert(hotupgrade_native.replace_file(config.root_path, "native_files/directory.lua", "bad") == nil)
print("HOTUPGRADE_FILES_OK")
