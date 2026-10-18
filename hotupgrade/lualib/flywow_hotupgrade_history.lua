--- 单 owner 的同步追加审计；事务记录限定为控制面生成的简单值。
local result = require "flywow_hotupgrade_error"
local native = require "flywow_hotupgrade_native"
local M = {}
local History = {}
-- 单个历史文件最多 64 MiB；耗尽后拒绝新事务，不截断已有审计记录。
local MAX_HISTORY_BYTES = 64 * 1024 * 1024
History.__index = History

-- 固定记录只含数字、字符串、布尔值和有限嵌套 table；拒绝循环及运行时对象。
local function encode(value, seen)
    local kind = type(value)
    if kind == "string" then
        local escaped = value:gsub('[%z\1-\31\\"]', function(character)
            local replacements =
            {
                ["\\"] = "\\\\",
                ['"'] = '\\"',
                ["\n"] = "\\n",
                ["\r"] = "\\r",
                ["\t"] = "\\t",
            }
            return replacements[character] or string.format("\\%03d", character:byte())
        end)
        return '"' .. escaped .. '"'
    end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil
        end
        return tostring(value)
    end
    if kind == "boolean" then
        return tostring(value)
    end
    if kind ~= "table" or seen[value] then
        return nil
    end

    seen[value] = true
    local parts = {}
    for key, item in pairs(value) do
        local encoded_key = encode(key, seen)
        local encoded_item = encode(item, seen)
        if not encoded_key or not encoded_item then
            seen[value] = nil
            return nil
        end
        parts[#parts + 1] = "[" .. encoded_key .. "]=" .. encoded_item
    end
    seen[value] = nil

    return "{" .. table.concat(parts, ",") .. "}"
end

local function native_code(value)
    if type(value) == "table" then
        return value.code or "HU_NATIVE_ERROR"
    end
    return value or "HU_NATIVE_ERROR"
end

-- 每行是一个封闭 Lua table 字面量；空环境执行只允许构造数据，不开放库函数。
local function replay(path)
    local records = {}
    local file, message, code = io.open(path, "rb")
    if not file then
        -- 当前 Linux/POSIX 宿主 ENOENT 为 2；只有确实不存在才允许创建新历史。
        if code == 2 then
            return result.success({records = records})
        end
        return result.failure("HU_HISTORY_READ_FAILED", message or "无法读取历史文件")
    end

    local size = file:seek("end")
    if not size or size > MAX_HISTORY_BYTES then
        file:close()
        return result.failure("HU_HISTORY_LIMIT", "审计文件超限或无法取得长度")
    end
    if not file:seek("set", 0) then
        file:close()
        return result.failure("HU_HISTORY_CORRUPT", "无法定位审计文件")
    end

    local bytes = file:read(size + 1)
    local closed = file:close()
    if not bytes or not closed or #bytes ~= size or #bytes > MAX_HISTORY_BYTES then
        return result.failure("HU_HISTORY_LIMIT", "审计读取失败或文件超限")
    end
    if #bytes > 0 and bytes:sub(-1) ~= "\n" then
        return result.failure("HU_HISTORY_CORRUPT", "审计记录不完整，需人工恢复")
    end

    for line in bytes:gmatch("[^\n]+") do
        local chunk = load(line, "@history", "t", {})
        if not chunk then
            return result.failure("HU_HISTORY_CORRUPT", "审计语法错误")
        end
        local executed = result.execute(chunk)
        local record = executed.ok and executed.values[1] or nil
        if type(record) ~= "table" or type(record.txn_id) ~= "string" then
            return result.failure("HU_HISTORY_CORRUPT", "审计记录缺少 txn_id")
        end
        records[record.txn_id] = record
    end

    return result.success({records = records, size = #bytes})
end

---@param path string 宿主配置的持久化文件；父目录需已存在，模块不创建目录。
---@return FlyWowHotUpgradeResult
function M.open(path)
    local replayed = replay(path)
    if not replayed.ok then
        return replayed
    end

    return result.success({history = setmetatable(
    {
        path = path,                -- 当前审计文件路径；由宿主配置并在本 History 生命周期内固定。
        records = replayed.records, -- 已重放记录，按 txn_id 查询并在 append 后更新。
        size = replayed.size or 0,  -- 当前文件字节数，用于追加前检查总容量。
    }, History)})
end

---@param record table Controller 生成的有界事务记录，只允许标量和无环 table。
---@return FlyWowHotUpgradeResult 只有 Native 同步追加成功后才更新内存记录。
function History:append(record)
    if self.failed then
        return result.failure("HU_RECOVERY_REQUIRED", "历史追加曾失败，需人工核对文件后重启")
    end
    local encoded = encode(record, {})
    if not encoded then
        return result.failure("HU_HISTORY_RECORD_INVALID", "审计记录只能包含标量和无环 table")
    end

    local line = "return " .. encoded .. "\n"
    if self.size + #line > MAX_HISTORY_BYTES then
        return result.failure("HU_HISTORY_LIMIT", "审计容量耗尽")
    end

    local ok, code = native.append_sync(self.path, line)
    if not ok then
        -- write/fsync 失败不能证明文件未变化；禁止继续追加到不确定的尾部。
        self.failed = true
        return result.failure(native_code(code), self.path)
    end

    self.size = self.size + #line
    self.records[record.txn_id] = record

    return result.success()
end

return M
