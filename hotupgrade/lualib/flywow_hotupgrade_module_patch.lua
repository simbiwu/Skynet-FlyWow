--- 当前 Lua State 内的完整模块替换；只支持无加载副作用、状态由 Service 持有的受信模块。
local result = require "flywow_hotupgrade_error"
local M = {}
local Engine = {}
Engine.__index = Engine

--- loaded 是本 State 的模块缓存；测试可注入独立缓存，不跨 Service 共享。
---@param options? table 可选 loaded；默认使用 package.loaded。
---@return table 模块更新器；同一时刻只持有一份可撤销更新。
function M.new(options)
    return setmetatable({
        loaded = options and options.loaded or package.loaded, -- 本 State 的模块缓存，可由测试注入。
        active = nil,                                          -- 唯一未结束的 Stage；commit 后仍保留至 finish 或 abort。
    }, Engine)
end

--- 加载完整模块文件；不得 yield、执行 I/O、修改线上状态或启动后台任务。
--- 本接口不是不受信代码沙箱，不能撤销违反合同的顶层副作用。
---@param entries table[] 连续数组，每项只有 name 和已固定的 source。
---@return FlyWowHotUpgradeResult 成功包含 stage；失败不安装任何导出。
function Engine:stage(entries)
    if self.active then
        return result.failure("HU_UPGRADE_BUSY", "已有未结束的模块更新")
    end
    if type(entries) ~= "table" then
        return result.failure("HU_INVALID_PATCH", "模块列表必须是连续数组")
    end
    for index in pairs(entries) do
        if math.type(index) ~= "integer" or index < 1 or index > #entries then
            return result.failure("HU_INVALID_PATCH", "模块列表必须是连续数组")
        end
    end

    -- 先检查全部输入并编译，再执行模块；不保留调用方可修改的 entry 对象。
    local state = {entries = {}, old = {}, committed = false}
    for index = 1, #entries do
        local entry = entries[index]
        if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == ""
            or type(entry.source) ~= "string" or state.entries[entry.name] then
            return result.failure("HU_INVALID_PATCH", "模块名、源码无效或模块重复")
        end
        local live = self.loaded[entry.name]
        if type(live) ~= "table" or getmetatable(live) ~= nil then
            return result.failure("HU_MODULE_NOT_REGISTERED", entry.name)
        end

        -- 旧模块同样必须符合无内存状态的导出合同，不能静默删除旧模块持有的业务表。
        for key, value in pairs(live) do
            local kind = type(value)
            if type(key) ~= "string" or (kind ~= "function" and kind ~= "number"
                and kind ~= "string" and kind ~= "boolean") then
                return result.failure("HU_MODULE_CONTRACT", entry.name .. " 的旧导出包含状态或不支持的值")
            end
        end

        -- require 只返回已加载的普通模块表；不启动新的加载链。
        -- 顶层只能取得依赖引用，不能调用依赖或修改它；这是受信模块的接入合同。
        local env = setmetatable({require = function(name)
            local dependency = self.loaded[name]
            assert(type(dependency) == "table" and getmetatable(dependency) == nil,
                "dependency must already be loaded: " .. tostring(name))
            return dependency
        end}, {__index = _G})
        local chunk, message = load(entry.source, "@" .. entry.name, "t", env)
        if not chunk then
            return result.failure("HU_MODULE_SYNTAX", message)
        end
        state.entries[entry.name] = {live = live, chunk = chunk}
    end

    for name, entry in pairs(state.entries) do
        local ok, candidate = pcall(entry.chunk)
        if not ok then
            return result.failure("HU_MODULE_LOAD_FAILED", tostring(candidate))
        end
        if type(candidate) ~= "table" or getmetatable(candidate) ~= nil or candidate == entry.live then
            return result.failure("HU_MODULE_CONTRACT", name .. " 必须返回新的普通导出表")
        end
        for key, value in pairs(candidate) do
            local kind = type(value)
            if type(key) ~= "string" or (kind ~= "function" and kind ~= "number"
                and kind ~= "string" and kind ~= "boolean") then
                return result.failure("HU_MODULE_CONTRACT", name .. " 只允许字符串键及函数或标量导出")
            end
            if entry.live[key] ~= nil and type(entry.live[key]) ~= kind then
                return result.failure("HU_MODULE_CONTRACT", name .. "." .. key .. " 导出类型变化")
            end
        end
        entry.candidate, entry.chunk = candidate, nil
    end
    self.active = state
    return result.success({stage = state})
end

--- 持有 Guard 且已排空时调用；安装与可选检查必须同步、无业务状态写入。
---@param state table 本更新器返回的 Stage。
---@param postcheck? function 现有控制面使用的受信检查；false/错误恢复旧导出。
---@return FlyWowHotUpgradeResult 完整安装或恢复旧字段；不会恢复任意外部副作用。
function Engine:commit(state, postcheck)
    if self.active ~= state or state.committed then
        return result.failure("HU_PHASE_INVALID", "Stage 不属于当前更新或已安装")
    end

    -- 先保存所有旧字段，再以 raw 操作安装，避免导出表元方法介入。
    for name, entry in pairs(state.entries) do
        local fields = {}
        for key, value in pairs(entry.live) do fields[key] = value end
        state.old[name] = fields
    end
    for _, entry in pairs(state.entries) do
        for key in pairs(entry.live) do rawset(entry.live, key, nil) end
        for key, value in pairs(entry.candidate) do rawset(entry.live, key, value) end
    end
    state.committed = true

    if postcheck then
        local ok, verdict = pcall(postcheck)
        if not ok or verdict == false or (type(verdict) == "table" and verdict.ok == false) then
            local restored = self:abort(state)
            if not restored.ok then return restored end
            return result.failure("HU_MODULE_COMMIT_FAILED", ok and "postcheck rejected" or tostring(verdict))
        end
    end
    return result.success()
end

--- 恢复原导出表字段；不替换表、不迁移闭包或业务状态。
---@param state table 当前更新的 Stage；未安装时只丢弃候选。
---@return FlyWowHotUpgradeResult 恢复完成后可释放安全点；失败必须保持暂停。
function Engine:abort(state)
    if self.active ~= state then
        if state.aborted then return result.success() end
        return result.failure("HU_PHASE_INVALID", "Stage 不属于当前更新")
    end
    for name, fields in pairs(state.old) do
        local live = state.entries[name].live
        if self.loaded[name] ~= live or getmetatable(live) ~= nil then
            return result.failure("HU_RECOVERY_REQUIRED", "模块表在更新期间被替换: " .. name)
        end
        for key in pairs(live) do rawset(live, key, nil) end
        for key, value in pairs(fields) do rawset(live, key, value) end
    end
    state.committed, state.aborted = false, true
    self:finish(state)
    return result.success()
end

--- 成功发布后释放候选和旧字段；已 finish 的更新不能再撤销。
---@param state table 当前更新的 Stage。
---@return FlyWowHotUpgradeResult 释放结果。
function Engine:finish(state)
    if self.active ~= state then
        return result.failure("HU_PHASE_INVALID", "Stage 不属于当前更新")
    end
    state.entries, state.old, state.closed = {}, {}, true
    self.active = nil
    return result.success()
end

return M
