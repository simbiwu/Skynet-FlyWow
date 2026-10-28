-- module_patch.stage 执行候选 chunk 时传入的加载名和文件路径。
local loader_name, loader_path = ...
assert(loader_name == "test_worker_logic")
assert(type(loader_path) == "string" and loader_path:sub(-#"/lualib/test_worker_logic.lua") == "/lualib/test_worker_logic.lua")
--- 私有模块状态由成对钩子迁移，不暴露私有可变表。
local count = 7
local M = {} -- 当前测试业务模块的导出表，后续把被测函数挂在此表并返回。
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
