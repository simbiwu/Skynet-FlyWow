--- PlayerService V2 普通模块；以完整版本更新导出表。
local M = {}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "剑" and 20 or 0) + 1
    end
end

return M
