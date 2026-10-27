-- V2 普通模块：新的攻击闭包通过首次声明的战斗规则模块计算加成。
local hotupgrade = require "flywow_hotupgrade"
local combat_rules = hotupgrade.require("combat_rules")
local M = {}

--- 返回普通模块当前发布版本，供 PlayerService 和课堂观察结果使用。
---@return string version 当前模块版本号 v2
function M.version()
    return "v2"
end

--- 创建依赖 combat_rules 的攻击闭包；V2 首次加载该依赖时通过 hotupgrade.require 登记。
---@param state table 当前 Service 的私有玩家状态根表
---@return fun(base_attack:number):number attack_calculator 输入基础攻击并返回装备加成后的攻击值
function M.make_attack(state)
    return function(base_attack)
        return base_attack + combat_rules.weapon_bonus(state.weapon)
    end
end

return M
