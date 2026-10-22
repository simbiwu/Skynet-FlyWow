--- 唯一控制面：冻结 Patch 并串行协调现存目标；只保存进程内状态。
local skynet = require "skynet"
require "skynet.manager"
local hotupgrade_native = require "flywow_hotupgrade_native"
local hotupgrade_result = require "flywow_hotupgrade_error"
local hotupgrade_common = require "flywow_hotupgrade_common"

local M =
{
    initialized          = nil, -- initialize 完整成功后设为 true；此前管理命令不可用。
    root_path            = nil, -- 已解析的宿主根目录；正式文件读取、替换和恢复共用此边界。
    patch_path           = nil, -- 已解析的受信 Patch 根目录；每个批次从此目录读取冻结源码。
    service_path         = nil, -- Patch 内按 Service 脚本分类的相对目录。
    targets              = nil, -- 以真实 Service handle 索引登记信息，供 Patch 匹配和批次快照使用。
    pending_creations    = nil, -- 尚未完成创建或首次登记的记录；完成后由 finish_creation 移除。
    creation_handles     = nil, -- 原生返回的真实 Service handle 到创建记录的索引，用于关联早到登记。
    registration_waiters = nil, -- 等待原生 Service handle 建立映射的登记协程；映射完成后唤醒。
    creation_count       = nil, -- 尚未完成原生创建或首次登记的数量；决定何时解除部署等待。
    module_loads         = nil, -- 许可 ID 到来源 Service/模块名的映射；登记或取消时移除。
    module_load_count    = nil, -- 正在执行首次加载与登记的许可数；决定何时解除部署等待。
    module_sequence      = nil, -- 本 Controller 内递增的许可序号，用来拒绝重复消费。
    sequence             = nil, -- 本 Controller 生命周期内递增的批次序号，用来拒绝迟到控制消息。
    -- Controller 阶段：IDLE -> WAITING_CREATIONS -> DEPLOYING -> APPLYING -> COMPLETED。
    -- 故障恢复成功后回到 IDLE；恢复未确认时进入 FAILED_LOCKED，显式确认后回到 IDLE。
    phase                = nil, -- Controller 生命周期/发布门禁；批次进度与结果另存于 active_batch.phase。
    lifecycle_waiters    = nil, -- 发布屏障期间等待创建或首次模块加载的协程，终态时统一唤醒。
    unique_services      = nil, -- 逻辑唯一 Service 名到在途结果/Service handle 的映射，仅限本 Controller。
    active_batch         = nil, -- 当前唯一活动批次；批次结束后移入 last_batch。
    last_batch           = nil, -- 最近结束批次的结果；更早批次不保留。
    recovery_required    = nil, -- 宿主文件或目标恢复未确认时阻止后续发布。
}

-- Native 失败时以第二返回值返回带 code 字段的错误对象。
local function native_code(native_error)
    if type(native_error) == "table" then
        return native_error.code or "HU_NATIVE_ERROR"
    end

    return "HU_NATIVE_ERROR"
end

-- 宿主根目录相对 Lua 路径对应 Controller 使用的唯一模块登记名。
local function module_name(relative_path)
    if relative_path:sub(-4) ~= ".lua" or relative_path:find("\\", 1, true) then
        return nil
    end

    return relative_path:sub(1, -5):gsub("/", ".")
end

