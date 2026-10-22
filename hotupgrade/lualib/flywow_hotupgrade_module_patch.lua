--- 本 Lua State 的完整模块更新；保留导出表身份，候选私有状态与旧版本隔离。
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"
local M = {}
local module_state =
{
    active = nil, -- 本 State 唯一候选和旧快照，保留至 finish/abort。
}

--- 将普通状态数据图从 source_graph 复制到 target_graph，保留共享引用和循环引用。
--- 恢复时复用目标根表；若来源中的 self 指向来源根表，复制后 self 会指向目标根表。
---@param source_graph any 待复制的状态数据图
---@param target_graph? table 可选的现存根表；提供时先清空，再原地写入复制结果
---@return any copied_graph 新建的复制结果；提供 target_graph 时返回该目标根表
local function copy_state_graph(source_graph, target_graph)
    local copied_tables = {} -- 源表到目标表的映射，用于保留共享引用和循环引用。
    local field_count = 0 -- 当前快照复制的字段数；达到上限时拒绝继续复制。
    local function copy_state_value(source_value, nesting_depth)
        local value_type = type(source_value)
        if value_type ~= "table" then
            assert(value_type == "nil" or value_type == "string" or value_type == "boolean"
                or value_type == "number", "状态快照只接受普通数据")
            return source_value
        end

        assert(getmetatable(source_value) == nil, "状态对象需要显式快照和恢复处理")
        if copied_tables[source_value] then
            return copied_tables[source_value]
        end

        assert(nesting_depth <= 128, "状态快照嵌套超过 128 层")
        local target_table = {}
        if nesting_depth == 1 and target_graph then
            target_table = target_graph
            assert(target_table ~= source_value and getmetatable(target_table) == nil,
                "快照必须与线上根表隔离")
            for key in pairs(target_table) do
                rawset(target_table, key, nil)
            end
        end
        copied_tables[source_value] = target_table
        for key, child_source in pairs(source_value) do
            field_count = field_count + 1
            assert(field_count <= 10000, "状态快照超过 10000 个字段")
            assert(type(key) == "string" or type(key) == "number" or type(key) == "boolean",
                "状态字段必须使用标量键")
            target_table[key] = copy_state_value(child_source, nesting_depth + 1)
        end

        return target_table
    end

    return copy_state_value(source_graph, 1)
end

--- 创建与来源隔离的普通数据图快照。
---@param source_graph any 要隔离的状态数据图
---@return any state_snapshot 独立快照；遇到不支持的数据时抛出错误
function M.snapshot_state(source_graph)
    return copy_state_graph(source_graph)
end

--- 将 source_graph 恢复到 target_graph；目标根表原地更新，身份保持不变。
---@param source_graph table 独立的普通状态快照
---@param target_graph table 需要原地恢复的线上状态根表
function M.restore_state(source_graph, target_graph)
    assert(type(source_graph) == "table" and type(target_graph) == "table", "状态必须为表")
    copy_state_graph(source_graph, target_graph)
end

--- 原地覆盖模块导出字段；各字段引用直接安装，保留导出表身份。
---@param live table Commit/Abort 已确认身份和元表的线上表
---@param fields table 完整新字段；调用者保证与 live 隔离
local function replace_exports(live, fields)
    --热更路径要求模块导出表没有元表，回滚前也会检查这一点。所以在当前约束下，普通赋值和 rawset 的效果相同。
    for key in pairs(live) do
        rawset(live, key, nil)
    end

    for key, value in pairs(fields) do
        rawset(live, key, value)
    end
end

