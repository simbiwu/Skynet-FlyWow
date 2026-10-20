--- 唯一控制面：冻结 Patch 并串行协调现存目标；只保存进程内状态。
local skynet = require "skynet"
require "skynet.manager"
local hotupgrade_native = require "flywow_hotupgrade_native"
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"

-- 与 Native 扫描器上限保持一致：单文件 2 MiB、一次 Patch 累计 16 MiB。
local MAX_FILE_BYTES = 2 * 1024 * 1024
local MAX_PATCH_BYTES = 16 * 1024 * 1024

local M = {}

-- Controller 实例共享此方法表；各实例的登记、活动批次和资源状态保存在实例表中。
local Controller = {}
Controller.__index = Controller

-- Native 以第二返回值携带稳定 HU_ 错误；兼容历史上的裸字符串错误值。
local function native_code(value)
    if type(value) == "table" then
        return value.code or "HU_NATIVE_ERROR"
    end

    return value or "HU_NATIVE_ERROR"
end

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

-- 递归扫描选定 Patch 目录，检查语法并冻结同一批次的全部源码。
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

---@class FlyWowHotUpgradeTargetMetadata
---@field service_module string 由现存 Service 声明，匹配配置 service_dir 下的相对路径
---@field creation_id? string 内部引导交付的创建标识；原生返回前登记时用它关联真实来源
---@field modules string[] 当前 State 已声明模块的唯一名称数组
---@field service_patch boolean 是否在本 State 提供私有状态及函数更新入口

---@class FlyWowHotUpgradeControlRequest
---@field batch_id string Controller handle 与本进程递增序号组成；仅在该 Controller 生命周期有效
---@field sequence integer 当前批次严格递增的序号，目标用来拒绝迟到消息
---@field timeout_ms integer prepare 等待 Guard 排空的毫秒上限，不代表远端操作取消
---@field modules? table[] stage 使用的 name/source 完整模块数组；不含业务对象
---@field service_source? string stage 使用的可选一次性 Service 脚本源码

---@class FlyWowHotUpgradeManagementRequest
---@field path? string validate/apply/dry_run 的 Patch Root 相对目录
---@field batch_id? string status/abort 指定的升级批次身份

---@class FlyWowHotUpgradeLifecycleStatus
---@field pending_creations integer 原生创建或首次登记尚未完成的记录数
---@field pending_module_loads integer 已授权、尚未登记或取消的模块加载数
---@field active_batch_id? string 当前活动批次；没有活动批次时为 nil
---@field recovery_required boolean 未确认恢复时关闭后续发布

---@class FlyWowHotUpgradeControllerConfig
---@field patch_root string 已存在且由宿主管理的受信 Patch 根目录
---@field root_path string 宿主项目根目录；模块登记名由其相对文件路径生成
---@field service_dir string root_path 下的相对 Service 目录，其下 Lua 文件作为一次性 Service 更新脚本
---@field timeout_ms? integer Guard 排空上限；默认值见 hotupgrade_common.DEFAULT_TIMEOUT_MS，不是 RPC 取消期限

--- 创建控制面；不读取持久化历史，不尝试恢复上一进程的批次。
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

    local timeout_ms = controller_config.timeout_ms or hotupgrade_common.DEFAULT_TIMEOUT_MS
    return hotupgrade_result.success({controller = setmetatable(
    {
        root              = root,                          -- 固定使用已解析的受信 Patch 根目录，不随批次改变。
        service_dir       = controller_config.service_dir, -- Patch 中仅此目录及其子目录按 Service 脚本处理。
        timeout_ms        = timeout_ms,                    -- Guard 排空期限，单位毫秒；默认值见 hotupgrade_common.DEFAULT_TIMEOUT_MS。
        target_count      = 0,                             -- 当前 Controller 生命周期内成功登记的目标数量，用于容量检查。
        targets           = {},                            -- 以真实 Service handle 为键，保存其模块声明和 Service 更新能力。
        creation_sequence = 0,                             -- 本 Controller 内递增且不复用的创建身份序号。
        pending_creations = {},                            -- 创建协程拥有的记录；原生启动返回且登记完成后才移除。
        creation_handles  = {},                            -- 真实 handle 到待创建记录的索引，不用名称或延迟关联。
        creation_count    = 0,                             -- 尚未完成原生创建或首次登记的操作数。
        module_loads      = {},                            -- 许可 ID 到来源 Service/模块名的记录，登记或取消时释放。
        module_load_count = 0,                             -- 首次加载关键区间的在途许可数。
        module_sequence   = 0,                             -- 本 Controller 内不复用的许可序号，拒绝重复消费。
        sequence          = 0,                             -- 当前 Controller 生命周期内递增的批次序号，用于拒绝迟到控制消息。
        active            = nil,                           -- 唯一活动批次；有值时拒绝启动另一个 apply 或 dry_run。
        last              = nil,                           -- 最近结束的批次结果；更早批次不保留，查询返回缺失。
        recovery_required = false,                         -- 恢复结果未确认时关闭后续发布，需先由宿主处理恢复。
    }, Controller)})
