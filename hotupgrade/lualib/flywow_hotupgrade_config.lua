--- 当前实例的配置代际视图；stage 不可见，激活和撤销均同步。
local snapshot = require "flywow_hotupgrade_snapshot"
local result = require "flywow_hotupgrade_error"
local M = {}
local Config = {}
Config.__index = Config

---@return table 当前 Lua State 独占配置 owner
function M.new()
    return setmetatable({current = {}, staged = {}, undo = {}}, Config)
end

---@param name string 配置名
---@param value table 新配置数据
---@param version integer 新配置版本
---@param txn_id string 暂存 owner
---@return flywow_hotupgrade_result
function Config:stage(name, value, version, txn_id)
    local cloned = snapshot.clone(value)
    if not cloned.ok then return cloned end
    self.staged[txn_id] = self.staged[txn_id] or {}
    self.staged[txn_id][name] = {value = cloned.value, version = version}
    return result.success()
end

---@param txn_id string owner
---@return flywow_hotupgrade_result
function Config:activate(txn_id)
    self.undo[txn_id] = {}
    for name, entry in pairs(self.staged[txn_id] or {}) do
        self.undo[txn_id][name] = {entry = self.current[name]}
        self.current[name] = entry
    end
    return result.success()
end

---@param txn_id string owner
---@return flywow_hotupgrade_result
function Config:abort(txn_id)
    for name, saved in pairs(self.undo[txn_id] or {}) do self.current[name] = saved.entry end
    self.undo[txn_id], self.staged[txn_id] = nil, nil
    return result.success()
end

---@param txn_id string owner
function Config:finish(txn_id)
    self.undo[txn_id], self.staged[txn_id] = nil, nil
end

--- 配置归该实例，只读使用；更新必须经过 stage/activate。
---@param name string 配置名
---@return table? value
---@return integer? version
function Config:get(name)
    local entry = self.current[name]
    if entry then return entry.value, entry.version end
end

return M