local function check_exports(exports, name)
    assert(type(exports) == "table" and getmetatable(exports) == nil, name .. " 必须导出无元表根表")
    local pending = {exports}
    local seen = {[exports] = true}
    while #pending > 0 do
        local current = table.remove(pending)
        for key, value in next, current do
            assert(key ~= exports and value ~= exports, name .. " 导出数据不得引用模块根导出表")
            if type(key) == "table" and not seen[key] then
                seen[key] = true
                pending[#pending + 1] = key
            end
            if type(value) == "table" and not seen[value] then
                seen[value] = true
                pending[#pending + 1] = value
            end
        end
    end

    -- 模块私有状态钩子在单个版本内成对提供；跨版本是否迁移由 Stage 决定。
    assert((exports.export_state == nil) == (exports.import_state == nil), name .. " 状态钩子须成对")
    if exports.export_state ~= nil then
        assert(type(exports.export_state) == "function" and type(exports.import_state) == "function",
            name .. " 状态钩子必须是函数")
    end
end

--- 编译全部源码后加载候选和迁移模块私有状态；受信顶层及钩子必须同步且无外部副作用。
---@param entries table[] Controller 已校验并去重的 name/source 连续数组；按传入顺序处理
---@return FlyWowHotUpgradeResult 成功含 stage；失败不安装线上导出。
function M.stage(entries)
    if module_state.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "模块 Stage 尚未结束")
    end

    -- 本 State 从 Stage 持有到 Finish/Abort；每条记录集中保存候选及恢复所需的旧字段。
    local module_stage =
    {
        entries   = {},    -- 按输入顺序保存模块记录；Commit 安装候选，Abort 恢复各记录的旧字段。
        committed = false, -- 开始写线上字段前置为 true；即使部分提交失败，Abort 也会执行恢复。
    }
    local ok, message = pcall(function()
        -- 数组结构、模块名、源码及唯一性已由 Controller 建立；这里只检查本 State 的实际对象。
        -- 先编译全部 Patch 并保存每个线上模块的旧字段。
        for _, item in ipairs(entries) do
            local live = package.loaded[item.name]
            check_exports(live, item.name)
            local fields = {}
            for key, value in pairs(live) do
                fields[key] = value
            end

            -- 只引用已加载依赖；不执行新的依赖加载链，不代表提供安全沙箱。
            local env = setmetatable({require = function(name)
                local dependency = package.loaded[name]
                assert(type(dependency) == "table", "依赖尚未加载: " .. tostring(name))
                return dependency
            end}, {__index = _G})
            local chunk = assert(load(item.source, "@" .. item.name, "t", env))
            module_stage.entries[#module_stage.entries + 1] =
            {
                name      = item.name, -- package.loaded 的规范名；提交与恢复时核对线上根表身份。
                live      = live,      -- 原模块根表；提交与恢复始终原地修改它的字段。
                old       = fields,    -- 旧导出字段及原引用；保留至 Finish 或恢复成功。
                chunk     = chunk,     -- 第一轮编译的源码；第二轮执行后释放。
                candidate = nil,       -- 第二轮准备的新导出；Commit 时整体安装其字段。
            }
        end

        -- 再执行候选模块，检查导出并迁移隔离的私有状态。
        for _, entry in ipairs(module_stage.entries) do
            local candidate = entry.chunk()
            check_exports(candidate, entry.name)
            assert(candidate ~= entry.live, "候选须返回新的导出表")
            -- 只有旧版提供快照且新版提供导入钩子时才迁移；缺少任一方就使用新版初始化状态。
            if entry.live.export_state and candidate.import_state then
                local snapshot = M.snapshot_state(entry.live.export_state())
                assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
            end
            entry.candidate = candidate
            entry.chunk = nil
        end
    end)
    if not ok then
        return hotupgrade_result.failure("HU_MODULE_STAGE_FAILED", tostring(message))
    end

    module_state.active = module_stage
    return hotupgrade_result.success({stage = module_stage})
end

--- 业务安全点已确认后同步安装；旧导出保留至 finish，供组合 Service 提交失败时恢复。
function M.commit(module_stage)
    if module_state.active ~= module_stage or module_stage.committed then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 无效或已提交")
    end

    local ok, message = pcall(function()
        -- 先确认所有根表身份仍有效；全部通过后才开始修改线上导出。
        for _, entry in ipairs(module_stage.entries) do
            assert(package.loaded[entry.name] == entry.live and getmetatable(entry.live) == nil,
                "模块身份在 Stage 后改变")
        end

        -- 所有候选已在 Stage 完成检查，现在原地替换每个模块的完整导出字段。
        module_stage.committed = true
        for _, entry in ipairs(module_stage.entries) do
            replace_exports(entry.live, entry.candidate)
        end
    end)
    return ok and hotupgrade_result.success() or hotupgrade_result.failure("HU_MODULE_COMMIT_FAILED", tostring(message))
end

--- 尽量恢复所有旧表；任一身份变化均报告故障并保留 Stage，以便人工核对。
function M.abort(module_stage)
    if module_state.active ~= module_stage then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    -- 尝试恢复每个模块并收集全部故障；单个模块失败不跳过其他模块。
    local errors = {}
    for _, entry in ipairs(module_stage.entries) do
        local ok, message = pcall(function()
            assert(package.loaded[entry.name] == entry.live and getmetatable(entry.live) == nil,
                "模块缓存身份或元表变化: " .. entry.name)
            if module_stage.committed then
                replace_exports(entry.live, entry.old)
            end
        end)
        if not ok then
            errors[#errors + 1] = tostring(message)
        end
    end

    -- 只有所有旧导出都确认恢复后才释放 Stage 和旧快照。
    if #errors > 0 then
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end

    return M.finish(module_stage)
end

--- 确认本地模块更新结束并释放旧快照；不负责开放业务入口。
function M.finish(module_stage)
    if module_state.active ~= module_stage then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    module_stage.entries = {}
    module_state.active = nil
    return hotupgrade_result.success()
end

return M
