--- Snapshot 校验与独立副本；对象属于当前调用者，不迁移 Runtime 资源。
local result = require "flywow_hotupgrade_error"
local M = {}

local function scalar(value, limits)
    local kind = type(value)
    if kind == "string" then
        limits.bytes = limits.bytes + #value
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return false
        end
        limits.bytes = limits.bytes + 8
    elseif kind ~= "nil" and kind ~= "boolean" then
        return false
    end
    return limits.bytes <= limits.max_bytes
end

local function copy(value, seen, limits, depth)
    limits.nodes = limits.nodes + 1
    if depth > limits.max_depth or limits.nodes > limits.max_nodes then
        return nil, "HU_SNAPSHOT_LIMIT"
    end
    if type(value) ~= "table" then
        if not scalar(value, limits) then
            return nil, "HU_RESTART_REQUIRED"
        end
        return value
    end
    if seen[value] or getmetatable(value) then
        return nil, "HU_RESTART_REQUIRED"
    end

    seen[value] = true
    local output = {}
    for key, item in pairs(value) do
        if type(key) ~= "string" and type(key) ~= "number" and type(key) ~= "boolean" then
            return nil, "HU_RESTART_REQUIRED"
        end
        local copied_key, key_error = copy(key, seen, limits, depth + 1)
        if key_error then return nil, key_error end
        local copied_item, item_error = copy(item, seen, limits, depth + 1)
        if item_error then return nil, item_error end
        output[copied_key] = copied_item
    end
    seen[value] = nil
    return output
end

--- 校验并复制，不共享可变引用；超限或资源类型不支持返回稳定错误。
---@param value any 待迁移状态
---@param options? table max_depth/max_nodes/max_bytes
---@return flywow_hotupgrade_result
function M.clone(value, options)
    options = options or {}
    local limits =
    {
        nodes = 0, bytes = 0,
        max_depth = options.max_depth or 64,
        max_nodes = options.max_nodes or 100000,
        max_bytes = options.max_bytes or 8 * 1024 * 1024,
    }
    local output, code = copy(value, {}, limits, 0)
    if code then
        return result.failure(code, "Snapshot 类型、循环或容量不满足迁移合同")
    end
    return result.success({value = output, bytes = limits.bytes})
end

---@param value any 状态
---@param options? table 校验限制
---@return flywow_hotupgrade_result
function M.validate(value, options)
    local checked = M.clone(value, options)
    checked.value = nil
    return checked
end

return M
