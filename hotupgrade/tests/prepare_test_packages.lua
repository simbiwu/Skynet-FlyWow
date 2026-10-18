--- 只创建测试脚本专用目录内的受信 Patch，不触碰宿主部署目录。
local root = "build/hotupgrade-tests/patches/"
local module_v2 = [[
local count = 0
local M = {}
function M.value() return 2 end
function M.bump()
    count = count + 1
    return count
end
function M.export_state() return {count = count} end
function M.import_state(state)
    count = state.count
    return true
end
M.added = true
return M
]]
local service = [[
return function(state)
    return {
        migrate = function(old)
            assert(old.schema_version == 1)
            old.equip = "剑"
            old.schema_version = 2
            return old
        end,
        functions = {
            load = function(item)
                return item.base_attack + (state.equip == "剑" and 20 or 0)
            end,
        },
    }
end
]]
local cases =
{
    module = {modules = {["test_worker_logic.lua"] = module_v2}},
    combined = {modules = {["test_worker_logic.lua"] = module_v2}, services = {["player.lua"] = service}},
    service = {services = {["player.lua"] = service}},
    stage_failure = {services = {["player.lua"] = [[return function(state)
        return {migrate = function(old)
            old.equip = "坏"
            old.nested.count = 99
            error("migration rejected")
        end}
    end]]}},
    functions = {services = {["player.lua"] = [[return function(state)
        return {functions = {load = function(item)
            return item.base_attack + (state.equip == "剑" and 20 or 0)
        end}}
    end]]}},
    state_only = {services = {["player.lua"] = [[return function()
        return {migrate = function(old)
            return {equip = "剑", level = old.level, schema_version = 2}
        end}
    end]]}},
    bad_functions = {services = {["player.lua"] = [[return function()
        return {functions = {load = 12}}
    end]]}},
    extra = {modules = {["hotupgrade_extra.lua"] = "return {value = function() return 2 end}"}},
    invalid = {modules = {["test_worker_logic.lua"] = "return {"}},
    invalid_category = {services = {["unused.lua"] = "return function() return {} end"}},
}
for name, categories in pairs(cases) do
    for category, entries in pairs(categories) do
        assert(os.execute("mkdir -p " .. root .. name .. "/" .. category))
        for file, source in pairs(entries) do
            local output = assert(io.open(root .. name .. "/" .. category .. "/" .. file, "wb"))
            assert(output:write(source))
            assert(output:close())
        end
    end
end
print("HOTUPGRADE_PACKAGES_OK")
