--- 本 Lua State 的完整模块更新；保留导出表身份，候选私有状态与旧版本隔离。
--- 只替换导出字段，不重绑定函数 upvalue；旧函数引用和候选根表引用均保留原 Lua 语义。
local flywow_result = require "flywow_result" -- 本模块向 HotUpgrade Service 返回统一结构化结果。
local hotupgrade_common = require "flywow_hotupgrade_common" -- 提供状态图复制的深度和字段数量上限。
-- 对 Service 暴露普通状态快照、候选 Stage、Commit、Abort 和 Finish 操作。
local M = {}
-- 暂存记录在模块 API 间共享，直到同一批次 Finish 或 Abort 才释放。
local module_state =
{
    active_module_stage = nil, -- 当前 State 唯一未完成的模块暂存记录，保留到 finish/abort。
}

---@class FlyWowHotUpgradeModuleStage
---@field entries table[] 本 State 每个候选模块的旧字段与新字段记录；Commit/Abort 处理，Finish 释放。
---@field committed boolean 是否已开始安装线上导出；部分提交失败时也必须恢复。

--- 复制普通 Lua 状态表，保留共享子表和循环引用；可把结果写入已有目标根表。
---@param source_graph any 要复制的业务状态根值；本函数递归读取其中的 table 字段。
---@param target_graph? table 可选的现存根表；提供时先清空，再原地写入复制结果
---@return any copied_graph 新建的复制结果；提供 target_graph 时返回该目标根表
local function copy_state_graph(source_graph, target_graph)
    local copied_tables = {} -- 源表到目标表的映射，用于保留共享引用和循环引用。
    local field_count = 0    -- 当前快照复制的字段数；达到上限时拒绝继续复制。

    --- 递归复制标量或表，并通过 copied_tables 维持共享引用和循环引用。
    ---@param source_value any 当前待复制的标量或子表；由父层遍历状态字段时传入。
    ---@param nesting_depth integer 当前值相对根表的层数；用于检查 MAX_STATE_DEPTH 上限。
    ---@return any copied_value 深复制后的标量或目标表引用。
    local function copy_state_value(source_value, nesting_depth)
        -- copied_tables 与 field_count 捕获自本次快照，所有递归层共用它们，分别保留引用关系并限制整张图的大小。
        -- 当前状态值的 Lua 类型；后面据此决定复制标量还是递归复制 table。
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
        -- 与当前源 table 对应的副本；根表可复用宿主提供的目标根表。
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
        -- key 是状态字段名，child_source 是对应旧字段值；递归结果写入目标副本。
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

--- 复制普通数据状态图并返回独立快照；遇到不支持的数据时抛出错误。
---@param source_graph any 业务方要保存的当前状态根值；调用者在更新前传入。
---@return any state_snapshot 独立快照；遇到不支持的数据时抛出错误
function M.snapshot_state(source_graph)
    return copy_state_graph(source_graph)
end

--- 把独立快照写回线上状态根表，并保持线上根表引用不变。
---@param source_graph table 此前由 snapshot_state 生成的旧状态快照；本函数从中读取要恢复的字段。
---@param target_graph table 仍被业务代码引用的线上状态根表；本函数清空并原地写入快照字段。
---@return nil
function M.restore_state(source_graph, target_graph)
    assert(type(source_graph) == "table" and type(target_graph) == "table", "状态必须为表")
    copy_state_graph(source_graph, target_graph)
end

--- 用候选字段原地替换线上模块导出表内容，保持线上根表身份不变。
---@param module_exports table 当前线上模块导出表；本函数清除它的旧字段，再安装候选字段。
---@param export_fields table 候选模块的完整导出字段和值；调用方保证其根表与 module_exports 隔离。
---@return nil
local function replace_exports(module_exports, export_fields)
    -- 先移除旧版本全部字段，再安装完整候选；两个阶段都保持根导出表身份。
    for key in pairs(module_exports) do
        rawset(module_exports, key, nil)
    end

    -- key/value 是新版本导出的字段和值，直接写入原模块根表以保留其身份。
    for key, value in pairs(export_fields) do
        rawset(module_exports, key, value)
    end
end

