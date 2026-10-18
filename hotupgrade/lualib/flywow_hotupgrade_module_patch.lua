--- 本 Lua State 的完整模块更新；保留导出表身份，候选私有状态与旧版本隔离。
local result = require "flywow_hotupgrade_error"
local M = {}
local Engine = {}
Engine.__index = Engine

--- 复制普通数据图；保留图内共享与循环，不复制函数、userdata、线程或带元表对象。
--- 非普通业务对象必须由所属 Service 的显式快照/恢复函数处理。
---@param value any 要隔离的数据
---@param destination? table 内部恢复时指定现存根表；调用前须保存独立旧快照
---@return any snapshot 独立数据图；不支持的值抛出错误，调用边界负责转换结果。
function M.copy_state(value, destination)
    local seen = {} -- 当前复制过程的旧表到新表映射，不保留在线上状态中。
    local count = 0 -- 限制一次快照的节点/字段数，避免错误状态图耗尽控制阶段资源。
    local function copy(item, depth)
        local kind = type(item)
        if kind ~= "table" then
            assert(kind == "nil" or kind == "string" or kind == "boolean" or kind == "number",
                "状态快照只接受普通数据")
            return item
        end
        assert(getmetatable(item) == nil, "状态对象需要显式快照和恢复处理")
        if seen[item] then
            return seen[item]
        end
        assert(depth <= 64, "状态快照嵌套超过 64 层")
        local target = {}
        if depth == 1 and destination then
            target = destination
            assert(target ~= item and getmetatable(target) == nil, "快照必须与线上根表隔离")
            for key in pairs(target) do
                rawset(target, key, nil)
            end
        end
        seen[item] = target
        for key, child in pairs(item) do
            count = count + 1
            assert(count <= 10000, "状态快照超过 10000 个字段")
            assert(type(key) == "string" or type(key) == "number" or type(key) == "boolean",
                "状态字段必须使用标量键")
            target[key] = copy(child, depth + 1)
        end
        return target
    end
    return copy(value, 1)
end

--- 原地恢复普通数据图；根循环重新指向 live，不让候选表取代线上根身份。
function M.restore_state(live, fields)
    assert(type(live) == "table" and type(fields) == "table", "状态必须为表")
    M.copy_state(fields, live)
end

--- 原地覆盖模块导出字段；函数与标量直接安装，保留导出表身份。
---@param live table 已持有的线上表
---@param fields table 完整新字段；调用者保证与 live 隔离
local function replace_exports(live, fields)
    assert(type(live) == "table" and getmetatable(live) == nil, "线上表身份或元表发生变化")
    for key in pairs(live) do
        rawset(live, key, nil)
    end
    for key, value in pairs(fields) do
        rawset(live, key, value)
    end
end

local function check_exports(exports, name)
    assert(type(exports) == "table" and getmetatable(exports) == nil, name .. " 必须导出普通表")
    for key, value in pairs(exports) do
        local kind = type(value)
        assert(type(key) == "string" and (kind == "function" or kind == "number"
            or kind == "string" or kind == "boolean"), name .. " 只接受函数字段和标量常量")
    end
    assert((exports.export_state == nil) == (exports.import_state == nil), name .. " 状态钩子须成对")
    if exports.export_state ~= nil then
        assert(type(exports.export_state) == "function" and type(exports.import_state) == "function",
            name .. " 状态钩子必须是函数")
    end
end

---@param options? table loaded 可注入独立测试缓存；默认使用本 State package.loaded。
function M.new(options)
    return setmetatable(
    {
        loaded = options and options.loaded or package.loaded, -- 当前 State 的模块缓存。
        active = nil,                                          -- 保留至 finish/abort 的唯一 Stage。
    }, Engine)
end

