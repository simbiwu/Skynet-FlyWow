-- player_logic.lua：V1 完整业务模块。
local M = {}

--- 返回普通模块当前发布版本，供 PlayerService 和课堂观察结果使用。
---@return string version 当前模块版本号 v1
function M.version()
    return "v1"
end

--- 创建捕获玩家状态的攻击闭包；后续更新同一状态表会影响闭包读取的装备。
---@param state table 当前 Service 的私有玩家状态根表
---@return fun(base_attack:number):number attack_calculator 输入基础攻击并返回装备加成后的攻击值
function M.make_attack(state)
    return function(base_attack)
        return base_attack + (state.weapon == "刀" and 5 or 0)
    end
end

return M
