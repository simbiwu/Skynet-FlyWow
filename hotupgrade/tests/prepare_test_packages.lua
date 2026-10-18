--- 测试夹具生成器：只写 build/hotupgrade-tests 下的 Patch 文件目录。
local root = "build/hotupgrade-tests/patches/"
local factory_file = assert(io.open("hotupgrade/tests/test_worker_factory.lua", "rb"))
local factory = assert(factory_file:read("*a"))
assert(factory_file:close())
-- 生成源码保持正常 Lua 排版，便于夹具变更时直接审阅。
local logic = [[
local M = {}

function M.value()
    return 2
end

function M.added()
    return true
end

function M.initial_count()
    return 42
end

return M
]]
local reverse_logic = [[
return
{
    value = function()
        return 1
    end,
}
]]

local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
end

local function package(name, service_type, entry_source, reverse, include_module, additional_service_types)
    local candidate_factory = entry_source or factory
    local module_source = reverse and reverse_logic or logic

    if include_module ~= false then
        write(root .. name .. "/modules/test_worker_logic.lua", module_source)
    end
    if service_type then
        write(root .. name .. "/services/" .. service_type .. ".lua", candidate_factory)
    end
    for _, additional_type in ipairs(additional_service_types or {}) do
        write(root .. name .. "/services/" .. additional_type .. ".lua", candidate_factory)
    end
end

package("module")
package("replace", "worker")
package("rollback", "worker", nil, true)
package("dry")
package("failed_candidate", "worker", [[
return function()
    error("candidate start failure")
end
]])
package("busy_candidate", "worker", [[
return function()
    while true do
    end
end
]])
package("missing_import", "worker_missing_import", nil, false, false)
package("export_failure", "worker_export_failure", nil, false, false)
package("import_failure", "worker_import_failure", nil, false, false)
package("rebuild", "worker_rebuild", nil, false, false)
package("partial", "worker_partial_a", nil, false, false, {"worker_partial_z"})
-- 在已注册但尚未完成 factory 的位置注入错误/等待，不能只测注册前失败。
local registered_failure, failure_replacements = factory:gsub("    start_timer%(%)",
    '    error("registered candidate failure")', 1)
assert(failure_replacements == 1)
local registered_waiting, waiting_replacements = factory:gsub("    start_timer%(%)",
    "    skynet.sleep(2000)\n    start_timer()", 1)
assert(waiting_replacements == 1)
package("registered_failure", "worker", registered_failure)
package("registered_waiting", "worker", registered_waiting)
package("waiting", "worker", [[
return function()
    require "skynet".sleep(2000)
end
]])
package("health", "worker_health")
package("frozen", "worker_frozen")
write(root .. "frozen/modules/test_candidate_only.lua", [[
local logic = require "test_worker_logic"
return {increment = function() return logic.value() - 1 end}
]])
write(root .. "frozen/modules/test_unused_candidate.lua", [[
error("unrelated frozen module must not execute")
]])
print("HOTUPGRADE_TEST_PACKAGES_OK")
