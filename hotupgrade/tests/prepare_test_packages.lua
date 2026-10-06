--- 测试夹具生成器：只写 build/hotupgrade-tests 下的 Patch 文件目录。
local root = "build/hotupgrade-tests/patches/"
local factory_file = assert(io.open("hotupgrade/tests/test_worker_factory.lua", "rb"))
local factory = assert(factory_file:read("*a"))
assert(factory_file:close())
local logic = 'local M = {}; function M.value() return 2 end; function M.added() return true end; return M\n'
local migration = 'return function(state) state.schema_version=2; state.extra=true; return state end\n'

local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
end

local function package(name, mode, extra, entry_source, reverse)
    local candidate_factory = entry_source or factory
    local module_source = reverse and 'return {value=function() return 1 end}\n' or logic
    local migration_source = reverse and 'return function(state) state.schema_version=1; state.extra=nil; return state end\n' or migration
    write(root .. name .. "/modules/test_worker_logic.lua", module_source)
    if mode ~= "module_patch" then
        write(root .. name .. "/services/worker.lua", candidate_factory)
    end
    if mode == "migrate" then
        local from, to = reverse and 2 or 1, reverse and 1 or 2
        write(root .. name .. "/migrations/worker/" .. from .. "-" .. to .. ".lua", migration_source)
    end
end

package("module", "module_patch")
package("migrate", "migrate", 'reversible=true,rollback_patch="rollback",')
package("rollback", "migrate", nil, nil, true)
package("drain", "drain")
package("dry", "module_patch")
package("failed_candidate", "drain", nil, 'return function() error("candidate start failure") end\n')
package("busy_candidate", "drain", nil, 'return function() while true do end end\n')
print("HOTUPGRADE_TEST_PACKAGES_OK")
