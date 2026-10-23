--- 只创建测试脚本专用目录内的受信 Patch，不触碰宿主部署目录。
local root = "build/hotupgrade-tests/patches/"
local host_root = "build/hotupgrade-tests/host/"
assert(os.execute("mkdir -p " .. host_root .. "lualib/battle/state_sync " .. host_root .. "lualib/packages/demo "
    .. host_root .. "config " .. host_root .. "service/battle " .. host_root .. "actors/zone"))
local function write(path, source)
    local output = assert(io.open(path, "wb"))
    assert(output:write(source))
    assert(output:close())
end
local original = assert(io.open("hotupgrade/tests/test_worker_logic.lua", "rb"))
write(host_root .. "lualib/test_worker_logic.lua", assert(original:read("*a")))
assert(original:close())
write(host_root .. "lualib/hotupgrade_extra.lua", "return {value = function() return 1 end}")
write(host_root .. "lualib/battle/state_sync/runtime.lua", "return {value = function() return 1 end}")
write(host_root .. "lualib/packages/demo/init.lua", "return {value = function() return 1 end}")
write(host_root .. "config/settings.lua", "return {max_level = 100}")
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
            return {equip = "剑", schema_version = 2}
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
    module = {lualib = {["test_worker_logic.lua"] = module_v2}},
    draining = {lualib = {["test_worker_logic.lua"] = module_v2,
        ["hotupgrade_extra.lua"] = "return {value = function() return 2 end}"}},
    drain_service = {lualib = {["test_worker_logic.lua"] = module_v2,
        ["hotupgrade_extra.lua"] = "return {value = function() return 2 end}",
        ["battle/state_sync/runtime.lua"] = "return {value = function() return 2 end}"},
        service = {["skynet_hotupgrade_drain.patch"] = service}},
    combined = {lualib = {["test_worker_logic.lua"] = module_v2}, service = {["skynet_hotupgrade_worker.patch"] = service}},
    service = {service = {["skynet_hotupgrade_worker.patch"] = service}},
    stage_failure = {lualib = {["test_worker_logic.lua"] = module_v2}, service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {migrate = function(old)
            old.equip = "坏"
            old.nested.count = 99
            error("migration rejected")
        end}
    end]]}},
    functions = {service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {functions = {load = function(item)
            return item.base_attack + (state.equip == "剑" and 20 or 0)
        end}}
    end]]}},
    state_only = {service = {["skynet_hotupgrade_worker.patch"] = [[return function()
        return {migrate = function(old)
            local nested = {count = 8}
            nested.self = nested
            local updates = {
                equip = "剑",
                schema_version = 2,
                nested = nested,
                ranks = {[1] = 9},
                mode = {phase = "v2"},
                replaced = "v2",
            }
            updates.obsolete = nil
            return updates
        end}
    end]]}},
    state_shared = {service = {["skynet_hotupgrade_worker.patch"] = [[return function()
        return {migrate = function(old_state)
            old_state.a.keep_a = 999
            local shared = {changed = 3}
            return {a = shared, b = shared}
        end}
    end]]}},
    bad_functions = {service = {["skynet_hotupgrade_worker.patch"] = [[return function()
        return {functions = {load = 12}}
    end]]}},
    extra = {lualib = {["hotupgrade_extra.lua"] = "return {value = function() return 2 end}"}},
    unmatched_module = {lualib = {
        ["test_worker_logic.lua"] = module_v2,
        ["missing_logic.lua"] = "return {value = 2}",
    }},
    unmatched_service = {lualib = {["test_worker_logic.lua"] = module_v2},
        service = {["unused.patch"] = service}},
    service_file = {service = {["new_service.lua"] = "return {version = 2}"}},
    deployment = {lualib = {["test_worker_logic.lua"] = module_v2,
        ["new/dependency.lua"] = "return {version = 2}"},
        service = {["new_service.lua"] = "return {version = 2}", ["skynet_hotupgrade_worker.patch"] = service}},
    deploy_failure = {lualib = {["a_added.lua"] = "return {version = 2}",
        ["test_worker_logic.lua"] = module_v2}, service = {["z_blocked.lua"] = "return {}"}},
    invalid_patch = {lualib = {["wrong.patch"] = "return function() end"}},
    invalid_service = {service = {["skynet_hotupgrade_worker.patch"] = "return {"}},
    invalid = {lualib = {["test_worker_logic.lua"] = "return {"}},
    host_paths = {config = {["settings.lua"] = "return {max_level = 200}"},
        lualib = {["battle/state_sync/runtime.lua"] = "return {value = function() return 2 end}",
            ["packages/demo/init.lua"] = "return {value = function() return 2 end}"}},
    nested_service = {service = {["skynet_hotupgrade_worker.patch"] = service}},
    nested_named_service = {service = {["battle/worker.patch"] = service}},
    nested_custom_service = {["actors/zone"] = {["battle/worker.patch"] = service}},
    custom_service = {actors = {["skynet_hotupgrade_worker.patch"] = service}},
    custom_service_files = {["actors/zone"] = {["skynet_hotupgrade_worker.patch"] = service}},
    custom_named_service = {["actors/zone"] = {["player.patch"] = service}},
    duplicate_module = {lualib = {["battle.worker.lua"] = "return {}",
        ["battle/worker.lua"] = "return {}"}},
    duplicate_service = {service = {["battle.worker.patch"] = service, ["battle/worker.patch"] = service}},
    duplicate_custom_service = {["actors/zone"] = {["battle.worker.patch"] = service,
        ["battle/worker.patch"] = service}},
}
for name, directories in pairs(cases) do
    for directory, entries in pairs(directories) do
        assert(os.execute("mkdir -p " .. root .. name .. "/" .. directory))
        for file, source in pairs(entries) do
            local path = root .. name .. "/" .. directory .. "/" .. file
            assert(os.execute("mkdir -p " .. assert(path:match("^(.*)/"))))
            write(path, source)
        end
    end
end
-- 生成超过旧限制的 Patch 夹具，验证扫描与源码冻结不再因数量或字节数拒绝。
assert(os.execute("mkdir -p " .. root .. "count_unlimited/config " .. root .. "count_unlimited/lualib "
    .. root .. "total_unlimited/config " .. root .. "total_unlimited/lualib " .. root .. "file_unlimited"))
for index = 1, 1025 do
    local directory = index % 2 == 0 and "config" or "lualib"
    write(root .. "count_unlimited/" .. directory .. "/" .. index .. ".lua", "")
end
local previous_file_limit = string.rep(" ", 2 * 1024 * 1024)
for index = 1, 9 do
    local directory = index % 2 == 0 and "config" or "lualib"
    write(root .. "total_unlimited/" .. directory .. "/" .. index .. ".lua", previous_file_limit)
end
write(root .. "file_unlimited/large.lua", previous_file_limit .. " ")
print("HOTUPGRADE_PACKAGES_OK")