--- 检查候选模块导出表是否满足普通模块更新合同；不符合时抛出 HU_MODULE_EXPORTS_INVALID。
---@param module_exports table 候选代码 return 的根表；本函数遍历其字段和嵌套值。
---@param module_name string Controller 提供的统一模块名；用于定位错误来自哪个模块。
---@return nil 无返回值；导出不满足要求时抛出 HU_MODULE_EXPORTS_INVALID。
local function check_exports(module_exports, module_name)
    assert(type(module_exports) == "table" and getmetatable(module_exports) == nil, module_name .. " 必须导出无元表根表")
    -- 每张嵌套表只入栈一次，允许数据共享引用或形成循环。
    local pending = {module_exports}       -- 尚未校验字段的表，作为显式工作栈。
    local seen = {[module_exports] = true} -- 已入栈的表，避免循环引用反复入栈。
    while #pending > 0 do
        -- 从待检查栈取出的一张模块导出表；随后逐字段核对它的内容。
        local current = table.remove(pending)
        -- key/value 是当前导出表中的一项，用于检查字段名和允许的导出类型。
        for key, value in next, current do
            assert(key ~= module_exports and value ~= module_exports, module_name .. " 导出数据不得引用模块根导出表")
            if current == module_exports then
                assert(type(key) == "string", module_name .. " 顶层导出字段名必须是字符串")
            else
                assert(type(key) == "string" or type(key) == "number" or type(key) == "boolean",
                    module_name .. " 嵌套导出键必须是字符串、数字或布尔值")
            end

            -- 当前导出字段的值类型；只有受支持的值和无元表 table 可以留下。
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

--- 编译并运行本批普通模块候选，保存旧字段和新字段，返回可提交的 Stage。
--- 所有候选准备成功后才返回 Stage；此时线上模块导出表还没有被替换。
---@param module_patches table[] Controller 按模块名排序的候选数组；每项含 name 和 source，本函数逐项编译并准备。
---@param module_loaders? table<string, {name:string, path:string}> 本 State 首次声明时使用的加载名和路径；独立调用省略时使用统一模块名，路径为 nil。
---@return FlyWowResult<{stage:FlyWowHotUpgradeModuleStage}> 成功载荷含 stage；失败不安装线上导出。候选顶层代码和状态钩子必须同步执行。
function M.stage(module_patches, module_loaders)
    -- module_patches 提供本轮新源码，module_loaders 提供首次 require 的原名/路径；package.loaded 才是本 State 当前线上根表。
    if module_state.active_module_stage then
        return flywow_result.failure("HU_UPGRADE_BUSY", "模块 Stage 尚未结束")
    end

    -- 本 State 从 Stage 持有到 Finish/Abort；每条记录集中保存候选及恢复所需的旧字段。
    local module_stage =
    {
        entries   = {},    -- 每项保存一个线上模块根表、旧字段和候选字段，供 Commit/Abort 使用。
        committed = false, -- Commit 开始改线上根表后置为 true，部分安装失败也必须恢复。
    }
    -- 候选编译、执行或状态迁移是否成功，以及失败时的异常/结果。
    local stage_succeeded, stage_failure = pcall(function()
        -- 数组结构、模块名、源码及唯一性已由 Controller 建立；这里只检查本 State 的实际对象。
        -- 先编译全部 Patch 并保存每个线上模块的旧字段。
        -- 当前发布的普通模块项，包含 Controller 固定下来的模块名和新源码。
        for _, module_patch in ipairs(module_patches) do
            -- 当前 Lua State 正在使用的模块根表；Commit 始终保留它的身份。
            local live = package.loaded[module_patch.name]
            check_exports(live, module_patch.name)
            -- 复制 live 的旧导出字段和值引用，供本批失败时原样恢复。
            local fields = {}
            -- 把旧根表中的每个字段和值引用记入恢复记录。
            -- key/value 是线上根表的旧导出项；保留原引用以便失败时恢复。
            for key, value in pairs(live) do
                fields[key] = value
            end

            -- 使用 Lua 原生 require；新加载的依赖不属于本次模块回滚。
            -- 已通过 Controller 语法检查的候选源码编译结果；此处先编译，不立即执行。
            local chunk = assert(load(hotupgrade_common.normalize_source(module_patch.source), "@" .. module_patch.name, "t"))
            -- 本 State 首次声明时保存的原始 require 名和路径；独立调用时没有该信息。
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
        -- 按发布顺序执行已编译候选，并把结果写回各自的恢复记录。
        for _, entry in ipairs(module_stage.entries) do
            -- 新源码返回的候选模块根表；后续校验并迁移状态，但暂不替换线上根表。
            local candidate = entry.chunk(entry.loader_name, entry.loader_path)
            check_exports(candidate, entry.name)
            assert(candidate ~= entry.live, "候选须返回新的导出表")
            -- 只有旧版提供快照且新版提供导入钩子时才迁移；缺少任一方就使用新版初始化状态。
            if entry.live.export_state and candidate.import_state then
                -- 旧模块导出的可迁移私有状态副本；只传给新模块导入，不改旧模块状态。
                local snapshot = M.snapshot_state(entry.live.export_state())
                assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
                -- 导入钩子可能改变候选导出；只在执行过该钩子后重新检查。
                check_exports(candidate, entry.name)
            end
            entry.candidate = candidate
            entry.chunk = nil
        end
    end)
    if not stage_succeeded then
        -- 内部若已返回 FlyWowResult 就保留其错误码；普通 Lua 异常只包装错误文本。
        local cause = type(stage_failure) == "table" and stage_failure.ok == false and stage_failure or nil
        return flywow_result.failure("HU_MODULE_STAGE_FAILED",
            cause and cause.message or tostring(stage_failure), cause and {cause_code = cause.code} or nil)
    end

    module_state.active_module_stage = module_stage
    return flywow_result.success({stage = module_stage})