end

-- 移除同一条创建记录；创建失败、登记完成和创建者取消共用此释放路径。
function Controller:finish_creation(creation)
    if self.pending_creations[creation.creation_id] == creation then
        self.pending_creations[creation.creation_id] = nil
        if creation.handle then
            self.creation_handles[creation.handle] = nil
        end
        self.creation_count = self.creation_count - 1
    end
end

-- 原生启动失败时，早到登记及其后续许可都属于已终止的启动，必须一起撤销。
function Controller:remove_failed_creation(creation)
    if creation.handle and self.targets[creation.handle] then
        for permit_id, permit in pairs(self.module_loads) do
            if permit.source == creation.handle then
                self.module_loads[permit_id] = nil
                self.module_load_count = self.module_load_count - 1
            end
        end
        self.targets[creation.handle] = nil
        self.target_count = self.target_count - 1
    end
    self:finish_creation(creation)
end

---@class FlyWowHotUpgradeServiceCreationRequest
---@field service_name string 原生 Service 入口，不改写调用方业务初始化参数
---@field arguments table 带 n 的启动参数数组；按原生 newservice 约束传递

--- 受管理 Service 的启动入口；参数原样转交原生 newservice，不接管业务 init。
--- 原生调用会 yield；返回 handle 后仍未登记的 Service 继续持有屏障。
---@param request FlyWowHotUpgradeServiceCreationRequest
---@param source integer 创建者的真实消息来源
---@return FlyWowHotUpgradeResult 成功含 handle
function Controller:newservice(request, source)
    if self.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "活动发布期间不能创建受管理 Service")
    end

    if math.type(source) ~= "integer" or source <= 0 or type(request.service_name) ~= "string"
        or not request.service_name:match("^%S+$") or request.service_name == "flywow_hotupgrade_bootstrap"
        or type(request.arguments) ~= "table"
        or math.type(request.arguments.n) ~= "integer" or request.arguments.n < 0 then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "需要创建者、Service 名和启动参数")
    end

    if self.target_count + self.creation_count >= hotupgrade_common.MAX_TARGETS then
        return hotupgrade_result.failure("HU_TARGET_LIMIT", "登记目标及待创建 Service 已达上限")
    end

    self.creation_sequence = self.creation_sequence + 1
    local creation_id = tostring(skynet.self()) .. ":creation:" .. self.creation_sequence
    local creation =
    {
        creation_id = creation_id, -- 仅引导携带的进程内创建标识。
        owner       = source,      -- 只有原创建者可以取消返回后尚未登记的 Service。
        handle      = nil,         -- 登记早到时从消息头绑定，原生返回后再次确认相同身份。
        returned    = false,       -- 登记早于原生返回时仍保持屏障，覆盖后续启动代码。
    }
    self.pending_creations[creation.creation_id] = creation
    self.creation_count = self.creation_count + 1
    local ok, handle = pcall(skynet.newservice, "flywow_hotupgrade_bootstrap",
        skynet.self(), creation.creation_id, request.service_name,
        table.unpack(request.arguments, 1, request.arguments.n))
    if not ok or math.type(handle) ~= "integer" or handle <= 0 then
        self:remove_failed_creation(creation)
        return hotupgrade_result.failure("HU_SERVICE_CREATE_FAILED", tostring(handle))
    end

    if creation.handle and creation.handle ~= handle then
        -- 身份串用属于启动错误：仅终止本次原生创建出的 Service，不能误杀登记消息来源。
        skynet.kill(handle)
        self:remove_failed_creation(creation)
        return hotupgrade_result.failure("HU_CREATION_HANDLE_MISMATCH", "登记来源与原生创建 handle 不一致")
    end
    creation.handle = handle
    creation.returned = true
    self.creation_handles[handle] = creation
    if self.targets[handle] then
        self:finish_creation(creation)
    end
    return hotupgrade_result.success({handle = handle})
