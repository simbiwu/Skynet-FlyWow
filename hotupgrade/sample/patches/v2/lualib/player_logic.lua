--- PlayerService V2 普通模块。
local hotupgrade = require "flywow_hotupgrade"
local combat_rules = hotupgrade.require("combat_rules")
local M = {}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + combat_rules.attack_bonus(state.equip)
    end
end

return M
