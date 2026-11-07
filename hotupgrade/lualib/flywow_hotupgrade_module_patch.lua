--- 本 Lua State 的完整模块更新；保留导出表身份，候选私有状态与旧版本隔离。
--- 只替换导出字段，不重绑定函数 upvalue；旧函数引用和候选根表引用均保留原 Lua 语义。
local flywow_result = require "flywow_result" -- 为 Stage、Commit 和 Abort 返回统一的成功或失败结果。
local hotupgrade_common = require "flywow_hotupgrade_common" -- 提供默认状态快照允许的最大嵌套层数和字段数。
-- 对 Service 暴露普通状态快照、候选 Stage、Commit 和 Abort 操作。
local M = {}

---@class FlyWowHotUpgradeModuleStage
---@field entries table[] 本 State 每个候选模块的旧字段与新字段记录；Commit/Abort 处理，Finish 释放。
---@field exports_write_started boolean 是否已开始安装线上导出；部分提交失败时也必须恢复。

--- 复制普通 Lua 状态图；数据限制失败时返回结构化错误。
---@param source_graph any 业务状态根值；只接受 nil、string、boolean、number 和普通 table。
---@param target_graph? table 可选的现存目标根表；成功时原地更新。
---@return FlyWowResult<any> 成功载荷为复制后的值；失败返回 HU_STATE_COPY_FAILED。
local function copy_state_graph(source_graph, target_graph)
    local copied_tables = {}
    local field_count = 0
    --- 递归复制状态值；子表保留共享引用和循环引用。
    ---@param source_value any 当前待复制的状态值；由父表遍历时传入。
    ---@param nesting_depth integer 当前值相对根表的层数；用于状态深度上限。
    ---@return FlyWowResult<any> 成功载荷为复制值；不支持的数据返回 HU_STATE_COPY_FAILED。
    local function copy_state_value(source_value, nesting_depth)
        -- 先接受标量值；table 才需要检查元表、循环引用和最大深度。
        local value_type = type(source_value)
        if value_type ~= "table" then
            if value_type == "nil" or value_type == "string" or value_type == "boolean" or value_type == "number" then
                return flywow_result.success(source_value)
            end
            return flywow_result.failure("HU_STATE_COPY_FAILED", "状态快照只接受普通数据")
        end

        -- 标量已在上面处理；接下来只接受无元表的普通 table。
        if getmetatable(source_value) ~= nil then
            return flywow_result.failure("HU_STATE_COPY_FAILED", "状态对象需要显式快照和恢复处理")
        end
        if copied_tables[source_value] then
            return flywow_result.success(copied_tables[source_value])
        end
        if nesting_depth > hotupgrade_common.MAX_STATE_DEPTH then
            return flywow_result.failure("HU_STATE_COPY_FAILED", "状态快照嵌套超过限制")
        end

        -- 根状态写回调用方传入的目标表，内部子表创建新表，避免共享线上对象。
        local restoring_root = nesting_depth == 1 and target_graph ~= nil
        local target_table = restoring_root and target_graph or {}
        if restoring_root and (target_table == source_value or getmetatable(target_table) ~= nil) then
            return flywow_result.failure("HU_STATE_COPY_FAILED", "快照必须与线上根表隔离")
        end

        -- 目标表创建后登记源到目标的映射，递归遇到该表时复用同一引用。
        copied_tables[source_value] = target_table

        -- 新表直接填充；恢复现存根表时先暂存字段，避免校验失败改坏线上状态。
        local copied_fields = restoring_root and {} or target_table
        for key, child_source in pairs(source_value) do
            field_count = field_count + 1
            if field_count > hotupgrade_common.MAX_STATE_FIELDS then
                return flywow_result.failure("HU_STATE_COPY_FAILED", "状态快照超过字段限制")
            end
            local key_type = type(key)
            if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
                return flywow_result.failure("HU_STATE_COPY_FAILED", "状态字段必须使用标量键")
            end
            local child_result = copy_state_value(child_source, nesting_depth + 1)
            if not child_result.ok then
                return child_result
            end
            rawset(copied_fields, key, child_result.value)
        end

        -- 整张图验证成功后才替换现存根表的字段，保留根表身份及图内回指。
        if restoring_root then
            for key in pairs(target_table) do
                rawset(target_table, key, nil)
            end
            for key, value in pairs(copied_fields) do
                rawset(target_table, key, value)
            end
        end
        return flywow_result.success(target_table)
    end
    return copy_state_value(source_graph, 1)
