--- PlayerService V2 普通模块。
local M = {}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "剑" and 20 or 0)
    end
end

return M
