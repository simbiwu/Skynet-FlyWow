--- 在真实 Skynet 内验证 Native 路径、分类及链接拒绝合同。
local hotupgrade_native = require "flywow_hotupgrade_native"
local controller = require "flywow_hotupgrade_controller"
local root = "./third_party/skynet-flywow/build/hotupgrade-tests/patches"
assert(hotupgrade_native.append_sync == nil)
local paths = assert(hotupgrade_native.list_lua(root, "module", "modules"))
assert(#paths == 1 and paths[1] == "test_worker_logic.lua")
assert(not hotupgrade_native.list_lua(root, "../module", "modules"))
local c = assert(controller.new({patch_root = root}).controller)
assert(c:control("register", {service_type = "unused", modules = {"test_worker_logic"},
    service_patch = false}, 10).ok)
assert(c:control("validate", {path = "module"}, 1).ok)
assert(not c:control("validate", {path = "invalid"}, 1).ok)
local link = root .. "/module/modules/linked.lua"
assert(os.execute("ln -s test_worker_logic.lua " .. link))
local linked = hotupgrade_native.list_lua(root, "module", "modules")
assert(os.remove(link))
assert(linked == nil)
local category = root .. "/invalid_category/modules"
assert(os.execute("ln -s ../module/modules " .. category))
local bad = c:control("validate", {path = "invalid_category"}, 1)
assert(os.remove(category))
assert(not bad.ok and bad.code == "HU_INVALID_PATH")
local output = assert(io.open(category, "wb"))
assert(output:write("invalid category"))
assert(output:close())
bad = c:control("validate", {path = "invalid_category"}, 1)
assert(os.remove(category))
assert(not bad.ok and bad.code == "HU_INVALID_PATH")
print("HOTUPGRADE_FILES_OK")
