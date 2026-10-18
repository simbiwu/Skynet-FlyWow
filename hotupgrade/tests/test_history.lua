--- 历史失败合同夹具：模拟 io.open/Native 返回，不读取真实权限或执行磁盘故障注入。
local append_count = 0 -- Native 追加夹具调用次数，用于验证失败后的写入边界。
package.loaded.flywow_hotupgrade_native =
{
    append_sync = function()
        append_count = append_count + 1
        return nil, {code = "HU_HISTORY_WRITE_FAILED"}
    end,
}
local history = require "flywow_hotupgrade_history"
local original_open = io.open
io.open = function()
    return nil, "不存在", 2
end
local absent = history.open("fixture")
io.open = function()
    return nil, "拒绝读取", 13
end
local unreadable = history.open("fixture")
io.open = original_open
assert(absent.ok)
assert(not unreadable.ok and unreadable.code == "HU_HISTORY_READ_FAILED")
assert(absent.history:append({txn_id = "first"}).code == "HU_HISTORY_WRITE_FAILED")
assert(absent.history:append({txn_id = "second"}).code == "HU_RECOVERY_REQUIRED")
assert(append_count == 1 and next(absent.history.records) == nil)
print("HOTUPGRADE_HISTORY_FAILURE_CONTRACT_OK")
