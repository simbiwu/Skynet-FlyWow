--- 只创建测试脚本专用目录内的受信 Patch，不触碰宿主部署目录。
-- 所有生成的 Patch 子目录共同使用的根路径；Controller 测试从这里读取发布包。
local root = "build/hotupgrade-tests/patches/"
-- 测试宿主 Lua 文件根目录；初始化模块从这里读取 V1 正式文件。
local host_root = "build/hotupgrade-tests/host/"
assert(os.execute("mkdir -p " .. host_root .. "lualib/battle/state_sync " .. host_root .. "lualib/packages/demo "
    .. host_root .. "config " .. host_root .. "service/battle " .. host_root .. "actors/zone"))
--- 创建测试发布包文件并写入源码；写入失败立即中止夹具生成。
---@param path string 测试发布包中的相对文件路径；本函数在对应目录创建文件。
---@param source string 要写入的测试源码；本函数完整写入该文件。
local function write(path, source)
    local output = assert(io.open(path, "wb")) -- 写入测试发布包文件的句柄；函数返回前关闭它。
    assert(output:write(source))
    assert(output:close())
end
-- 仓库中可编译的 V1 Worker 模块源文件句柄。
local original = assert(io.open("hotupgrade/tests/test_worker_logic.lua", "rb"))
write(host_root .. "lualib/test_worker_logic.lua", assert(original:read("*a")))
assert(original:close())
write(host_root .. "lualib/hotupgrade_extra.lua", "return {value = function() return 1 end}")
write(host_root .. "lualib/battle/state_sync/runtime.lua", "return {value = function() return 1 end}")
write(host_root .. "lualib/packages/demo/init.lua", "return {value = function() return 1 end}")
write(host_root .. "config/settings.lua", "return {max_level = 100}")
-- 普通 V2 候选源码模板；用于验证版本更新、私有状态迁移和新增导出。
local module_v2 = [[
local loader_name, loader_path = ...
assert(loader_name == "test_worker_logic")
assert(type(loader_path) == "string" and loader_path:sub(-#"/lualib/test_worker_logic.lua") == "/lualib/test_worker_logic.lua")
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
-- 声明新增依赖的 V2 候选源码；测试 Stage 期间新模块登记合同。
local module_new_modules_v2 = [[
local loader_name, loader_path = ...
assert(loader_name == "test_worker_logic")
assert(type(loader_path) == "string" and loader_path:sub(-#"/lualib/test_worker_logic.lua") == "/lualib/test_worker_logic.lua")
local hotupgrade = require "flywow_hotupgrade"
local rules = hotupgrade.require("hotupgrade_new_rules")
local count = 0
local M = {}
function M.value() return rules.value() end
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
-- 后续批次使用的普通新依赖源码，验证它可在当前批次登记后再热更。
local new_dependency_v2 = [[return {value = function() return 50 end}]]
-- 新依赖的候选源码；它再 require 另一个模块以覆盖分层声明路径。
local new_rules_v2 = [[
local hotupgrade = require "flywow_hotupgrade"
local dependency = hotupgrade.require("hotupgrade_new_dependency")
return {value = function() return dependency.value() + 2 end}
]]
-- Service Patch 的 new_modules 清单，按依赖先后声明新增模块。
local new_modules_service = [[return function()
    return {new_modules = {"hotupgrade_new_rules", "hotupgrade_new_dependency"}}
end]]
-- 同一组新模块的反向声明顺序，验证加载时依赖仍能正确登记。
local concurrent_new_modules_service = [[return function()
    return {new_modules = {"hotupgrade_new_dependency", "hotupgrade_new_rules"}}
end]]
-- 故意漏列真实依赖的 Service Patch，用于验证新模块声明失败。
local undeclared_modules_service = [[return function()
    return {new_modules = {"hotupgrade_bad_new_parent"}}
end]]
-- 通用 Service Patch 夹具；把状态迁移到 V2 并替换 load 函数。
local service = [[
return function(state)
    return {
        update_state = function()
            assert(state.schema_version == 1)
            state.equip = "剑"
            state.schema_version = 2
        end,
        replace_functions = {
            load = function(item)
                return item.base_attack + (state.equip == "剑" and 20 or 0)
            end,
        },
    }
end
]]
-- 发布目录名到相对目录/文件源码的夹具映射；循环末尾写入测试目录。
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
    new_modules = {lualib = {["test_worker_logic.lua"] = module_new_modules_v2,
        ["hotupgrade_new_dependency.lua"] = "return {value = function() return 40 end}",
        ["hotupgrade_new_rules.lua"] = [[local hotupgrade = require "flywow_hotupgrade"
            local dependency = hotupgrade.require("hotupgrade_new_dependency")
            return {value = function() return dependency.value() + 2 end}]]},
        service = {["skynet_hotupgrade_worker.patch"] = new_modules_service}},
    new_modules_concurrent = {lualib = {["test_worker_logic.lua"] = module_new_modules_v2,
        ["hotupgrade_new_dependency.lua"] = "return {value = function() return 40 end}",
        ["hotupgrade_new_rules.lua"] = [[local hotupgrade = require "flywow_hotupgrade"
            local dependency = hotupgrade.require("hotupgrade_new_dependency")
            return {value = function() return dependency.value() + 2 end}]]},
        service = {["skynet_hotupgrade_worker.patch"] = concurrent_new_modules_service}},
    new_modules_failure = {lualib = {["test_worker_logic.lua"] = "error('injected candidate failure')",
        ["hotupgrade_new_dependency.lua"] = "return {value = function() return 40 end}",
        ["hotupgrade_new_rules.lua"] = [[local hotupgrade = require "flywow_hotupgrade"
            local dependency = hotupgrade.require("hotupgrade_new_dependency")
            return {value = function() return dependency.value() + 2 end}]]},
        service = {["skynet_hotupgrade_worker.patch"] = new_modules_service}},
    new_modules_followup = {lualib = {["test_worker_logic.lua"] = module_new_modules_v2,
        ["hotupgrade_new_dependency.lua"] = new_dependency_v2,
        ["hotupgrade_new_rules.lua"] = new_rules_v2}},
    new_modules_undeclared = {lualib = {["hotupgrade_bad_new_parent.lua"] = [[
        local hotupgrade = require "flywow_hotupgrade"
        return hotupgrade.require("hotupgrade_unlisted_dependency")
    ]], ["hotupgrade_unlisted_dependency.lua"] = "return {value = 2}"},
        service = {["skynet_hotupgrade_worker.patch"] = undeclared_modules_service}},
    new_modules_candidate_undeclared = {lualib = {["test_worker_logic.lua"] = module_new_modules_v2,
        ["hotupgrade_new_dependency.lua"] = "return {value = function() return 40 end}",
        ["hotupgrade_new_rules.lua"] = new_rules_v2}},
    new_modules_candidate_caught_error = {lualib = {["test_worker_logic.lua"] = [[
        local hotupgrade = require "flywow_hotupgrade"
        local loaded = pcall(hotupgrade.require, "hotupgrade_unlisted_dependency")
        assert(not loaded)
        error("injected unrelated candidate failure")
    ]], ["hotupgrade_unlisted_dependency.lua"] = "return {value = 1}"}},
    service = {service = {["skynet_hotupgrade_worker.patch"] = service}},
    stage_failure = {lualib = {["test_worker_logic.lua"] = module_v2}, service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {update_state = function()
            state.equip = "坏"
            state.nested.count = 99
            error("migration rejected")
        end}
    end]]}},
    functions = {service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {replace_functions = {load = function(item)
            return item.base_attack + (state.equip == "剑" and 20 or 0)
        end}}
    end]]}},
    state_only = {service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {update_state = function()
            state.equip = "剑"
            state.schema_version = 2
            state.nested.count = 8
            state.nested.self = state.nested
            state.ranks[1] = 9
            state.mode = {phase = "v2"}
            state.replaced = "v2"
            state.obsolete = nil
        end}
    end]]}},
    state_shared = {service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {update_state = function()
            state.a.changed = 3
            state.b.changed = 3
        end}
    end]]}},
    bad_functions = {service = {["skynet_hotupgrade_worker.patch"] = [[return function()
        return {replace_functions = {load = 12}}
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
-- 需要覆盖的文件开头组合：无前缀、BOM、shebang 及两者组合。
local header_prefixes = {"", "\239\187\191", "#!/usr/bin/env lua\n", "\239\187\191#!/usr/bin/env lua\r\n"}
-- index 生成不同目录名，prefix 是本轮写入到 Lua/Patch/配置文件前的字节。
for index, prefix in ipairs(header_prefixes) do
    cases["source_headers_" .. index] = {
        lualib = {["test_worker_logic.lua"] = prefix .. module_v2},
        service = {["skynet_hotupgrade_worker.patch"] = prefix .. [[return function(state)
            return {update_state = function() state.level = 51 end}
        end]]},
        config = {["headers.lua"] = prefix .. "return {ready = true}"},
    }
end
cases.repair = {
    lualib = {["test_worker_logic.lua"] = module_v2:gsub("function M.value%(%) return 2 end", "function M.value() return 3 end")},
    service = {["skynet_hotupgrade_worker.patch"] = [[return function(state)
        return {update_state = function() state.equip = "枪"; state.level = 60; state.schema_version = 3 end}
    end]]},
}
-- name 是发布包名称，directories 是该包内相对目录到文件源码的映射。
for name, directories in pairs(cases) do
    -- directory 是发布包内子目录，entries 列出该目录待写文件。
    for directory, entries in pairs(directories) do
        assert(os.execute("mkdir -p " .. root .. name .. "/" .. directory))
        -- file 是相对文件名，source 是测试准备器写入的精确源码字节。
        for file, source in pairs(entries) do
            -- 当前夹具文件的完整输出路径。
            local path = root .. name .. "/" .. directory .. "/" .. file
            assert(os.execute("mkdir -p " .. assert(path:match("^(.*)/"))))
            write(path, source)
        end
    end
end
-- 生成大量文件的 Patch 夹具，验证扫描和源码读取不会因文件数量或总字节数被拒绝。
assert(os.execute("mkdir -p " .. root .. "count_unlimited/config " .. root .. "count_unlimited/lualib "
    .. root .. "total_unlimited/config " .. root .. "total_unlimited/lualib " .. root .. "file_unlimited"))
for index = 1, 1025 do
    -- 测试源码在 config 与 lualib 两类目录间交替，避免只覆盖一种路径。
    local directory = index % 2 == 0 and "config" or "lualib" -- 按 index 生成依赖文件所在的 config 或 lualib 目录。
    write(root .. "count_unlimited/" .. directory .. "/" .. index .. ".lua", "")
end
-- 构造大于旧单文件限制的源码内容，确认发布扫描不再拒绝该大小。
local previous_file_limit = string.rep(" ", 2 * 1024 * 1024)
for index = 1, 9 do
    local directory = index % 2 == 0 and "config" or "lualib" -- 按 index 生成依赖文件所在的 config 或 lualib 目录。
    write(root .. "total_unlimited/" .. directory .. "/" .. index .. ".lua", previous_file_limit)
end
write(root .. "file_unlimited/large.lua", previous_file_limit .. " ")
print("HOTUPGRADE_PACKAGES_OK")