end

--- 创建者在业务初始化失败后显式终止尚未登记的 Service；不自动超时清理。
---@param request {handle:integer} 原生创建返回的待登记 Service
---@param source integer 创建者的真实来源
---@return FlyWowHotUpgradeResult
function Controller:cancel_service_creation(request, source)
    if math.type(request.handle) ~= "integer" then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "需要待登记 Service handle")
    end

    local creation = self.creation_handles[request.handle]
    if self.targets[request.handle] then
        return hotupgrade_result.failure("HU_SERVICE_ALREADY_REGISTERED", "已登记 Service 不能取消创建")
    end
    if not creation or not creation.returned then
        return hotupgrade_result.failure("HU_CREATION_MISSING", "没有可取消的待登记 Service")
    end
    if creation.owner ~= source then
        return hotupgrade_result.failure("HU_UNAUTHORIZED", "只有创建者可以取消该 Service")
    end

    local ok, message = pcall(skynet.kill, request.handle)
    if not ok then
        return hotupgrade_result.failure("HU_SERVICE_CANCEL_FAILED", tostring(message))
    end
    self:finish_creation(creation)
    return hotupgrade_result.success()
end

---@class FlyWowHotUpgradeModuleLoadRequest
---@field name string 模块的规范文件登记名，必须与许可绑定名称一致
---@field permit_id? string begin 返回的不复用 ID；完成或取消命令必须携带

--- 已登记 Service 在实际执行首次 require 前取得许可；许可覆盖本地状态建立与登记 RPC。
---@param request FlyWowHotUpgradeModuleLoadRequest
---@param source integer 已登记 Service 的真实消息来源
---@return FlyWowHotUpgradeResult 成功含 permit_id
function Controller:begin_module_load(request, source)
    if self.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "活动发布期间不能首次加载模块")
    end

    local target = self.targets[source]
    if not target then
        return hotupgrade_result.failure("HU_SERVICE_NOT_REGISTERED", "模块加载者未登记")
    end
    if type(request.name) ~= "string" or request.name == "" then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "模块名无效")
    end
    if target.loading_modules[request.name] then
        return hotupgrade_result.failure("HU_MODULE_LOADING", "该模块已有未完成的加载许可")
    end
    if target.module_load_count >= hotupgrade_common.MAX_MODULES then
        return hotupgrade_result.failure("HU_MODULE_LIMIT", "目标待模块加载许可已达上限")
    end
    if not target.modules[request.name] and target.module_count >= hotupgrade_common.MAX_MODULES then
        return hotupgrade_result.failure("HU_MODULE_LIMIT", "目标模块已达上限")
    end

    self.module_sequence = self.module_sequence + 1
    local permit_id = tostring(skynet.self()) .. ":module:" .. self.module_sequence
    self.module_loads[permit_id] = {source = source, name = request.name}
    target.loading_modules[request.name] = permit_id
    target.module_load_count = target.module_load_count + 1
    self.module_load_count = self.module_load_count + 1
    return hotupgrade_result.success({permit_id = permit_id})
end

--- 完成或撤销许可；他人的许可和重复请求都不能消费记录。
---@param request FlyWowHotUpgradeModuleLoadRequest
---@param source integer 许可原申请者的真实来源
---@param cancel boolean true 仅释放许可，不声明模块
---@return FlyWowHotUpgradeResult
function Controller:complete_module_load(request, source, cancel)
    local permit = self.module_loads[request.permit_id]
    if not permit then
        return hotupgrade_result.failure("HU_MODULE_PERMIT_MISSING", "模块加载许可不存在或已消费")
    end
    if permit.source ~= source then
        return hotupgrade_result.failure("HU_UNAUTHORIZED", "模块加载许可来源不匹配")
    end
    if permit.name ~= request.name then
        return hotupgrade_result.failure("HU_MODULE_PERMIT_MISMATCH", "模块名与许可不匹配")
    end

    local target = self.targets[source]
    if not target then
        return hotupgrade_result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未登记")
    end
    if not cancel and not target.modules[request.name] then
        if target.module_count >= hotupgrade_common.MAX_MODULES then
            return hotupgrade_result.failure("HU_MODULE_LIMIT", "目标模块已达上限")
        end
        target.modules[request.name] = true
        target.module_count = target.module_count + 1
    end

    self.module_loads[request.permit_id] = nil
    target.loading_modules[request.name] = nil
    target.module_load_count = target.module_load_count - 1
    self.module_load_count = self.module_load_count - 1
    return hotupgrade_result.success()
