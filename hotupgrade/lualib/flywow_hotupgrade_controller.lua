--- 唯一控制面：冻结 Patch 并串行协调现存目标；只保存进程内状态。
local skynet = require "skynet"
require "skynet.manager"
local hotupgrade_native = require "flywow_hotupgrade_native"
local flywow_result = require "flywow_result"
local hotupgrade_common = require "flywow_hotupgrade_common"

local M =
{
    initialized                    = nil,                 -- initialize 完整成功后设为 true；此前管理命令不可用。
    root_path                      = nil,                 -- 已解析的宿主根目录；正式文件读取、替换和恢复共用此边界。
    patch_root                     = nil,                 -- 已解析的受信 Patch 根目录；每个批次从此目录读取冻结源码。
    service_path                   = nil,                 -- Patch 内按 Service 脚本分类的相对目录。
    service_registrations          = nil,                 -- 按真实 Service handle 保存登记记录；供许可校验、Patch 匹配和批次快照读取。
    pending_creations              = nil,                 -- 尚未完成创建或首次登记的记录；完成后由 finish_creation 移除。
    service_creations              = nil,                 -- Service handle 到创建记录的索引；用于匹配早到的 register。
    early_exit_handles             = nil,                 -- 原生创建尚未返回时收到的退出 handle；创建调用收敛后立即清空。
    service_registration_waiters   = nil,                 -- 等待原生 Service handle 建立映射的登记协程；映射完成后唤醒。
    pending_service_count          = nil,                 -- 尚未完成创建或首次登记的受管理 Service 数；归零后批次可重匹配并完成 Prepare 收口。
    module_load_permits            = nil,                 -- 许可 ID 到来源 Service/模块名的映射；登记或取消时移除。
    pending_module_count           = nil,                 -- 尚未完成登记或取消的普通模块首次加载许可数；全部完成后才能关闭 Update 门禁。
    module_permit_sequence         = nil,                 -- 本 Controller 内递增的许可序号，用于生成不重复的许可 ID。
    batch_sequence                 = nil,                 -- 本 Controller 生命周期内递增的批次序号，用来拒绝迟到控制消息。
    lifecycle_gate_waiters         = nil,                 -- Update 起等待创建或首次模块加载的协程，终态时统一唤醒。
    unique_service_entries         = nil,                 -- 逻辑唯一 Service 名到在途结果/Service handle 的映射，仅限本 Controller。
    active_batch                   = nil,                 -- 当前唯一活动批次；批次结束后移入 last_batch。
    last_batch                     = nil,                 -- 最近结束批次的结果；更早批次不保留。
}

---@class FlyWowHotUpgradeController
---@field root_path string 已解析的宿主目录；正式文件读取、部署和恢复共用此根。
---@field service_registrations table<integer, FlyWowHotUpgradeRegisteredService> 按真实 Service handle 索引的登记信息。
---@field pending_service_count integer 已受理但尚未结束的 Service 创建/登记数。
---@field pending_module_count integer 已取得许可但尚未登记或取消的普通模块首次加载数。
---@field active_batch? FlyWowHotUpgradeBatch 当前唯一活动批次。
---@field last_batch? FlyWowHotUpgradeBatch 最近结束并供 status 查询的批次。

--- 根据活动批次阶段决定创建和普通模块首次加载是否等待；WAITING_CREATIONS/PREPARE 接纳依赖，之后关闭入口。
---@param controller table Controller 当前批次进度
---@return boolean 是否处于关闭 Service 创建和模块首次加载的阶段。
local function lifecycle_closed(controller)
    local batch = controller.active_batch
    return batch ~= nil and batch.phase ~= "WAITING_CREATIONS" and batch.phase ~= "PREPARE"
end

--- 统一提取 Native 失败对象中的稳定错误码；没有有效 code 时返回 HU_NATIVE_ERROR。
---@param native_error any Native 返回的错误值
---@return string 稳定 Native 错误码。
local function native_code(native_error)
    if type(native_error) == "table" then
        return native_error.code or "HU_NATIVE_ERROR"
    end

    return "HU_NATIVE_ERROR"
end

--- 校验原生 Service 入口路径；允许嵌套目录用斜杠分隔，但拒绝绝对路径和非法片段。
---@param service_name any 原生入口名
---@return boolean 名称能否映射到合法 Skynet Service 入口路径。
local function valid_service_name(service_name)
    if type(service_name) ~= "string" or service_name == "" or service_name:find("\\", 1, true)
        or service_name:sub(1, 1) == "/" or service_name:sub(-1) == "/" or service_name:find("//", 1, true) then
        return false
    end

    for segment in service_name:gmatch("[^/]+") do
        if segment == "." or segment == ".." or not segment:match("^[%w_.%-]+$") then
            return false
        end
    end
    return true
end

--- 将发布包中的相对 Lua 文件路径转为登记模块名；Service 文件不应调用此转换。
---@param relative_path string 发布包中的相对 Lua 路径
---@return string|nil relative_module_name 去掉 .lua 并转为点分隔的模块名；路径不合法时为 nil。
local function module_name(relative_path)
    if relative_path:sub(-4) ~= ".lua" or relative_path:find("\\", 1, true) then
        return nil
    end

    return relative_path:sub(1, -5):gsub("/", ".")
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

---@class FlyWowHotUpgradeServiceTarget
---@field service_handle integer 从登记记录复制的业务 Service handle；当前热更 RPC 的接收者
---@field modules table[] 本批匹配到的完整模块 Patch
---@field service_patch_source? string Controller 冻结的 Service .patch 文件源码，Update 时发送给对应目标
---@field service_entry_file? string 本批 Service Patch 的相对路径，用于错误诊断
---@field exited? boolean 原生 MONITOR 已确认目标退出；保留结果快照，停止对其发送控制消息
---@field participated? boolean 是否已进入本批控制流程，决定失败时是否发送 Abort
---@field result? FlyWowResult 该目标最近一次 Prepare/Update/Finish/Abort 结果

---@class FlyWowHotUpgradeServiceResult
---@field service_handle integer 本批结果所属业务 Service 的真实 handle
---@field hotupgrade_result FlyWowResult 该目标的事务结果

---@class FlyWowHotUpgradeBatchStatus
---@field batch_id string 本批唯一身份
---@field phase string 本批最终或当前阶段
---@field succeeded_service_count integer 已收到成功事务结果的目标 Service 数
---@field failed_service_count integer 已收到失败事务结果的目标 Service 数
---@field target_service_count integer 当前匹配到的目标 Service 数；Prepare 期间可增长，Update 前确定最终数量
---@field current_service_handle? integer status 查询时当前或最近一次处理的业务 Service handle
---@field service_results FlyWowHotUpgradeServiceResult[] 各业务 Service 的处理结果
---@field error? FlyWowResult 本批失败诊断
---@field control_started boolean 是否已向目标发送控制命令

---@class FlyWowHotUpgradePatchFile
---@field entry_file string 宿主根目录下的 Lua 相对路径；部署和恢复均使用此路径
---@field source string 从本批 Patch 冻结的 Lua 文件内容，作为正式部署内容
---@field old_source? string|false 部署前的正式文件内容；false 表示文件原先不存在，nil 表示尚未完成快照
---@field touched? boolean 仅在正式文件替换成功后设为 true，决定失败时是否恢复

