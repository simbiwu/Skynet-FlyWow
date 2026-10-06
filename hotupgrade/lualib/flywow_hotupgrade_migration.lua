--- 显式状态迁移链；只转换 Snapshot 副本，不允许外部副作用和 yield。
local result = require "flywow_hotupgrade_error"
local snapshot = require "flywow_hotupgrade_snapshot"
local M = {}

---@param steps table[] from/to/up 的连续迁移清单
---@param from integer 当前 schema
---@param target integer 目标 schema
---@return flywow_hotupgrade_result
function M.resolve(steps, from, target)
    local index, chain = {}, {}
    for _, step in ipairs(steps or {}) do
        if index[step.from] or math.abs(step.to - step.from) ~= 1 or type(step.up) ~= "function" then
            return result.failure("HU_INVALID_MIGRATION", "迁移必须单步、无歧义")
        end
        index[step.from] = step
    end
    local direction = target >= from and 1 or -1
    for version = from, target - direction, direction do
        if not index[version] or index[version].to ~= version + direction then
            return result.failure("HU_MIGRATION_MISSING", "缺少 schema " .. version)
        end
        chain[#chain + 1] = index[version]
    end
    return result.success({chain = chain})
end

---@param state any 导出状态
---@param chain table[] 已校验迁移链
---@param context table 只读迁移上下文
---@return flywow_hotupgrade_result
function M.apply(state, chain, context)
    local cloned = snapshot.clone(state)
    if not cloned.ok then return cloned end

    for _, step in ipairs(chain) do
        local executed = result.execute(step.up, context.instruction_budget, cloned.value, context)
        if not executed.ok then
            return result.failure("HU_MIGRATION_FAILED", executed.message)
        end
        cloned = snapshot.clone(executed.values[1])
        if not cloned.ok then return cloned end
        if type(cloned.value) ~= "table" or cloned.value.schema_version ~= step.to then
            return result.failure("HU_INVALID_MIGRATION", "迁移没有输出目标 schema")
        end
    end
    return cloned
end

return M
