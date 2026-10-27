-- V2 普通模块：新的攻击闭包通过首次声明的战斗规则模块计算加成。
local hotupgrade = require "flywow_hotupgrade"
local combat_rules = hotupgrade.require("combat_rules")
local M = {}

function M.version()
    return "v2"
end

function M.make_attack(state)
    return function(base_attack)
        return base_attack + combat_rules.weapon_bonus(state.weapon)
    end
end

return M