---@class FlyWowHotUpgradeModulePatch
---@field name string 与目标 Service 已登记模块名匹配的规范模块名
---@field entry_file string 发布包内模块文件的相对路径，用于冻结和错误诊断
---@field source string 本批冻结的模块源码，随 Update 发给匹配 Service

---@class FlyWowHotUpgradeServicePatch
---@field entry_file string 发布包内 Service .patch 的相对路径，用于错误诊断
---@field source string 本批冻结的一次性 Service 更新脚本源码

---@class FlyWowHotUpgradeBatch
---@field batch_id string 本批唯一身份
---@field sequence integer Controller 生命周期内递增的本批序号
---@field patch_dir string begin 接受时固定的发布包目录；相对 Controller 的 patch_root，冻结本批源码时从此目录读取
---@field modules FlyWowHotUpgradeModulePatch[] 本批冻结的普通模块源码；不携带文件恢复快照
---@field service_patches table<string, FlyWowHotUpgradeServicePatch> 本批冻结的 Service Patch，重匹配直接复用
---@field phase string 本批当前阶段及终态
---@field service_results FlyWowHotUpgradeServiceResult[] 本批参与控制的 Service 结果；终态汇总并由 status 返回
---@field service_targets FlyWowHotUpgradeServiceTarget[] 本批匹配到的目标 Service 记录；Prepare 期间可增长，Update 前固定并保留参与记录
---@field files? FlyWowHotUpgradePatchFile[] 本批冻结的宿主文件及恢复快照
---@field succeeded_service_count integer 已收到成功事务结果的目标 Service 数
---@field failed_service_count integer 已收到失败事务结果的目标 Service 数
---@field target_service_count integer 当前匹配到的目标 Service 数；Prepare 期间可增长，Update 前确定最终数量
---@field current_service_handle? integer 当前或最近一次处理的业务 Service handle；status 对外返回此值
---@field waiter? thread 等待创建/登记或首次模块加载完成的批次协程
---@field error? FlyWowResult 本批首个失败或恢复失败结果
---@field control_started? boolean 是否已向任一目标发送控制命令，用于报告本批是否触及目标

---@class FlyWowHotUpgradeControlRequest
---@field batch_id string Controller Service handle 与本进程递增序号组成；仅在该 Controller 生命周期有效
---@field sequence integer 当前批次严格递增的序号，目标用来拒绝迟到消息
---@field modules? table[] Controller 按目标登记集合筛选、按模块名排序的 name/source 模块数组；不含业务对象
---@field service_patch_source? string Update 请求携带的 Service .patch 源码；没有匹配的 Service Patch 时为 nil

---@class FlyWowHotUpgradeManagementRequest
---@field path? string begin 的 Patch Root 相对目录
---@field batch_id? string status 使用 begin 返回的身份

---@class FlyWowHotUpgradeLifecycleStatus
---@field phase string IDLE/WAITING_CREATIONS/DEPLOYING/APPLYING/COMPLETED
---@field batch_id? string 当前或最近批次
---@field pending_service_count integer 原生创建或首次登记尚未完成的受管理 Service 数
---@field pending_module_count integer 已授权、尚未登记或取消的普通模块首次加载数
---@field active_batch_id? string 当前活动批次；没有活动批次时为 nil
---@field recovery_required boolean 最近批次的恢复错误诊断，不限制后续操作

---@class FlyWowHotUpgradeControllerConfig
---@field patch_path string 已存在且由宿主管理的受信 Patch 根目录；begin 的发布目录相对它指定
---@field root_path string 宿主项目根目录；模块登记名由其相对文件路径生成
---@field service_path string root_path 下的相对 Service 目录；.lua 完整部署，.patch 匹配现存实例

--- 初始化唯一控制面；不读取持久化历史，不尝试恢复上一进程的批次。
---@param controller_config FlyWowHotUpgradeControllerConfig
---@return FlyWowResult<nil> 初始化结果
function M.initialize(controller_config)
    -- 先校验配置并解析全部路径；任一步失败都不发布部分运行状态。
    if type(controller_config) ~= "table" or type(controller_config.patch_path) ~= "string" or controller_config.patch_path == ""
        or type(controller_config.root_path) ~= "string" or controller_config.root_path == ""
        or type(controller_config.service_path) ~= "string" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "需要 patch_path、root_path、service_path")
    end

    local patch_root, code = hotupgrade_native.resolve(controller_config.patch_path .. "/.")
    if not patch_root then
        return flywow_result.failure(native_code(code), "Patch 根目录不可用")
    end

    local root_path, root_error = hotupgrade_native.resolve(controller_config.root_path .. "/.")
    if not root_path then
        return flywow_result.failure(native_code(root_error), "宿主项目根目录不可用")
    end

    local resolved_service_path, service_error = hotupgrade_native.resolve(root_path, controller_config.service_path)
    if not resolved_service_path then
        return flywow_result.failure(native_code(service_error), "Service 相对目录无效: " .. controller_config.service_path)
    end

    -- 只发布一份宿主根路径，业务 State 可在登记前通过 require 生成相同的文件身份。
    local published_root = skynet.getenv(hotupgrade_common.ROOT_PATH_ENV)
    if published_root and published_root ~= root_path then
        return flywow_result.failure("HU_INVALID_OPTIONS", "同一 Skynet 进程的 Controller 必须使用相同 root_path")
    end
    if M.initialized then
        return flywow_result.failure("HU_ALREADY_INITIALIZED", "控制面已初始化")
    end

    -- 校验成功后构造初始化候选；提交前模块表的长期状态字段保持 nil。
    local controller_initial_state =
    {
        root_path                     = root_path,                                      -- 已解析的宿主根目录；Controller 的正式文件读取、部署和恢复共用此根。
        patch_root                    = patch_root,                                     -- 已解析的受信 Patch 根目录；每批从此处读取并冻结发布源码。
        service_path                  = controller_config.service_path,                 -- 宿主根目录下的相对 Service 目录；据此区分 Service 文件与普通模块。
        service_registrations         = {},                                             -- 按真实 Service handle 保存登记信息；用于加载许可、Patch 匹配和控制 RPC。
        pending_creations             = {},                                             -- 保存已受理但尚未登记或取消的创建记录；完成后从集合移除。
        service_creations             = {},                                             -- 按 Service handle 索引创建记录；用于匹配早到的 register。
        early_exit_handles            = {},                                             -- 记录原生创建返回前收到的退出 handle；对应创建结果收敛后清除。
        service_registration_waiters  = {},                                             -- 保存等待 register 来源与原生 handle 匹配的协程；映射变化时唤醒重查。
        pending_service_count         = 0,                                              -- 尚未完成登记或取消的受管理 Service 数；归零后批次可继续重匹配。
        module_load_permits           = {},                                             -- 按许可 ID 保存 Service handle 与模块名；登记、取消或 Service 退出时消费。
        pending_module_count          = 0,                                              -- 尚未完成登记或取消的普通模块首次加载许可数；归零后批次可关闭 Update 门禁。
        module_permit_sequence        = 0,                                              -- 本 Controller 内递增的许可序号；生成不复用的首次加载许可 ID。
        batch_sequence                = 0,                                              -- 本 Controller 内递增的批次序号；生成批次身份并拒绝迟到控制消息。
        lifecycle_gate_waiters        = {},                                             -- 保存因 Update 门禁暂停的创建/首次加载协程；批次终态后统一唤醒。
        unique_service_entries        = {},                                             -- 按逻辑 Service 名保存唯一创建记录、等待者及已创建 handle。
        active_batch                  = nil,                                            -- 当前唯一活动批次；终态后原记录移入 last_batch。
        last_batch                    = nil,                                            -- 最近结束批次及其报告；下一批结束后替换，不保留更早历史。
    }

    if not published_root then
        skynet.setenv(hotupgrade_common.ROOT_PATH_ENV, root_path)
    end

    -- 校验和路径解析全部成功后才发布运行状态，失败不会留下半初始化控制面。
    for name, value in pairs(controller_initial_state) do
        M[name] = value
    end
    M.initialized = true
    return flywow_result.success()
