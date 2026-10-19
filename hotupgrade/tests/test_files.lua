--- 在真实 Skynet 内验证递归扫描、路径安全及整包资源边界。
local hotupgrade_native = require "flywow_hotupgrade_native"
local controller = require "flywow_hotupgrade_controller"
local config = require "hotupgrade_test_options"
local root = config.patch_root
assert(hotupgrade_native.append_sync == nil)
local paths = assert(hotupgrade_native.list_lua(root, "module"))
assert(#paths == 1 and paths[1] == "lualib/test_worker_logic.lua")
local hotupgrade = require "flywow_hotupgrade"
local early_ok, early_error = pcall(hotupgrade.require, "test_worker_logic")
assert(not early_ok and tostring(early_error):find("HU_NOT_INITIALIZED", 1, true))
local c = assert(controller.new(config).controller)
assert(c:control("register", {service_type = "unused", modules = {"lualib.test_worker_logic"},
    service_patch = false}, 10).ok)
assert(c:control("validate", {path = "module"}, 1).ok)
assert(not c:control("validate", {path = "invalid"}, 1).ok)
for _, path in ipairs({"../module", "/module", "module/../module", "module//lualib",
    "module/", "module/./lualib", "module\\lualib", "module" .. string.char(0)}) do
    assert(not hotupgrade_native.list_lua(root, path), path)
end

for _, path in ipairs({"duplicate_module", "duplicate_service"}) do
    assert(c:control("validate", {path = path}, 1).code == "HU_INVALID_PATCH")
end
for _, path in ipairs({"count_limit", "file_limit", "total_limit"}) do
    local listed, failure = hotupgrade_native.list_lua(root, path)
    assert(not listed and failure.code == "HU_PATCH_LIMIT")
end
local other_root = config.root_path .. "/another"
assert(os.execute("mkdir -p " .. other_root .. "/service"))
local conflicting = controller.new({patch_root = root, root_path = other_root, service_dir = "service"})
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
for _, service_dir in ipairs({"../service", "/service", "service/../service", "service/"}) do
    local rejected = controller.new(
    {
        patch_root = root, root_path = config.root_path, service_dir = service_dir,
    })
    assert(not rejected.ok and rejected.code == "HU_INVALID_PATH")
end
local service_link = config.root_path .. "/service_link"
assert(os.execute("ln -s service " .. service_link))
local rejected = controller.new({patch_root = root, root_path = config.root_path, service_dir = "service_link"})
assert(os.remove(service_link))
assert(not rejected.ok and rejected.code == "HU_INVALID_PATH")
local nested = assert(controller.new(
    {patch_root = root, root_path = config.root_path, service_dir = "actors/zone"}).controller)
assert(nested:control("register",
    {service_type = "player", modules = {}, service_patch = true}, 20).ok)
assert(nested:control("validate", {path = "custom_service"}, 1).ok)
print("HOTUPGRADE_FILES_OK")
