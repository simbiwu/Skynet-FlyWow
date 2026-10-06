--- 当前控制面轻量指标；可注入上报函数，不依赖监控平台。
local M = {}
local result = require "flywow_hotupgrade_error"
local Metrics = {}
Metrics.__index = Metrics

---@param emit? function name/value -> 无 yield 上报
---@return table
function M.new(emit)
    return setmetatable({values = {}, emit = emit}, Metrics)
end

---@param name string 已定义指标名
---@param value number 增量
function Metrics:add(name, value)
    self.values[name] = (self.values[name] or 0) + value
    if self.emit then result.execute(self.emit, 100000, name, value) end
end

return M
