--- PlayerService V2 普通模块。
local hotupgrade = require "flywow_hotupgrade"
local combat_rules = hotupgrade.require("combat_rules") -- 通过 HotUpgrade 登记本模块依赖，控制面据此匹配普通模块候选。
-- V2 combat 模块的导出根表；本文件返回它供普通 require 使用。
local M = {}

--- 返回普通模块当前发布版本，供 Service 状态检查和示例输出使用。
---@return string version 当前模块版本号 v2
function M.version()
    return "v2"
end

--- 创建读取玩家状态和 combat_rules 的攻击闭包；该文件加载时明确登记新增依赖。
---@param state table PlayerService 传入的玩家状态表；本函数返回的闭包按调用时的装备读取加成并计算攻击值。
---@return fun(base_attack:number):number load_calculator 输入基础攻击并返回装备加成后的攻击值
function M.make_load(state)
    return function(base_attack)
        return base_attack + combat_rules.attack_bonus(state.equip)
    end
end

return M
