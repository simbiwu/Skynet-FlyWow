--- PlayerService V2 新增的普通模块。
local M = {}

--- 按装备名称返回 V2 攻击加成；未知装备不增加攻击。
---@param equip string 当前装备名称
---@return integer bonus 攻击力增加值
function M.attack_bonus(equip)
    return equip == "剑" and 20 or 0
end

return M
