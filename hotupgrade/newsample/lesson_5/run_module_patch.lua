-- 从 FlyWow 仓库根目录执行；直接使用仓库的 Module Patch Engine。
package.path = "./hotupgrade/lualib/?.lua;"
    .. "./hotupgrade/lesson5/v1/?.lua;"
    .. package.path

local module_patch = require "flywow_hotupgrade_module_patch"
local logic = require "player_logic"

-- 教学实验只模拟 hotupgrade.require 已建立的规范名称别名。
-- 真实 Service 中由 hotupgrade.require 创建，不需要业务这样写。
package.loaded["lualib.player_logic"] = logic

local logic_root = logic
local old_version = logic.version
local old_settings = logic.settings
local state = {equip = "刀"}
local old_load = logic.make_load(state)

-- 更新前，调用两次 V1 私有计数函数。
logic.next_count()
logic.next_count()
print("V1:", logic.version(), old_load(100), logic.export_state().count)

-- 从文件读取完整 V2 源码，作为引擎 stage() 的输入。
local file = assert(io.open("hotupgrade/lesson5/v2/player_logic.lua", "rb"))
local v2_source = file:read("*a")
file:close()

local modules =
{
    {name = "lualib.player_logic", source = v2_source},
}

-- 第一次更新：Stage → Commit → Abort，观察恢复。
local prepared = module_patch.stage(modules)
if not prepared.ok then
    error(prepared.message)
end
local module_stage = prepared.stage
print("Stage:", logic.version(), logic.export_state().count)

local committed = module_patch.commit(module_stage)
if not committed.ok then
    error(committed.message)
end
state.equip = "剑" -- 仅模拟 Service 状态迁移；不是模块引擎的职责。
print("Commit:", logic.version(), logic.make_load(state)(100), old_load(100))
print("字段:", logic.legacy_tag, logic.new_tag, logic.settings.bonus)
print("表身份:", logic == logic_root, logic.settings == old_settings)
print("候选私有计数:", logic.next_count())

local aborted = module_patch.abort(module_stage)
if not aborted.ok then
    error(aborted.message)
end
print("Abort:", logic.version(), state.equip, old_load(100), logic.export_state().count)
print("旧字段恢复:", logic.legacy_tag, logic.new_tag, logic.settings == old_settings)

-- Module Patch Engine 不会恢复业务 state，实验手工回到 V1。
state.equip = "刀"

-- 第二次更新：Stage → Commit → Finish，正式保留 V2。
local prepared_again = module_patch.stage(modules)
if not prepared_again.ok then
    error(prepared_again.message)
end
local committed_again = module_patch.commit(prepared_again.stage)
if not committed_again.ok then
    error(committed_again.message)
end
state.equip = "剑" -- 同样只模拟 Service Patch 对状态的更新。

local finished = module_patch.finish(prepared_again.stage)
if not finished.ok then
    error(finished.message)
end
print("Finish:", logic.version(), logic.make_load(state)(100), old_load(100))
print("旧引用:", old_version(), old_settings.bonus)
print("最终根表:", logic == logic_root, package.loaded["lualib.player_logic"] == logic)
print("最终私有计数:", logic.export_state().count)