end

--- 释放一条已登记到 pending_creations 的在途记录，并在计数归零时唤醒批次/登记等待者。
---@param creation FlyWowHotUpgradeServiceCreation 待释放的 Controller 创建记录
---@return nil
function M:finish_creation(creation)
    if self.pending_creations[creation] == creation then
        self.pending_creations[creation] = nil
        if creation.service_handle then
            self.service_creations[creation.service_handle] = nil
        end
        self.pending_service_count = self.pending_service_count - 1
        self:wake_batch()
        self:wake_registration()

        local native_pending = false
        for _, pending in pairs(self.pending_creations) do
            if not pending.native_create_returned then
                native_pending = true
                break
            end
        end
        if not native_pending then
            self.early_exit_handles = {}
        end
    end
end

--- 收敛已跟踪 Service 的退出影响：清除登记/许可/创建记录，并通知批次目标及等待者。
---@param service_handle integer Skynet 原生退出通知中的 Service handle
---@return nil
function M:on_service_exit(service_handle)
    if math.type(service_handle) ~= "integer" or service_handle <= 0 then
        return
    end

    local service_registration = self.service_registrations[service_handle]
    local creation = self.service_creations[service_handle]
    local tracked = service_registration ~= nil or creation ~= nil
    if service_registration then
        self.service_registrations[service_handle] = nil
    end

    for name, unique_service_entry in pairs(self.unique_service_entries) do
        if unique_service_entry.service_handle == service_handle then
            self.unique_service_entries[name] = nil
            tracked = true
        end
    end

    if creation then
        self:finish_creation(creation)
    end

    for permit_id, permit in pairs(self.module_load_permits) do
        if permit.service_handle == service_handle then
            self.module_load_permits[permit_id] = nil
            self.pending_module_count = self.pending_module_count - 1
            if service_registration then
                service_registration.loading_modules[permit.module_name] = nil
            end
            tracked = true
        end
    end

    local batch = self.active_batch
    if batch and batch.service_targets then
        for _, service_target in ipairs(batch.service_targets) do
            if service_target.service_handle == service_handle and not service_target.exited then
                service_target.exited = true
                service_target.result = flywow_result.failure("HU_SERVICE_EXITED",
                    "Service " .. service_handle .. " 在发布期间退出")
                if batch.phase == "PREPARE" or batch.phase == "UPDATE" then
                    batch.error = batch.error or service_target.result
                elseif batch.phase == "PUBLISH_DECIDED" then
                    batch.error = batch.error or flywow_result.failure("HU_RECOVERY_REQUIRED",
                        service_target.result.message, {step = "finish"})
                end
                tracked = true
            end
        end
    end

    if not tracked then
        for _, pending in pairs(self.pending_creations) do
            if not pending.native_create_returned then
                self.early_exit_handles[service_handle] = true
                break
            end
        end
    end
    self:wake_batch()
    self:wake_registration()
end

--- 唤醒等待 Service handle 与 register 来源匹配的协程；被唤醒方会重新检查映射，不视为登记成功。
---@return nil
function M:wake_registration()
    for waiter in pairs(self.service_registration_waiters) do
        skynet.wakeup(waiter)
    end
end

---@class FlyWowHotUpgradeUniqueServiceEntry
---@field waiters table<thread, boolean> 等待同名首次创建结果的协程；创建完成或失败后逐个唤醒
---@field service_handle? integer 首次创建成功后保存的真实 Service handle，供后续调用复用
---@field error? FlyWowResult 首次创建失败时供等待者读取；失败项随后从唯一名映射移除

---@class FlyWowHotUpgradeModuleLoadPermit
---@field service_handle integer 获得许可的已登记 Service；退出时 Controller 按此来源清理许可
---@field module_name string 与许可绑定的规范模块名；完成时校验并更新登记集合

---@class FlyWowHotUpgradeServiceCreationRequest
---@field service_name string 原生 Service 入口，不改写调用方业务初始化参数
---@field arguments table 带 n 的启动参数数组；按原生 newservice 约束传递
---@field global? boolean true 明确拒绝；不支持跨节点全局唯一

---@class FlyWowHotUpgradeServiceCreation
---@field creator_service_handle integer 首次调用者身份；仅该来源可取消尚未登记的创建。
---@field service_name string 原生 Service 入口名；后续用于 Patch 匹配。
---@field service_handle? integer 原生 newservice 返回后建立的目标 handle；早到登记以此核对 source。
---@field unique_name? string 本 Controller 内唯一入口的逻辑预留名；普通创建时为空。
---@field native_create_returned boolean 区分原生启动尚未返回与 handle 已建立的阶段，处理早到 register/退出。

--- Prepare 前后的排空窗口继续接纳依赖；Update 起等待发布终态。
--- 关门后的等待请求尚未开始，不计入当前批次的在途操作。
---@return nil
function M:wait_lifecycle()
    while lifecycle_closed(self) do
        local waiter = coroutine.running()
        self.lifecycle_gate_waiters[waiter] = true
        skynet.wait(waiter)
        self.lifecycle_gate_waiters[waiter] = nil
    end
end

--- 校验创建入口收到的请求和真实消息来源；调用者在生命周期门禁开放时调用。
---@param request FlyWowHotUpgradeServiceCreationRequest 创建入口的规范请求
---@param source integer Skynet 消息头中的创建者 handle
---@return boolean 请求字段与来源是否满足 Controller 创建合同。
local function valid_service_creation_request(request, source)
    return math.type(source) == "integer" and source > 0 and valid_service_name(request.service_name)
        and type(request.arguments) == "table"
        and math.type(request.arguments.n) == "integer" and request.arguments.n >= 0
        and (request.global == nil or type(request.global) == "boolean")
end

