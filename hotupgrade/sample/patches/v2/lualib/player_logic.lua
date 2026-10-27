--- PlayerService V2 普通模块。
local hotupgrade = require "flywow_hotupgrade"
local combat_rules = hotupgrade.require("combat_rules")
local M = {}

--- 返回普通模块当前发布版本，供 Service 状态检查和示例输出使用。
---@return string version 当前模块版本号 v2
function M.version()
    return "v2"
end

--- 创建读取玩家状态和 combat_rules 的攻击闭包；该文件加载时明确登记新增依赖。
---@param state table 当前 Service 的玩家状态；闭包按调用时装备计算结果
---@return fun(base_attack:number):number load_calculator 输入基础攻击并返回装备加成后的攻击值
function M.make_load(state)
    return function(base_attack)
        return base_attack + combat_rules.attack_bonus(state.equip)
    end
end

return M
