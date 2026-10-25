--- PlayerService V2 新增的普通模块。
local M = {}

function M.attack_bonus(equip)
    return equip == "剑" and 20 or 0
end

return M
