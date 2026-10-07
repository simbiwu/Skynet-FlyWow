--- 单 owner 的同步追加审计；写入 fsync 完成才返回，重启保留事务决定。
local result = require "flywow_hotupgrade_error"
local native = require "flywow_hotupgrade_native"
local native_error = require "flywow_hotupgrade_native_error"
local snapshot = require "flywow_hotupgrade_snapshot"
local M = {}
local History = {}
History.__index = History

local function encode(value)
    if type(value) == "string" then
        return string.format("%q", value):gsub("\\\n", "\\n")
    end
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, item in pairs(value) do
        parts[#parts + 1] = "[" .. encode(key) .. "]=" .. encode(item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function replay(path)
    local records = {}
    local file = io.open(path, "rb")
    if not file then return result.success({records = records}) end
    local size = file:seek("end")
    if not size or size > 64 * 1024 * 1024 then
        file:close()
        return result.failure("HU_HISTORY_LIMIT", "审计文件超限或无法取得长度")
    end
    if not file:seek("set", 0) then
        file:close()
        return result.failure("HU_HISTORY_CORRUPT", "无法定位审计文件")
    end
    local bytes = file:read(size + 1)
    file:close()
    if not bytes then return result.failure("HU_HISTORY_CORRUPT", "审计读取失败") end
    if #bytes > 64 * 1024 * 1024 then return result.failure("HU_HISTORY_LIMIT", "审计文件超限") end
    if #bytes > 0 and bytes:sub(-1) ~= "\n" then
        return result.failure("HU_HISTORY_CORRUPT", "审计记录不完整，需人工恢复")
    end
    for line in bytes:gmatch("[^\n]+") do
        local chunk = load(line, "@history", "t", {})
        if not chunk then return result.failure("HU_HISTORY_CORRUPT", "审计语法错误") end
        local executed = result.execute(chunk)
        if not executed.ok then return executed end
        local checked = snapshot.clone(executed.values[1])
        if not checked.ok then return checked end
        records[checked.value.txn_id] = checked.value
    end
    return result.success({records = records, size = #bytes})
end

---@param path string 宿主配置的持久化文件，父目录需已存在
---@return flywow_hotupgrade_result
function M.open(path)
    local replayed = replay(path)
    if not replayed.ok then return replayed end
    return result.success({history = setmetatable(
        {path = path, records = replayed.records, size = replayed.size or 0}, History)})
end

---@param record table 可序列化审计记录
---@return flywow_hotupgrade_result
function History:append(record)
    local cloned = snapshot.clone(record)
    if not cloned.ok then return cloned end
    local line = "return " .. encode(cloned.value) .. "\n"
    if self.size + #line > 64 * 1024 * 1024 then
        return result.failure("HU_HISTORY_LIMIT", "审计容量耗尽")
    end
    local ok, code = native.append_sync(self.path, line)
    if not ok then return result.failure(native_error.code(code), self.path) end
    self.size = self.size + #line
    self.records[record.txn_id] = cloned.value
    return result.success()
end

return M
