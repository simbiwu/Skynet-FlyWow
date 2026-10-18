--- 私有模块状态由成对钩子迁移，不暴露私有可变表。
local count = 7
local M = {}
function M.value()
    return 1
end
function M.bump()
    count = count + 1
    return count
end
function M.export_state()
    return {count = count}
end
function M.import_state(state)
    count = state.count
    return true
end
M.removed = true
return M
