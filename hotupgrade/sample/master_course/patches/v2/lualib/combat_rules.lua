-- 新增战斗规则：V1 运行时尚未存在。
local M = {}

--- 按武器名称返回对应的攻击力加成；未列出的武器加成为 0。
---@param weapon string player_logic.make_attack 从玩家状态读取的武器名；本函数按该名称查找加成。
---@return integer bonus 攻击力增加值
function M.weapon_bonus(weapon)
    return weapon == "剑" and 20 or 0
end

return M