end

---@param request FlyWowHotUpgradeTargetMetadata
---@param source integer Skynet 消息头中的真实 Service handle
---@return FlyWowHotUpgradeResult
function Controller:register(request, source)
    if math.type(source) ~= "integer" or type(request.service_module) ~= "string"
        or not request.service_module:match("^[%w_.%-]+$") or type(request.modules) ~= "table"
        or type(request.service_patch) ~= "boolean" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "登记元数据无效")
    end

    if self.targets[source] then
        return hotupgrade_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
    end

    if self.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "活动发布期间不能登记新 Service")
    end

    local creation = self.creation_handles[source] or self.pending_creations[request.creation_id]
    if not creation or self.pending_creations[creation.creation_id] ~= creation
        or (creation.handle and creation.handle ~= source)
        or (request.creation_id and request.creation_id ~= creation.creation_id) then
        return hotupgrade_result.failure("HU_CREATION_MISSING", "来源不是受管理入口创建的待登记 Service")
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

    -- 原生返回前通过创建身份找到记录，但目标始终使用消息头中的真实 source。
    creation.handle = source
    self.creation_handles[source] = creation
    self.target_count = self.target_count + 1
    self.targets[source] =
    {
        handle            = source,                 -- Skynet 提供的真实来源，也是后续控制目标。
        service_module    = request.service_module, -- 匹配配置 service_dir 下的相对路径。
        module_count      = #request.modules,       -- 已登记声明数，用于拒绝无界增长。
        modules           = modules,                -- 该 State 明确声明的可更新模块集合。
        loading_modules   = {},                     -- 同一 Service/模块同时只允许一项首次加载操作。
        module_load_count = 0,                      -- 此目标在途许可数，受 MAX_MODULES 限制。
        service_patch     = request.service_patch,  -- 是否提供本地 Service 状态/函数入口。
    }
    if creation.returned then
        self:finish_creation(creation)
    end
    return hotupgrade_result.success()
end

