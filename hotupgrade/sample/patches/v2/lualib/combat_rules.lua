--- PlayerService V2 新增的普通模块。
local M = {}

--- 按装备名称返回 V2 攻击加成；未知装备不增加攻击。
---@param equip string player_logic 创建的攻击闭包从玩家状态读取的装备名；本函数按它查找攻击加成。
---@return integer bonus 攻击力增加值
function M.attack_bonus(equip)
    return equip == "剑" and 20 or 0
end

return M