end

--- 复制普通数据状态图并返回独立快照。
---@param source_graph any 业务方要保存的当前状态根值；调用者在更新前传入。
---@return FlyWowResult<any> 成功载荷为独立快照；失败返回 HU_STATE_COPY_FAILED。
function M.snapshot_state(source_graph)
    return copy_state_graph(source_graph)
end

--- 把独立快照写回线上状态根表，并保持线上根表引用不变。
---@param source_graph table 此前保存的旧状态快照；本函数从中读取要恢复的字段。
---@param target_graph table 仍被业务代码引用的线上状态根表；成功时原地写入快照字段。
---@return FlyWowResult<nil> 恢复成功或带 HU_STATE_COPY_FAILED 的失败结果。
function M.restore_state(source_graph, target_graph)
    if type(source_graph) ~= "table" or type(target_graph) ~= "table" then
        return flywow_result.failure("HU_STATE_COPY_FAILED", "状态必须为表")
    end

    -- 两个根表类型确认后再复制；复制失败时不把半成品作为成功结果返回。
    local restored = copy_state_graph(source_graph, target_graph)
    if not restored.ok then
        return restored
    end

    return flywow_result.success()
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

--- 检查普通模块返回的根表和嵌套字段；键或值类型不受支持时返回失败。
---@param module_exports table 候选代码 return 的根表；本函数遍历其字段和嵌套值。
---@param module_name string Controller 提供的统一模块名；用于定位错误来自哪个模块。
---@return FlyWowResult<nil> 校验成功或带模块名的 HU_MODULE_EXPORTS_INVALID 失败结果。
local function check_exports(module_exports, module_name)
    --- 把模块名和具体失败原因写入 HU_MODULE_EXPORTS_INVALID 结果。
    ---@param message string 当前字段的键/值类型或导出表结构违反 HotUpgrade 要求的具体原因。
    ---@return FlyWowResult<nil> HU_MODULE_EXPORTS_INVALID 结果，含模块名和具体原因。
    local function invalid(message)
        return flywow_result.failure("HU_MODULE_EXPORTS_INVALID", module_name .. ": " .. message)
    end

    if type(module_exports) ~= "table" or getmetatable(module_exports) ~= nil then
        return invalid("必须导出无元表根表")
    end

    -- 每张嵌套表只入栈一次，允许数据共享引用或形成循环。
    local pending = {module_exports}
    local seen = {[module_exports] = true}
    while #pending > 0 do
        local current = table.remove(pending)
        for key, value in next, current do
            if key == module_exports or value == module_exports then
                return invalid("导出数据不得引用模块根导出表")
            end
            if current == module_exports then
                if type(key) ~= "string" then
                    return invalid("顶层导出字段名必须是字符串")
                end
            elseif type(key) ~= "string" and type(key) ~= "number" and type(key) ~= "boolean" then
                return invalid("嵌套导出键必须是字符串、数字或布尔值")
            end

            local value_type = type(value)
            if value_type ~= "function" and value_type ~= "number" and value_type ~= "string"
                and value_type ~= "boolean" and value_type ~= "table" then
                return invalid("导出值类型不受支持")
            end
            if value_type == "table" and not seen[value] then
                if getmetatable(value) ~= nil then
                    return invalid("嵌套导出表不得带元表")
                end
                seen[value] = true
                pending[#pending + 1] = value
            end
        end
    end

    if (module_exports.export_state == nil) ~= (module_exports.import_state == nil) then
        return invalid("状态钩子须成对")
    end
    -- 两个状态迁移钩子必须同时存在，并且都必须是函数。
    if module_exports.export_state ~= nil and
        (type(module_exports.export_state) ~= "function" or type(module_exports.import_state) ~= "function") then
        return invalid("状态钩子必须是函数")
    end
    return flywow_result.success()
end
--- 编译并运行本批普通模块候选，保存旧字段和新字段，返回可提交的 Stage。
--- 所有候选准备成功后才返回 Stage；此时线上模块导出表还没有被替换。
---@param module_patches table[] Controller 按模块名排序的候选数组；每项含 name 和 source，本函数逐项编译并准备。
---@param module_loaders? table<string, {name:string, path:string}> 本 State 首次声明时使用的加载名和路径；独立调用省略时使用统一模块名，路径为 nil。
--- 候选 chunk、export_state 和 import_state 在本调用中同步执行，不得 yield。
---@return FlyWowResult<FlyWowHotUpgradeModuleStage> 成功载荷是暂存记录；失败保留编译、候选校验或迁移阶段错误，且不安装线上导出。
function M.stage(module_patches, module_loaders)
    -- module_patches 提供本轮新源码，module_loaders 提供首次 require 的原名/路径；package.loaded 保存当前线上根表。
    -- 保存本批各模块的线上表和旧字段；Commit 安装新字段，Abort 恢复旧字段，Finish 释放记录。
    local module_stage =
    {
        entries               = {},    -- 每个模块的线上表、旧字段和候选导出；Commit 安装，Abort 恢复，Finish 释放。
        exports_write_started = false, -- 只要开始替换线上导出就置 true；即使部分模块失败，Abort 也会恢复。
    }
    -- 导出检查与快照复制的失败归入 Stage 错误，编译与导入失败保留各自阶段的错误码。
    --- 将导出检查或状态快照的失败转换为 Stage 合同，同时保留原始错误码。
    ---@param result FlyWowResult<nil> 导出检查或快照复制产生的失败结果。
    ---@return FlyWowResult<nil> HU_MODULE_STAGE_FAILED；原始错误码写入 details.cause_code。
    local function reject_stage(result)
        return flywow_result.failure("HU_MODULE_STAGE_FAILED", result.message, {cause_code = result.code})
    end

    -- 先编译全部 Patch 并保存旧导出字段，避免执行候选时遗漏后续编译失败。
    for _, module_patch in ipairs(module_patches) do
        local live = package.loaded[module_patch.name]
        local live_exports = check_exports(live, module_patch.name)
        if not live_exports.ok then
            return reject_stage(live_exports)
        end

        local fields = {}
        for key, value in pairs(live) do
            fields[key] = value
        end

        local chunk, compile_failure = load(
            hotupgrade_common.normalize_source(module_patch.source), "@" .. module_patch.name, "t")
        if not chunk then
            return flywow_result.failure("HU_MODULE_COMPILE_FAILED",
                module_patch.name .. ": " .. tostring(compile_failure))
        end
        local loader = module_loaders and module_loaders[module_patch.name]
        module_stage.entries[#module_stage.entries + 1] =
        {
            name        = module_patch.name, -- package.loaded 中当前线上模块的名称。
            live        = live,              -- 业务代码正在使用的导出表；Commit/Abort 都保留这张表本身。
            old         = fields,            -- 更新前字段和值的引用；Abort 用它装回旧版本。
            chunk       = chunk,             -- 编译后的候选代码；下一阶段执行并检查其返回表。
            loader_name = loader and loader.name or module_patch.name, -- 保留首次 require 使用的名称，作为候选 chunk 的第一个参数。
            loader_path = loader and loader.path, -- 保留首次加载文件路径，作为候选 chunk 的第二个参数；无记录时为 nil。
            candidate   = nil,               -- 候选 chunk 返回的新表；Commit 从中复制字段到 live。
        }
    end

    -- 运行更新包里的模块代码；如果文件顶层代码抛错，就转换成 HU_MODULE_STAGE_FAILED 返回。
    for _, entry in ipairs(module_stage.entries) do
        local candidate_succeeded, candidate = pcall(entry.chunk, entry.loader_name, entry.loader_path)
        if not candidate_succeeded then
            local failure_text = tostring(candidate)
            local cause_code, cause_message = failure_text:match("(HU_[A-Z0-9_]+):%s*(.*)$")
            return flywow_result.failure("HU_MODULE_STAGE_FAILED", cause_message or failure_text,
                cause_code and {cause_code = cause_code} or nil)
        end
        local candidate_exports = check_exports(candidate, entry.name)
        if not candidate_exports.ok then
            return reject_stage(candidate_exports)
        end
        if candidate == entry.live then
            return flywow_result.failure("HU_MODULE_EXPORTS_INVALID", entry.name .. ": 候选须返回新的导出表")
        end

        if entry.live.export_state and candidate.import_state then
            -- 运行线上模块的 export_state 保存旧状态；回调抛错时停止本批并返回 HU_MODULE_STAGE_FAILED。
            local export_called, exported_state = pcall(entry.live.export_state)
            if not export_called then
                return flywow_result.failure("HU_MODULE_STAGE_FAILED",
                    entry.name .. ": " .. tostring(exported_state))
            end
            local snapshot_result = M.snapshot_state(exported_state)
            if not snapshot_result.ok then
                return reject_stage(snapshot_result)
            end

            -- 运行新模块的 import_state 写入旧状态快照；回调抛错时返回 HU_MODULE_IMPORT_FAILED。
            local import_called, import_result = pcall(candidate.import_state, snapshot_result.value)
            if not import_called then
                return flywow_result.failure("HU_MODULE_IMPORT_FAILED",
                    entry.name .. ": " .. tostring(import_result))
            end
            if type(import_result) ~= "table" or type(import_result.ok) ~= "boolean" then
                return flywow_result.failure("HU_MODULE_IMPORT_FAILED",
                    entry.name .. ": import_state 必须返回 FlyWowResult<nil>")
            end
            if not import_result.ok then
                return flywow_result.failure("HU_MODULE_IMPORT_FAILED",
                    entry.name .. ": " .. tostring(import_result.message or import_result.code),
                    {cause_code = import_result.code})
            end
            local imported_exports = check_exports(candidate, entry.name)
            if not imported_exports.ok then
                return reject_stage(imported_exports)
            end
        end
        entry.candidate = candidate
        entry.chunk = nil
    end

    -- 候选编译、执行和导出校验成功后，发布暂存记录供 Commit 或 Abort 使用。
    return flywow_result.success(module_stage)
end

--- 把 Stage 中候选模块的字段写入线上导出表；部分提交失败时保留记录供 Abort 恢复。
---@param module_stage FlyWowHotUpgradeModuleStage 当前 State 的候选 Stage；本函数按 entries 安装新字段并记录提交进度。
---@return FlyWowResult<nil> 同步提交结果；导出表身份变化或安装失败时返回 HU_MODULE_COMMIT_FAILED。
function M.commit(module_stage)
    -- 检查线上缓存是否仍指向 Stage 保存的根表；失败直接返回，尚未修改线上导出。
    for _, entry in ipairs(module_stage.entries) do
        if package.loaded[entry.name] ~= entry.live or getmetatable(entry.live) ~= nil then
            return flywow_result.failure("HU_MODULE_COMMIT_FAILED", "模块身份在 Stage 后改变")
        end
    end

    -- 捕获替换导出字段时的意外异常；Controller 收到失败结果后会调用 Abort。
    local commit_succeeded, commit_failure = pcall(function()
        -- 所有候选已在 Stage 完成检查，现在原地替换每个模块的完整导出字段。
        module_stage.exports_write_started = true
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
    -- entries.old 保存 Stage 时的字段引用；exports_write_started 表示已开始改线上表，包含只提交了部分模块的失败情况。
    -- 逐个尝试恢复线上表；单个模块失败不能阻止后面的模块恢复。
    -- 每个失败原因都暂存到 errors，循环结束后合并到 HU_RECOVERY_REQUIRED。
    local errors = {}
    -- 当前需要恢复的模块记录，包含线上根表和 Stage 时保存的旧字段。
    for _, entry in ipairs(module_stage.entries) do
        -- package.loaded 若已指向别的表，就不能覆盖它；记录失败后继续恢复下一模块。
        if package.loaded[entry.name] ~= entry.live or getmetatable(entry.live) ~= nil then
            errors[#errors + 1] = "模块缓存身份或元表变化: " .. entry.name
        elseif module_stage.exports_write_started then
            -- 字段恢复中的意外 Lua 错误不应阻止其他模块恢复。
            local restore_succeeded, restore_failure = pcall(replace_exports, entry.live, entry.old)
            if not restore_succeeded then
                errors[#errors + 1] = tostring(restore_failure)
            end
        end
    end

    if #errors > 0 then
        return flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end
    return flywow_result.success()
end

return M
