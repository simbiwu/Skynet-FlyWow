--- 文件、checksum、迁移代码、配置屏障和审计重放测试。
local native = require "flywow_hotupgrade_native"
local patch = require "flywow_hotupgrade_patch"
local history = require "flywow_hotupgrade_history"
local config = require "flywow_hotupgrade_config"
assert(native.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
local loaded = patch.load({root = "build/hotupgrade-tests/patches", path = "module"})
assert(loaded.ok, loaded.message)
local found_module = false
for _, entry in ipairs(loaded.patch.modules) do
    if entry.name == "test_worker_logic" then found_module = true end
end
assert(found_module)
assert(not patch.load({root = "build/hotupgrade-tests/patches", path = "../module"}).ok)
assert(not patch.load_pure("while true do end").ok)

local configs = config.new()
assert(configs:stage("x", {value = 4}, 2, "t").ok)
assert(configs:get("x") == nil)
assert(configs:activate("t").ok)
assert(configs:get("x").value == 4)
assert(configs:abort("t").ok and configs:get("x") == nil)

local path = "build/hotupgrade-tests/files.history"
os.remove(path)
local opened = history.open(path)
assert(opened.ok)
assert(opened.history:append({txn_id = "a", message = "line\n中文", phase = "ACTIVATING"}).ok)
local replayed = history.open(path)
assert(replayed.ok, replayed.message)
assert(replayed.history.records.a.message == "line\n中文")
print("HOTUPGRADE_FILES_OK")
