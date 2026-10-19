--- 唯一控制面：冻结 Patch 并串行协调现存目标；只保存进程内状态。
local skynet = require "skynet"
local hotupgrade_native = require "flywow_hotupgrade_native"
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"

-- Native 以第二返回值携带稳定 HU_ 错误；兼容历史上的裸字符串错误值。
local function native_code(value)
    if type(value) == "table" then
        return value.code or "HU_NATIVE_ERROR"
    end

    return value or "HU_NATIVE_ERROR"
end

-- 与 Native 扫描器上限保持一致：单文件 2 MiB、一次 Patch 累计 16 MiB。
local MAX_FILE_BYTES = 2 * 1024 * 1024
local MAX_PATCH_BYTES = 16 * 1024 * 1024

-- 有界读取单个已规范化文件；关闭失败也视为读取失败，避免冻结不完整内容。
local function read(path)
    local file, message = io.open(path, "rb")
    if not file then
        return hotupgrade_result.failure("HU_FILE_NOT_FOUND", message)
    end

    local bytes = file:read(MAX_FILE_BYTES + 1)
    local closed = file:close()
    if not bytes or not closed then
        return hotupgrade_result.failure("HU_FILE_READ_FAILED", path)
    end

    if #bytes > MAX_FILE_BYTES then
        return hotupgrade_result.failure("HU_PATCH_LIMIT", path)
    end

    return hotupgrade_result.success({bytes = bytes})
end

-- 宿主根目录相对 Lua 路径对应 Controller 使用的唯一模块登记名。
local function module_name(path)
    if path:sub(-4) ~= ".lua" or path:find("\\", 1, true) then
        return nil
    end

    return path:sub(1, -5):gsub("/", ".")
end

