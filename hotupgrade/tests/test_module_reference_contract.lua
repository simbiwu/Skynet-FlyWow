--- 验证稳定根表、候选闭包根表及缓存旧函数的边界，不对 upvalue 做自动重绑定。
local module_patch = require "flywow_hotupgrade_module_patch"
local module_name = "hotupgrade_reference_contract" -- package.loaded 中用于验证旧函数引用行为的测试模块名。
-- V1/V2 候选共用的测试源码模板；format 参数填入版本和初始计数。
local module_source = [[
-- 候选闭包捕获的私有计数初值，由测试模板参数提供。
local count = %d
-- 候选模块导出根表；版本值由测试模板参数提供。
local M = {version = %d}

function M:read_version()
    return self.version
end

-- 反例：捕获的是本版本创建的根表，不能假定它等于提交后的线上根表。
function M:is_same_table()
    return self == M
end

function M.next_count()
    count = count + 1
    return count
end

function M.export_state()
    return {count = count}
end

function M.import_state(snapshot)
    count = snapshot.count
end

return M
]]
-- 执行 V1 模板得到的当前线上模块根表。
local live = assert(load(module_source:format(7, 1), "@reference_v1.lua", "t"))()
package.loaded[module_name] = live
-- 测试预先缓存的 V1 函数引用，Commit 后仍应指向原闭包。
local cached_next = live.next_count
-- 测试预先缓存的 V1 状态导出函数引用。
local cached_export = live.export_state
-- 测试预先缓存的 V1 根表身份检查函数引用。
local cached_identity = live.is_same_table
assert(live:read_version() == 1 and live:is_same_table())
assert(live.next_count() == 8 and live.next_count() == 9)

-- 以当前 live 为线上模块创建 V2 候选 Stage，后续验证旧引用保留语义。
local staged = module_patch.stage({{name = module_name, source = module_source:format(0, 2)}})
assert(staged.ok, staged.message)
assert(live.version == 1 and cached_export().count == 9)
assert(module_patch.commit(staged.value.stage).ok and module_patch.finish(staged.value.stage).ok)

-- 提交只安装字段：self 来自线上根表，捕获的 M 仍是候选根表；此反例不属于受支持的身份假设。
assert(package.loaded[module_name] == live and live.version == 2)
assert(live:read_version() == 2 and not live:is_same_table())
assert(cached_identity(live))

-- 新闭包继承快照中的 9，旧引用仍操作 V1 的私有 count；两个版本不共享同一个 upvalue。
assert(live.next_count() == 10 and live.next_count() == 11)
assert(cached_next() == 10)
assert(live.export_state().count == 11 and cached_export().count == 10)

-- 后一批的恢复找回 V2 函数及其原有状态，继续以本批开始时的现场为基准。
local installed_next = live.next_count
staged = module_patch.stage({{name = module_name, source = module_source:format(0, 3)}})
assert(staged.ok and module_patch.commit(staged.value.stage).ok)
assert(live.version == 3 and live.export_state().count == 11)
assert(module_patch.abort(staged.value.stage).ok)
assert(live.version == 2 and live.next_count == installed_next)
assert(live.next_count() == 12 and cached_export().count == 10)
package.loaded[module_name] = nil
print("HOTUPGRADE_MODULE_REFERENCE_CONTRACT_OK")
