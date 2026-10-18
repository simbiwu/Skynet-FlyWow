--- Patch 文件名身份和审计重放测试。
local native = require "flywow_hotupgrade_native"
local patch = require "flywow_hotupgrade_patch"
local history = require "flywow_hotupgrade_history"
local loaded = patch.load({root = "./third_party/skynet-flywow/build/hotupgrade-tests/patches", path = "module"})
assert(loaded.ok, loaded.message)
local found_module = false
for _, entry in ipairs(loaded.patch.modules) do
    if entry.name == "test_worker_logic" then
        found_module = true
    end
end
assert(found_module)
local repeated = patch.load({root = "./third_party/skynet-flywow/build/hotupgrade-tests/patches", path = "module"})
assert(repeated.ok and repeated.patch.patch_id == loaded.patch.patch_id)
assert(loaded.patch.patch_id:find("test_worker_logic.lua", 1, true))
assert(not patch.load({root = "./third_party/skynet-flywow/build/hotupgrade-tests/patches", path = "../module"}).ok)

-- 扫描器必须拒绝 Patch 内的符号链接，避免读取根目录外的源码。
local patch_root = "./third_party/skynet-flywow/build/hotupgrade-tests/patches"
local link_path = patch_root .. "/module/modules/linked.lua"
assert(os.execute("ln -s test_worker_logic.lua " .. link_path))
local linked = native.list_lua(patch_root, "module", "modules")
os.remove(link_path)
assert(linked == nil, "Patch 扫描必须拒绝符号链接")
print("HOTUPGRADE_FILES_SYMLINK_REJECTED_OK")

-- 即使 services 合法，分类本身为链接/普通文件也必须拒绝整个 Patch，不能静默忽略。
local category_root = patch_root .. "/invalid_category"
assert(os.execute("mkdir -p " .. category_root .. "/services"))
local service_file = assert(io.open(category_root .. "/services/worker.lua", "wb"))
assert(service_file:write("return function() end"))
assert(service_file:close())
assert(os.execute("ln -s ../module/modules " .. category_root .. "/modules"))
local category_link = patch.load({root = patch_root, path = "invalid_category"})
assert(os.remove(category_root .. "/modules"))
assert(not category_link.ok and category_link.code == "HU_INVALID_PATH")
local category_file = assert(io.open(category_root .. "/modules", "wb"))
assert(category_file:write("invalid category"))
assert(category_file:close())
local invalid_category = patch.load({root = patch_root, path = "invalid_category"})
assert(os.remove(category_root .. "/modules"))
assert(not invalid_category.ok and invalid_category.code == "HU_INVALID_PATH")
assert(patch.load({root = patch_root, path = "invalid_category"}).ok)


-- History 追加完成后从新实例重放，确认稳定审计字段与 UTF-8 内容完整。
local path = "./third_party/skynet-flywow/build/hotupgrade-tests/files.history"
os.remove(path)
local opened = history.open(path)
assert(opened.ok)
assert(opened.history:append({txn_id = "a", message = "line\n中文", phase = "ACTIVATING"}).ok)
local replayed = history.open(path)
assert(replayed.ok, replayed.message)
assert(replayed.history.records.a.message == "line\n中文")
print("HOTUPGRADE_FILES_OK")