--- 已通过门禁和参数检查的共同创建过程；原生调用可能 yield，计数保留至登记完成。
---@param self FlyWowHotUpgradeController 保存创建记录和在途计数的唯一控制面
---@param request FlyWowHotUpgradeServiceCreationRequest 已校验的创建请求
---@param source integer 已校验的真实创建者来源
---@param unique_name? string 仅本地唯一入口在内部传入的逻辑预留名
---@return FlyWowResult<{service_handle:integer}> 成功载荷包含 service_handle
local function start_service(self, request, source, unique_name)
    local creation =
    {
        creator_service_handle = source,                -- 原创建者拥有返回后未登记 Service 的取消权。
        service_name    = request.service_name,  -- Patch 匹配使用的原生 Service 入口名。
        service_handle  = nil,                   -- 仅由原生返回值建立真实来源索引。
        unique_name     = unique_name,            -- 本地唯一预留名，不改变其既有语义。
        native_create_returned = false,                  -- 原生返回前，早到登记只能让出执行权等待。
    }
    self.pending_creations[creation] = creation
    self.pending_service_count = self.pending_service_count + 1

    -- 打包参数的 n 保留包括中间 nil 在内的完整签名；启动行约束仍由原生 Skynet 决定。
    local create_succeeded, service_handle_or_failure = pcall(function()
        return skynet.newservice(request.service_name,
            table.unpack(request.arguments, 1, request.arguments.n))
    end)
    if not create_succeeded or math.type(service_handle_or_failure) ~= "integer"
        or service_handle_or_failure <= 0 then
        self:finish_creation(creation)
        return flywow_result.failure("HU_SERVICE_CREATE_FAILED", tostring(service_handle_or_failure))
    end

    local service_handle = service_handle_or_failure
    creation.service_handle = service_handle
    self.service_creations[service_handle] = creation
    creation.native_create_returned = true
    if self.early_exit_handles[service_handle] then
        self.early_exit_handles[service_handle] = nil
        self:finish_creation(creation)
        return flywow_result.failure("HU_SERVICE_EXITED", "Service 在原生创建返回前退出")
    end
    self:wake_registration()
    return flywow_result.success({service_handle = service_handle})
end

--- 只协调本 Controller 内的逻辑唯一名，不调用原生唯一服务管理器。
--- 在途重复请求等待同一创建结果；失败释放预留，既有 handle 在发布期间也可直接返回。
---@param request FlyWowHotUpgradeServiceCreationRequest 本地唯一 Service 的创建请求
---@param source integer 原请求者的真实消息来源；仅首次创建者拥有取消权
---@return FlyWowResult<{service_handle:integer}> 成功载荷包含 service_handle；全局和特殊启动合同明确拒绝
function M:uniqueservice(request, source)
    -- 先验证唯一创建合同，再决定复用现有实例、等待在途创建或发起新创建。
    if request.global == true then
        return flywow_result.failure("HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED", "受管理唯一服务只支持本 Controller 内的本地唯一")
    end

    if not valid_service_creation_request(request, source) then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要创建者、逻辑 Service 名和完整启动参数")
    end

    if request.service_name == "snaxd" then
        return flywow_result.failure("HU_SPECIAL_SERVICE_UNSUPPORTED", "snaxd 不满足受管理 Service 自行调用 register_service 的登记合同")
    end

    local unique_service_entry = self.unique_service_entries[request.service_name]
    if not (unique_service_entry and unique_service_entry.service_handle) then
        self:wait_lifecycle()
        -- 等待门禁会 yield；恢复后重查唯一名，再决定等待、复用或预留。
        unique_service_entry = self.unique_service_entries[request.service_name]
    end

    if unique_service_entry then
        if unique_service_entry.service_handle then
            return flywow_result.success({service_handle = unique_service_entry.service_handle})
        end
        local waiter = coroutine.running()
        unique_service_entry.waiters[waiter] = true
        skynet.wait(waiter)
        unique_service_entry.waiters[waiter] = nil
        return unique_service_entry.error or flywow_result.success({service_handle = unique_service_entry.service_handle})
    end

    ---@type FlyWowHotUpgradeUniqueServiceEntry
    unique_service_entry =
    {
        waiters = {}, -- 同名创建尚未完成时暂存调用协程；创建结果确定后全部唤醒。
    }
    self.unique_service_entries[request.service_name] = unique_service_entry
    local create_called, creation_result = pcall(start_service, self, request, source, request.service_name)
    if not create_called then
        creation_result = flywow_result.failure("HU_SERVICE_CREATE_FAILED", tostring(creation_result))
    end
    if creation_result.ok then
        unique_service_entry.service_handle = creation_result.value.service_handle
    else
        unique_service_entry.error = creation_result
        if self.unique_service_entries[request.service_name] == unique_service_entry then
            self.unique_service_entries[request.service_name] = nil
        end
    end
    for waiter in pairs(unique_service_entry.waiters) do
        skynet.wakeup(waiter)
    end
    return creation_result
end

--- Controller 命令入口：校验请求后创建普通 Service。
---@param request FlyWowHotUpgradeServiceCreationRequest
---@param source integer 创建者的真实消息来源
---@param unique_name? string 仅本地唯一入口在内部传入的逻辑预留名
---@return FlyWowResult<{service_handle:integer}> 成功载荷包含 service_handle
function M:newservice(request, source, unique_name)
    if not valid_service_creation_request(request, source) then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要创建者、Service 名和启动参数")
    end
    if request.service_name == "snaxd" then
        return flywow_result.failure("HU_SPECIAL_SERVICE_UNSUPPORTED", "snaxd 不满足受管理 Service 自行调用 register_service 的登记合同")
    end

    self:wait_lifecycle()
    return start_service(self, request, source, unique_name)
end

--- 创建者在业务初始化失败后显式终止尚未登记的 Service；不自动超时清理。
---@param request {service_handle:integer} 原生创建返回的待登记 Service
---@param source integer 创建者的真实来源
---@return FlyWowResult<nil> 取消结果。
function M:cancel_service_creation(request, source)
    if math.type(request.service_handle) ~= "integer" then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要待登记 Service handle")
    end

    local creation = self.service_creations[request.service_handle]
    if self.service_registrations[request.service_handle] then
        return flywow_result.failure("HU_SERVICE_ALREADY_REGISTERED", "已登记 Service 不能取消创建")
    end
    if not creation or not creation.native_create_returned then
        return flywow_result.failure("HU_CREATION_MISSING", "没有可取消的待登记 Service")
    end
    if creation.creator_service_handle ~= source then
        return flywow_result.failure("HU_UNAUTHORIZED", "只有创建者可以取消该 Service")
    end

    local kill_succeeded, kill_failure = pcall(skynet.kill, request.service_handle)
    if not kill_succeeded then
        return flywow_result.failure("HU_SERVICE_CANCEL_FAILED", tostring(kill_failure))
    end
    if creation.unique_name then
        local unique_service_entry = self.unique_service_entries[creation.unique_name]
        if unique_service_entry and unique_service_entry.service_handle == request.service_handle then
            self.unique_service_entries[creation.unique_name] = nil
        end
    end
    self:finish_creation(creation)
    return flywow_result.success()
end

---@class FlyWowHotUpgradeModuleLoadRequest
---@field name string 模块的规范文件登记名，必须与许可绑定名称一致
---@field permit_id? string begin 返回的不复用 ID；完成或取消命令必须携带

--- 已登记 Service 在实际执行首次 require 前取得许可；许可覆盖本地状态建立与登记 RPC。
---@param request FlyWowHotUpgradeModuleLoadRequest
---@param source integer 已登记 Service 的真实消息来源
---@return FlyWowResult<{permit_id:string}> 成功载荷包含 permit_id
function M:begin_module_load(request, source)
    self:wait_lifecycle()

    local service_registration = self.service_registrations[source]
    if not service_registration then
        return flywow_result.failure("HU_SERVICE_NOT_REGISTERED", "模块加载者未登记")
    end

    if type(request.name) ~= "string" or request.name == "" then
        return flywow_result.failure("HU_INVALID_REQUEST", "模块名无效")
    end

    if service_registration.loading_modules[request.name] then
        return flywow_result.failure("HU_MODULE_LOADING", "该模块已有未完成的加载许可")
    end

    self.module_permit_sequence = self.module_permit_sequence + 1
    local permit_id = tostring(skynet.self()) .. ":module:" .. self.module_permit_sequence
    self.module_load_permits[permit_id] =
    {
        service_handle = source,      -- 获得许可的已登记 Service；退出通知据此释放许可。
        module_name    = request.name, -- 与 Service 本地 loading_modules 对应的规范模块名。
    }
    service_registration.loading_modules[request.name] = permit_id
    self.pending_module_count = self.pending_module_count + 1
    return flywow_result.success({permit_id = permit_id})