--- 编译全部源码后加载候选和迁移模块私有状态；受信顶层及钩子必须同步且无外部副作用。
---@param entries table[] 含 name/source 的完整模块源码数组
---@return FlyWowHotUpgradeResult 成功含 stage；失败不安装线上导出。
function Engine:stage(entries)
    if self.active then
        return result.failure("HU_UPGRADE_BUSY", "模块 Stage 尚未结束")
    end
    local state = {entries = {}, order = {}, old = {}, committed = false}
    local ok, message = pcall(function()
        assert(type(entries) == "table" and #entries <= 1024, "模块列表必须是最多 1024 项的数组")
        local entry_count = 0
        for index in pairs(entries) do
            entry_count = entry_count + 1
            assert(math.type(index) == "integer" and index >= 1 and index <= #entries, "模块列表有空洞")
        end
        assert(entry_count == #entries, "模块列表有空洞")
        for _, item in ipairs(entries) do
            assert(type(item) == "table" and type(item.name) == "string" and item.name ~= "" and type(item.source) == "string",
                "模块名和源码无效")
            assert(not state.entries[item.name], "模块重复")
            local live = self.loaded[item.name]
            check_exports(live, item.name)
            local fields = {}
            for key, value in pairs(live) do
                fields[key] = value
            end
            -- 只引用已加载依赖；不执行新的依赖加载链，不代表提供安全沙箱。
            local env = setmetatable({require = function(name)
                local dependency = self.loaded[name]
                assert(type(dependency) == "table", "依赖尚未加载: " .. tostring(name))
                return dependency
            end}, {__index = _G})
            local chunk = assert(load(item.source, "@" .. item.name, "t", env))
            state.entries[item.name] = {live = live, chunk = chunk}
            state.order[#state.order + 1] = item.name
            state.old[item.name] = fields
        end
        for _, name in ipairs(state.order) do
            local entry = state.entries[name]
            local candidate = entry.chunk()
            check_exports(candidate, name)
            assert(candidate ~= entry.live, "候选须返回新的导出表")
            for key, value in pairs(candidate) do
                assert(entry.live[key] == nil or type(entry.live[key]) == type(value), "导出字段类型变化")
            end
            assert((entry.live.export_state == nil) == (candidate.import_state == nil),
                "新旧模块缺少配对状态钩子")
            if entry.live.export_state then
                -- 新版只能接触独立数据；旧闭包仍持有自己的状态，Abort 恢复旧导出即可。
                local snapshot = M.copy_state(entry.live.export_state())
                assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
            end
            entry.candidate = candidate
            entry.chunk = nil
        end
    end)
    if not ok then
        return result.failure("HU_MODULE_STAGE_FAILED", tostring(message))
    end
    self.active = state
    return result.success({stage = state})
end

--- Guard 已排空后同步安装；旧导出保留至 finish，供组合 Service 提交失败时恢复。
function Engine:commit(state)
    if self.active ~= state or state.committed then
        return result.failure("HU_PHASE_INVALID", "模块 Stage 无效或已提交")
    end
    local ok, message = pcall(function()
        for _, name in ipairs(state.order) do
            local entry = state.entries[name]
            assert(self.loaded[name] == entry.live and getmetatable(entry.live) == nil,
                "模块身份在 Stage 后改变")
        end
        state.committed = true
        for _, name in ipairs(state.order) do
            local entry = state.entries[name]
            replace_exports(entry.live, entry.candidate)
        end
    end)
    return ok and result.success() or result.failure("HU_MODULE_COMMIT_FAILED", tostring(message))
end

--- 尽量恢复所有旧表；任一身份变化均报告故障并保留 Stage，以便人工核对。
function Engine:abort(state)
    if self.active ~= state then
        return result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end
    local errors = {}
    for _, name in ipairs(state.order) do
        local entry = state.entries[name]
        local ok, message = pcall(function()
            assert(self.loaded[name] == entry.live and getmetatable(entry.live) == nil,
                "模块缓存身份或元表变化: " .. name)
            if state.committed then
                replace_exports(entry.live, state.old[name])
            end
        end)
        if not ok then
            errors[#errors + 1] = tostring(message)
        end
    end
    if #errors > 0 then
        return result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end
    return self:finish(state)
end

function Engine:finish(state)
    if self.active ~= state then
        return result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end
    state.entries = {}
    state.old = {}
    self.active = nil
    return result.success()
end

return M