end

--- 把 Stage 中候选模块的字段写入线上导出表；部分提交失败时保留记录供 Abort 恢复。
---@param module_stage FlyWowHotUpgradeModuleStage 当前 State 的候选 Stage；本函数按 entries 安装新字段并记录提交进度。
---@return FlyWowResult<nil> 同步提交结果；提交回调失败时返回 HU_MODULE_COMMIT_FAILED。
function M.commit(module_stage)
    -- entries 同时保存 live 和 candidate；这里检查 live 身份后安装 candidate，旧字段继续保留供 Abort 使用。
    if module_state.active_module_stage ~= module_stage or module_stage.committed then
        return flywow_result.failure("HU_PHASE_INVALID", "模块 Stage 无效或已提交")
    end

    -- 整批候选是否成功安装，以及安装异常；失败后 Controller 会调用 Abort。
    local commit_succeeded, commit_failure = pcall(function()
        -- 先确认所有根表身份仍有效；全部通过后才开始修改线上导出。
        -- 先逐个确认线上缓存仍指向 Stage 时保存的旧根表。
        for _, entry in ipairs(module_stage.entries) do
            assert(package.loaded[entry.name] == entry.live and getmetatable(entry.live) == nil,
                "模块身份在 Stage 后改变")
        end

        -- 所有候选已在 Stage 完成检查，现在原地替换每个模块的完整导出字段。
        module_stage.committed = true
        -- 逐个安装候选字段；某项异常时仍保留整个 Stage 供 Abort 恢复。
        for _, entry in ipairs(module_stage.entries) do
            replace_exports(entry.live, entry.candidate)
        end
    end)
    return commit_succeeded and flywow_result.success()
        or flywow_result.failure("HU_MODULE_COMMIT_FAILED", tostring(commit_failure))
end

--- 按 Stage 记录恢复已提交模块的旧字段；继续尝试其余模块并汇总恢复失败。
---@param module_stage FlyWowHotUpgradeModuleStage 需要恢复的当前 State Stage；entries 保存各模块旧字段和是否已提交。
---@return FlyWowResult<nil> 恢复结果；恢复失败返回 HU_RECOVERY_REQUIRED。
function M.abort(module_stage)
    -- entries.old 保存 Stage 时的字段引用；committed 表示已开始改线上表，包含只提交了部分模块的失败情况。
    if module_state.active_module_stage ~= module_stage then
        return flywow_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    -- 尝试恢复每个模块并收集全部故障；单个模块失败不跳过其他模块。
    -- 收集每个模块恢复失败的原因；单项失败不跳过其余模块。
    local errors = {}
    -- 当前需要恢复的模块记录，包含线上根表和 Stage 时保存的旧字段。
    for _, entry in ipairs(module_stage.entries) do
        -- 当前模块能否恢复；异常被收集后继续处理列表中的其他模块。
        local restore_succeeded, restore_failure = pcall(function()
            assert(package.loaded[entry.name] == entry.live and getmetatable(entry.live) == nil,
                "模块缓存身份或元表变化: " .. entry.name)
            if module_stage.committed then
                replace_exports(entry.live, entry.old)
            end
        end)
        if not restore_succeeded then
            errors[#errors + 1] = tostring(restore_failure)
        end
    end

    -- 所有恢复项都已尝试；失败仍报告，但本批快照不阻塞下一次 Stage。
    -- 清理本批模块记录的结果；无论某项恢复失败都释放 Stage。
    local finished = M.finish(module_stage)
    if #errors > 0 then
        return flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end

    return finished
end

--- 确认 Stage 结束并释放候选、旧字段和加载器引用；不修改当前线上导出表。
---@param module_stage FlyWowHotUpgradeModuleStage 已 Commit 或 Abort 的当前 State Stage；本函数清除其中用于恢复和候选加载的引用。
---@return FlyWowResult<nil> 清理结果；不执行回滚。
function M.finish(module_stage)
    -- active_module_stage 是本 State 的唯一在途暂存；清空 entries 释放旧导出与候选引用，不修改线上模块。
    if module_state.active_module_stage ~= module_stage then
        return flywow_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    module_stage.entries = {}
    module_state.active_module_stage = nil
    return flywow_result.success()
end

return M
