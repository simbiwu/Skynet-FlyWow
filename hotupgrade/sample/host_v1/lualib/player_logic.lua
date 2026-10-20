--- PlayerService V1 普通模块。
local M = {}

function M.version()
    return "v1"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "刀" and 5 or 0)
    end
end

return M
