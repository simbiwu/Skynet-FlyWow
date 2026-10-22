--- 本 Lua State 的完整模块更新；保留导出表身份，候选私有状态与旧版本隔离。
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"
local M = {}
local module_state =
{
    active = nil, -- 本 State 唯一候选和旧快照，保留至 finish/abort。
}

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

--- 原地覆盖模块导出字段；各字段引用直接安装，保留导出表身份。
---@param live table Commit/Abort 已确认身份和元表的线上表
---@param fields table 完整新字段；调用者保证与 live 隔离
local function replace_exports(live, fields)
    for key in pairs(live) do
        rawset(live, key, nil)
    end

    for key, value in pairs(fields) do
        rawset(live, key, value)
    end
end

local function check_exports(exports, name)
    -- 先校验顶层导出并收集嵌套表，seen 允许数据图共享引用和循环引用。
    assert(type(exports) == "table" and getmetatable(exports) == nil, name .. " 必须导出普通表")
    local pending = {} -- 待检查的嵌套表；迭代遍历避免深层数据造成递归栈溢出。
    local seen = {}    -- 每张嵌套表只检查一次，允许共享引用与嵌套表之间的循环。
    local function check_value(value)
        local kind = type(value)
        if kind == "table" then
            assert(value ~= exports, name .. " 嵌套导出不得引用模块根导出表")
            assert(getmetatable(value) == nil, name .. " 嵌套导出必须是无元表普通表")
            if not seen[value] then
                seen[value] = true
                pending[#pending + 1] = value
            end
        else
            assert(kind == "function" or kind == "number" or kind == "string" or kind == "boolean",
                name .. " 导出包含不支持的类型: " .. kind)
        end
    end

    for key, value in pairs(exports) do
        assert(type(key) == "string", name .. " 顶层导出字段名必须是字符串")
        check_value(value)
    end

    -- 遍历嵌套数据图，校验键和值类型并拒绝元表和根表回指。
    while #pending > 0 do
        local nested = table.remove(pending)
        for key, value in pairs(nested) do
            local kind = type(key)
            assert(kind == "string" or kind == "number" or kind == "boolean",
                name .. " 嵌套导出键必须是字符串、数字或布尔值")
            check_value(value)
        end
    end

    -- 模块私有状态钩子是额外合同，必须成对提供且都为函数。
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
