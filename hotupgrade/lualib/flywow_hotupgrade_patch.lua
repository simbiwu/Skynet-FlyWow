--- 从 Patch Root 扫描、校验并冻结 Lua 模块文件；不执行 Patch 顶层代码。
local native = require "flywow_hotupgrade_native"
local result = require "flywow_hotupgrade_error"
local M = {}

local MAX_FILE_BYTES = 2 * 1024 * 1024
local MAX_PATCH_BYTES = 16 * 1024 * 1024

local function read(path)
    local file, message = io.open(path, "rb")
    if not file then return result.failure("HU_FILE_NOT_FOUND", message) end
    local bytes = file:read(MAX_FILE_BYTES + 1)
    local closed = file:close()
    if not bytes or not closed then return result.failure("HU_FILE_READ_FAILED", path) end
    if #bytes > MAX_FILE_BYTES then return result.failure("HU_PATCH_LIMIT", path) end
    return result.success({bytes = bytes})
end

local function module_name(path)
    if path:sub(-4) ~= ".lua" or path:find("\\", 1, true) then return nil end
    return path:sub(1, -5):gsub("/", ".")
end

local function load_category(root, patch_path, category, frozen, budget)
    local paths, code = native.list_lua(root, patch_path, category)
    if not paths and code == "HU_PATCH_EMPTY" then return result.success({entries = {}}) end
    if not paths then return result.failure(code, "Patch 目录扫描失败: " .. category) end
    table.sort(paths)

    local entries = {}
    for _, relative in ipairs(paths) do
        local absolute = root .. "/" .. patch_path .. "/" .. category .. "/" .. relative
        local located, locate_error = native.resolve(absolute)
        if not located then return result.failure(locate_error, relative) end
        local loaded = read(located)
        if not loaded.ok then return loaded end
        budget.bytes = budget.bytes + #loaded.bytes
        if budget.bytes > MAX_PATCH_BYTES then return result.failure("HU_PATCH_LIMIT", "Patch 总字节数超限") end
        local chunk, syntax_error = load(loaded.bytes, "@" .. relative, "t", {})
        if not chunk then return result.failure("HU_MODULE_SYNTAX", syntax_error) end
        entries[#entries + 1] = {file = relative, source = loaded.bytes}
        frozen[#frozen + 1] = category .. "/" .. relative .. "\0" .. loaded.bytes
    end
    return result.success({entries = entries})
end

local function build_patch(root, patch_path)
    local frozen, budget = {}, {bytes = 0}
    local loaded = {}
    for _, category in ipairs({"modules", "services", "migrations", "configs"}) do
        loaded[category] = load_category(root, patch_path, category, frozen, budget)
        if not loaded[category].ok then return loaded[category] end
    end

    local modules = {}
    for _, entry in ipairs(loaded.modules.entries) do
        local name = module_name(entry.file)
        if not name or name == "" or modules[name] then
            return result.failure("HU_INVALID_PATCH", "Lua 模块路径重复或无效: " .. entry.file)
        end
        modules[name] = {name = name, source = entry.source, replace_all_values = true}
    end

    local services = {}
    for _, entry in ipairs(loaded.services.entries) do
        local name = entry.file:match("^([%w_.%-]+)%.lua$")
        if not name or services[name] then
            return result.failure("HU_INVALID_PATCH", "Service 文件名须为 <service_type>.lua")
        end
        services[name] = {service_type = name, entry_file = "services/" .. entry.file, source = entry.source}
    end

    local migrations = {}
    for _, entry in ipairs(loaded.migrations.entries) do
        local service_type, from, to = entry.file:match("^([%w_.%-]+)/(%d+)%-(%d+)%.lua$")
        if not service_type or tonumber(from) == tonumber(to) then
            return result.failure("HU_INVALID_PATCH", "迁移文件须为 <service_type>/<from>-<to>.lua")
        end
        migrations[#migrations + 1] =
        {service_type = service_type, from = tonumber(from), to = tonumber(to),
            file = "migrations/" .. entry.file, source = entry.source}
    end

    local configs = {}
    for _, entry in ipairs(loaded.configs.entries) do
        local service_type, name = entry.file:match("^([%w_.%-]+)/([%w_.%-]+)%.lua$")
        if not service_type then
            return result.failure("HU_INVALID_PATCH", "配置文件须为 configs/<service_type>/<name>.lua")
        end
        configs[#configs + 1] = {service_type = service_type, name = name, source = entry.source}
    end

    if next(modules) == nil and next(services) == nil and #configs == 0 then
        return result.failure("HU_PATCH_EMPTY", "Patch 至少要有一个模块或 Service 文件")
    end
    table.sort(frozen)
    local digest = native.sha256(patch_path .. "\0" .. table.concat(frozen, "\0"))
    local patch = {patch_id = digest, modules = {}, services = services, migrations = migrations,
        configs = configs, frozen_files = {}}
    for _, module in pairs(modules) do patch.modules[#patch.modules + 1] = module end
    table.sort(patch.modules, function(left, right) return left.name < right.name end)
    for _, entry in ipairs(loaded.services.entries) do patch.frozen_files["services/" .. entry.file] = entry.source end
    return result.success({patch = patch, checksum = digest})
end

--- 同步扫描 PatchRoot/<path>/modules 的 Lua 文件并冻结源码；不 yield。
---@param options table root 与 PatchRoot 下相对目录 path
---@return flywow_hotupgrade_result
function M.load(options)
    if type(options) ~= "table" or type(options.root) ~= "string"
        or type(options.path) ~= "string" then
        return result.failure("HU_INVALID_PATCH", "Patch Root 或目录路径无效")
    end
    local root, code = native.resolve(options.root)
    if not root then return result.failure(code, "Patch Root 不存在") end
    return build_patch(root, options.path)
end

--- 迁移/配置纯 Lua 文件运行在预算协程，不暴露 Skynet 或 I/O。
---@param source string 已冻结源码
---@return flywow_hotupgrade_result
function M.load_pure(source)
    local env = {assert = assert, error = error, pairs = pairs, ipairs = ipairs,
        type = type, tonumber = tonumber, tostring = tostring}
    local chunk, message = load(source, "@patch_pure", "t", env)
    if not chunk then return result.failure("HU_MODULE_SYNTAX", message) end
    local executed = result.execute(chunk)
    if not executed.ok then return executed end
    return result.success({value = executed.values[1]})
end

return M
