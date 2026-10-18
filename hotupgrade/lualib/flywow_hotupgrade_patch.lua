--- 从 Patch Root 扫描、校验并冻结 Lua 模块文件；不执行 Patch 顶层代码。
local native = require "flywow_hotupgrade_native"
local result = require "flywow_hotupgrade_error"
local M = {}

-- Native 以第二返回值携带稳定 HU_ 错误；兼容历史上的裸字符串错误值。
local function native_code(value)
    if type(value) == "table" then
        return value.code or "HU_NATIVE_ERROR"
    end
    return value or "HU_NATIVE_ERROR"
end

-- 与 Native 扫描器上限保持一致：单文件 2 MiB、一次 Patch 累计 16 MiB。
local MAX_FILE_BYTES = 2 * 1024 * 1024
local MAX_PATCH_BYTES = 16 * 1024 * 1024

-- 有界读取单个已规范化文件；关闭失败也视为读取失败，避免冻结不完整内容。
local function read(path)
    local file, message = io.open(path, "rb")
    if not file then
        return result.failure("HU_FILE_NOT_FOUND", message)
    end
    local bytes = file:read(MAX_FILE_BYTES + 1)
    local closed = file:close()
    if not bytes or not closed then
        return result.failure("HU_FILE_READ_FAILED", path)
    end
    if #bytes > MAX_FILE_BYTES then
        return result.failure("HU_PATCH_LIMIT", path)
    end
    return result.success({bytes = bytes})
end

-- 将分类目录内的相对 Lua 路径映射为 require 模块名。
local function module_name(path)
    if path:sub(-4) ~= ".lua" or path:find("\\", 1, true) then
        return nil
    end
    return path:sub(1, -5):gsub("/", ".")
end

-- 扫描一个白名单分类，校验语法并把源码纳入同一 Patch 字节预算。
local function load_category(root, patch_path, category, identity, budget)
    local paths, code = native.list_lua(root, patch_path, category)
    code = native_code(code)
    if not paths and code == "HU_PATCH_EMPTY" then
        return result.success({entries = {}})
    end
    if not paths then
        return result.failure(native_code(code), "Patch 目录扫描失败: " .. category)
    end
    table.sort(paths)

    local entries = {}
    for _, relative in ipairs(paths) do
        local absolute = root .. "/" .. patch_path .. "/" .. category .. "/" .. relative
        local located, locate_error = native.resolve(absolute)
        if not located then
            return result.failure(native_code(locate_error), relative)
        end
        local loaded = read(located)
        if not loaded.ok then
            return loaded
        end
        budget.bytes = budget.bytes + #loaded.bytes
        if budget.bytes > MAX_PATCH_BYTES then
            return result.failure("HU_PATCH_LIMIT", "Patch 总字节数超限")
        end
        local chunk, syntax_error = load(loaded.bytes, "@" .. relative, "t", {})
        if not chunk then
            return result.failure("HU_MODULE_SYNTAX", syntax_error)
        end
        entries[#entries + 1] = {file = relative, source = loaded.bytes}
        identity[#identity + 1] = category .. "/" .. relative
    end
    return result.success({entries = entries})
end

-- 汇总模块与 Service 文件；Patch 身份仅由路径和文件名组成。
local function build_patch(root, patch_path)
    local identity, budget = {}, {bytes = 0}
    local loaded = {}
    for _, category in ipairs({"modules", "services"}) do
        loaded[category] = load_category(root, patch_path, category, identity, budget)
        if not loaded[category].ok then
            return loaded[category]
        end
    end

    local modules = {}
    for _, entry in ipairs(loaded.modules.entries) do
        local name = module_name(entry.file)
        if not name or name == "" or modules[name] then
            return result.failure("HU_INVALID_PATCH", "Lua 模块路径重复或无效: " .. entry.file)
        end
        modules[name] = {name = name, source = entry.source}
    end

    local services = {}
    for _, entry in ipairs(loaded.services.entries) do
        local name = entry.file:match("^([%w_.%-]+)%.lua$")
        if not name or services[name] then
            return result.failure("HU_INVALID_PATCH", "Service 文件名须为 <service_type>.lua")
        end
        services[name] = {entry_file = "services/" .. entry.file, source = entry.source}
    end

    if next(modules) == nil and next(services) == nil then
        return result.failure("HU_PATCH_EMPTY", "Patch 至少要有一个模块或 Service 文件")
    end
    table.sort(identity)
    local identity_parts = {tostring(#patch_path) .. ":" .. patch_path}
    for _, entry in ipairs(identity) do
        identity_parts[#identity_parts + 1] = tostring(#entry) .. ":" .. entry
    end
    local patch = {patch_id = table.concat(identity_parts),
        modules = {}, services = services}
    for _, module in pairs(modules) do
        patch.modules[#patch.modules + 1] = module
    end
    table.sort(patch.modules, function(left, right)
        return left.name < right.name
    end)
    return result.success({patch = patch})
end

--- 同步扫描 PatchRoot/<path>/modules 的 Lua 文件并冻结源码；不 yield。
---@param options table root 是已存在的 Patch Root；path 是其下相对目录，不允许绝对路径和越界路径。
---@return FlyWowHotUpgradeResult 返回冻结源码和文件名身份；扫描/读取在当前调用内同步完成。
function M.load(options)
    if type(options) ~= "table" or type(options.root) ~= "string"
        or type(options.path) ~= "string" then
        return result.failure("HU_INVALID_PATCH", "Patch Root 或目录路径无效")
    end
    local root, code = native.resolve(options.root)
    code = native_code(code)
    if not root then
        return result.failure(native_code(code), "Patch Root 不存在")
    end
    return build_patch(root, options.path)
end

return M