-- 递归扫描选定 Patch 目录，检查语法并冻结同一事务的全部源码。
local function load_files(root, patch_path, identity, budget)
    local paths, code = hotupgrade_native.list_lua(root, patch_path)
    code = native_code(code)
    if not paths and code == "HU_PATCH_EMPTY" then
        return hotupgrade_result.success({entries = {}})
    end

    if not paths then
        return hotupgrade_result.failure(native_code(code), "Patch 目录扫描失败: " .. patch_path)
    end

    table.sort(paths)

    local entries = {}
    for _, relative in ipairs(paths) do
        local absolute = root .. "/" .. patch_path .. "/" .. relative
        local located, locate_error = hotupgrade_native.resolve(absolute)
        if not located then
            return hotupgrade_result.failure(native_code(locate_error), relative)
        end

        local loaded = read(located)
        if not loaded.ok then
            return loaded
        end
        budget.bytes = budget.bytes + #loaded.bytes
        if budget.bytes > MAX_PATCH_BYTES then
            return hotupgrade_result.failure("HU_PATCH_LIMIT", "Patch 总字节数超限")
        end

        local chunk, syntax_error = load(loaded.bytes, "@" .. relative, "t", {})
        if not chunk then
            return hotupgrade_result.failure("HU_MODULE_SYNTAX", syntax_error)
        end
        entries[#entries + 1] = {file = relative, source = loaded.bytes}
        identity[#identity + 1] = relative
    end

    return hotupgrade_result.success({entries = entries})
end

-- 汇总模块与 Service 文件；Patch 身份仅由路径和文件名组成。
local function build_patch(root, patch_path, service_dir)
    local identity = {}        -- 当前 Patch 的路径身份字段，不是内容 hash。
    local budget = {bytes = 0} -- 整包冻结源码累计字节数。
    local loaded = load_files(root, patch_path, identity, budget)
    if not loaded.ok then
        return loaded
    end

    local modules = {}
    local services = {}
    local service_prefix = service_dir .. "/"
    for _, entry in ipairs(loaded.entries) do
        local is_service = entry.file:sub(1, #service_prefix) == service_prefix
        local relative = is_service and entry.file:sub(#service_prefix + 1) or entry.file
        local name = module_name(relative)
        local entries = is_service and services or modules
        if not name or name == "" or entries[name]
            or (is_service and not name:match("^[%w_.%-]+$")) then
            return hotupgrade_result.failure("HU_INVALID_PATCH", "Lua 路径映射重复或无效: " .. entry.file)
        end
        entries[name] = {name = name, entry_file = entry.file, source = entry.source}
    end

    if next(modules) == nil and next(services) == nil then
        return hotupgrade_result.failure("HU_PATCH_EMPTY", "Patch 至少要有一个模块或 Service 文件")
    end

    table.sort(identity)
    local identity_parts = {tostring(#patch_path) .. ":" .. patch_path}
    for _, entry in ipairs(identity) do
        identity_parts[#identity_parts + 1] = tostring(#entry) .. ":" .. entry
    end

    local patch = {patch_id = table.concat(identity_parts),
        modules = {}, services = services}
    for _, module in pairs(modules) do
        patch.modules[#patch.modules + 1] = module
    end

    table.sort(patch.modules, function(left, right)
        return left.name < right.name
    end)
    return hotupgrade_result.success({patch = patch})
end


local M = {}

-- 当前控制面实际持有的登记容量；同时约束目标快照与逐项结果大小。
local Controller = {}
Controller.__index = Controller

---@class FlyWowHotUpgradeTargetMetadata
---@field service_type string 由现存 Service 声明，匹配配置 service_dir 下的相对路径
---@field modules string[] 当前 State 已声明模块的唯一名称数组
---@field service_patch boolean 是否在本 State 提供私有状态及函数更新入口

---@class FlyWowHotUpgradeControlRequest
---@field txn_id string Controller handle 与本进程递增序号组成；仅在该 Controller 生命周期有效
---@field sequence integer 当前控制面严格递增的事务序号，目标用来拒绝迟到消息
---@field timeout_ms integer prepare 等待 Guard 排空的毫秒上限，不代表远端操作取消
---@field modules? table[] stage 使用的 name/source 完整模块数组；不含业务对象
---@field service_source? string stage 使用的可选一次性 Service 脚本源码

---@class FlyWowHotUpgradeManagementRequest
---@field path? string validate/apply/dry_run 的 Patch Root 相对目录
---@field txn_id? string status/abort 指定的事务身份

---@class FlyWowHotUpgradeControllerConfig
---@field patch_root string 已存在且由宿主管理的受信 Patch 根目录
---@field root_path string 宿主项目根目录；模块登记名由其相对文件路径生成
---@field service_dir string root_path 下的相对 Service 目录，其下 Lua 文件作为一次性 Service 更新脚本
---@field timeout_ms? integer Guard 排空上限；默认值见 hotupgrade_common.DEFAULT_TIMEOUT_MS，不是 RPC 取消期限

--- 创建控制面；不读取持久化历史，不尝试恢复上一进程的事务。
---@param controller_config FlyWowHotUpgradeControllerConfig
---@return FlyWowHotUpgradeResult 成功含 controller
function M.new(controller_config)
    if type(controller_config) ~= "table" or type(controller_config.patch_root) ~= "string" or controller_config.patch_root == ""
        or type(controller_config.root_path) ~= "string" or controller_config.root_path == ""
        or type(controller_config.service_dir) ~= "string"
        or (controller_config.timeout_ms ~= nil and (math.type(controller_config.timeout_ms) ~= "integer"
            or controller_config.timeout_ms <= 0)) then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "需要 patch_root、root_path、service_dir 和可选正整数 timeout_ms")
    end

    local root, code = hotupgrade_native.resolve(controller_config.patch_root .. "/.")
    if not root then
        return hotupgrade_result.failure(native_code(code), "Patch 根目录不可用")
    end

    local root_path, root_error = hotupgrade_native.resolve(controller_config.root_path .. "/.")
    if not root_path then
        return hotupgrade_result.failure(native_code(root_error), "宿主项目根目录不可用")
    end

    local service_path, service_error = hotupgrade_native.resolve(root_path, controller_config.service_dir)
    if not service_path then
        return hotupgrade_result.failure(native_code(service_error), "Service 相对目录无效: " .. controller_config.service_dir)
    end

    -- 只发布一份宿主根路径，业务 State 可在登记前通过 require 生成相同的文件身份。
    local published_root = skynet.getenv(hotupgrade_common.ROOT_PATH_ENV)
    if published_root and published_root ~= root_path then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "同一 Skynet 进程的 Controller 必须使用相同 root_path")
    end
    if not published_root then
        skynet.setenv(hotupgrade_common.ROOT_PATH_ENV, root_path)
    end

    return hotupgrade_result.success({controller = setmetatable(
    {
        root              = root,                                -- 固定使用已解析的受信 Patch 根目录，不随事务改变。
        service_dir       = controller_config.service_dir,        -- Patch 中仅此目录及其子目录按 Service 脚本处理。
        timeout_ms        = controller_config.timeout_ms or hotupgrade_common.DEFAULT_TIMEOUT_MS, -- Guard 排空期限，单位毫秒；默认值见 hotupgrade_common.DEFAULT_TIMEOUT_MS。
        target_count      = 0,                                   -- 当前 Controller 生命周期内成功登记的目标数量，用于容量检查。
        targets           = {},                                  -- 以真实 Service handle 为键，保存其模块声明和 Service 更新能力。
        sequence          = 0,                                   -- 当前 Controller 生命周期内递增的事务序号，用于拒绝迟到控制消息。
        active            = nil,                                 -- 唯一活动事务；有值时拒绝启动另一个 apply 或 dry_run。
        last              = nil,                                 -- 最近结束的事务结果；更早事务不保留，查询返回缺失。
        recovery_required = false,                               -- 恢复结果未确认时关闭后续发布，需先由宿主处理恢复。
    }, Controller)})
end

---@param request FlyWowHotUpgradeTargetMetadata
---@param source integer Skynet 消息头中的真实 Service handle
---@return FlyWowHotUpgradeResult
function Controller:register(request, source)
    if math.type(source) ~= "integer" or type(request.service_type) ~= "string"
        or not request.service_type:match("^[%w_.%-]+$") or type(request.modules) ~= "table"
        or type(request.service_patch) ~= "boolean" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "登记元数据无效")
    end

    if self.targets[source] then
        return hotupgrade_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
    end

    if self.target_count >= hotupgrade_common.MAX_TARGETS then
        return hotupgrade_result.failure("HU_TARGET_LIMIT", "登记目标已达 " .. hotupgrade_common.MAX_TARGETS .. " 上限")
    end

    if #request.modules > hotupgrade_common.MAX_MODULES then
        return hotupgrade_result.failure("HU_MODULE_LIMIT", "目标模块已达 " .. hotupgrade_common.MAX_MODULES .. " 上限")
    end

    local modules = {}
    local module_count = 0
    for index, name in pairs(request.modules) do
        if math.type(index) ~= "integer" or index < 1 or index > #request.modules
            or type(name) ~= "string" or name == "" or modules[name] then
            return hotupgrade_result.failure("HU_INVALID_OPTIONS", "模块声明列表无效")
        end
        modules[name] = true
        module_count = module_count + 1
    end

    if module_count ~= #request.modules then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "模块声明数组有空洞")
    end

    self.target_count = self.target_count + 1
    self.targets[source] =
    {
        handle = source,                        -- Skynet 提供的真实来源，也是后续控制目标。
        service_type = request.service_type,    -- 匹配配置 service_dir 下的相对路径。
        module_count = #request.modules,         -- 已登记声明数，用于拒绝无界增长。
        modules = modules,                      -- 该 State 明确声明的可更新模块集合。
        service_patch = request.service_patch,  -- 是否提供本地 Service 状态/函数入口。
    }
    return hotupgrade_result.success()
end

--- 冻结文件并生成目标快照；不执行 Patch 代码、不读其他 Service Lua State。
function Controller:load(request)
    if self.recovery_required then
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", "存在未确认恢复的目标")
    end

    if type(request.path) ~= "string" or request.selector ~= nil then
        return hotupgrade_result.failure("HU_INVALID_PATCH", "需要相对 path；不再支持灰度 selector")
    end

    local loaded = build_patch(self.root, request.path, self.service_dir)
    if not loaded.ok then
        return loaded
    end

    -- 按已登记模块和 Service 类型建立目标快照，之后再检查每个文件均已匹配。
    local targets = {}
    local matched = {} -- 仅当前登记快照覆盖的 Patch 文件；全量匹配后才允许启动事务。
    for _, record in pairs(self.targets) do
        local modules = {}
        for _, entry in ipairs(loaded.patch.modules) do
            if record.modules[entry.name] then
                modules[#modules + 1] = entry
                matched[entry.entry_file] = true
            end
        end

        local service = loaded.patch.services[record.service_type]
        if service and not record.service_patch then
            return hotupgrade_result.failure("HU_SERVICE_PATCH_UNSUPPORTED", request.path .. "/" .. service.entry_file
                .. ": 目标 " .. record.handle .. " 未提供 Service 内部更新入口")
        end

        if service then
            matched[service.entry_file] = true
        end

        if #modules > 0 or service then
            targets[#targets + 1] =
            {
                handle = record.handle,
                modules = modules,
                service_source = service and service.source,
                service_entry_file = service and service.entry_file,
            }
        end
    end
    -- 每份文件都必须有接收者，不能因其他文件匹配成功而静默遗漏。
    -- 整包匹配校验先于任何目标 RPC，避免部分 Patch 被静默遗漏。
    for _, entry in ipairs(loaded.patch.modules) do
        if not matched[entry.entry_file] then
            return hotupgrade_result.failure("HU_TARGET_MISSING", request.path .. "/" .. entry.entry_file
                .. ": 没有已登记目标声明模块 " .. entry.name)
        end
    end

    for service_type, entry in pairs(loaded.patch.services) do
        if not matched[entry.entry_file] then
            return hotupgrade_result.failure("HU_TARGET_MISSING", request.path .. "/" .. entry.entry_file
                .. ": 没有已登记目标匹配 service_type " .. service_type)
        end
    end

    table.sort(targets, function(left, right)
        return left.handle < right.handle
    end)
    if #targets == 0 then
        return hotupgrade_result.failure("HU_TARGET_MISSING", "没有匹配的已登记目标")
    end

    return hotupgrade_result.success({patch = loaded.patch, targets = targets})
end

--- 直接使用 Skynet 原生 call；失败不代表远端操作取消，协调方仍须明确恢复。
function Controller:step(txn, target, command)
    ---@type FlyWowHotUpgradeControlRequest
    local request =
    {
        txn_id = txn.id,
        sequence = txn.sequence,
        timeout_ms = self.timeout_ms,
    }
    if command == "stage" then
        request.modules = target.modules
        request.service_source = target.service_source
    end

    local ok, answer = pcall(skynet.call, target.handle, "hotupgrade", command, request)
    if not ok or type(answer) ~= "table" or type(answer.ok) ~= "boolean" then
        return hotupgrade_result.failure("HU_RPC_FAILED", tostring(answer), command)
    end

    if not answer.ok and target.service_entry_file then
        answer.message = target.service_entry_file .. ": " .. (answer.message or answer.code)
    end
    return answer
end

function Controller:run_target(txn, target, dry_run)
    for _, command in ipairs({"prepare", "stage", "activate"}) do
        txn.phase = command:upper()
        local answer = self:step(txn, target, command)
        if not answer.ok or txn.cancelled then
            local restored = self:step(txn, target, "abort")
            if not restored.ok then
                return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", restored.message, command)
            end

            if txn.cancelled then
                return hotupgrade_result.failure("HU_ABORT_REQUESTED", "管理端终止发布")
            end

            if answer.code == "HU_RECOVERY_REQUIRED" then
                -- 目标先前恢复失败，但本次显式 Abort 已确认恢复；保留失败诊断而不伪报仍未恢复。
                return hotupgrade_result.failure("HU_UPDATE_FAILED", answer.message, command)
            end

            return answer
        end
    end

    if dry_run then
        local restored = self:step(txn, target, "abort")
        return restored.ok and restored or hotupgrade_result.failure("HU_RECOVERY_REQUIRED", restored.message, "abort")
    end

    -- 当前目标已同步提交；发布决定后 finish 结果不明不能伪称已恢复。
    txn.phase = "PUBLISH_DECIDED"
    txn.decided = true
    target.decided = true
    local finished = self:step(txn, target, "finish")
    if not finished.ok then
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", finished.message, "finish")
    end

    return hotupgrade_result.success()
end

function Controller:run(txn, dry_run)
    for _, target in ipairs(txn.targets) do
        txn.current_handle = target.handle
        local ok, answer = pcall(self.run_target, self, txn, target, dry_run)
        if not ok then
            local restored = not target.decided and self:step(txn, target, "abort")
            answer = hotupgrade_result.failure(restored and restored.ok and "HU_CONTROL_FAILED" or "HU_RECOVERY_REQUIRED",
                tostring(answer))
        end

        txn.results[#txn.results + 1] = {handle = target.handle, hotupgrade_result = answer}
        if not answer.ok then
            txn.failed = txn.failed + 1
            txn.error = answer
            if answer.code == "HU_RECOVERY_REQUIRED" then
                txn.phase = "RECOVERY_REQUIRED"
                self.recovery_required = true
            else
                txn.phase = txn.success > 0 and "PARTIAL" or "ABORTED"
            end
            break
        end

        txn.success = txn.success + 1
    end

    if not txn.error then
        txn.phase = dry_run and "DRY_RUN_COMPLETED" or "COMPLETED"
    end
    -- 终态只保留有界结果，不继续持有冻结源码或目标运行时快照。
    txn.targets = nil
    self.last = txn
    self.active = nil
end

--- 异步推进，立即返回 txn_id；一次仅执行一个发布，status 查询进程内状态。
function Controller:apply(request, dry_run)
    if self.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "已有活动发布")
    end

    local loaded = self:load(request)
    if not loaded.ok then
        return loaded
    end

    self.sequence = self.sequence + 1
    local txn =
    {
        id = tostring(skynet.self()) .. ":" .. self.sequence,
        sequence = self.sequence,
        phase = "PREPARING",
        targets = loaded.targets,
        target_count = #loaded.targets,
        results = {},
        success = 0,
        failed = 0,
    }
    self.active = txn
    skynet.fork(function()
        self:run(txn, dry_run)
    end)
    return hotupgrade_result.success({txn_id = txn.id, target_count = txn.target_count})
end

--- 管理命令不做远程认证；宿主掌握 Controller handle，登记来源由消息头确定。
---@param command string register/register_module/validate/apply/dry_run/status/abort
---@param request FlyWowHotUpgradeManagementRequest|FlyWowHotUpgradeTargetMetadata|table 命令请求
---@param source integer Skynet 真实调用方
---@return FlyWowHotUpgradeResult 可判别的管理结果；目标控制调用可能 yield
function Controller:control(command, request, source)
    if type(request) ~= "table" then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "请求必须是 table")
    end

    if command == "register" then
        return self:register(request, source)
    end

    if command == "register_module" then
        local target = self.targets[source]
        if not target or type(request.name) ~= "string" or request.name == "" then
            return hotupgrade_result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未登记或模块名无效")
        end

        if not target.modules[request.name] then
            if target.module_count >= hotupgrade_common.MAX_MODULES then
                return hotupgrade_result.failure("HU_MODULE_LIMIT", "目标模块已达 " .. hotupgrade_common.MAX_MODULES .. " 上限")
            end
            target.modules[request.name] = true
            target.module_count = target.module_count + 1
        end

        return hotupgrade_result.success()
    end

    if command == "validate" then
        local loaded = self:load(request)
        if not loaded.ok then
            return loaded
        end

        return hotupgrade_result.success({target_count = #loaded.targets, patch_id = loaded.patch.patch_id})
    end

    if command == "apply" or command == "dry_run" then
        return self:apply(request, command == "dry_run")
    end

    if command == "status" then
        local txn = self.active and self.active.id == request.txn_id and self.active or self.last
        if not txn or txn.id ~= request.txn_id then
            return hotupgrade_result.failure("HU_TRANSACTION_MISSING", "仅保留活动及最近终态事务")
        end

        return hotupgrade_result.success({record =
        {
            txn_id = txn.id, phase = txn.phase, success = txn.success, failed = txn.failed,
            target_count = txn.target_count, current_handle = txn.current_handle,
            results = txn.results, error = txn.error,
        }, recovery_required = self.recovery_required})
    end

    if command == "abort" then
        local txn = self.active
        if not txn or txn.id ~= request.txn_id or txn.decided then
            return hotupgrade_result.failure("HU_ABORT_NOT_SAFE", "事务不存在或已有目标越过发布决定")
        end

        txn.cancelled = true
        return hotupgrade_result.success()
    end

    return hotupgrade_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
