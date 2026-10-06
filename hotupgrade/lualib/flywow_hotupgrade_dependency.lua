--- 验证强依赖子图；weak 不阻止退休，不能用它掩盖其它强环。
local result = require "flywow_hotupgrade_error"
local M = {}

local function visit(key, graph, marks)
    if marks[key] == "visiting" then return false end
    if marks[key] == "done" then return true end

    marks[key] = "visiting"
    for _, edge in ipairs(graph[key] or {}) do
        if edge.edge == "strong" and not visit(edge.target, graph, marks) then
            return false
        end
    end
    marks[key] = "done"
    return true
end

---@param graph table 逻辑 key 到依赖数组
---@return flywow_hotupgrade_result
function M.validate(graph)
    local marks = {}
    for key in pairs(graph) do
        if not visit(key, graph, marks) then
            return result.failure("HU_DEPENDENCY_CYCLE", "strong 依赖存在循环")
        end
    end
    return result.success()
end

return M
