-- V3 普通模块：让“霜剑”玩家的攻击力额外增加 25 点。
local M = {} -- 保持候选模块导出根表，Commit 会把导出写回已加载的模块表。

--- 返回当前普通模块版本，供 PlayerService 快照展示。
---@return string version 本候选模块的固定版本标记
function M.version()
    return "v3"
end

--- 为一个玩家状态创建攻击函数；闭包读取同一个 state 表，Update 后仍能看到新武器。
---@param state table PlayerService 持有的玩家状态表；攻击函数会读取其中的 weapon 字段。
---@return fun(base_attack:integer):integer attack_fn 接收基础攻击力并返回加上武器加成后的攻击力
function M.make_attack(state)
    return function(base_attack)
        return base_attack + (state.weapon == "霜剑" and 25 or 0)
    end
end

return M
