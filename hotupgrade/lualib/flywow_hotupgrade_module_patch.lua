--- 本 Lua State 的完整模块更新；保留导出表身份，候选私有状态与旧版本隔离。
--- 只替换导出字段，不重绑定函数 upvalue；旧函数引用和候选根表引用均保留原 Lua 语义。
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"
local M = {}
local module_state =
{
    active_module_stage = nil, -- 当前 State 唯一未完成的模块暂存记录，保留到 finish/abort。
}

--- 将普通状态数据图从 source_graph 复制到 target_graph，保留共享引用和循环引用。
--- 恢复时复用目标根表；若来源中的 self 指向来源根表，复制后 self 会指向目标根表。
---@param source_graph any 待复制的状态数据图
---@param target_graph? table 可选的现存根表；提供时先清空，再原地写入复制结果
---@return any copied_graph 新建的复制结果；提供 target_graph 时返回该目标根表
local function copy_state_graph(source_graph, target_graph)
    local copied_tables = {} -- 源表到目标表的映射，用于保留共享引用和循环引用。
    local field_count = 0    -- 当前快照复制的字段数；达到上限时拒绝继续复制。

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

        assert(nesting_depth <= hotupgrade_common.MAX_STATE_DEPTH, "状态快照嵌套超过限制")
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
            assert(field_count <= hotupgrade_common.MAX_STATE_FIELDS, "状态快照超过字段限制")
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
---@param module_exports table Commit/Abort 已确认身份和元表的线上表
---@param export_fields table 完整新字段；调用者保证与 module_exports 隔离
local function replace_exports(module_exports, export_fields)
    -- 先移除旧版本全部字段，再安装完整候选；两个阶段都保持根导出表身份。
    for key in pairs(module_exports) do
        rawset(module_exports, key, nil)
    end

    for key, value in pairs(export_fields) do
        rawset(module_exports, key, value)
    end
end

--- 校验候选模块根导出及嵌套数据的类型、键和引用关系。
---@param module_exports table 候选模块返回的根导出表
---@param module_name string 模块名称，用于生成错误诊断
local function check_exports(module_exports, module_name)
    assert(type(module_exports) == "table" and getmetatable(module_exports) == nil, module_name .. " 必须导出无元表根表")
    -- 每张嵌套表只入栈一次，允许数据共享引用或形成循环。
    local pending = {module_exports}       -- 尚未校验字段的表，作为显式工作栈。
    local seen = {[module_exports] = true} -- 已入栈的表，避免循环引用反复入栈。
    while #pending > 0 do
        local current = table.remove(pending)
        for key, value in next, current do
            assert(key ~= module_exports and value ~= module_exports, module_name .. " 导出数据不得引用模块根导出表")
            if current == module_exports then
                assert(type(key) == "string", module_name .. " 顶层导出字段名必须是字符串")
            else
                assert(type(key) == "string" or type(key) == "number" or type(key) == "boolean",
                    module_name .. " 嵌套导出键必须是字符串、数字或布尔值")
            end

            local value_type = type(value)
            assert(value_type == "function" or value_type == "number" or value_type == "string"
                or value_type == "boolean" or value_type == "table", module_name .. " 导出值类型不受支持")
            if value_type == "table" and not seen[value] then
                assert(getmetatable(value) == nil, module_name .. " 嵌套导出表不得带元表")
                seen[value] = true
                pending[#pending + 1] = value
            end
        end
    end

    -- 模块私有状态钩子在单个版本内成对提供；跨版本是否迁移由 Stage 决定。
    assert((module_exports.export_state == nil) == (module_exports.import_state == nil), module_name .. " 状态钩子须成对")
    if module_exports.export_state ~= nil then
        assert(type(module_exports.export_state) == "function" and type(module_exports.import_state) == "function",
            module_name .. " 状态钩子必须是函数")
    end
end

--- 编译全部源码后加载候选和迁移模块私有状态；受信顶层及钩子必须同步且无外部副作用。
---@param module_patches table[] 待暂存模块项；每项包含规范模块名 name 和冻结源码 source。
---@param module_loaders? table<string, {name:string, path:string}> 本 State 首次声明的加载名和路径；独立调用省略时使用规范名，路径为 nil。
---@return FlyWowHotUpgradeResult 成功含 stage；失败不安装线上导出。
function M.stage(module_patches, module_loaders)
    if module_state.active_module_stage then
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
        for _, module_patch in ipairs(module_patches) do
            local live = package.loaded[module_patch.name]
            check_exports(live, module_patch.name)
            local fields = {}
            for key, value in pairs(live) do
                fields[key] = value
            end

            -- 使用 Lua 原生 require；新加载的依赖不属于本次模块回滚。
            local chunk = assert(load(hotupgrade_common.normalize_source(module_patch.source), "@" .. module_patch.name, "t"))
            local loader = module_loaders and module_loaders[module_patch.name]
            module_stage.entries[#module_stage.entries + 1] =
            {
                name        = module_patch.name,                           -- package.loaded 的规范名；提交与恢复时核对线上根表身份。
                live        = live,                                        -- 原模块根表；提交与恢复始终原地修改它的字段。
                old         = fields,                                      -- 旧导出字段及原引用；保留至本批 Finish/Abort 结束。
                chunk       = chunk,                                       -- 第一轮编译的源码；第二轮执行后释放。
                loader_name = loader and loader.name or module_patch.name, -- 首次 require 名称，不用规范登记名替代。
                loader_path = loader and loader.path,                      -- 首次加载路径，与普通 Lua 文件加载参数一致。
                candidate   = nil,                                         -- 第二轮准备的新导出；Commit 时整体安装其字段。
            }
        end

        -- 再执行候选模块，检查导出并迁移隔离的私有状态。
        for _, entry in ipairs(module_stage.entries) do
            local candidate = entry.chunk(entry.loader_name, entry.loader_path)
            check_exports(candidate, entry.name)
            assert(candidate ~= entry.live, "候选须返回新的导出表")
            -- 只有旧版提供快照且新版提供导入钩子时才迁移；缺少任一方就使用新版初始化状态。
            if entry.live.export_state and candidate.import_state then
                local snapshot = M.snapshot_state(entry.live.export_state())
                assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
            end
            -- import_state 属于受信钩子，但可能改变候选导出图；提交前重新验证最终图。
            check_exports(candidate, entry.name)
            entry.candidate = candidate
            entry.chunk = nil
        end
    end)
    if not ok then
        local cause = type(message) == "table" and message.ok == false and message or nil
        return hotupgrade_result.failure("HU_MODULE_STAGE_FAILED",
            cause and cause.message or tostring(message), nil, cause and cause.code)
    end

    module_state.active_module_stage = module_stage
    return hotupgrade_result.success({stage = module_stage})
end

--- 业务安全点已确认后同步安装；旧导出保留至 finish，供组合 Service 提交失败时恢复。
function M.commit(module_stage)
    if module_state.active_module_stage ~= module_stage or module_stage.committed then
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

--- 尽量恢复所有旧表；任一身份变化均报告故障，结束时释放本批 Stage。
function M.abort(module_stage)
    if module_state.active_module_stage ~= module_stage then
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

    -- 所有恢复项都已尝试；失败仍报告，但本批快照不阻塞下一次 Stage。
    local finished = M.finish(module_stage)
    if #errors > 0 then
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end

    return finished
end

--- 确认本地模块更新结束并释放旧快照；不负责开放业务入口。
function M.finish(module_stage)
    if module_state.active_module_stage ~= module_stage then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    module_stage.entries = {}
    module_state.active_module_stage = nil
    return hotupgrade_result.success()
end

return M