end

--- 完成或撤销许可；他人的许可和重复请求都不能消费记录。
---@param request FlyWowHotUpgradeModuleLoadRequest
---@param source integer 许可原申请者的真实来源
---@param cancel boolean true 仅释放许可，不声明模块
---@return FlyWowResult<nil> 完成或取消许可的结果。
function M:complete_module_load(request, source, cancel)
    ---@type FlyWowHotUpgradeModuleLoadPermit
    local permit = self.module_load_permits[request.permit_id]
    if not permit then
        return flywow_result.failure("HU_MODULE_PERMIT_MISSING", "模块加载许可不存在或已消费")
    end
    if permit.service_handle ~= source then
        return flywow_result.failure("HU_UNAUTHORIZED", "模块加载许可来源不匹配")
    end
    if permit.module_name ~= request.name then
        return flywow_result.failure("HU_MODULE_PERMIT_MISMATCH", "模块名与许可不匹配")
    end

    local service_registration = self.service_registrations[source]
    if not service_registration then
        return flywow_result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未登记")
    end

    if not cancel and not service_registration.modules[request.name] then
        service_registration.modules[request.name] = true
    end

    self.module_load_permits[request.permit_id] = nil
    service_registration.loading_modules[request.name] = nil
    self.pending_module_count = self.pending_module_count - 1
    self:wake_batch()
    return flywow_result.success()
end

---@class FlyWowHotUpgradeNewModuleRequest
---@field batch_id string 当前正在更新的批次身份
---@field name string 已登记 Service 首次加载的新模块规范名

--- UPDATE 期间由当前目标登记 .patch 声明的新模块，不申请常规生命周期许可。
---@param request FlyWowHotUpgradeNewModuleRequest
---@param source integer 正在执行 Update 的真实目标 Service handle
---@return FlyWowResult<nil> 登记结果。
function M:register_new_module(request, source)
    if type(request.batch_id) ~= "string" or type(request.name) ~= "string" or request.name == "" then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要批次身份和模块名")
    end

    local batch = self.active_batch
    if not batch or batch.batch_id ~= request.batch_id or batch.phase ~= "UPDATE"
        or batch.current_service_handle ~= source then
        return flywow_result.failure("HU_NEW_MODULE_NOT_ALLOWED", "仅当前批次正在更新的目标可登记新模块")
    end

    local service_registration = self.service_registrations[source]
    if not service_registration then
        return flywow_result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未登记")
    end

    service_registration.modules[request.name] = true
    return flywow_result.success()
end

--- 早到登记会 yield，直至原生返回的 handle 与消息 source 精确匹配或全部原生创建结束。
---@param request FlyWowHotUpgradeTargetMetadata
---@param service_handle integer Skynet 消息头中的真实业务 Service handle；由受管理创建结果确认
---@return FlyWowResult<nil> Service 登记结果。
function M:register(request, service_handle)
    -- 先校验登记元数据并构造模块集合，失败时不写入 Controller 目标表。
    if math.type(service_handle) ~= "integer" or type(request.modules) ~= "table"
        or type(request.has_service_update) ~= "boolean" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "登记元数据无效")
    end

    if self.service_registrations[service_handle] then
        return flywow_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
    end

    local modules = {}
    local module_count = 0
    for index, name in pairs(request.modules) do
        if math.type(index) ~= "integer" or index < 1 or index > #request.modules
            or type(name) ~= "string" or name == "" or modules[name] then
            return flywow_result.failure("HU_INVALID_OPTIONS", "模块声明列表无效")
        end
        modules[name] = true
        module_count = module_count + 1
    end

    if module_count ~= #request.modules then
        return flywow_result.failure("HU_INVALID_OPTIONS", "模块声明数组有空洞")
    end

    -- 不猜测名称或创建顺序；原生调用返回前，登记必须让出执行权等待真实 handle。
    local creation = self.service_creations[service_handle]
    while not creation do
        local native_pending = false
        for _, pending in pairs(self.pending_creations) do
            if not pending.native_create_returned then
                native_pending = true
                break
            end
        end
        if not native_pending then
            return flywow_result.failure("HU_CREATION_MISSING", "来源不是受管理入口创建的待登记 Service")
        end

        local waiter = coroutine.running()
        self.service_registration_waiters[waiter] = true
        skynet.wait(waiter)
        self.service_registration_waiters[waiter] = nil
        if self.service_registrations[service_handle] then
            return flywow_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
        end
        creation = self.service_creations[service_handle]
    end

    if lifecycle_closed(self) then
        return flywow_result.failure("HU_LIFECYCLE_PENDING", "当前阶段不能登记新 Service")
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
    self.service_registrations[service_handle] = registered_service
    self:finish_creation(creation)
    return flywow_result.success()
end

