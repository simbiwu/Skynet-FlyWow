-- 新增战斗规则：V1 运行时尚未存在。
local M = {}

--- 按武器名称返回对应的攻击力加成；未列出的武器加成为 0。
---@param weapon string 当前武器名称
---@return integer bonus 攻击力增加值
function M.weapon_bonus(weapon)
    return weapon == "剑" and 20 or 0
end

return M
