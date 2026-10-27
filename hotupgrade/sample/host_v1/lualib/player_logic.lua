--- PlayerService V1 普通模块。
local M = {}

--- 返回普通模块当前发布版本，供 Service 状态检查和示例输出使用。
---@return string version 当前模块版本号 v1
function M.version()
    return "v1"
end

--- 创建读取共享玩家状态的攻击计算闭包；闭包保留传入的 state 引用。
---@param state table 当前 Service 的玩家状态；后续字段更新会被闭包读取
---@return fun(base_attack:number):number load_calculator 输入基础攻击并返回装备加成后的攻击值
function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "刀" and 5 or 0)
    end
end

return M