--- 对冻结 Patch 与当前登记表重新匹配；复用旧目标记录保留 Prepare、退出和恢复进度。
---@param batch FlyWowHotUpgradeBatch 已冻结的发布内容和上一轮目标快照
---@param registered_services table<integer, FlyWowHotUpgradeRegisteredService> Controller 当前登记表
---@return FlyWowResult<{needs_prepare:boolean}> 成功时替换目标列表并返回是否有未 Prepare 目标；失败时保留旧列表。
local function match_service_targets(batch, registered_services)
    -- 先按真实 handle 建旧目标索引；匹配回来的 Service 必须保留其 Prepare 和恢复进度。
    local service_targets_by_handle = {} -- 原目标保留参与记录、退出通知和恢复结果。
    for _, service_target in ipairs(batch.service_targets or {}) do
        service_targets_by_handle[service_target.service_handle] = service_target
    end
    local service_targets = {} -- 本轮完整匹配成功后才交回批次。
    local matched_services = {} -- .patch 必须匹配至少一个已登记且支持更新的 Service。
    local needs_prepare = false -- 返回是否有尚未 Prepare 的匹配目标，供 run_batch 决定是否再循环。
    -- 以最新登记表重建目标清单，并在生成目标时同时计算是否需要再做一轮 Prepare。
    for _, service_registration in pairs(registered_services) do
        local modules = {}
        for _, module_patch in ipairs(batch.modules) do
            if service_registration.modules[module_patch.name] then
                modules[#modules + 1] = module_patch
            end
        end

        local service_patch = batch.service_patches[service_registration.service_name]
        if service_patch and not service_registration.has_service_update then
            return flywow_result.failure("HU_SERVICE_PATCH_UNSUPPORTED", batch.patch_dir .. "/" .. service_patch.entry_file
                .. ": 目标 " .. service_registration.service_handle .. " 未提供 Service 内部更新入口")
        end
        if service_patch then
            matched_services[service_patch.entry_file] = true
        end

        if #modules > 0 or service_patch then
            local service_target = service_targets_by_handle[service_registration.service_handle]
            if not service_target then
                service_target =
                {
                    service_handle = service_registration.service_handle,
                    service_patch_source = service_patch and service_patch.service_patch_source,
                    service_entry_file = service_patch and service_patch.entry_file,
                }
            end
            service_target.modules = modules
            if not service_target.participated then
                needs_prepare = true
            end
            service_targets[#service_targets + 1] = service_target
        end
    end
    -- 先确保每个 Service .patch 都有真实目标；验证完整后才替换批次目标快照。
    for service_name, service_patch in pairs(batch.service_patches) do
        if not matched_services[service_patch.entry_file] then
            return flywow_result.failure("HU_TARGET_MISSING", batch.patch_dir .. "/" .. service_patch.entry_file
                .. ": 没有已登记目标匹配 Service 名称 " .. service_name)
        end
    end

    table.sort(service_targets, function(left, right)
        return left.service_handle < right.service_handle
    end)
    batch.service_targets = service_targets
    batch.target_service_count = #service_targets
    return flywow_result.success({needs_prepare = needs_prepare})
end

--- 将发布包直接冻结到批次，再完成初次目标匹配；后续只复用批次数据。
---@param batch FlyWowHotUpgradeBatch 本批 patch_dir 已由 begin 固定；内部测试也可提供仅含 patch_dir 的记录
---@return FlyWowResult<{needs_prepare:boolean}> 成功时已冻结发布文件并匹配目标；失败时携带稳定错误码。
function M:load_patch(batch)
    if type(batch.patch_dir) ~= "string" then
        return flywow_result.failure("HU_INVALID_PATCH", "需要相对 patch_root 的 patch_dir")
    end

    -- 一次扫描并冻结所选发布目录；扫描结果排序后，后续读取和目标匹配顺序稳定。
    local paths, failure = hotupgrade_native.list_lua(self.patch_root, batch.patch_dir)
    if not paths then
        local code = native_code(failure)
        return flywow_result.failure(code,
            code == "HU_PATCH_EMPTY" and "发布包至少要有一个 .lua 或 Service .patch"
                or "Patch 目录扫描失败: " .. batch.patch_dir)
    end
    table.sort(paths)

    batch.files = {}
    batch.modules = {}
    batch.service_patches = {}
    -- 逐个读取并只编译检查源码，不执行 Patch；普通 Lua 文件与 Service .patch 在此分流。
    local module_names = {} -- 原始路径可能映射到同一规范名，冻结时一次性拒绝冲突。
    local service_prefix = self.service_path .. "/"
    for _, relative_path in ipairs(paths) do
        local source, read_failure = hotupgrade_native.read_file(self.patch_root, batch.patch_dir .. "/" .. relative_path)
        if source == nil or source == false then
            return flywow_result.failure(source == false and "HU_FILE_NOT_FOUND" or native_code(read_failure),
                "发布包读取失败: " .. batch.patch_dir .. "/" .. relative_path)
        end
        local chunk, syntax_error = load(hotupgrade_common.normalize_source(source), "@" .. relative_path, "t", {})
        if not chunk then
            return flywow_result.failure("HU_MODULE_SYNTAX", syntax_error)
        end

        local is_service = relative_path:sub(1, #service_prefix) == service_prefix
        if relative_path:sub(-6) == ".patch" then
            if not is_service then
                return flywow_result.failure("HU_INVALID_PATCH", ".patch 只能位于 service_path: " .. relative_path)
            end
            local service_name = relative_path:sub(#service_prefix + 1, -7)
            if not valid_service_name(service_name) or batch.service_patches[service_name] then
                return flywow_result.failure("HU_INVALID_PATCH", "Service 路径映射重复或无效: " .. relative_path)
            end
            batch.service_patches[service_name] = {entry_file = relative_path, service_patch_source = source}
        else
            local file = {entry_file = relative_path, source = source}
            batch.files[#batch.files + 1] = file
            if not is_service then
                local name = module_name(relative_path)
                if not name or name == "" or module_names[name] then
                    return flywow_result.failure("HU_INVALID_PATCH", "Lua 路径映射重复或无效: " .. relative_path)
                end
                module_names[name] = true
                batch.modules[#batch.modules + 1] = {name = name, entry_file = relative_path, source = source}
            end
        end
    end
    -- 发布文件全部通过读取、语法和路径分类后，才形成初始 Service 目标匹配。
    if #batch.files == 0 and next(batch.service_patches) == nil then
        return flywow_result.failure("HU_PATCH_EMPTY", "发布包至少要有一个 .lua 或 Service .patch")
    end
    table.sort(batch.modules, function(left, right)
        return left.name < right.name
    end)
    return match_service_targets(batch, self.service_registrations)
end

--- 直接使用 Skynet 原生 call；该 RPC 可能 yield，调用失败不代表远端操作已取消，协调方仍须明确恢复。
---@param batch FlyWowHotUpgradeBatch 当前 Controller 正在协调的批次
---@param service_target FlyWowHotUpgradeServiceTarget 本次 RPC 的目标快照，handle 来自 register 消息的真实 source
---@param command string 发送给目标的事务命令
---@return FlyWowResult<nil> 目标返回的事务结果，或本地 RPC 失败结果；调用可能 yield。
function M:step(batch, service_target, command)
    ---@type FlyWowHotUpgradeControlRequest
    local request =
    {
        batch_id = batch.batch_id,
        sequence = batch.sequence,
    }

    if command == "update" then
        request.modules = service_target.modules
        request.service_patch_source = service_target.service_patch_source
    end

    if service_target.exited then
        return service_target.result
    end

    batch.control_started = true
    local call_succeeded, service_result = pcall(skynet.call,
        service_target.service_handle, "hotupgrade", command, request)
    if service_target.exited then
        return service_target.result
    end
    if not call_succeeded or type(service_result) ~= "table" or type(service_result.ok) ~= "boolean" then
        return flywow_result.failure("HU_RPC_FAILED", tostring(service_result), {step = command})
    end

    if not service_result.ok and service_target.service_entry_file then
        service_result.message = service_target.service_entry_file .. ": " .. (service_result.message or service_result.code)
    end
    return service_result
end

-- 等待已接纳的 Service 创建和首次模块加载全部结束；等待期间由完成回调唤醒批次。
--- 等待 begin 前或 Prepare 期间已受理的创建/首次加载收敛；通过完成回调唤醒而非轮询。
---@param controller FlyWowHotUpgradeController 当前唯一控制面
---@param batch FlyWowHotUpgradeBatch 正在等待的批次
---@return nil 可能 yield；在途计数归零后返回。
local function wait_for_batch_work(controller, batch)
    while controller.pending_service_count > 0 or controller.pending_module_count > 0 do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end
end

--- 冻结发布包、准备目标、部署正式文件并执行全部 Update。
--- 冻结 Patch 并保存旧文件后逐轮 Prepare；确认依赖排空，再部署正式文件、清缓存并串行 Update。
--- 该阶段可能在等待或目标 RPC 时 yield；异常由 run_batch 转成 HU_CONTROL_FAILED，失败结果写入 batch.error。
---@param controller FlyWowHotUpgradeController 当前唯一控制面
---@param batch FlyWowHotUpgradeBatch 当前活动批次
---@return nil 成功表示所有目标 Update 完成；失败通过 batch.error 返回。
local function prepare_and_update_batch(controller, batch)
    -- DEPLOYING 阶段只读取一次发布包，并保存所有正式文件的旧内容。
    local load_result = controller:load_patch(batch)
    if not load_result.ok then
        batch.error = load_result
        return
    end

    for _, file in ipairs(batch.files) do
        local old_source, read_failure = hotupgrade_native.read_file(controller.root_path, file.entry_file)
        if old_source == nil then
            batch.error = flywow_result.failure(native_code(read_failure), "文件准备失败: " .. file.entry_file)
            return
        end
        file.old_source = old_source
    end

    -- Prepare 期间继续接纳依赖；每轮排空后用同一份冻结 Patch 重新匹配目标。
    batch.phase = "PREPARE"
    while true do
        for _, service_target in ipairs(batch.service_targets) do
            if not service_target.participated then
                batch.current_service_handle = service_target.service_handle
                service_target.participated = true
                local service_result = controller:step(batch, service_target, "prepare")
                if batch.error then
                    return
                end
                if not service_result.ok then
                    service_target.result = service_result
                    batch.error = service_result
                    return
                end
            end
        end

        wait_for_batch_work(controller, batch)
        if batch.error then
            return
        end

        -- 新登记的匹配目标由 matcher 标记；失败时保留已参与目标供 Abort 恢复。
        local matched = match_service_targets(batch, controller.service_registrations)
        if not matched.ok then
            batch.error = matched
            return
        end
        if not matched.value.needs_prepare then
            break
        end
    end

    -- PREPARE 收口后无 yield 地关闭入口；先部署本批完整 Lua 文件并清缓存。
    batch.phase = "UPDATE"
    for _, file in ipairs(batch.files) do
        local file_written, write_failure = hotupgrade_native.replace_file(
            controller.root_path, file.entry_file, file.source)
        if not file_written then
            batch.error = flywow_result.failure(native_code(write_failure), "部署失败: " .. file.entry_file)
            return
        end
        file.touched = true
    end
    if #batch.files > 0 then
        local cache_cleared, cache_failure = pcall(skynet.cache.clear)
        if not cache_cleared then
            batch.error = flywow_result.failure("HU_CACHE_CLEAR_FAILED", tostring(cache_failure))
            return
        end
    end

    -- 全部文件就绪后才向目标发送 Update；新生命周期请求继续等待批次终态。
    for _, service_target in ipairs(batch.service_targets) do
        batch.current_service_handle = service_target.service_handle
        local service_result = controller:step(batch, service_target, "update")
        if batch.error then
            return
        end
        if not service_result.ok then
            service_target.result = service_result
            batch.error = service_result
            return
        end
    end
end

--- 文件恢复和目标 Abort 按原顺序尽力执行；任一项失败都记录后继续其余恢复。
--- 先逆序恢复已部署文件并清缓存，再逆序 Abort 已参与目标；单项失败会收集后继续。
--- Abort RPC 可能 yield；全部尝试后按恢复结果设置 ABORTED 或 RECOVERY_REQUIRED，不锁定后续批次。
---@param controller FlyWowHotUpgradeController 当前唯一控制面
---@param batch FlyWowHotUpgradeBatch 失败批次及其文件、目标快照
---@return nil 更新恢复结果，并将阶段设为 ABORTED 或 RECOVERY_REQUIRED。
local function recover_batch(controller, batch)
    local recovery_errors = {} -- 汇总所有恢复失败；单项失败不停止其余文件或目标恢复。
    local recovery_failure -- 保留第一份结构化恢复错误，供最终结果携带诊断。
    local files_touched = false -- 只有正式文件被替换后才需要清理文件缓存。

    -- 先恢复正式文件并清缓存，保证目标重新开放时看到旧代码。
    for index = #(batch.files or {}), 1, -1 do
        local file = batch.files[index]
        if file.touched then
            files_touched = true
            local restore_called, file_restored, restore_failure = pcall(hotupgrade_native.replace_file,
                controller.root_path, file.entry_file, file.old_source or nil)
            if not restore_called or not file_restored then
                recovery_failure = recovery_failure or flywow_result.failure(
                    restore_called and native_code(restore_failure) or "HU_CONTROL_FAILED", file.entry_file)
                recovery_errors[#recovery_errors + 1] = file.entry_file .. ": "
                    .. tostring(restore_called and native_code(restore_failure) or file_restored)
            end
        end
    end
    if files_touched then
        local cache_cleared, cache_failure = pcall(skynet.cache.clear)
        if not cache_cleared then
            recovery_failure = recovery_failure or flywow_result.failure("HU_CACHE_CLEAR_FAILED", tostring(cache_failure))
            recovery_errors[#recovery_errors + 1] = tostring(cache_failure)
        end
    end

    -- 再逆序撤销已参与且仍存活的目标；失败目标也不能跳过其余 Abort。
    for index = #batch.service_targets, 1, -1 do
        local service_target = batch.service_targets[index]
        if service_target.participated and not service_target.exited then
            local restored = controller:step(batch, service_target, "abort")
            if not restored.ok and not service_target.exited then
                recovery_failure = recovery_failure or restored
                recovery_errors[#recovery_errors + 1] = service_target.service_handle .. ": "
                    .. tostring(restored.message or restored.code)
                service_target.result = restored
            end
        end
    end

    if #recovery_errors > 0 then
        local original = batch.error
        batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(recovery_errors, "; "))
        batch.error.details = {original_error = original or recovery_failure, recovery_error = recovery_failure}
    end
    batch.phase = (#recovery_errors > 0 or batch.error.code == "HU_RECOVERY_REQUIRED")
        and "RECOVERY_REQUIRED" or "ABORTED"
end

--- 发布决定后逐目标 Finish；失败只报告收尾故障，不回滚已提交目标。
--- 进入 PUBLISH_DECIDED 后逐目标 Finish；Finish RPC 可能 yield，失败只报告收尾故障、不回滚已提交目标。
---@param controller FlyWowHotUpgradeController 当前唯一控制面
---@param batch FlyWowHotUpgradeBatch 已完成所有 Update 的批次
---@return nil 将批次阶段设为 COMPLETED 或 RECOVERY_REQUIRED。
local function finish_batch(controller, batch)
    batch.phase = "PUBLISH_DECIDED"
    for _, service_target in ipairs(batch.service_targets) do
        batch.current_service_handle = service_target.service_handle
        if not service_target.exited then
            service_target.result = controller:step(batch, service_target, "finish")
        end
        if not service_target.result.ok then
            batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED",
                service_target.result.message or service_target.result.code, {step = "finish"})
        end
    end
    batch.phase = batch.error and "RECOVERY_REQUIRED" or "COMPLETED"
end

--- 汇总逐目标结果、释放本批冻结内容并开放下一批生命周期请求。
--- 汇总已参与目标的结果，释放本批冻结源码/恢复快照，保存最近批次并唤醒门禁等待者。
---@param controller FlyWowHotUpgradeController 当前唯一控制面
---@param batch FlyWowHotUpgradeBatch 已进入 ABORTED、RECOVERY_REQUIRED 或成功终态的批次
---@return nil 批次成为 last_batch，active_batch 清空。
local function complete_batch(controller, batch)
    for _, service_target in ipairs(batch.service_targets) do
        if service_target.participated then
            local service_result = service_target.result or (batch.error
                and flywow_result.failure("HU_BATCH_ABORTED", "本批失败，已尝试恢复")
                or flywow_result.success())
            batch.service_results[#batch.service_results + 1] =
            {
                service_handle = service_target.service_handle,
                hotupgrade_result = service_result,
            }
            if service_result.ok then
                batch.succeeded_service_count = batch.succeeded_service_count + 1
            else
                batch.failed_service_count = batch.failed_service_count + 1
            end
        end
    end

    batch.service_targets = nil
    batch.files = nil
    batch.modules = nil
    batch.service_patches = nil
    controller.last_batch = batch
    controller.active_batch = nil
    controller:wake_lifecycle()
end

--- 驱动一批热更：等已有操作结束，准备并更新；失败走恢复，成功走 Finish，最后汇总并开放门禁。
--- 等待和目标 RPC 可能 yield；终态错误保存在 batch.error/phase，供 status 查询。
---@param batch FlyWowHotUpgradeBatch 当前唯一活动批次
---@return nil 批次处理完毕后由 complete_batch 保存为最近结果。
function M:run_batch(batch)
    -- 批次开始前已接纳的创建和首次加载必须先收敛，再关闭入口准备目标。
    wait_for_batch_work(self, batch)
    batch.phase = "DEPLOYING"

    local control_succeeded, control_failure = pcall(prepare_and_update_batch, self, batch)
    if not control_succeeded then
        batch.error = flywow_result.failure("HU_CONTROL_FAILED", tostring(control_failure))
    end

    if batch.error then
        recover_batch(self, batch)
    else
        finish_batch(self, batch)
    end
    complete_batch(self, batch)
end

--- 在途创建/首次加载计数全部归零后唤醒批次；最终关闭入口由 run_batch 在 Prepare 收口后执行。
---@return nil
function M:wake_batch()
    local batch = self.active_batch
    if batch and batch.waiter and self.pending_service_count == 0 and self.pending_module_count == 0 then
        skynet.wakeup(batch.waiter)
    end
end

--- 唤醒因 Update 门禁暂停的创建/首次加载协程；它们恢复后会重新检查批次阶段。
---@return nil
function M:wake_lifecycle()
    for waiter in pairs(self.lifecycle_gate_waiters) do
        skynet.wakeup(waiter)
    end
end

--- 接受发布并立即返回批次；Prepare 期间继续接纳依赖，最终排空后关闭门禁并更新。
---@param request FlyWowHotUpgradeManagementRequest path 指向发布包
---@return FlyWowResult<{batch_id:string}> 成功仅表示接受请求；最终结果通过 status(batch_id) 查询
function M:begin(request)
    if self.active_batch then
        return flywow_result.failure("HU_UPGRADE_BUSY", "已有发布屏障")
    end
    self.batch_sequence = self.batch_sequence + 1
    ---@type FlyWowHotUpgradeBatch
    local batch =
    {
        batch_id                 = tostring(skynet.self()) .. ":" .. self.batch_sequence,                 -- begin 返回给管理端，并作为 status 查询本批的身份。
        sequence                 = self.batch_sequence,                                                   -- 本 Controller 内递增；控制 RPC 用它拒绝迟到的旧批消息。
        patch_dir                = request.path,                                                              -- 相对 patch_root 的发布目录；begin 接受时固定并从此冻结源码。
        phase                    = "WAITING_CREATIONS",                                             -- run_batch 推进；生命周期门禁和 status 视图据此生成。
        service_results          = {},                                                              -- run_batch 终态汇总参与控制的 Service 结果，供 status 返回。
        service_targets          = {},                                                              -- 目标 Service 记录；Prepare 重匹配时补齐，Update 前固定，终态后释放。
        succeeded_service_count  = 0,                                                               -- run_batch 汇总成功事务结果的目标 Service 数，供 status 返回。
        failed_service_count     = 0,                                                               -- run_batch 汇总失败事务结果的目标 Service 数，供 status 返回。
        target_service_count     = 0,                                                               -- 当前匹配的目标 Service 数；Prepare 可增长，Update 前确定最终值。
    }
    self.active_batch = batch
    skynet.fork(function()
        self:run_batch(batch)
    end)
    return flywow_result.success({batch_id = batch.batch_id})
end

---@alias FlyWowHotUpgradeManagementCommand
---| "register"
---| "begin"
---| "uniqueservice"
---| "newservice"
---| "cancel_service_creation"
---| "begin_module_load"
---| "register_module"
---| "register_new_module"
---| "cancel_module_load"
---| "status"

--- 管理命令不做远程认证；宿主掌握 Controller handle，登记来源由消息头确定。
---@param command FlyWowHotUpgradeManagementCommand Controller Service 分发的稳定管理命令
---@param request FlyWowHotUpgradeManagementRequest|FlyWowHotUpgradeTargetMetadata|FlyWowHotUpgradeServiceCreationRequest|FlyWowHotUpgradeModuleLoadRequest|FlyWowHotUpgradeNewModuleRequest 命令对应的已校验请求
---@param source integer Skynet 消息头中的真实调用方 handle
---@return FlyWowResult<table> begin 返回 batch_id、status 返回 lifecycle/record、创建返回 service_handle；登记/许可命令通常无载荷，失败返回稳定 code。
--- 创建、登记等待或目标控制命令可能 yield；每个命令的具体权限和字段由对应方法处理。
function M:handle_command(command, request, source)
    if type(request) ~= "table" then
        return flywow_result.failure("HU_INVALID_REQUEST", "请求必须是 table")
    end

    if command == "register" then
        return self:register(request, source)
    end

    if command == "begin" then
        return self:begin(request)
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

    if command == "register_new_module" then
        return self:register_new_module(request, source)
    end

    if command == "status" then
        local batch = self.active_batch or self.last_batch
        local phase = batch and batch.phase or "IDLE"
        if self.active_batch then
            if phase == "PREPARE" or phase == "UPDATE" or phase == "PUBLISH_DECIDED" then
                phase = "APPLYING"
            end
        elseif batch and batch.error then
            phase = "IDLE"
        end
        -- 管理查询字段由批次事实生成，沿用现有对外值，不独立保存和同步。
        local recovery_required = self.last_batch ~= nil and self.last_batch.phase == "RECOVERY_REQUIRED"
        if self.active_batch and batch.phase == "PUBLISH_DECIDED" and batch.error then
            recovery_required = batch.error.code == "HU_RECOVERY_REQUIRED"
        end
        local lifecycle =
        {
            phase = phase,
            batch_id = batch and batch.batch_id,
            pending_service_count = self.pending_service_count,
            pending_module_count = self.pending_module_count,
            active_batch_id = self.active_batch and self.active_batch.batch_id,
            recovery_required = recovery_required,
        }
        if request.batch_id == nil then
            return flywow_result.success({lifecycle = lifecycle, recovery_required = recovery_required})
        end

        batch = self.active_batch and self.active_batch.batch_id == request.batch_id and self.active_batch or self.last_batch
        if not batch or batch.batch_id ~= request.batch_id then
            return flywow_result.failure("HU_BATCH_MISSING", "仅保留活动及最近终态批次")
        end

        ---@type FlyWowHotUpgradeBatchStatus
        local batch_status =
        {
            batch_id = batch.batch_id, phase = batch.phase, succeeded_service_count = batch.succeeded_service_count,
            failed_service_count = batch.failed_service_count,
            target_service_count = batch.target_service_count, current_service_handle = batch.current_service_handle,
            service_results = batch.service_results, error = batch.error, control_started = batch.control_started == true,
        }
        return flywow_result.success({record = batch_status,
            lifecycle = lifecycle, recovery_required = recovery_required})
    end

    return flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