--- 冻结文件并生成目标快照；不执行 Patch 代码、不读其他 Service Lua State。
function Controller:load(request)
    if self.creation_count > 0 or self.module_load_count > 0 then
        return hotupgrade_result.failure("HU_LIFECYCLE_PENDING",
            "生命周期未完成：待创建/登记 " .. self.creation_count .. "，待模块加载/登记 " .. self.module_load_count)
    end

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

    -- 按已登记模块和 Service 模块建立目标快照，之后再检查每个文件均已匹配。
    local targets = {}
    local matched = {} -- 仅当前登记快照覆盖的 Patch 文件；全量匹配后才允许启动批次。
    for _, record in pairs(self.targets) do
        local modules = {}
        for _, entry in ipairs(loaded.patch.modules) do
            if record.modules[entry.name] then
                modules[#modules + 1] = entry
                matched[entry.entry_file] = true
            end
        end

        local service = loaded.patch.services[record.service_module]
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

    for service_module, entry in pairs(loaded.patch.services) do
        if not matched[entry.entry_file] then
            return hotupgrade_result.failure("HU_TARGET_MISSING", request.path .. "/" .. entry.entry_file
                .. ": 没有已登记目标匹配 service_module " .. service_module)
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
function Controller:step(batch, target, command)
    ---@type FlyWowHotUpgradeControlRequest
    local request =
    {
        batch_id = batch.batch_id,
        sequence = batch.sequence,
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

function Controller:run_target(batch, target, dry_run)
    for _, command in ipairs({"prepare", "stage", "activate"}) do
        batch.phase = command:upper()
        local answer = self:step(batch, target, command)
        if not answer.ok or batch.cancelled then
            local restored = self:step(batch, target, "abort")
            if not restored.ok then
                return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", restored.message, command)
            end

            if batch.cancelled then
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
        local restored = self:step(batch, target, "abort")
        return restored.ok and restored or hotupgrade_result.failure("HU_RECOVERY_REQUIRED", restored.message, "abort")
    end

    -- 当前目标已同步提交；发布决定后 finish 结果不明不能伪称已恢复。
    batch.phase = "PUBLISH_DECIDED"
    batch.decided = true
    target.decided = true
    local finished = self:step(batch, target, "finish")
    if not finished.ok then
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", finished.message, "finish")
    end

    return hotupgrade_result.success()
end

function Controller:run(batch, dry_run)
    for _, target in ipairs(batch.targets) do
        batch.current_handle = target.handle
        local ok, answer = pcall(self.run_target, self, batch, target, dry_run)
        if not ok then
            local restored = not target.decided and self:step(batch, target, "abort")
            answer = hotupgrade_result.failure(restored and restored.ok and "HU_CONTROL_FAILED" or "HU_RECOVERY_REQUIRED",
                tostring(answer))
        end

        batch.results[#batch.results + 1] = {handle = target.handle, hotupgrade_result = answer}
        if not answer.ok then
            batch.failed = batch.failed + 1
            batch.error = answer
            if answer.code == "HU_RECOVERY_REQUIRED" then
                batch.phase = "RECOVERY_REQUIRED"
                self.recovery_required = true
            else
                batch.phase = batch.success > 0 and "PARTIAL" or "ABORTED"
            end
            break
        end

        batch.success = batch.success + 1
    end

    if not batch.error then
        batch.phase = dry_run and "DRY_RUN_COMPLETED" or "COMPLETED"
    end
    -- 终态只保留有界结果，不继续持有冻结源码或目标运行时快照。
    batch.targets = nil
    self.last = batch
    self.active = nil
end

--- 异步推进，立即返回 batch_id；一次仅执行一个发布，status 查询进程内状态。
function Controller:apply(request, dry_run)
    if self.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "已有活动发布")
    end

    local loaded = self:load(request)
    if not loaded.ok then
        return loaded
    end

    self.sequence = self.sequence + 1
    local batch =
    {
        batch_id = tostring(skynet.self()) .. ":" .. self.sequence,
        sequence = self.sequence,
        phase = "PREPARING",
        targets = loaded.targets,
        target_count = #loaded.targets,
        results = {},
        success = 0,
        failed = 0,
    }
    self.active = batch
    skynet.fork(function()
        self:run(batch, dry_run)
    end)
    return hotupgrade_result.success({batch_id = batch.batch_id, target_count = batch.target_count})
end

--- 管理命令不做远程认证；宿主掌握 Controller handle，登记来源由消息头确定。
---@param command string newservice/cancel_service_creation/register/begin_module_load/register_module/cancel_module_load/validate/apply/dry_run/status/abort
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

    if command == "newservice" then
        return self:newservice(request, source)
    end

    if command == "cancel_service_creation" then
        return self:cancel_service_creation(request, source)
    end

    if command == "begin_module_load" then
        return self:begin_module_load(request, source)
    end

    if command == "register_module" or command == "cancel_module_load" then
        return self:complete_module_load(request, source, command == "cancel_module_load")
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
        local lifecycle =
        {
            pending_creations = self.creation_count,
            pending_module_loads = self.module_load_count,
            active_batch_id = self.active and self.active.batch_id,
            recovery_required = self.recovery_required,
        }
        if request.batch_id == nil then
            return hotupgrade_result.success({lifecycle = lifecycle, recovery_required = self.recovery_required})
        end

        local batch = self.active and self.active.batch_id == request.batch_id and self.active or self.last
        if not batch or batch.batch_id ~= request.batch_id then
            return hotupgrade_result.failure("HU_BATCH_MISSING", "仅保留活动及最近终态批次")
        end

        return hotupgrade_result.success({record =
        {
            batch_id = batch.batch_id, phase = batch.phase, success = batch.success, failed = batch.failed,
            target_count = batch.target_count, current_handle = batch.current_handle,
            results = batch.results, error = batch.error,
        }, lifecycle = lifecycle, recovery_required = self.recovery_required})
    end

    if command == "abort" then
        local batch = self.active
        if not batch or batch.batch_id ~= request.batch_id or batch.decided then
            return hotupgrade_result.failure("HU_ABORT_NOT_SAFE", "批次不存在或已有目标越过发布决定")
        end

        batch.cancelled = true
        return hotupgrade_result.success()
    end

    return hotupgrade_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