-- 递归扫描选定 Patch 目录，检查语法并冻结同一批次的全部源码。
local function load_files(patch_base_path, selected_patch_path, patch_identity)
    -- 先递归枚举所选目录并确认扫描结果，再读取源码。
    local paths, code = hotupgrade_native.list_lua(patch_base_path, selected_patch_path)
    code = native_code(code)
    if not paths and code == "HU_PATCH_EMPTY" then
        return hotupgrade_result.success({entries = {}})
    end

    if not paths then
        return hotupgrade_result.failure(code, "Patch 目录扫描失败: " .. selected_patch_path)
    end

    -- 固定路径顺序后逐个读取并编译源码，形成供本批复用的冻结清单。
    table.sort(paths)

    local entries = {}
    for _, relative in ipairs(paths) do
        local source, failure = hotupgrade_native.read_file(patch_base_path, selected_patch_path .. "/" .. relative)
        if source == nil or source == false then
            return hotupgrade_result.failure(source == false and "HU_FILE_NOT_FOUND" or native_code(failure),
                "发布包读取失败: " .. selected_patch_path .. "/" .. relative)
        end
        -- load 只编译并检查语法，不执行返回的 chunk；失败时 syntax_error 用于诊断。
        -- @路径标记错误中的文件名，t 只接受文本源码，最后的空表是 chunk 的运行环境。
        local chunk, syntax_error = load(source, "@" .. relative, "t", {})
        if not chunk then
            return hotupgrade_result.failure("HU_MODULE_SYNTAX", syntax_error)
        end
        entries[#entries + 1] = {file = relative, source = source}
        patch_identity[#patch_identity + 1] = relative
    end

    return hotupgrade_result.success({entries = entries})
end

-- 汇总模块与 Service 文件；Patch 身份仅由路径和文件名组成。
local function build_patch(patch_base_path, selected_patch_path, service_path)
    local patch_identity = {}        -- 当前 Patch 的路径身份字段，不是内容 hash。
    -- 所有文件先完成扫描、读取和语法检查；后续只分类这份冻结清单。
    local loaded_files = load_files(patch_base_path, selected_patch_path, patch_identity)
    if not loaded_files.ok then
        return loaded_files
    end

    local modules         = {}                 -- 按规范模块名归集普通 .lua，供已登记目标更新。
    local service_patches = {}                 -- service_path 下的 Service .patch，按 Service 名索引；不含 Service .lua。
    local files           = {}                 -- 冻结的完整 .lua，正式发布时部署；不含 .patch。
    local service_prefix  = service_path .. "/" -- 此目录下的 .lua 仅部署，.patch 才匹配 Service。
    for _, entry in ipairs(loaded_files.entries) do
        local is_service = entry.file:sub(1, #service_prefix) == service_prefix
        local is_patch = entry.file:sub(-6) == ".patch"
        if is_patch and not is_service then
            return hotupgrade_result.failure("HU_INVALID_PATCH", ".patch 只能位于 service_path: " .. entry.file)
        end

        if is_patch then
            local name = entry.file:sub(#service_prefix + 1, -7):gsub("/", ".")
            if name == "" or not name:match("^[%w_.%-]+$") or service_patches[name] then
                return hotupgrade_result.failure("HU_INVALID_PATCH", "Service 路径映射重复或无效: " .. entry.file)
            end
            service_patches[name] = {name = name, entry_file = entry.file, source = entry.source}
        else
            files[#files + 1] = {entry_file = entry.file, source = entry.source}
            if not is_service then
                local name = module_name(entry.file)
                if not name or name == "" or modules[name] then
                    return hotupgrade_result.failure("HU_INVALID_PATCH", "Lua 路径映射重复或无效: " .. entry.file)
                end
                modules[name] = {name = name, entry_file = entry.file, source = entry.source}
            end
        end
    end

    if #files == 0 and next(service_patches) == nil then
        return hotupgrade_result.failure("HU_PATCH_EMPTY", "发布包至少要有一个 .lua 或 Service .patch")
    end

    -- 按相对路径生成稳定身份，避免 Native 返回顺序影响同一 Patch 的标识。
    table.sort(patch_identity)
    local identity_parts = {tostring(#selected_patch_path) .. ":" .. selected_patch_path}
    for _, entry in ipairs(patch_identity) do
        identity_parts[#identity_parts + 1] = tostring(#entry) .. ":" .. entry
    end

    local patch = {patch_id = table.concat(identity_parts),
        modules = {}, service_patches = service_patches, files = files}
    for _, module in pairs(modules) do
        patch.modules[#patch.modules + 1] = module
    end

    table.sort(patch.modules, function(left, right)
        return left.name < right.name
    end)
    return hotupgrade_result.success({patch = patch})
end

---@class FlyWowHotUpgradeTargetMetadata
---@field modules string[] 当前 State 已声明模块的唯一名称数组
---@field has_service_update boolean 是否在本 State 提供私有状态及函数更新入口

---@class FlyWowHotUpgradeRegisteredService
---@field service_handle integer register 消息头中的真实 source；作为登记索引和热更 RPC 接收者
---@field service_name string Skynet Service 入口名，用于匹配 Service Patch
---@field modules table<string, boolean> 当前 Lua State 声明的完整模块名集合
---@field loading_modules table<string, boolean> 正在首次加载的模块；并发许可期间阻止重复加载
---@field has_service_update boolean 是否提供 Service 私有状态/函数更新入口

---@class FlyWowHotUpgradeBatchTarget
---@field service_handle integer 从登记记录复制的业务 Service handle；当前热更 RPC 的接收者
---@field modules table[] 本批匹配到的完整模块 Patch
---@field service_source? string 本批 Service Patch 的冻结源码
---@field service_entry_file? string 本批 Service Patch 的相对路径，用于错误诊断
---@field participated? boolean 是否已进入本批控制流程，决定失败时是否发送 Abort
---@field result? FlyWowHotUpgradeResult 该目标最近一次 Prepare/Update/Finish/Abort 结果

---@class FlyWowHotUpgradeBatchTargetResult
---@field service_handle integer 本批结果所属业务 Service 的真实 handle
---@field hotupgrade_result FlyWowHotUpgradeResult 该目标的事务结果

---@class FlyWowHotUpgradeBatchStatus
---@field batch_id string 本批唯一身份
---@field phase string 本批最终或当前阶段
---@field success integer 成功目标数
---@field failed integer 失败目标数
---@field target_count integer 本批目标数
---@field current_service_handle? integer status 查询时当前或最近一次处理的业务 Service handle
---@field results FlyWowHotUpgradeBatchTargetResult[] 各业务 Service 的处理结果
---@field error? FlyWowHotUpgradeResult 本批失败诊断
---@field resolved? boolean 宿主是否确认完成部署恢复
---@field control_started boolean 是否已向目标发送控制命令

---@class FlyWowHotUpgradeBatch
---@field batch_id string 本批唯一身份
---@field sequence integer Controller 生命周期内递增的本批序号
---@field phase string 本批当前阶段及终态
---@field results FlyWowHotUpgradeBatchTargetResult[] 按目标记录的本批结果
---@field targets FlyWowHotUpgradeBatchTarget[] 当前批次冻结的目标快照
---@field files? table[] 本批冻结的宿主文件及恢复快照
---@field success integer 成功目标数
---@field failed integer 失败目标数
---@field target_count integer 本批目标数
---@field current_service_handle? integer 当前或最近一次处理的业务 Service handle；status 对外返回此值
---@field waiter? thread 等待创建/登记屏障或显式恢复确认的协程
---@field cancelled? boolean 管理端是否请求在安全点终止本批
---@field error? FlyWowHotUpgradeResult 本批首个失败或恢复失败结果
---@field control_started? boolean 是否已向任一目标发送控制命令，决定恢复确认条件
---@field decided? boolean 是否已越过发布决定；此后 Finish 失败不回滚
---@field resolved? boolean 宿主是否已显式确认完成部署恢复

---@class FlyWowHotUpgradeControlRequest
---@field batch_id string Controller Service handle 与本进程递增序号组成；仅在该 Controller 生命周期有效
---@field sequence integer 当前批次严格递增的序号，目标用来拒绝迟到消息
---@field modules? table[] Controller 按目标登记集合筛选、按模块名排序的 name/source 模块数组；不含业务对象
---@field service_source? string update 使用的可选一次性 Service 脚本源码

---@class FlyWowHotUpgradeManagementRequest
---@field path? string begin 的 Patch Root 相对目录
---@field batch_id? string status/abort/resolve_deployment 使用 begin 返回的身份
---@field confirmed? boolean 宿主明确确认恢复完成
---@field confirmation? string UNCHANGED 或 CONVERGED_CACHE_CLEARED

---@class FlyWowHotUpgradeLifecycleStatus
---@field phase string IDLE/WAITING_CREATIONS/DEPLOYING/APPLYING/COMPLETED/FAILED_LOCKED
---@field batch_id? string 当前或最近批次
---@field failed_locked boolean 是否因失败锁定版本门禁
---@field pending_creations integer 原生创建或首次登记尚未完成的记录数
---@field pending_module_loads integer 已授权、尚未登记或取消的模块加载数
---@field active_batch_id? string 当前活动批次；没有活动批次时为 nil
---@field recovery_required boolean 未确认恢复时关闭后续发布

---@class FlyWowHotUpgradeControllerConfig
---@field patch_path string 已存在且由宿主管理的受信 Patch 根目录
---@field root_path string 宿主项目根目录；模块登记名由其相对文件路径生成
---@field service_path string root_path 下的相对 Service 目录；.lua 完整部署，.patch 匹配现存实例

--- 初始化唯一控制面；不读取持久化历史，不尝试恢复上一进程的批次。
---@param controller_config FlyWowHotUpgradeControllerConfig
---@return FlyWowHotUpgradeResult 初始化结果
function M.initialize(controller_config)
    -- 先校验配置并解析全部路径；任一步失败都不发布部分运行状态。
    if type(controller_config) ~= "table" or type(controller_config.patch_path) ~= "string" or controller_config.patch_path == ""
        or type(controller_config.root_path) ~= "string" or controller_config.root_path == ""
        or type(controller_config.service_path) ~= "string" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "需要 patch_path、root_path、service_path")
    end

    local patch_path, code = hotupgrade_native.resolve(controller_config.patch_path .. "/.")
    if not patch_path then
        return hotupgrade_result.failure(native_code(code), "Patch 根目录不可用")
    end

    local root_path, root_error = hotupgrade_native.resolve(controller_config.root_path .. "/.")
    if not root_path then
        return hotupgrade_result.failure(native_code(root_error), "宿主项目根目录不可用")
    end

    local resolved_service_path, service_error = hotupgrade_native.resolve(root_path, controller_config.service_path)
    if not resolved_service_path then
        return hotupgrade_result.failure(native_code(service_error), "Service 相对目录无效: " .. controller_config.service_path)
    end

    -- 只发布一份宿主根路径，业务 State 可在登记前通过 require 生成相同的文件身份。
    local published_root = skynet.getenv(hotupgrade_common.ROOT_PATH_ENV)
    if published_root and published_root ~= root_path then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "同一 Skynet 进程的 Controller 必须使用相同 root_path")
    end
    if M.initialized then
        return hotupgrade_result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
    end

    -- 校验成功后构造初始化候选；提交前模块表的长期状态字段保持 nil。
    local initialized_state =
    {
        root_path            = root_path,
        patch_path           = patch_path,
        service_path         = controller_config.service_path,
        targets              = {},
        pending_creations    = {},
        creation_handles     = {},
        registration_waiters = {},
        creation_count       = 0,
        module_loads         = {},
        module_load_count    = 0,
        module_sequence      = 0,
        sequence             = 0,
        phase                = "IDLE",
        lifecycle_waiters    = {},
        unique_services      = {},
        active_batch         = nil,
        last_batch           = nil,
        recovery_required    = false,
    }

    if not published_root then
        skynet.setenv(hotupgrade_common.ROOT_PATH_ENV, root_path)
    end

    -- 校验和路径解析全部成功后才发布运行状态，失败不会留下半初始化控制面。
    for name, value in pairs(initialized_state) do
        M[name] = value
    end
    M.initialized = true
    return hotupgrade_result.success()
end

-- 移除同一条创建记录；创建失败、登记完成和创建者取消共用此释放路径。
function M:finish_creation(creation)
    if self.pending_creations[creation] == creation then
        self.pending_creations[creation] = nil
        if creation.service_handle then
            self.creation_handles[creation.service_handle] = nil
        end
        self.creation_count = self.creation_count - 1
        self:advance_deployment()
        self:wake_registration()
    end
end

-- 映射和计数先更新，再唤醒登记协程；唤醒不代表已匹配成功。
function M:wake_registration()
    for waiter in pairs(self.registration_waiters) do
        skynet.wakeup(waiter)
    end
end

---@class FlyWowHotUpgradeServiceCreationRequest
---@field service_name string 原生 Service 入口，不改写调用方业务初始化参数
---@field arguments table 带 n 的启动参数数组；按原生 newservice 约束传递
---@field global? boolean true 明确拒绝；不支持跨节点全局唯一

--- 等待发布门禁；只有成功终态或显式恢复确认后重新检查接纳条件。
--- 等待中的请求不计入在途创建/许可，避免阻塞当前批次排空。
function M:wait_lifecycle()
    while self.phase == "WAITING_CREATIONS" or self.phase == "DEPLOYING" or self.phase == "APPLYING" do
        local waiter = coroutine.running()
        local waiting = {}
        self.lifecycle_waiters[waiter] = waiting
        skynet.wait(waiter)
        self.lifecycle_waiters[waiter] = nil
        if waiting.blocked then
            return hotupgrade_result.failure("HU_DEPLOYMENT_BLOCKED", "等待期间发布失败，操作未开始")
        end
    end
    if self.phase == "FAILED_LOCKED" then
        return hotupgrade_result.failure("HU_DEPLOYMENT_BLOCKED", "发布失败，须显式确认版本恢复一致")
    end
    return hotupgrade_result.success()
end

local function valid_service_creation_request(request, source)
    return math.type(source) == "integer" and source > 0 and type(request.service_name) == "string"
        and request.service_name:match("^[%w_.%-]+$") and type(request.arguments) == "table"
        and math.type(request.arguments.n) == "integer" and request.arguments.n >= 0
        and (request.global == nil or type(request.global) == "boolean")
end

--- 已校验请求的共同创建过程；原生调用可能 yield，返回 handle 后仍持有登记屏障。
---@param request FlyWowHotUpgradeServiceCreationRequest 已校验的创建请求
---@param source integer 已校验的真实创建者来源
---@param unique_name? string 仅本地唯一入口在内部传入的逻辑预留名
---@return FlyWowHotUpgradeResult 成功时包含 service_handle
local function start_service(self, request, source, unique_name)
    local admitted = self:wait_lifecycle()
    if not admitted.ok then
        return admitted
    end

    local creation =
    {
        owner           = source,                -- 原创建者拥有返回后未登记 Service 的取消权。
        service_name    = request.service_name,  -- Patch 匹配使用的原生 Service 入口名。
        service_handle  = nil,                   -- 仅由原生返回值建立真实来源索引。
        unique_name     = unique_name,            -- 本地唯一预留名，不改变其既有语义。
        returned        = false,                  -- 原生返回前，早到登记只能让出执行权等待。
    }
    self.pending_creations[creation] = creation
    self.creation_count = self.creation_count + 1

    -- 打包参数的 n 保留包括中间 nil 在内的完整签名；启动行约束仍由原生 Skynet 决定。
    local ok, service_handle = pcall(function()
        return skynet.newservice(request.service_name,
            table.unpack(request.arguments, 1, request.arguments.n))
    end)
    if not ok or math.type(service_handle) ~= "integer" or service_handle <= 0 then
        self:finish_creation(creation)
        return hotupgrade_result.failure("HU_SERVICE_CREATE_FAILED", tostring(service_handle))
    end

    creation.service_handle = service_handle
    self.creation_handles[service_handle] = creation
    creation.returned = true
    self:wake_registration()
    return hotupgrade_result.success({service_handle = service_handle})
end

--- 只协调本 Controller 内的逻辑唯一名，不调用原生唯一服务管理器。
--- 在途重复请求等待同一创建结果；失败释放预留，既有 handle 在发布期间也可直接返回。
---@param request FlyWowHotUpgradeServiceCreationRequest
---@param source integer 原请求者的真实消息来源；仅首次创建者拥有取消权
---@return FlyWowHotUpgradeResult 成功时包含 service_handle；全局和特殊启动合同明确拒绝
function M:uniqueservice(request, source)
    -- 先验证唯一创建合同，再决定复用现有实例、等待在途创建或发起新创建。
    if request.global == true then
        return hotupgrade_result.failure("HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED", "受管理唯一服务只支持本 Controller 内的本地唯一")
    end

    if not valid_service_creation_request(request, source) then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "需要创建者、逻辑 Service 名和完整启动参数")
    end

    if request.service_name == "snaxd" then
        return hotupgrade_result.failure("HU_SPECIAL_SERVICE_UNSUPPORTED", "snaxd 不满足受管理 Service 自行调用 register_service 的登记合同")
    end

    local unique = self.unique_services[request.service_name]
    if unique then
        if unique.service_handle then
            return hotupgrade_result.success({service_handle = unique.service_handle})
        end
        if self.phase == "FAILED_LOCKED" then
            return hotupgrade_result.failure("HU_DEPLOYMENT_BLOCKED", "发布失败，唯一创建请求未开始")
        end
        local waiter = coroutine.running()
        unique.waiters[waiter] = true
        skynet.wait(waiter)
        unique.waiters[waiter] = nil
        return unique.error or hotupgrade_result.success({service_handle = unique.service_handle})
    end

    unique = {waiters = {}}
    self.unique_services[request.service_name] = unique
    local ok, answer = pcall(start_service, self, request, source, request.service_name)
    if not ok then
        answer = hotupgrade_result.failure("HU_SERVICE_CREATE_FAILED", tostring(answer))
    end
    if answer.ok then
        unique.service_handle = answer.service_handle
    else
        unique.error = answer
        if self.unique_services[request.service_name] == unique then
            self.unique_services[request.service_name] = nil
        end
    end
    for waiter in pairs(unique.waiters) do
        skynet.wakeup(waiter)
    end
    return answer
end

--- Controller 命令入口：校验请求后创建普通 Service。
---@param request FlyWowHotUpgradeServiceCreationRequest
---@param source integer 创建者的真实消息来源
---@param unique_name? string 仅本地唯一入口在内部传入的逻辑预留名
---@return FlyWowHotUpgradeResult 成功时包含 service_handle
function M:newservice(request, source, unique_name)
    if not valid_service_creation_request(request, source) then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "需要创建者、Service 名和启动参数")
    end
    if request.service_name == "snaxd" then
        return hotupgrade_result.failure("HU_SPECIAL_SERVICE_UNSUPPORTED", "snaxd 不满足受管理 Service 自行调用 register_service 的登记合同")
    end

    return start_service(self, request, source, unique_name)
end

--- 创建者在业务初始化失败后显式终止尚未登记的 Service；不自动超时清理。
---@param request {service_handle:integer} 原生创建返回的待登记 Service
---@param source integer 创建者的真实来源
---@return FlyWowHotUpgradeResult
function M:cancel_service_creation(request, source)
    if math.type(request.service_handle) ~= "integer" then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "需要待登记 Service handle")
    end

    local creation = self.creation_handles[request.service_handle]
    if self.targets[request.service_handle] then
        return hotupgrade_result.failure("HU_SERVICE_ALREADY_REGISTERED", "已登记 Service 不能取消创建")
    end
    if not creation or not creation.returned then
        return hotupgrade_result.failure("HU_CREATION_MISSING", "没有可取消的待登记 Service")
    end
    if creation.owner ~= source then
        return hotupgrade_result.failure("HU_UNAUTHORIZED", "只有创建者可以取消该 Service")
    end

    local ok, message = pcall(skynet.kill, request.service_handle)
    if not ok then
        return hotupgrade_result.failure("HU_SERVICE_CANCEL_FAILED", tostring(message))
    end
    if creation.unique_name then
        local unique = self.unique_services[creation.unique_name]
        if unique and unique.service_handle == request.service_handle then
            self.unique_services[creation.unique_name] = nil
        end
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
function M:begin_module_load(request, source)
    local admitted = self:wait_lifecycle()
    if not admitted.ok then
        return admitted
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

    self.module_sequence = self.module_sequence + 1
    local permit_id = tostring(skynet.self()) .. ":module:" .. self.module_sequence
    self.module_loads[permit_id] = {source = source, name = request.name}
    target.loading_modules[request.name] = permit_id
    self.module_load_count = self.module_load_count + 1
    return hotupgrade_result.success({permit_id = permit_id})
end

--- 完成或撤销许可；他人的许可和重复请求都不能消费记录。
---@param request FlyWowHotUpgradeModuleLoadRequest
---@param source integer 许可原申请者的真实来源
---@param cancel boolean true 仅释放许可，不声明模块
---@return FlyWowHotUpgradeResult
function M:complete_module_load(request, source, cancel)
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
        target.modules[request.name] = true
    end

    self.module_loads[request.permit_id] = nil
    target.loading_modules[request.name] = nil
    self.module_load_count = self.module_load_count - 1
    self:advance_deployment()
    return hotupgrade_result.success()
end

--- 早到登记会 yield，直至原生返回的 handle 与消息 source 精确匹配或全部原生创建结束。
---@param request FlyWowHotUpgradeTargetMetadata
---@param service_handle integer Skynet 消息头中的真实业务 Service handle；由受管理创建结果确认
---@return FlyWowHotUpgradeResult
function M:register(request, service_handle)
    -- 先校验登记元数据并构造模块集合，失败时不写入 Controller 目标表。
    if math.type(service_handle) ~= "integer" or type(request.modules) ~= "table"
        or type(request.has_service_update) ~= "boolean" then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "登记元数据无效")
    end
    if request.service_module ~= nil then
        return hotupgrade_result.failure("HU_INVALID_OPTIONS", "不再接受 service_module")
    end

    if self.targets[service_handle] then
        return hotupgrade_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
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

    -- 不猜测名称或创建顺序；原生调用返回前，登记必须让出执行权等待真实 handle。
    local creation = self.creation_handles[service_handle]
    while not creation do
        local native_pending = false
        for _, pending in pairs(self.pending_creations) do
            if not pending.returned then
                native_pending = true
                break
            end
        end
        if not native_pending then
            return hotupgrade_result.failure("HU_CREATION_MISSING", "来源不是受管理入口创建的待登记 Service")
        end

        local waiter = coroutine.running()
        self.registration_waiters[waiter] = true
        skynet.wait(waiter)
        self.registration_waiters[waiter] = nil
        if self.targets[service_handle] then
            return hotupgrade_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
        end
        creation = self.creation_handles[service_handle]
    end

    if self.phase == "DEPLOYING" or self.phase == "APPLYING" or self.phase == "FAILED_LOCKED" then
        return hotupgrade_result.failure("HU_DEPLOYMENT_BLOCKED", "当前阶段不能登记新 Service")
    end
    -- 绑定真实来源并提交登记；完成后释放创建屏障。
    ---@type FlyWowHotUpgradeRegisteredService
    local registered_service =
    {
        service_handle      = service_handle,                     -- register 消息头中的真实来源，也是后续热更 RPC 目标。
        service_name        = creation.service_name,       -- 来自该 handle 对应的受管理创建记录。
        modules             = modules,                    -- 该 State 明确声明的可更新模块集合。
        loading_modules     = {},                          -- 同一 Service/模块同时只允许一项首次加载操作。
        has_service_update  = request.has_service_update,  -- 是否提供本地 Service 状态/函数入口。
    }
    self.targets[service_handle] = registered_service
    self:finish_creation(creation)
    return hotupgrade_result.success()
end

--- 冻结文件并生成目标快照；不执行 Patch 代码、不读其他 Service Lua State。
function M:load_patch(request)
    -- 先确认生命周期与路径请求有效，再从冻结 Patch 构造目标快照；此阶段不发送事务 RPC。
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

    local loaded = build_patch(self.patch_path, request.path, self.service_path)
    if not loaded.ok then
        return loaded
    end

    -- 固定运行时接收者；只有一次性 Service .patch 强制要求目标存在。
    ---@type FlyWowHotUpgradeBatchTarget[]
    local targets = {} -- 本批需要执行原有更新协议的真实 Service。
    local matched = {} -- 当前登记快照已覆盖的 Service .patch 文件。
    ---@type table<integer, FlyWowHotUpgradeRegisteredService>
    local registered_services = self.targets
    for _, record in pairs(registered_services) do
        local modules = {}
        for _, entry in ipairs(loaded.patch.modules) do
            if record.modules[entry.name] then
                modules[#modules + 1] = entry
            end
        end

        local service = loaded.patch.service_patches[record.service_name]
        if service and not record.has_service_update then
            return hotupgrade_result.failure("HU_SERVICE_PATCH_UNSUPPORTED", request.path .. "/" .. service.entry_file
                .. ": 目标 " .. record.service_handle .. " 未提供 Service 内部更新入口")
        end

        if service then
            matched[service.entry_file] = true
        end

        if #modules > 0 or service then
            targets[#targets + 1] =
            {
                service_handle = record.service_handle,
                modules = modules,
                service_source = service and service.source,
                service_entry_file = service and service.entry_file,
            }
        end
    end
    -- 完整 .lua 无运行时接收者时只部署；一次性 .patch 必须匹配现存目标。
    for service_name, entry in pairs(loaded.patch.service_patches) do
        if not matched[entry.entry_file] then
            return hotupgrade_result.failure("HU_TARGET_MISSING", request.path .. "/" .. entry.entry_file
                .. ": 没有已登记目标匹配 Service 名称 " .. service_name)
        end
    end

    table.sort(targets, function(left, right)
        return left.service_handle < right.service_handle
    end)
    return hotupgrade_result.success({patch = loaded.patch, targets = targets})
end

--- 直接使用 Skynet 原生 call；失败不代表远端操作取消，协调方仍须明确恢复。
---@param batch FlyWowHotUpgradeBatch 当前 Controller 正在协调的批次
---@param target FlyWowHotUpgradeBatchTarget 本次 RPC 的目标快照，service_handle 来自 register 的 source
---@param command string 发送给目标的事务命令
function M:step(batch, target, command)
    ---@type FlyWowHotUpgradeControlRequest
    local request =
    {
        batch_id = batch.batch_id,
        sequence = batch.sequence,
    }
    if command == "update" then
        request.modules = target.modules
        request.service_source = target.service_source
    end

    batch.control_started = true
    local ok, answer = pcall(skynet.call, target.service_handle, "hotupgrade", command, request)
    if not ok or type(answer) ~= "table" or type(answer.ok) ~= "boolean" then
        return hotupgrade_result.failure("HU_RPC_FAILED", tostring(answer), command)
    end

    if not answer.ok and target.service_entry_file then
        answer.message = target.service_entry_file .. ": " .. (answer.message or answer.code)
    end
    return answer
end

-- 按阶段协调整批目标；Finish 开始后只报告收尾故障，不回滚已开放业务的目标。
---@param batch FlyWowHotUpgradeBatch 当前唯一活动批次
---@param request FlyWowHotUpgradeManagementRequest 批次开始时冻结的管理请求
function M:run_batch(batch, request)
    -- 登记 waiter 到 wait 之间不 yield；完成回调会唤醒同一批次，恢复后重验身份和计数。
    while self.active_batch == batch and (self.creation_count > 0 or self.module_load_count > 0) do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end
    if self.active_batch ~= batch then
        return
    end
    -- 初始计数为零时不会触发完成回调，由此处推进到 DEPLOYING。
    self:advance_deployment()
    -- 屏障排空后加载并匹配发布包，再准备可恢复的宿主文件快照。
    local ok, message = pcall(function()
        local loaded = self:load_patch(request)
        if not loaded.ok then
            batch.error = loaded
            return
        end
        -- 为每个待部署文件保存旧内容；任何读取失败都在发送目标 RPC 前终止。
        for _, file in ipairs(loaded.patch.files) do
            local old_source, failure = hotupgrade_native.read_file(self.root_path, file.entry_file)
            if old_source == nil then
                batch.error = hotupgrade_result.failure(native_code(failure), "文件准备失败: " .. file.entry_file)
                return
            end
            file.old_source = old_source
        end
        -- 固定 Patch 文件和匹配目标快照，后续提交只使用这份批次数据。
        batch.files = loaded.patch.files
        batch.targets = loaded.targets
        batch.target_count = #loaded.targets
        self.phase = "APPLYING"

        -- 逐个调用 before_upgrade；全部目标成功后才进入 Update。
        batch.phase = "PREPARE"
        for _, target in ipairs(batch.targets) do
            if batch.cancelled then
                batch.error = hotupgrade_result.failure("HU_ABORT_REQUESTED", "管理端终止发布")
                return
            end
            batch.current_service_handle = target.service_handle
            target.participated = true
            local answer = self:step(batch, target, "prepare")
            if not answer.ok then
                target.result = answer
                batch.error = answer
                return
            end
        end

        -- Prepare 已确认全部业务排空，现在逐个更新现存目标。
        batch.phase = "UPDATE"
        for _, target in ipairs(batch.targets) do
            if batch.cancelled then
                batch.error = hotupgrade_result.failure("HU_ABORT_REQUESTED", "管理端终止发布")
                return
            end
            batch.current_service_handle = target.service_handle
            local answer = self:step(batch, target, "update")
            if not answer.ok then
                target.result = answer
                batch.error = answer
                return
            end
        end

        if batch.cancelled then
            batch.error = hotupgrade_result.failure("HU_ABORT_REQUESTED", "管理端终止发布")
            return
        end

        -- 仅使用已冻结的完整文件，不能在 Update 后重新读取发布包。
        for _, file in ipairs(batch.files) do
            local written, failure = hotupgrade_native.replace_file(self.root_path, file.entry_file, file.source)
            if not written then
                batch.error = hotupgrade_result.failure(native_code(failure), "部署失败: " .. file.entry_file)
                return
            end
            file.touched = true
        end
        if #batch.files > 0 then
            local cleared, failure = pcall(skynet.cache.clear)
            if not cleared then
                batch.error = hotupgrade_result.failure("HU_CACHE_CLEAR_FAILED", tostring(failure))
            end
        end
    end)

    if not ok then
        batch.error = hotupgrade_result.failure("HU_CONTROL_FAILED", tostring(message))
    end

    -- 主流程失败后进入恢复阶段；恢复文件和缓存后再撤销已参与目标。
    if batch.error then
        local recovery_errors  = {}    -- 汇总全部恢复失败的信息，不因一项失败停止其余恢复。
        local recovery_failure         -- 第一份原始恢复错误，供 status 保留具体错误码。
        local files_touched    = false -- 只有已替换文件时，恢复流程才需要清理正式代码缓存。
        -- 文件先恢复、清缓存，再 Abort 目标；业务重新开放时必须读取到旧文件。
        for index = #(batch.files or {}), 1, -1 do
            local file = batch.files[index]
            if file.touched then
                files_touched = true
                local called, restored, failure = pcall(hotupgrade_native.replace_file,
                    self.root_path, file.entry_file, file.old_source or nil)
                if not called or not restored then
                    recovery_failure = recovery_failure or hotupgrade_result.failure(
                        called and native_code(failure) or "HU_CONTROL_FAILED", file.entry_file)
                    recovery_errors[#recovery_errors + 1] = file.entry_file .. ": "
                        .. tostring(called and native_code(failure) or restored)
                end
            end
        end
        if files_touched then
            local cleared, failure = pcall(skynet.cache.clear)
            if not cleared then
                recovery_failure = recovery_failure or hotupgrade_result.failure("HU_CACHE_CLEAR_FAILED", tostring(failure))
                recovery_errors[#recovery_errors + 1] = tostring(failure)
            end
        end

        for index = #batch.targets, 1, -1 do
            local target = batch.targets[index]
            if target.participated then
                local restored = self:step(batch, target, "abort")
                if not restored.ok then
                    recovery_failure = recovery_failure or restored
                    recovery_errors[#recovery_errors + 1] = target.service_handle .. ": " .. tostring(restored.message or restored.code)
                    target.result = restored
                elseif target.result and target.result.code == "HU_RECOVERY_REQUIRED" then
                    target.result = hotupgrade_result.failure("HU_UPDATE_FAILED", target.result.message)
                end
            end
        end

        if #recovery_errors > 0 then
            local original = batch.error
            batch.error = hotupgrade_result.failure("HU_RECOVERY_REQUIRED", table.concat(recovery_errors, "; "))
            batch.error.original_error = original or recovery_failure
            batch.error.recovery_error = recovery_failure
            self.recovery_required = true
        elseif batch.error and batch.error.code == "HU_RECOVERY_REQUIRED" then
            batch.error = hotupgrade_result.failure("HU_UPDATE_FAILED", batch.error.message)
        end
        batch.phase = #recovery_errors > 0 and "RECOVERY_REQUIRED" or "ABORTED"
    else
        -- 文件和全部 Update 已确认成功；各目标 Finish 独立报告，不再执行回滚。
        batch.phase = "PUBLISH_DECIDED"
        batch.decided = true
        for _, target in ipairs(batch.targets) do
            batch.current_service_handle = target.service_handle
            target.result = self:step(batch, target, "finish")
            if not target.result.ok then
                batch.error = hotupgrade_result.failure("HU_RECOVERY_REQUIRED",
                    target.result.message or target.result.code, "finish")
                self.recovery_required = true
            end
        end
        batch.phase = batch.error and "RECOVERY_REQUIRED" or "COMPLETED"
    end

    -- 生成 status 所需的逐目标结果和成功/失败计数。
    for _, target in ipairs(batch.targets) do
        if target.participated then
            local answer = target.result or (batch.error
                and hotupgrade_result.failure("HU_BATCH_ABORTED", "本批失败，已尝试恢复")
                or hotupgrade_result.success())
            batch.results[#batch.results + 1] = {service_handle = target.service_handle, hotupgrade_result = answer}
            if answer.ok then
                batch.success = batch.success + 1
            else
                batch.failed = batch.failed + 1
            end
        end
    end

    -- 释放目标快照；未确认恢复时保留文件快照供宿主处理。
    batch.targets = nil
    if batch.decided or not self.recovery_required then
        batch.files = nil
    end
    self.last_batch = batch
    self.active_batch = nil
    self.phase = self.recovery_required and "FAILED_LOCKED"
        or (batch.error and "IDLE" or batch.phase)
    self:wake_lifecycle()
end

-- 完成回调推进等待阶段，不轮询或超时删除创建记录。
function M:advance_deployment()
    if self.phase == "WAITING_CREATIONS" and self.creation_count == 0 and self.module_load_count == 0 then
        self.phase = "DEPLOYING"
        self.active_batch.phase = "DEPLOYING"
        if self.active_batch.waiter then
            skynet.wakeup(self.active_batch.waiter)
        end
    end
end

function M:wake_lifecycle()
    for waiter, waiting in pairs(self.lifecycle_waiters) do
        waiting.blocked = waiting.blocked or self.phase == "FAILED_LOCKED"
        skynet.wakeup(waiter)
    end
end

--- 接受发布并立即返回批次；协程等待已有创建/许可后读取发布包并完成更新。
---@param request FlyWowHotUpgradeManagementRequest path 指向发布包
---@return FlyWowHotUpgradeResult 成功仅表示接受请求，最终结果通过 status(batch_id) 查询
function M:begin(request)
    if self.phase == "FAILED_LOCKED" then
        return hotupgrade_result.failure("HU_DEPLOYMENT_BLOCKED", "上次发布尚未恢复")
    end
    if self.active_batch then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "已有发布屏障")
    end
    local path = request.path
    self.sequence = self.sequence + 1
    ---@type FlyWowHotUpgradeBatch
    local batch =
    {
        batch_id = tostring(skynet.self()) .. ":" .. self.sequence,
        sequence = self.sequence,
        -- 批次阶段：WAITING_CREATIONS -> DEPLOYING -> PREPARE/UPDATE -> PUBLISH_DECIDED -> COMPLETED。
        -- 更新失败且恢复成功时为 ABORTED；恢复失败或 Finish 失败时为 RECOVERY_REQUIRED。
        phase = "WAITING_CREATIONS", -- 当前批次进度及终态；Controller 门禁状态保存在 self.phase。
        results = {},
        targets = {},
        success = 0,
        failed = 0,
        target_count = 0,
    }
    self.active_batch = batch
    self.phase = "WAITING_CREATIONS"
    skynet.fork(function()
        self:run_batch(batch, {path = path})
    end)
    return hotupgrade_result.success({batch_id = batch.batch_id})
end

--- 仅校验宿主的显式恢复确认；不发送目标 RPC，也不恢复或强制开放目标业务。
function M:resolve_deployment(request)
    local batch = self.active_batch or self.last_batch
    if not batch or request.batch_id ~= batch.batch_id then
        return hotupgrade_result.failure("HU_BATCH_MISSING", "恢复批次号不匹配")
    end
    if self.phase ~= "FAILED_LOCKED" and self.phase ~= "DEPLOYING" and self.phase ~= "WAITING_CREATIONS" then
        return hotupgrade_result.failure("HU_DEPLOYMENT_PHASE", "当前阶段不能确认恢复")
    end
    if request.confirmed ~= true or (request.confirmation ~= "UNCHANGED"
        and request.confirmation ~= "CONVERGED_CACHE_CLEARED") then
        return hotupgrade_result.failure("HU_RECOVERY_CONFIRMATION_REQUIRED", "须确认文件及运行时未变更，或已完成版本收敛和必要缓存清理")
    end
    if request.confirmation == "UNCHANGED" and batch.control_started then
        return hotupgrade_result.failure("HU_RECOVERY_CONFIRMATION_REQUIRED", "已向目标发送控制命令，不能声明运行时未发生变更")
    end

    self.active_batch = nil
    if batch.waiter then
        skynet.wakeup(batch.waiter)
    end
    self.last_batch = batch
    batch.resolved = true
    batch.files = nil
    self.recovery_required = false
    self.phase = "IDLE"
    self:wake_lifecycle()
    return hotupgrade_result.success()
end

---@alias FlyWowHotUpgradeManagementCommand
---| "register"
---| "begin"
---| "resolve_deployment"
---| "uniqueservice"
---| "newservice"
---| "cancel_service_creation"
---| "begin_module_load"
---| "register_module"
---| "cancel_module_load"
---| "status"
---| "abort"

--- 管理命令不做远程认证；宿主掌握 Controller handle，登记来源由消息头确定。
---@param command FlyWowHotUpgradeManagementCommand Controller Service 分发的稳定管理命令
---@param request FlyWowHotUpgradeManagementRequest|FlyWowHotUpgradeTargetMetadata|table 命令请求
---@param source integer Skynet 真实调用方
---@return FlyWowHotUpgradeResult 可判别的管理结果；目标控制调用可能 yield
function M:handle_command(command, request, source)
    if type(request) ~= "table" then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "请求必须是 table")
    end

    if command == "register" then
        return self:register(request, source)
    end

    if command == "begin" then
        return self:begin(request)
    end

    if command == "resolve_deployment" then
        return self:resolve_deployment(request)
    end

    if command == "uniqueservice" then
        return self:uniqueservice(request, source)
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

    if command == "status" then
        local lifecycle =
        {
            phase = self.phase,
            batch_id = (self.active_batch or self.last_batch) and (self.active_batch or self.last_batch).batch_id,
            failed_locked = self.phase == "FAILED_LOCKED",
            pending_creations = self.creation_count,
            pending_module_loads = self.module_load_count,
            active_batch_id = self.active_batch and self.active_batch.batch_id,
            recovery_required = self.recovery_required,
        }
        if request.batch_id == nil then
            return hotupgrade_result.success({lifecycle = lifecycle, recovery_required = self.recovery_required})
        end

        local batch = self.active_batch and self.active_batch.batch_id == request.batch_id and self.active_batch or self.last_batch
        if not batch or batch.batch_id ~= request.batch_id then
            return hotupgrade_result.failure("HU_BATCH_MISSING", "仅保留活动及最近终态批次")
        end

        ---@type FlyWowHotUpgradeBatchStatus
        local batch_status =
        {
            batch_id = batch.batch_id, phase = batch.phase, success = batch.success, failed = batch.failed,
            target_count = batch.target_count, current_service_handle = batch.current_service_handle,
            results = batch.results, error = batch.error, resolved = batch.resolved, control_started = batch.control_started == true,
        }
        return hotupgrade_result.success({record = batch_status,
            lifecycle = lifecycle, recovery_required = self.recovery_required})
    end

    if command == "abort" then
        local batch = self.active_batch
        if batch and batch.batch_id == request.batch_id and self.phase ~= "APPLYING" then
            return self:resolve_deployment(request)
        end
        if not batch or batch.batch_id ~= request.batch_id or batch.decided then
            return hotupgrade_result.failure("HU_ABORT_NOT_SAFE", "批次不存在或已有目标越过发布决定")
        end

        batch.cancelled = true
        return hotupgrade_result.success()
    end

    return hotupgrade_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
