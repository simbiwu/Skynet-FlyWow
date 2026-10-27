-- 新增战斗规则：V1 运行时尚未存在。
local M = {}

function M.weapon_bonus(weapon)
    return weapon == "剑" and 20 or 0
end

return M