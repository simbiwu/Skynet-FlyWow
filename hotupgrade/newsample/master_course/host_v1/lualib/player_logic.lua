-- player_logic.lua：V1 完整业务模块。
local M = {}

function M.version()
    return "v1"
end

function M.make_attack(state)
    return function(base_attack)
        return base_attack + (state.weapon == "刀" and 5 or 0)
    end
end

return M
