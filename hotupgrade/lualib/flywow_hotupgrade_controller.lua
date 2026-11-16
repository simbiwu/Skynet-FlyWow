--- Controller 固定本批发布文件，按顺序通知已登记 Service，并保存每个目标的结果。
local skynet = require "skynet"
-- 为取消尚未完成登记的 Service 提供 skynet.kill 管理接口。
require "skynet.manager"
-- 负责受信目录解析、Patch 文件读取和正式 Lua 文件部署的 Native 接口。
local hotupgrade_native = require "flywow_hotupgrade_native"
-- 构造 Controller 向宿主和目标 Service 返回的统一结果表。
local flywow_result = require "flywow_result"
-- 提供跨 Service 协议号、路径环境变量名及状态快照的深度和字段数上限。
local hotupgrade_common = require "flywow_hotupgrade_common"

-- Controller 对外提供初始化、Service 生命周期协调和热更批次管理操作。
---@class FlyWowHotUpgradeController
---@field root_path string 已解析的宿主目录；正式文件读取、部署和恢复共用此根。
---@field patch_root string 受信 Patch 根目录；begin 的相对发布目录从此解析。
---@field service_path string 宿主根目录下区分 Service 入口和普通模块的相对路径。
---@field service_registrations table<integer, FlyWowHotUpgradeRegisteredService> 按真实 Service handle 索引的登记信息。
---@field native_creations_in_flight integer 仍在等待原生 skynet.newservice 返回的受管理创建数。
---@field service_creations table<integer, FlyWowHotUpgradeServiceCreation> 已返回真实 handle、尚未登记或取消的创建记录。
---@field early_exit_handles table<integer, boolean> 创建接口返回前收到的退出 handle 集合。
---@field service_registration_waiters table<thread, boolean> 等待创建 handle 与 register 来源匹配的协程集合。
---@field module_load_permits table<string, table> 尚未登记或取消的普通模块首次加载许可。
---@field module_permit_sequence integer Controller 内递增的首次加载许可序号。
---@field batch_sequence integer Controller 内递增的批次序号。
---@field lifecycle_gate_waiters table<thread, boolean> Update 门禁暂停的创建或首次加载协程。
---@field unique_service_entries table<string, FlyWowHotUpgradeUniqueServiceEntry> 唯一 Service 名到共享创建结果的映射。
---@field active_batch? FlyWowHotUpgradeBatch 当前唯一活动批次。
---@field last_batch? FlyWowHotUpgradeBatch 最近结束并供 status 查询的批次。
---@field initialize fun(controller_config: FlyWowHotUpgradeControllerConfig): FlyWowResult<nil> 校验路径并初始化唯一 Controller。
---@field finish_creation fun(self: FlyWowHotUpgradeController, service_handle: integer) 删除已结束的待登记记录并唤醒等待者。
---@field on_service_exit fun(self: FlyWowHotUpgradeController, service_handle: integer) 清理退出 Service 的登记、许可和等待关系。
---@field wake_registration fun(self: FlyWowHotUpgradeController) 唤醒等待登记映射的协程。
---@field wait_lifecycle fun(self: FlyWowHotUpgradeController) 等待当前生命周期门禁开放。
---@field uniqueservice fun(self: FlyWowHotUpgradeController, request: table, source: integer): FlyWowResult<any> 获取或创建唯一 Service。
---@field newservice fun(self: FlyWowHotUpgradeController, request: table, source: integer): FlyWowResult<any> 创建并登记受管理 Service。
---@field cancel_service_creation fun(self: FlyWowHotUpgradeController, request: table, source: integer): FlyWowResult<nil> 取消受管理 Service 创建。
---@field begin_module_load fun(self: FlyWowHotUpgradeController, request: table, source: integer): FlyWowResult<any> 核发普通模块首次加载许可。
---@field complete_module_load fun(self: FlyWowHotUpgradeController, request: table, source: integer, cancel: boolean): FlyWowResult<nil> 完成或取消模块加载许可。
---@field register_new_module fun(self: FlyWowHotUpgradeController, request: table, source: integer): FlyWowResult<nil> 登记当前 Update 声明的新模块。
---@field register fun(self: FlyWowHotUpgradeController, request: table, service_handle: integer): FlyWowResult<nil> 登记受管理 Service。
---@field call_target_control fun(self: FlyWowHotUpgradeController, batch: FlyWowHotUpgradeBatch, service_target: FlyWowHotUpgradeServiceTarget, command: string): FlyWowResult<nil> 向单个目标发送热更控制命令。
---@field run_batch fun(self: FlyWowHotUpgradeController, batch: FlyWowHotUpgradeBatch) 推进本批发布并保存终态。
---@field wake_batch fun(self: FlyWowHotUpgradeController) 唤醒等待批次进度的协程。
---@field wake_lifecycle fun(self: FlyWowHotUpgradeController) 唤醒等待生命周期门禁的协程。
---@field begin fun(self: FlyWowHotUpgradeController, request: FlyWowHotUpgradeManagementRequest): FlyWowResult<any> 接受并启动一个新批次。
---@field handle_command fun(self: FlyWowHotUpgradeController, command: string, request: table, source: integer): FlyWowResult<any> 分派管理、创建与许可请求。
local M =
{
    root_path                      = nil,                 -- 已解析的宿主根目录；正式文件读取、替换和恢复都以它为根目录。
    patch_root                     = nil,                 -- 已解析的受信 Patch 根目录；每个批次从此目录读取冻结源码。
    service_path                   = nil,                 -- Patch 内按 Service 脚本分类的相对目录。
    service_registrations          = nil,                 -- 按真实 Service handle 保存登记记录；供许可校验、Patch 匹配和批次快照读取。
    native_creations_in_flight     = nil,                 -- 原生创建调用开始时递增、返回时递减；登记等待和排空据此判断。
    service_creations              = nil,                 -- Service handle 到创建记录的索引；用于匹配早到的 register。
    early_exit_handles             = nil,                 -- 保存可能早于创建返回的退出通知；原生在途数归零时清空。
    service_registration_waiters   = nil,                 -- 等待原生 Service handle 建立映射的登记协程；映射完成后唤醒。
    module_load_permits            = nil,                 -- 许可 ID 到来源 Service 和模块文件路径的映射；登记或取消时移除。
    module_permit_sequence         = nil,                 -- 本 Controller 内递增的许可序号，用于生成不重复的许可 ID。
    batch_sequence                 = nil,                 -- 本 Controller 生命周期内递增的批次序号，用来生成唯一批次 ID。
    lifecycle_gate_waiters         = nil,                 -- Update 起等待创建或首次模块加载的协程，终态时统一唤醒。
    unique_service_entries         = nil,                 -- 逻辑唯一 Service 名到在途结果/Service handle 的映射，仅限本 Controller。
    active_batch                   = nil,                 -- 当前唯一活动批次；批次结束后移入 last_batch。
    last_batch                     = nil,                 -- 最近结束批次的结果；更早批次不保留。
}

--- 根据 active_batch.phase 判断是否暂停新的 Service 创建和普通模块首次加载。
--- WAITING_CREATIONS 与 PREPARE 仍接纳依赖；之后创建/首次加载请求等待批次结束。
---@param controller table 已初始化的 Controller；本函数读取 active_batch.phase 决定入口是否关闭。
---@return boolean 是否处于关闭 Service 创建和模块首次加载的阶段。
local function lifecycle_closed(controller)
    -- Controller 当前正在处理的批次；阶段决定创建和首次加载入口是否关闭。
    local batch = controller.active_batch
    return batch ~= nil and batch.phase ~= "WAITING_CREATIONS" and batch.phase ~= "PREPARE"
end

--- 判断发布是否仍须等待创建、首次登记或普通模块首次加载。
---@param controller FlyWowHotUpgradeController 已初始化的控制面；读取原生调用数、待登记记录和模块许可。
---@return boolean 至少有一项操作尚未完成时返回 true。
local function has_pending_lifecycle_work(controller)
    return controller.native_creations_in_flight > 0 or next(controller.service_creations) ~= nil
        or next(controller.module_load_permits) ~= nil
end

--- 从 Native 返回的错误对象提取稳定错误码；没有可用错误码时使用 HU_NATIVE_ERROR。
---@param native_error any Native 文件操作返回的失败值；table 形式读取其中的 code，其他形式使用通用错误码。
---@return string 稳定 Native 错误码。
local function native_code(native_error)
    if type(native_error) == "table" then
        return native_error.code or "HU_NATIVE_ERROR"
    end

    return "HU_NATIVE_ERROR"
end

--- 检查从 Service .patch 路径得到的入口名能否交给 Skynet 启动。
--- 允许斜杠表示子目录，拒绝绝对路径、空路径段、点段和非法字符。
---@param service_name any 从 service_path 下的 .patch 相对路径去掉目录前缀和扩展名后得到的入口名。
---@return boolean 名称能否映射到合法 Skynet Service 入口路径。
local function valid_service_name(service_name)
    if type(service_name) ~= "string" or service_name == "" or service_name:find("\\", 1, true)
        or service_name:sub(1, 1) == "/" or service_name:sub(-1) == "/" or service_name:find("//", 1, true) then
        return false
    end

    -- 路径格式通过首轮检查后，再拒绝每个路径段为 .、.. 或含 Skynet 不接受字符的名称。
    for segment in service_name:gmatch("[^/]+") do
        if segment == "." or segment == ".." or not segment:match("^[%w_.%-]+$") then
            return false
        end
    end
    return true
end

--- 把发布包中的普通 Lua 文件路径转换成 require 模块名。
--- 例如 lualib/player/logic.lua 转成 lualib.player.logic；非法扩展名或反斜杠返回 nil。
---@param relative_path string 相对发布包根目录的普通 Lua 文件路径；本函数去掉 .lua 并把 / 换成 .。
---@return string|nil relative_module_name 去掉 .lua 并转为点分隔的模块名；路径不合法时为 nil。
local function module_name(relative_path)
    if relative_path:sub(-4) ~= ".lua" or relative_path:find("\\", 1, true) then
        return nil
    end

    return relative_path:sub(1, -5):gsub("/", ".")
end

---@class FlyWowHotUpgradeTargetMetadata
---@field module_paths string[] 当前 State 已声明模块的宿主相对文件路径数组
---@field has_service_update boolean 是否在本 State 提供私有状态及函数更新入口

---@class FlyWowHotUpgradeRegisteredService
---@field service_name string Skynet Service 入口名，用于匹配 Service Patch
---@field module_paths table<string, boolean> 当前 Lua State 声明的宿主相对文件路径集合
---@field loading_modules table<string, string> 宿主相对文件路径到在途 permit_id 的索引；同一文件仅允许一项在途许可
---@field has_service_update boolean 是否提供 Service 私有状态/函数更新入口

---@class FlyWowHotUpgradeServiceTarget
---@field service_handle integer 从登记记录复制的业务 Service handle；当前热更 RPC 的接收者
---@field modules table[] 本批匹配到的完整模块 Patch
---@field service_patch? FlyWowHotUpgradeServicePatchSource 引用本批唯一固定的 Service Patch 记录；Update 源码与错误路径均从这里读取
---@field exited? boolean 原生 MONITOR 已确认目标退出；保留结果快照，停止对其发送控制消息
---@field participated? boolean 是否已进入本批控制流程，决定失败时是否发送 Abort
---@field hotupgrade_result? FlyWowResult 本目标本批的汇总结果；失败或退出时提前写入，成功由 Finish 写入，恢复失败可覆盖为恢复结果

---@class FlyWowHotUpgradeServiceResult
---@field service_handle integer 本批结果所属业务 Service 的真实 handle
---@field hotupgrade_result FlyWowResult 该目标的热更结果

---@class FlyWowHotUpgradeBatchStatus
---@field batch_id string 本批唯一身份
---@field phase string 本批最终或当前阶段
---@field succeeded_service_count integer 已收到成功热更结果的目标 Service 数
---@field failed_service_count integer 已收到失败热更结果的目标 Service 数
---@field target_service_count integer 当前匹配到的目标 Service 数；Prepare 期间可增长，Update 前确定最终数量
---@field current_service_handle? integer status 查询时当前或最近一次处理的业务 Service handle
---@field service_results FlyWowHotUpgradeServiceResult[] 各业务 Service 的处理结果
---@field error? FlyWowResult 本批失败诊断

---@class FlyWowHotUpgradePatchFile
---@field host_relative_path string 相对于 Controller.root_path 的 Lua 文件路径；例如 lualib/player_logic.lua；部署和恢复都使用该路径
---@field source string 从本批 Patch 读取并固定的 Lua 文件内容，作为正式部署内容
---@field name? string 普通模块的缓存别名；Service 入口只部署，不设置此字段

---@class FlyWowHotUpgradeModulePatch
---@field name string 目标 Lua State 的缓存别名；如 lualib/player.lua 对应 lualib.player
---@field host_relative_path string 相对宿主根的真实文件路径；Controller 按它匹配，目标按它取得原加载参数
---@field source string 本批读取并固定的模块源码，随 Update 发给匹配 Service

---@class FlyWowHotUpgradeServicePatchSource
---@field patch_relative_path string 相对于本批 patch_dir 的 Service .patch 路径，例如 service/player_service.patch；用于目标匹配和错误诊断，不用于宿主部署
---@field service_patch_source string 本批读取并固定的 Service .patch 源码，随 Update 请求发送

---@class FlyWowHotUpgradeBatch
---@field batch_id string 本批唯一身份
---@field patch_dir string begin 接受时固定的发布包目录；相对 Controller 的 patch_root，开始处理批次时从此目录读取源码
---@field modules FlyWowHotUpgradeModulePatch[] 本批读取并固定的普通模块源码；不携带文件恢复快照
---@field service_patches table<string, FlyWowHotUpgradeServicePatchSource> 本批读取并固定的 Service Patch，重匹配直接复用
---@field phase string 本批当前阶段及终态
---@field service_results FlyWowHotUpgradeServiceResult[] 本批参与控制的 Service 结果；终态汇总并由 status 返回
---@field service_targets FlyWowHotUpgradeServiceTarget[] 本批匹配到的目标 Service 记录；Prepare 期间可增长，Update 前固定并保留参与记录
---@field files? FlyWowHotUpgradePatchFile[] 按部署顺序保存本批冻结的宿主文件，普通模块列表引用同一批文件记录
---@field old_sources? table<string, string|false> 按宿主相对路径保存部署前的源码；false 表示文件原本不存在，仅 Controller 用于恢复
---@field deployed_file_count integer 已顺序替换成功的正式文件数；Abort 只恢复 files 中这段前缀。
---@field target_service_count? integer 终态释放 service_targets 前保存的最终目标数；活动期间从目标列表计算
---@field current_service_handle? integer 当前或最近一次处理的业务 Service handle；status 对外返回此值
---@field waiter? thread 等待创建/登记或首次模块加载完成的批次协程
---@field error? FlyWowResult 本批首个失败或恢复失败结果

---@class FlyWowHotUpgradeControlRequest
---@field batch_id string Controller Service handle 与本进程递增序号组成；仅在该 Controller 生命周期有效
---@field modules? FlyWowHotUpgradeModulePatch[] Controller 按目标已登记文件筛选、按缓存别名排序的候选；不含业务对象
---@field service_patch_source? string Update 请求携带的 Service .patch 源码；没有匹配的 Service Patch 时为 nil

---@class FlyWowHotUpgradeManagementRequest
---@field path? string begin 的 Patch Root 相对目录
---@field batch_id? string status 使用 begin 返回的身份

---@class FlyWowHotUpgradeLifecycleStatus
---@field phase string IDLE/WAITING_CREATIONS/APPLYING/COMPLETED
---@field batch_id? string 当前或最近批次
---@field pending_service_count integer 原生创建或首次登记尚未完成的受管理 Service 数
---@field pending_module_count integer 已授权、尚未登记或取消的普通模块首次加载数
---@field active_batch_id? string 当前活动批次；没有活动批次时为 nil
---@field recovery_required boolean 最近批次的恢复错误诊断，不限制后续操作

---@class FlyWowHotUpgradeControllerConfig
---@field patch_path string 已存在且由宿主管理的受信 Patch 根目录；begin 的发布目录相对它指定
---@field root_path string 宿主项目根目录；模块登记和发布匹配均使用相对于此目录的文件路径
---@field service_path string root_path 下的相对 Service 目录；.lua 完整部署，.patch 匹配现存实例

--- 检查宿主根目录、Patch 根目录和 Service 子目录后初始化唯一 Controller。
--- 配置无效时返回失败结果；成功解析的路径供文件扫描、部署和恢复共用。
---@param controller_config FlyWowHotUpgradeControllerConfig 宿主启动 Controller 时提供的三个目录：发布包根目录 patch_path、正式 Lua 根目录 root_path、Service 入口目录 service_path；本函数解析并检查它们。
---@return FlyWowResult<nil> 初始化结果
function M.initialize(controller_config)
    -- 先校验配置并解析全部路径；任一步失败都不发布部分运行状态。
    if type(controller_config) ~= "table" or type(controller_config.patch_path) ~= "string" or controller_config.patch_path == ""
        or type(controller_config.root_path) ~= "string" or controller_config.root_path == ""
        or type(controller_config.service_path) ~= "string" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "需要 patch_path、root_path、service_path")
    end

    -- 解析后的发布包根目录，以及 Native 解析失败时返回的错误码。
    local patch_root, code = hotupgrade_native.resolve(controller_config.patch_path .. "/.")
    if not patch_root then
        return flywow_result.failure(native_code(code), "Patch 根目录不可用")
    end

    -- 解析后的宿主根目录，以及路径解析失败时的 Native 错误信息。
    local root_path, root_error = hotupgrade_native.resolve(controller_config.root_path .. "/.")
    if not root_path then
        return flywow_result.failure(native_code(root_error), "宿主项目根目录不可用")
    end

    -- 宿主内 Service 目录的真实路径，以及无效相对路径的错误信息。
    local resolved_service_path, service_error = hotupgrade_native.resolve(root_path, controller_config.service_path)
    if not resolved_service_path then
        return flywow_result.failure(native_code(service_error), "Service 相对目录无效: " .. controller_config.service_path)
    end

    -- 所有受管理 State 必须以同一份宿主根路径生成相对文件路径。
    local published_root = skynet.getenv(hotupgrade_common.ROOT_PATH_ENV)
    if published_root and published_root ~= root_path then
        return flywow_result.failure("HU_INVALID_OPTIONS", "同一 Skynet 进程的 Controller 必须使用相同 root_path")
    end

    -- 首次初始化时发布根路径，供业务 State 在登记前定位受控模块。
    if not published_root then
        skynet.setenv(hotupgrade_common.ROOT_PATH_ENV, root_path)
    end

    -- 三个目录均已验证，由外层 Service 在 MONITOR 安装后开放命令。
    M.root_path = root_path
    M.patch_root = patch_root
    M.service_path = controller_config.service_path
    M.service_registrations = {}
    M.native_creations_in_flight = 0
    M.service_creations = {}
    M.early_exit_handles = {}
    M.service_registration_waiters = {}
    M.module_load_permits = {}
    M.module_permit_sequence = 0
    M.batch_sequence = 0
    M.lifecycle_gate_waiters = {}
    M.unique_service_entries = {}
    return flywow_result.success()
end

--- 登记、取消或退出结束已返回 handle 的创建；移除待登记记录后通知发布协程重查排空条件。
---@param service_handle integer 已匹配待登记记录的真实 Service handle；本函数据此删除该记录。
---@return nil 无返回值。
function M:finish_creation(service_handle)
    self.service_creations[service_handle] = nil
    self:wake_batch()
end

--- 处理 Skynet MONITOR 报告的 Service 退出，清除它的登记、许可和创建记录。
--- 若退出 Service 是活动批次目标，本函数还记录目标失败并唤醒等待者。
---@param service_handle integer MONITOR 通知中的真实 Service handle；本函数按它查找并清理对应记录。
---@return nil
function M:on_service_exit(service_handle)
    -- 登记表和创建索引分别覆盖已登记与尚未登记的实例；退出通知可能先于原生创建返回。
    if math.type(service_handle) ~= "integer" or service_handle <= 0 then
        return
    end

    -- 该退出 handle 对应的已登记 Service 记录；没有登记记录时可能仍有创建记录。
    local service_registration = self.service_registrations[service_handle]
    -- 该 handle 对应的待登记创建记录；退出通知可能早于原生创建返回。
    local creation = self.service_creations[service_handle]
    -- 判断退出 handle 是否属于 Controller 管理的 Service；未知进程不改批次状态。
    local tracked = service_registration ~= nil or creation ~= nil
    if service_registration then
        -- 该 Service 的在途许可 ID 已按模块名索引，直接从全局许可表删除对应项。
        for _, permit_id in pairs(service_registration.loading_modules) do
            self.module_load_permits[permit_id] = nil
        end
        self.service_registrations[service_handle] = nil
    end

    -- 唯一名与创建入口同名；核对 handle 后才删除，普通实例退出时不能移除同名唯一实例。
    local service_name = service_registration and service_registration.service_name or creation and creation.service_name
    local unique_service_entry = service_name and self.unique_service_entries[service_name]
    if unique_service_entry and unique_service_entry.service_handle == service_handle then
        self.unique_service_entries[service_name] = nil
    end

    -- 当前活动批次；若退出实例是本批目标，就把退出结果写入该目标。
    local batch = self.active_batch
    if batch and batch.service_targets then
        for _, service_target in ipairs(batch.service_targets) do
            if service_target.service_handle == service_handle and not service_target.exited then
                service_target.exited = true
                service_target.hotupgrade_result = flywow_result.failure("HU_SERVICE_EXITED",
                    "Service " .. service_handle .. " 在发布期间退出")
                if batch.phase == "PREPARE" or batch.phase == "UPDATE" then
                    batch.error = batch.error or service_target.hotupgrade_result
                elseif batch.phase == "PUBLISH_DECIDED" then
                    batch.error = batch.error or flywow_result.failure("HU_RECOVERY_REQUIRED",
                        service_target.hotupgrade_result.message, {step = "finish"})
                end
                tracked = true
            end
        end
    end

    -- 受管理记录清理后，未知退出事件仅在原生创建尚未返回时暂存。
    if not tracked then
        if self.native_creations_in_flight > 0 then
            self.early_exit_handles[service_handle] = true
        end
    end

    -- 所有退出事实就绪后只发一次通知；存在待创建记录时由它的收尾路径唤醒。
    if creation then
        self:finish_creation(service_handle)
    else
        self:wake_batch()
    end
end

--- 唤醒等待 register 消息来源与原生创建 handle 匹配的协程。
--- 被唤醒协程会重新查询创建表；唤醒本身不代表登记已成功。
---@return nil
function M:wake_registration()
    -- 这些等待者尚不能把 register 的 source 对上创建 handle；唤醒只通知它们重查索引。
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
---@field host_relative_path string 该许可绑定的宿主相对 Lua 文件路径

---@class FlyWowHotUpgradeServiceCreationRequest
---@field service_name string 原生 Service 入口，不改写调用方业务初始化参数
---@field arguments table 带 n 的启动参数数组；按原生 newservice 约束传递
---@field global? boolean true 明确拒绝；不支持跨节点全局唯一

---@class FlyWowHotUpgradeServiceCreation
---@field creator_service_handle integer 首次调用者身份；仅该来源可取消尚未登记的创建。
---@field service_name string 原生 Service 入口名；后续用于 Patch 匹配。

--- Update 门禁关闭时暂停新的 Service 创建或模块首次加载请求。
--- 门禁重新开放后返回；调用方醒来后仍须重新检查唯一名、许可或批次条件。
---@return nil
function M:wait_lifecycle()
    -- lifecycle_gate_waiters 保存尚未受理的请求协程，不计入原生创建、待登记或模块许可。
    while lifecycle_closed(self) do
        -- 这里可能是 newservice、uniqueservice 或首次 require 请求；它们都要等创建/更新门禁开放。
        -- 保存当前 RPC 协程；入口开放后唤醒它，让请求重新检查唯一名、许可和批次条件。
        local waiter = coroutine.running()
        self.lifecycle_gate_waiters[waiter] = true
        skynet.wait(waiter)
        self.lifecycle_gate_waiters[waiter] = nil
    end
end

--- 检查受管理创建请求里的 Service 名、启动参数和真实调用者来源。
--- 通过校验后，调用方才能占用一个原生创建名额并调用 newservice。
---@param request FlyWowHotUpgradeServiceCreationRequest newservice/uniqueservice 收到的请求；本函数检查入口名 service_name、启动参数 arguments 和可选的 global 标记。
---@param source integer Skynet 消息头中的调用方 Service handle；本函数将它记为创建者，之后只有它能取消未登记的 Service。
---@return boolean 请求字段是否完整且 source 是否为有效的创建者 handle。
local function valid_service_creation_request(request, source)
    return math.type(source) == "integer" and source > 0 and valid_service_name(request.service_name)
        and type(request.arguments) == "table"
        and math.type(request.arguments.n) == "integer" and request.arguments.n >= 0
        and (request.global == nil or type(request.global) == "boolean")
end

--- 调用原生 skynet.newservice；返回有效且未退出的 handle 后建立待登记记录。
--- 原生创建可能 yield；本函数返回 handle 后不等待业务 init 或 register_service。
---@param self FlyWowHotUpgradeController 当前 Controller；本函数维护原生创建在途数，并按返回的 handle 保存待登记记录。
---@param request FlyWowHotUpgradeServiceCreationRequest 已通过校验的创建请求；本函数把 service_name 和 arguments 原样传给 Skynet。
---@param source integer 创建 RPC 消息头中的真实调用者 handle；写入创建记录供之后权限核对。
---@return FlyWowResult<{service_handle:integer}> 成功载荷包含 service_handle
local function start_service(self, request, source)
    -- 原生启动可能 yield，此时尚无目标 handle，发布和早到登记据在途数决定是否等待。
    self.native_creations_in_flight = self.native_creations_in_flight + 1
    -- 原生调用的执行结果和返回值；调用失败时第二项是用于诊断的异常值。
    local create_succeeded, service_handle = pcall(function()
        return skynet.newservice(request.service_name,
            table.unpack(request.arguments, 1, request.arguments.n))
    end)
    self.native_creations_in_flight = self.native_creations_in_flight - 1

    -- 只拿有效的真实 handle 核对已收到的退出通知，失败值不会用来查表。
    local valid_handle = create_succeeded and math.type(service_handle) == "integer" and service_handle > 0
    -- 此 handle 已收到 MONITOR 退出通知时，不建立待登记记录。
    local exited_before_return = valid_handle and self.early_exit_handles[service_handle]
    if self.native_creations_in_flight == 0 then
        self.early_exit_handles = {}
    elseif exited_before_return then
        self.early_exit_handles[service_handle] = nil
    end

    -- 启动失败或目标已退出，无需等待登记。等待未知 handle 的登记协程也要重查。
    if not valid_handle or exited_before_return then
        self:wake_batch()
        self:wake_registration()
        if exited_before_return then
            return flywow_result.failure("HU_SERVICE_EXITED", "Service 在原生创建返回前退出")
        end
        return flywow_result.failure("HU_SERVICE_CREATE_FAILED", tostring(service_handle))
    end

    -- 同一次不 yield 的执行内转成待登记记录，发布协程不会看到虚假的排空。
    self.service_creations[service_handle] =
    {
        creator_service_handle = source,               -- 原创建者拥有待登记 Service 的取消权。
        service_name           = request.service_name, -- 登记后按该入口名匹配 Service Patch。
    }
    self:wake_registration()
    return flywow_result.success({service_handle = service_handle})
end

--- 按本 Controller 内的 service_name 查找或创建唯一 Service。
--- 已有 handle 直接返回；同名创建在途时等待其结果；创建失败释放预留供后续重试。
---@param request FlyWowHotUpgradeServiceCreationRequest uniqueservice 传入的入口名、启动参数和唯一性选项；本函数按 service_name 查找或建立本地唯一创建记录。
---@param source integer Skynet 消息头中的真实请求者 handle；首次创建时保存为创建者，后续重复调用只等待结果。
---@return FlyWowResult<{service_handle:integer}> 成功载荷包含 service_handle；global=true 和不支持的特殊入口返回明确失败。
function M:uniqueservice(request, source)
    -- unique_service_entries 按逻辑入口名合并请求；其中 handle 表示可复用实例，waiters 表示首次创建仍在途。
    -- 先检查 Service 名、调用者 handle 和启动参数，再决定复用实例、等待创建或发起创建。
    if request.global == true then
        return flywow_result.failure("HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED", "受管理唯一服务只支持本 Controller 内的本地唯一")
    end

    if not valid_service_creation_request(request, source) then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要创建者、逻辑 Service 名和完整启动参数")
    end

    if request.service_name == "snaxd" then
        return flywow_result.failure("HU_SPECIAL_SERVICE_UNSUPPORTED", "snaxd 不会自行调用 register_service，不能纳入受管理 Service 创建流程")
    end

    -- 该逻辑名对应的唯一 Service 记录；可能保存现有 handle 或首次创建的等待者。
    local unique_service_entry = self.unique_service_entries[request.service_name]
    if not (unique_service_entry and unique_service_entry.service_handle) then
        self:wait_lifecycle()
        -- 这里会等到当前热更批次结束；恢复后重新查询名字，避免等待期间已有同名 Service 创建完成。
        unique_service_entry = self.unique_service_entries[request.service_name]
    end

    -- 生命周期门禁释放后已重新查询唯一名，再复用实例或等待创建结果。
    if unique_service_entry then
        if unique_service_entry.service_handle then
            return flywow_result.success({service_handle = unique_service_entry.service_handle})
        end
        -- 保存当前 uniqueservice RPC 协程；原生创建返回 handle 后唤醒它，并返回该 handle 或创建错误。
        local waiter = coroutine.running()
        unique_service_entry.waiters[waiter] = true
        skynet.wait(waiter)
        unique_service_entry.waiters[waiter] = nil
        return unique_service_entry.error or flywow_result.success({service_handle = unique_service_entry.service_handle})
    end

    -- 没有同名实例或创建在途时，先建立一条共享记录，再启动一次 Service 创建。
    ---@type FlyWowHotUpgradeUniqueServiceEntry
    unique_service_entry =
    {
        waiters = {}, -- 同名创建尚未完成时暂存调用协程；创建结果确定后全部唤醒。
    }
    self.unique_service_entries[request.service_name] = unique_service_entry
    -- 把创建结果写进共享记录；同名等待者醒来后从这条记录读取 handle 或错误。
    local creation_result = start_service(self, request, source)
    if creation_result.ok then
        unique_service_entry.service_handle = creation_result.value.service_handle
    else
        unique_service_entry.error = creation_result
        if self.unique_service_entries[request.service_name] == unique_service_entry then
            self.unique_service_entries[request.service_name] = nil
        end
    end

    -- 唯一创建结果已写入共享记录后，唤醒所有同名等待者读取结果。
    for waiter in pairs(unique_service_entry.waiters) do
        skynet.wakeup(waiter)
    end
    return creation_result
end

--- 接收管理端的受管理 Service 创建命令，校验请求后进入共同创建流程。
---@param request FlyWowHotUpgradeServiceCreationRequest hotupgrade.newservice 转来的入口名和启动参数；本函数校验后交给 start_service 调用原生 Skynet 创建。
---@param source integer Skynet 消息头中的创建者 handle；用于限制谁能取消尚未登记的实例。
---@return FlyWowResult<{service_handle:integer}> 成功载荷包含 service_handle
function M:newservice(request, source)
    if not valid_service_creation_request(request, source) then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要创建者、Service 名和启动参数")
    end
    if request.service_name == "snaxd" then
        return flywow_result.failure("HU_SPECIAL_SERVICE_UNSUPPORTED", "snaxd 不会自行调用 register_service，不能纳入受管理 Service 创建流程")
    end

    -- 请求检查通过后，等当前热更批次结束，再创建并登记新 Service。
    self:wait_lifecycle()
    return start_service(self, request, source)
end

--- 由创建者取消已创建但尚未登记的 Service，并在终止成功后释放创建记录。
--- 已登记、未知 handle 或非创建者均返回明确失败，不终止 Service。
---@param request {service_handle:integer} 包含 service_handle 的取消请求；handle 必须来自先前 newservice 成功返回。
---@param source integer Skynet 消息头中的取消请求者 handle；必须与创建记录里的 creator_service_handle 相同。
---@return FlyWowResult<nil> 取消结果。
function M:cancel_service_creation(request, source)
    -- service_creations 只用于找到待登记实例的创建者；登记表中已有该 handle 时不再具有取消创建权。
    if math.type(request.service_handle) ~= "integer" then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要待登记 Service handle")
    end

    -- 按 handle 找到尚未登记实例的创建记录，供创建者权限和收尾检查。
    local creation = self.service_creations[request.service_handle]
    if self.service_registrations[request.service_handle] then
        return flywow_result.failure("HU_SERVICE_ALREADY_REGISTERED", "已登记 Service 不能取消创建")
    end
    if not creation then
        return flywow_result.failure("HU_CREATION_MISSING", "没有可取消的待登记 Service")
    end
    if creation.creator_service_handle ~= source then
        return flywow_result.failure("HU_UNAUTHORIZED", "只有创建者可以取消该 Service")
    end

    -- skynet.kill 抛错时转换为取消失败结果，并保留原生错误内容。
    local kill_succeeded, kill_failure = pcall(skynet.kill, request.service_handle)
    if not kill_succeeded then
        return flywow_result.failure("HU_SERVICE_CANCEL_FAILED", tostring(kill_failure))
    end

    -- 只有映射指向被取消的实例才释放唯一名；普通创建允许使用同一个入口名。
    local unique_service_entry = self.unique_service_entries[creation.service_name]
    if unique_service_entry and unique_service_entry.service_handle == request.service_handle then
        self.unique_service_entries[creation.service_name] = nil
    end

    -- 取消和原生终止处理完成后，统一移除创建记录并唤醒等待者。
    self:finish_creation(request.service_handle)
    return flywow_result.success()
end

---@class FlyWowHotUpgradeModuleLoadRequest
---@field host_relative_path string 受控 Lua 模块相对于宿主根目录的文件路径
---@field permit_id? string begin 返回的不复用 ID；完成或取消命令必须携带

--- 在已登记 Service 第一次执行普通 require 前发放一次性许可，避免加载过程与批次更新交错。
---@param request FlyWowHotUpgradeModuleLoadRequest 普通 require 传来的宿主相对文件路径 host_relative_path；本函数为这个 Service 和文件路径创建一次性许可。
---@param source integer 发起 require 的已登记 Service handle；许可只属于这个 Lua State。
---@return FlyWowResult<{permit_id:string}> 成功载荷包含 permit_id
function M:begin_module_load(request, source)
    -- 来源 Service 的登记集合决定谁能申请许可；loading_modules 按文件路径防重，许可总表则用于批次排空。
    self:wait_lifecycle()

    -- 消息来源对应的已登记 Service；只有它能申请或完成自己的首次模块加载。
    local service_registration = self.service_registrations[source]
    if not service_registration then
        return flywow_result.failure("HU_SERVICE_NOT_REGISTERED", "模块加载者未登记")
    end

    if type(request.host_relative_path) ~= "string" or request.host_relative_path == "" then
        return flywow_result.failure("HU_INVALID_REQUEST", "文件路径无效")
    end

    if service_registration.loading_modules[request.host_relative_path] then
        return flywow_result.failure("HU_MODULE_LOADING", "该模块已有未完成的加载许可")
    end

    -- 来源、批次门禁和模块唯一许可均已核验，分配新的许可身份。
    self.module_permit_sequence = self.module_permit_sequence + 1
    -- 本 Controller 生成且不复用的许可编号；模块登记或取消时必须原样带回。
    local permit_id = tostring(skynet.self()) .. ":module:" .. self.module_permit_sequence
    self.module_load_permits[permit_id] =
    {
        service_handle     = source,                     -- 获得许可的已登记 Service；退出通知据此释放许可。
        host_relative_path = request.host_relative_path, -- 许可只允许登记或取消申请时指定的文件。
    }
    service_registration.loading_modules[request.host_relative_path] = permit_id
    return flywow_result.success({permit_id = permit_id})
end

--- 登记普通模块首次加载成功，或在加载失败时取消许可。
--- 只接受许可所属 Service；成功登记会把文件路径加入其模块集合并消费许可。
---@param request FlyWowHotUpgradeModuleLoadRequest require 完成时传回的 permit_id 和宿主相对文件路径 host_relative_path；本函数用两者找到并核对先前发放的许可。
---@param source integer 原许可申请 Service 的真实 handle；防止其他 Service 消费该许可。
---@param cancel boolean 加载失败时为 true，只删除许可；加载成功后为 false，登记模块并消费许可。
---@return FlyWowResult<nil> 完成或取消许可的结果。
function M:complete_module_load(request, source, cancel)
    -- request.permit_id 指向此前授予的唯一加载操作；先核对来源和模块，再同时消费许可及按文件路径建立的索引。
    ---@type FlyWowHotUpgradeModuleLoadPermit
    local permit = self.module_load_permits[request.permit_id]
    if not permit then
        return flywow_result.failure("HU_MODULE_PERMIT_MISSING", "模块加载许可不存在或已消费")
    end
    if permit.service_handle ~= source then
        return flywow_result.failure("HU_UNAUTHORIZED", "模块加载许可来源不匹配")
    end
    if permit.host_relative_path ~= request.host_relative_path then
        return flywow_result.failure("HU_MODULE_PERMIT_MISMATCH", "文件路径与许可不匹配")
    end

    -- 退出时许可和登记一起清除；匹配到的有效许可仍有对应的 Service 登记记录。
    local service_registration = self.service_registrations[source]

    -- 许可身份和文件路径均匹配后，成功加载才登记模块所有权。
    if not cancel and not service_registration.module_paths[request.host_relative_path] then
        service_registration.module_paths[request.host_relative_path] = true
    end

    -- 登记或取消结果确定后，消费许可并释放模块在途索引。
    self.module_load_permits[request.permit_id] = nil
    service_registration.loading_modules[request.host_relative_path] = nil
    self:wake_batch()
    return flywow_result.success()
end

---@class FlyWowHotUpgradeNewModuleRequest
---@field batch_id string 当前正在更新的批次身份
---@field host_relative_path string 受控 Lua 模块相对于宿主根目录的文件路径

--- 把当前 Update 目标通过 Service .patch 的 new_modules 清单加载的新模块加入该 Service 登记集合。
--- 仅当前批次和正在执行 Update 的目标来源可以登记；该模块从下一批普通 Stage 起参与匹配。
---@param request FlyWowHotUpgradeNewModuleRequest Service .patch 的 new_modules 加载流程提交的 batch_id 和宿主相对文件路径 host_relative_path；本函数据此核对批次并登记模块。
---@param source integer 发送登记请求的目标 Service handle；必须是当前活动批次中正在 Update 的目标。
---@return FlyWowResult<nil> 登记结果。
function M:register_new_module(request, source)
    -- active_batch 的阶段、身份和 current_service_handle 共同限定本轮正在等待 Update 的目标，不能借此登记其他 Service。
    if type(request.batch_id) ~= "string" or type(request.host_relative_path) ~= "string" or request.host_relative_path == "" then
        return flywow_result.failure("HU_INVALID_REQUEST", "需要批次身份和文件路径")
    end

    -- 当前活动批次；新模块登记必须属于正处于 UPDATE 的同一目标。
    local batch = self.active_batch
    if not batch or batch.batch_id ~= request.batch_id or batch.phase ~= "UPDATE"
        or batch.current_service_handle ~= source then
        return flywow_result.failure("HU_NEW_MODULE_NOT_ALLOWED", "仅当前批次正在更新的目标可登记新模块")
    end

    -- 正在更新的 Service 登记记录；成功后把新文件路径加入它的模块集合。
    local service_registration = self.service_registrations[source]
    if not service_registration then
        return flywow_result.failure("HU_SERVICE_NOT_REGISTERED", "模块声明者未登记")
    end

    -- 来源、批次和声明权限确认后，把新模块写入 Service 登记集合。
    service_registration.module_paths[request.host_relative_path] = true
    return flywow_result.success()
end

--- 登记业务 Service 的模块清单和更新能力，并将它关联到受管理创建记录。
--- 若登记早于原生 newservice 返回，本调用会 yield，直到真实 handle 可核对。
---@param request FlyWowHotUpgradeTargetMetadata 业务 Service 启动时提交的宿主相对文件路径列表 module_paths 和更新能力标记 has_service_update；本函数保存为该 Service 的登记信息。
---@param service_handle integer Skynet 消息头中的真实业务 Service handle；必须与受管理 newservice 返回值一致。
---@return FlyWowResult<nil> Service 登记结果。
function M:register(request, service_handle)
    -- request.module_paths 是目标 State 的初始声明数组；这里转为路径集合，随后与真实创建记录绑定。
    -- 先校验登记元数据并构造模块集合，失败时不写入 Controller 目标表。
    if math.type(service_handle) ~= "integer" or type(request.module_paths) ~= "table"
        or type(request.has_service_update) ~= "boolean" then
        return flywow_result.failure("HU_INVALID_OPTIONS", "登记元数据无效")
    end

    if self.service_registrations[service_handle] then
        return flywow_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
    end

    -- 把请求中的文件路径数组转成集合，后续可按路径检查 Service 是否声明过模块。
    local module_paths = {}
    -- 统计有效文件路径数量，最后与数组长度比较以发现列表空洞。
    local module_count = 0
    for index, host_relative_path in pairs(request.module_paths) do
        if math.type(index) ~= "integer" or index < 1 or index > #request.module_paths
            or type(host_relative_path) ~= "string" or host_relative_path == "" or module_paths[host_relative_path] then
            return flywow_result.failure("HU_INVALID_OPTIONS", "模块声明列表无效")
        end
        module_paths[host_relative_path] = true
        module_count = module_count + 1
    end

    if module_count ~= #request.module_paths then
        return flywow_result.failure("HU_INVALID_OPTIONS", "模块声明数组有空洞")
    end

    -- register 可能先于 newservice 返回；这里 yield 等真实 handle 建好索引后再完成登记。
    local creation = self.service_creations[service_handle]
    while not creation do
        if self.native_creations_in_flight == 0 then
            return flywow_result.failure("HU_CREATION_MISSING", "来源不是受管理入口创建的待登记 Service")
        end

        -- 保存 register RPC 协程；newservice 返回真实 handle 后唤醒它继续绑定登记。
        local waiter = coroutine.running()
        self.service_registration_waiters[waiter] = true
        skynet.wait(waiter)
        self.service_registration_waiters[waiter] = nil
        if self.service_registrations[service_handle] then
            return flywow_result.failure("HU_DUPLICATE_SERVICE", "Service 已登记")
        end
        creation = self.service_creations[service_handle]
    end

    -- 待登记创建仍阻止批次关门；绑定真实来源后释放这条创建记录。
    ---@type FlyWowHotUpgradeRegisteredService
    local registered_service =
    {
        service_name       = creation.service_name,      -- 来自该 handle 对应的受管理创建记录。
        module_paths       = module_paths,               -- 该 State 声明的宿主相对文件路径集合。
        loading_modules    = {},                         -- 同一 Service/模块同时只允许一项首次加载操作。
        has_service_update = request.has_service_update, -- 是否提供本地 Service 状态/函数入口。
    }
    self.service_registrations[service_handle] = registered_service
    self:finish_creation(service_handle)
    return flywow_result.success()
end

--- 按每个已登记 Service 的模块清单和入口名筛选本批候选。
--- 创建或复用 service_targets 记录，并返回是否存在尚未 Prepare 的目标。
---@param batch FlyWowHotUpgradeBatch 已读取候选模块和 Service .patch 的本批记录；本函数根据当前登记信息重建目标列表 service_targets。
---@param registered_services table<integer, FlyWowHotUpgradeRegisteredService> Controller 按 Service handle 保存的登记信息；本函数读取每个 Service 的文件路径和入口名来挑选本批候选。
---@return FlyWowResult<boolean> 成功时替换目标列表并返回是否有未 Prepare 目标；失败时保留旧列表。
local function match_service_targets(batch, registered_services)
    -- 先按真实 handle 建旧目标索引；匹配回来的 Service 必须保留其 Prepare 和恢复进度。
    -- 上一轮已匹配的目标记录按真实 handle 索引，用来保留 Prepare、退出和恢复进度。
    local service_targets_by_handle = {}
    for _, service_target in ipairs(batch.service_targets or {}) do
        service_targets_by_handle[service_target.service_handle] = service_target
    end

    -- 暂存按最新登记表生成的目标；全部匹配成功后才替换批次原有列表。
    local service_targets = {} -- 保存本轮匹配到的 Service 及它们将收到的候选模块。
    local matched_services = {} -- 记录每个 .patch 是否匹配到支持更新的已登记 Service。
    local needs_prepare = false -- 有新目标尚未 Prepare 时置 true，run_batch 会再匹配一轮。
    -- 以最新登记表重建目标清单，并在生成目标时同时计算是否需要再做一轮 Prepare。
    for service_handle, service_registration in pairs(registered_services) do
        -- 登记记录的 modules 是名称集合；本地 modules 则保存本目标真正要收到的候选源码项。
        local modules = {}
        for _, module_patch in ipairs(batch.modules) do
            if service_registration.module_paths[module_patch.host_relative_path] then
                modules[#modules + 1] = module_patch
            end
        end

        -- 与当前 Service 入口名匹配的 .patch；没有对应文件时为 nil。
        local service_patch = batch.service_patches[service_registration.service_name]
        if service_patch and not service_registration.has_service_update then
            return flywow_result.failure("HU_SERVICE_PATCH_UNSUPPORTED", batch.patch_dir .. "/" .. service_patch.patch_relative_path
                .. ": 目标 " .. service_handle .. " 未提供 Service 内部更新入口")
        end
        if service_patch then
            matched_services[service_patch.patch_relative_path] = true
        end

        if #modules > 0 or service_patch then
            -- 本 Service 在上一轮目标列表中的记录；复用它才能保留 Prepare 和退出结果。
            local service_target = service_targets_by_handle[service_handle]
            if not service_target then
                service_target =
                {
                    service_handle = service_handle, -- register 消息来源；后续 Prepare/Update/Abort/Finish 都发给它。
                }
            end
            -- 当前 Service 要执行的 Service Patch；nil 表示本批只更新普通模块。
            service_target.service_patch = service_patch
            -- 只含当前 Service 已登记模块的候选源码，避免把其他 Service 的模块发来。
            service_target.modules = modules
            if not service_target.participated then
                needs_prepare = true
            end
            service_targets[#service_targets + 1] = service_target
        end
    end

    -- 先确保每个 Service .patch 都有真实目标；验证完整后才替换批次目标快照。
    for service_name, service_patch in pairs(batch.service_patches) do
        if not matched_services[service_patch.patch_relative_path] then
            return flywow_result.failure("HU_TARGET_MISSING", batch.patch_dir .. "/" .. service_patch.patch_relative_path
                .. ": 没有已登记目标匹配 Service 名称 " .. service_name)
        end
    end

    -- 所有 Patch 均匹配成功后，按 handle 排序以固定 RPC 顺序。
    table.sort(service_targets, function(left, right)
        return left.service_handle < right.service_handle
    end)
    batch.service_targets = service_targets
    return flywow_result.success(needs_prepare)
end

--- 扫描 batch.patch_dir 并读取全部 Lua 与 Service .patch 文件，建立正式文件、普通模块和 Service Patch 三份清单。
--- Lua 文件只做语法编译检查，不执行；源码留在 batch 中供后续部署和 Update 使用。
---@param controller FlyWowHotUpgradeController 已初始化的 Controller；提供 patch_root 和 service_path 来定位并分类发布文件。
---@param batch FlyWowHotUpgradeBatch begin 创建的本批记录；本函数从 patch_dir 读取文件，并把结果写入 files、modules 和 service_patches。
---@return FlyWowResult<nil> 失败返回路径、读取或语法错误；成功时三个发布视图均已建立
local function freeze_patch_files(controller, batch)
    -- patch_root 是全部发布包的根，batch.patch_dir 只选择本包；输出分别服务文件部署、模块 Update 和 Service Patch 匹配。
    if type(batch.patch_dir) ~= "string" then
        return flywow_result.failure("HU_INVALID_PATCH", "需要相对 patch_root 的 patch_dir")
    end

    -- 一次扫描并固定所选发布目录的文件列表；排序后按稳定顺序读取和匹配目标。
    -- 发布目录中的 Lua 与 Service Patch 相对路径列表，以及扫描失败时的错误信息。
    local paths, failure = hotupgrade_native.list_lua(controller.patch_root, batch.patch_dir)
    if not paths then
        -- 转成 HotUpgrade 对外稳定的错误码，供管理调用方按 code 判断失败类型。
        local code = native_code(failure)
        return flywow_result.failure(code,
            code == "HU_PATCH_EMPTY" and "发布包至少要有一个 .lua 或 Service .patch"
                or "Patch 目录扫描失败: " .. batch.patch_dir)
    end

    -- 目录扫描成功后按相对路径排序，固定后续读取、部署和恢复顺序。
    table.sort(paths)

    -- 保存本批目录中每个 Lua 文件的相对路径和新源码，正式部署及失败恢复都使用这里的固定内容。
    batch.files = {}
    -- 保存可由已登记模块名匹配的普通 Lua 候选；Service 自己的 Lua 文件不进入此集合。
    batch.modules = {}
    -- 按 Service 入口名保存对应的 .patch 源码，目标匹配时据此选择本 Service 的更新定义。
    batch.service_patches = {}
    -- 逐个读取并检查源码；文件部署清单、普通模块候选和 Service Patch 在此分开建立。
    -- 记录本批已遇到的普通 Lua 模块名；例如 a/b.lua 和 a.b.lua 都会变成 a.b，不能同时发布。
    local module_names = {}
    -- 宿主配置的 Service 目录前缀；它用于区分 Service 文件和可独立热更的普通模块。
    local service_prefix = controller.service_path .. "/"
    -- relative_path 是当前发布文件相对 Patch 目录的路径，用来读取文件并判定其类别。
    for _, relative_path in ipairs(paths) do
        -- 当前文件的新源码，以及读取失败时 Native 返回的诊断。
        local source, read_failure = hotupgrade_native.read_file(controller.patch_root, batch.patch_dir .. "/" .. relative_path)
        if source == nil or source == false then
            return flywow_result.failure(source == false and "HU_FILE_NOT_FOUND" or native_code(read_failure),
                "发布包读取失败: " .. batch.patch_dir .. "/" .. relative_path)
        end
        -- 只编译不执行的检查结果；chunk 证明语法有效，syntax_error 用于报告无效源码。
        local chunk, syntax_error = load(hotupgrade_common.normalize_source(source), "@" .. relative_path, "t", {})
        if not chunk then
            return flywow_result.failure("HU_MODULE_SYNTAX", syntax_error)
        end

        -- 当前 Lua 文件是否位于宿主 Service 目录；Service 文件不进入普通模块候选集合。
        local is_service = relative_path:sub(1, #service_prefix) == service_prefix
        if relative_path:sub(-6) == ".patch" then
            if not is_service then
                return flywow_result.failure("HU_INVALID_PATCH", ".patch 只能位于 service_path: " .. relative_path)
            end
            -- 从 Service 文件路径去掉目录前缀和 .patch 后得到入口名，用于匹配已登记实例。
            local service_name = relative_path:sub(#service_prefix + 1, -7)
            if not valid_service_name(service_name) or batch.service_patches[service_name] then
                return flywow_result.failure("HU_INVALID_PATCH", "Service 路径映射重复或无效: " .. relative_path)
            end
            batch.service_patches[service_name] =
            {
                patch_relative_path   = relative_path, -- 相对本批 patch_dir 的 .patch 路径，用于诊断和目标匹配。
                service_patch_source = source,        -- Controller 已读取并冻结的 Service Patch 源码。
            }
        else
            -- 正式部署的一条文件记录；保留相对路径和新源码供后续部署与恢复使用。
            local file =
            {
                host_relative_path = relative_path, -- 相对宿主 root_path 的正式 Lua 文件路径，用于部署和恢复。
                source             = source,        -- 从本批发布包读取并冻结的文件内容。
            }
            batch.files[#batch.files + 1] = file
            if not is_service then
                -- 普通 Lua 文件对应的 require 名；按斜杠转点，例如 a/b.lua 得到 a.b。
                local name = module_name(relative_path)
                if not name or name == "" or module_names[name] then
                    return flywow_result.failure("HU_INVALID_PATCH", "Lua 路径映射重复或无效: " .. relative_path)
                end
                module_names[name] = true
                -- 普通模块与正式文件共用冻结记录；缓存别名用于排序和定位目标 State 的导出表。
                file.name = name
                batch.modules[#batch.modules + 1] = file
            end
        end
    end

    -- Lua 文件分类完成后排序普通模块候选，稳定目标请求内容。
    table.sort(batch.modules, function(left, right)
        return left.name < right.name
    end)
    return flywow_result.success()
end

--- 向一个目标 Service 发送 prepare、update、abort 或 finish RPC，并返回远端结果或 RPC 失败结果。
--- Skynet call 可能 yield；RPC 异常转换为 FlyWowResult，不推断远端是否已执行。
---@param batch FlyWowHotUpgradeBatch 当前发布记录；本函数保存正在处理的 Service handle 和结果。
---@param service_target FlyWowHotUpgradeServiceTarget 本次要更新的 Service 及其匹配结果；本函数读取 handle、普通模块源码和可选 Service .patch。
---@param command string 本次要发给 Service 的 prepare、update、abort 或 finish 命令；目标 Service 按它选择对应处理步骤。
---@return FlyWowResult<nil> 目标返回的热更结果，或本地 RPC 失败结果；调用可能 yield。
function M:call_target_control(batch, service_target, command)
    -- service_target 是本批复用的目标记录；modules 是筛选后的候选，service_patch 保存匹配到的 .patch 源码。
    ---@type FlyWowHotUpgradeControlRequest
    local request =
    {
        batch_id = batch.batch_id, -- Controller 生成的本批身份，Service 用它拒绝其他批次命令。
    }

    if command == "update" then
        request.modules = service_target.modules -- 当前 Service 已登记模块对应的候选源码。
        request.service_patch_source = service_target.service_patch and service_target.service_patch.service_patch_source -- 当前 Service 的更新脚本源码；没有匹配脚本时为 nil。
    end

    if service_target.exited then
        return service_target.hotupgrade_result
    end

    -- 捕获 skynet.call 的 RPC 异常并转换为 FlyWowResult；不猜测远端是否已执行。
    local call_succeeded, service_result = pcall(skynet.call,
        service_target.service_handle, "hotupgrade", command, request)
    if service_target.exited then
        return service_target.hotupgrade_result
    end
    if not call_succeeded or type(service_result) ~= "table" or type(service_result.ok) ~= "boolean" then
        return flywow_result.failure("HU_RPC_FAILED", tostring(service_result), {step = command})
    end

    -- Service Patch 失败时附上脚本路径，便于定位发布包中的文件。
    if not service_result.ok and service_target.service_patch then
        service_result.message = service_target.service_patch.patch_relative_path .. ": " .. (service_result.message or service_result.code)
    end
    return service_result
end

--- 正常发布等待已受理的 Service 创建和普通模块首次加载排空。
--- 批次一旦失败就结束等待，由调用方进入现有恢复流程。
---@param controller FlyWowHotUpgradeController 保存待创建和许可记录的 Controller；本函数等相应集合清空。
---@param batch FlyWowHotUpgradeBatch 当前等待的活动批次；本函数在其中保存 waiter 协程。
---@return nil 可能 yield；在途记录清空或批次失败后返回。
local function wait_for_batch_work(controller, batch)
    -- 两张事实表分别记录待登记创建和待消费许可；退出通知写入 batch.error 后无需继续排空。
    while not batch.error and has_pending_lifecycle_work(controller) do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end
end

--- 读取发布包并保存每个正式 Lua 文件部署前的内容，再检查目标匹配。
---@param controller FlyWowHotUpgradeController 已初始化的 Controller；提供 patch_root、root_path 和 service_path。
---@param batch FlyWowHotUpgradeBatch 本批记录；本函数把新源码和部署前旧内容分别保存到 batch.files。
---@return FlyWowResult<nil> 读取和匹配成功；失败返回文件或匹配错误。
local function load_and_snapshot_batch_files(controller, batch)
    -- 固定并校验发布包，后续部署不再读取发布目录。
    local frozen = freeze_patch_files(controller, batch)
    if not frozen.ok then
        return frozen
    end

    -- 用已登记 Service 的文件路径和入口名找出首轮 Prepare 目标。
    local matched = match_service_targets(batch, controller.service_registrations)
    if not matched.ok then
        return matched
    end

    -- 再为每个正式文件保存部署前内容，供部分部署失败时恢复。
    -- 旧内容只由 Controller 持有，避免随普通模块文件记录发给目标 Service。
    batch.old_sources = {}
    for _, file in ipairs(batch.files) do
        local old_source, read_failure = hotupgrade_native.read_file(controller.root_path, file.host_relative_path)
        if old_source == nil then
            return flywow_result.failure(native_code(read_failure), "文件准备失败: " .. file.host_relative_path)
        end
        batch.old_sources[file.host_relative_path] = old_source
    end
    return flywow_result.success()
end

--- 逐轮向尚未准备的目标发送 Prepare，并在新目标加入前等待创建和许可排空。
---@param controller FlyWowHotUpgradeController 负责发送目标 RPC 和记录 Service 退出的 Controller。
---@param batch FlyWowHotUpgradeBatch 保存本批目标及其 Prepare 进度的记录。
---@return FlyWowResult<nil> 所有目标都已 Prepare；目标返回失败、创建/加载等待失败或目标匹配失败时返回具体失败结果。
local function prepare_batch_targets(controller, batch)
    batch.phase = "PREPARE"

    -- 先 Prepare 当前已匹配目标；逐个检查控制 RPC 和异步退出记录。
    while true do
        for _, service_target in ipairs(batch.service_targets) do
            if not service_target.participated then
                batch.current_service_handle = service_target.service_handle
                service_target.participated = true
                local service_result = controller:call_target_control(batch, service_target, "prepare")
                if batch.error then
                    return batch.error
                end
                if not service_result.ok then
                    service_target.hotupgrade_result = service_result
                    return service_result
                end
            end
        end

        -- Prepare RPC 可能让出协程；等已受理的创建和模块首次加载结束后，重新读取登记表并匹配新 Service。
        wait_for_batch_work(controller, batch)
        if batch.error then
            return batch.error
        end
        local matched = match_service_targets(batch, controller.service_registrations)
        if not matched.ok then
            return matched
        end
        if not matched.value then
            break
        end
    end
    return flywow_result.success()
end

--- Prepare 全部完成后部署本批正式 Lua 文件并清理 Skynet 缓存。
---@param controller FlyWowHotUpgradeController 提供 root_path 的 Controller；正式文件写入该宿主根目录。
---@param batch FlyWowHotUpgradeBatch 保存了新源码和旧文件快照的批次；每次替换成功后推进 deployed_file_count。
---@return FlyWowResult<nil> 部署与缓存清理成功；失败返回 Native 文件或缓存错误。
local function deploy_batch_files(controller, batch)
    batch.phase = "UPDATE"

    -- 按清单顺序安装；遇到首个失败即停止，只有下标不超过部署进度的文件需要恢复。
    for index, file in ipairs(batch.files) do
        local file_written, write_failure = hotupgrade_native.replace_file(
            controller.root_path, file.host_relative_path, file.source)
        if not file_written then
            return flywow_result.failure(native_code(write_failure), "部署失败: " .. file.host_relative_path)
        end
        batch.deployed_file_count = index
    end

    -- 所有文件写入成功后再清理 Lua 缓存；清理失败仍由上层恢复文件。
    if batch.deployed_file_count > 0 then
        local cache_cleared, cache_failure = pcall(skynet.cache.clear)
        if not cache_cleared then
            return flywow_result.failure("HU_CACHE_CLEAR_FAILED", tostring(cache_failure))
        end
    end
    return flywow_result.success()
end

--- 按固定目标顺序发送 Update；首个失败交给批次恢复流程。
---@param controller FlyWowHotUpgradeController 负责发送 Update 并接收 Service 退出通知的 Controller。
---@param batch FlyWowHotUpgradeBatch 正式文件已部署的活动批次。
---@return FlyWowResult<nil> 所有目标 Update 成功；失败返回首个目标或异步生命周期错误。
local function update_batch_targets(controller, batch)
    for _, service_target in ipairs(batch.service_targets) do
        batch.current_service_handle = service_target.service_handle
        local service_result = controller:call_target_control(batch, service_target, "update")
        if batch.error then
            return batch.error
        end
        if not service_result.ok then
            service_target.hotupgrade_result = service_result
            return service_result
        end
    end
    return flywow_result.success()
end

--- 按顺序读取发布包、Prepare 目标、部署文件并执行 Update。
---@param controller FlyWowHotUpgradeController 持有本批进度和宿主目录配置的唯一 Controller。
---@param batch FlyWowHotUpgradeBatch begin 建立的活动批次；本函数按发布顺序处理各阶段。
---@return FlyWowResult<nil> 各阶段均成功；失败直接返回所属阶段结果，可能 yield。
local function prepare_and_update_batch(controller, batch)
    -- 先固定当前批次的 Patch 源码和旧文件快照，失败恢复使用同一份基线。
    local result = load_and_snapshot_batch_files(controller, batch)
    if not result.ok then
        return result
    end

    -- 所有目标进入安全点后，才允许替换宿主上的正式文件。
    result = prepare_batch_targets(controller, batch)
    if not result.ok then
        return result
    end

    -- 部署本批已固定的 Patch 文件；任一写入失败后由上层恢复已替换项。
    result = deploy_batch_files(controller, batch)
    if not result.ok then
        return result
    end

    -- 文件部署完成后再通知目标执行 Update。
    return update_batch_targets(controller, batch)
end

--- 更新失败时先逆序恢复已替换的正式文件并清缓存，再逆序 Abort 已参与且仍存活的目标。
--- 单项恢复失败会记录下来，但不会停止恢复其他文件和目标。
---@param controller FlyWowHotUpgradeController 提供宿主 root_path 和目标控制 RPC 的 Controller。
---@param batch FlyWowHotUpgradeBatch 更新失败的批次；本函数只恢复已替换文件，并 Abort 已参与且未退出的 Service。
---@return nil Abort RPC 可 yield；尽力恢复后设为 ABORTED 或 RECOVERY_REQUIRED，后续批次仍可执行。
local function recover_batch(controller, batch)
    -- 部署进度限定要恢复的文件前缀；目标列表的 participated/exited 决定哪些实例仍需 Abort。
    local recovery_errors = {}    -- 汇总所有恢复失败；单项失败不停止其余文件或目标恢复。
    local recovery_failure        -- 保留第一份结构化恢复错误，供最终结果携带诊断。

    -- 从最后一个已替换的文件逆序恢复；首个部署失败的文件及其后续项无需处理。
    for index = batch.deployed_file_count, 1, -1 do
        -- 按部署顺序定位已写入的文件，再按路径查找原始内容；false 原样表示旧文件不存在。
        local file = batch.files[index]
        local old_source = batch.old_sources[file.host_relative_path]
        local restore_called, file_restored, restore_failure = pcall(hotupgrade_native.replace_file,
            controller.root_path, file.host_relative_path, old_source or nil)
        if not restore_called or not file_restored then
            recovery_failure = recovery_failure or flywow_result.failure(
                restore_called and native_code(restore_failure) or "HU_CONTROL_FAILED", file.host_relative_path)
            recovery_errors[#recovery_errors + 1] = file.host_relative_path .. ": "
                .. tostring(restore_called and native_code(restore_failure) or file_restored)
        end
    end

    -- 所有已替换文件都尝试恢复后，再清理恢复文件对应的 Lua 缓存。
    if batch.deployed_file_count > 0 then
        -- 恢复文件后的缓存清理结果；失败也报告，但仍继续 Abort 已 Prepare 的目标。
        local cache_cleared, cache_failure = pcall(skynet.cache.clear)
        if not cache_cleared then
            recovery_failure = recovery_failure or flywow_result.failure("HU_CACHE_CLEAR_FAILED", tostring(cache_failure))
            recovery_errors[#recovery_errors + 1] = tostring(cache_failure)
        end
    end

    -- 再逆序撤销已参与且仍存活的目标；失败目标也不能跳过其余 Abort。
    for index = #batch.service_targets, 1, -1 do
        -- 当前倒序撤销的目标 Service；只对本批已参与且尚未退出的实例发送 Abort。
        local service_target = batch.service_targets[index]
        if service_target.participated and not service_target.exited then
            -- 当前目标的 Abort 结果；单个目标恢复失败不跳过剩余目标。
            local restored = controller:call_target_control(batch, service_target, "abort")
            if not restored.ok and not service_target.exited then
                recovery_failure = recovery_failure or restored
                recovery_errors[#recovery_errors + 1] = service_target.service_handle .. ": "
                    .. tostring(restored.message or restored.code)
                service_target.hotupgrade_result = restored
            end
        end
    end

    -- 文件和目标恢复均已完成；汇总错误供终态和管理查询使用。
    if #recovery_errors > 0 then
        batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(recovery_errors, "; "),
            {original_error = batch.error or recovery_failure, recovery_error = recovery_failure})
    end

    -- 恢复和 Abort 均已尝试后，根据汇总错误确定批次终态。
    batch.phase = (#recovery_errors > 0 or batch.error.code == "HU_RECOVERY_REQUIRED")
        and "RECOVERY_REQUIRED" or "ABORTED"
end

--- 发布决定后向所有参与目标发送 Finish，并汇总收尾错误。
--- Finish 失败只报告为 RECOVERY_REQUIRED，不回滚已提交目标。
---@param controller FlyWowHotUpgradeController 向参与目标发送 Finish 的 Controller。
---@param batch FlyWowHotUpgradeBatch 所有目标 Update 已成功并已进入 PUBLISH_DECIDED 的批次。
---@return nil 将批次阶段设为 COMPLETED 或 RECOVERY_REQUIRED。
local function finish_batch(controller, batch)
    -- 目标的 hotupgrade_result 在此记录 Finish 或退出结果；发布决定已作出，错误只影响收尾报告。
    batch.phase = "PUBLISH_DECIDED"
    for _, service_target in ipairs(batch.service_targets) do
        batch.current_service_handle = service_target.service_handle
        if not service_target.exited then
            service_target.hotupgrade_result = controller:call_target_control(batch, service_target, "finish")
        end
        if not service_target.hotupgrade_result.ok then
            batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED",
                service_target.hotupgrade_result.message or service_target.hotupgrade_result.code, {step = "finish"})
        end
    end

    -- 所有 Finish 结果汇总后才确定批次终态；发布决定已作出，不回滚。
    batch.phase = batch.error and "RECOVERY_REQUIRED" or "COMPLETED"
end

--- 生成批次最终查询结果，释放批次源码和恢复快照，并重新开放等待入口。
--- 最后保存 last_batch、清空 active_batch，再唤醒生命周期等待者。
---@param controller FlyWowHotUpgradeController 保存 active_batch、last_batch 和等待协程的 Controller。
---@param batch FlyWowHotUpgradeBatch 已完成或已恢复的活动批次；本函数汇总结果并把它转存为 last_batch。
---@return nil 批次成为 last_batch，active_batch 清空。
local function complete_batch(controller, batch)
    -- service_targets 仍持有参与状态和恢复结果；先汇总到终态 service_results，再释放目标和源码快照。
    for _, service_target in ipairs(batch.service_targets) do
        if service_target.participated then
            -- 该目标已记录的最后结果；若尚无目标结果，则用批次失败原因生成结果。
            local service_result = service_target.hotupgrade_result or (batch.error
                and flywow_result.failure("HU_BATCH_ABORTED", "本批失败，已尝试恢复")
                or flywow_result.success())
            batch.service_results[#batch.service_results + 1] =
            {
                service_handle   = service_target.service_handle, -- 该条结果对应的目标 Service。
                hotupgrade_result = service_result,              -- 目标最后一次控制步骤的 FlyWowResult。
            }
        end
    end

    -- 活动目标列表即将释放，终态 status 仍需保留最终匹配数量。
    batch.target_service_count = #batch.service_targets
    batch.service_targets = nil
    batch.files = nil
    batch.old_sources = nil
    batch.deployed_file_count = nil
    batch.modules = nil
    batch.service_patches = nil
    controller.last_batch = batch
    controller.active_batch = nil
    controller:wake_lifecycle()
end

--- 后台推进 begin 接受的这一批发布；成功走 Finish，失败走恢复，然后统一保存终态。
--- 等待和 RPC 可能 yield；终态记录完成后唤醒生命周期等待者。
---@param batch FlyWowHotUpgradeBatch begin 创建并放入 active_batch 的记录；本函数读取 path 并持续更新 phase、error 和结果。
---@return nil 等待和 RPC 可 yield；错误保存在 batch.error/phase，终态由 complete_batch 保存。
function M:run_batch(batch)
    -- 先等本批开始前已受理的 Service 创建和模块首次加载结束，再部署文件并 Prepare 目标。
    wait_for_batch_work(self, batch)

    -- Prepare/Update 主流程是否正常结束；异常在此转换为批次级控制错误。
    local control_succeeded, control_result = pcall(prepare_and_update_batch, self, batch)
    if not control_succeeded then
        batch.error = flywow_result.failure("HU_CONTROL_FAILED", tostring(control_result))
    elseif not control_result.ok then
        batch.error = control_result
    end

    -- Prepare/Update 已得出批次结果；失败进入恢复，成功进入发布完成阶段。
    if batch.error then
        local recovery_completed, recovery_exception = pcall(recover_batch, self, batch)
        if not recovery_completed then
            batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED", tostring(recovery_exception),
                {original_error = batch.error})
            batch.phase = "RECOVERY_REQUIRED"
        end
    else
        local finish_completed, finish_exception = pcall(finish_batch, self, batch)
        if not finish_completed then
            batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED", tostring(finish_exception), {step = "finish"})
            batch.phase = "RECOVERY_REQUIRED"
        end
    end

    -- 恢复或 Finish 结果写回后，保存批次终态并唤醒生命周期等待者。
    complete_batch(self, batch)
end

--- 在途记录清空或批次失败时唤醒发布协程；协程恢复后重新检查结束条件。
---@return nil
function M:wake_batch()
    -- 目标退出使批次失败时，即使无关操作尚未完成，也要唤醒协程执行恢复。
    local batch = self.active_batch
    if batch and batch.waiter
        and (batch.error or not has_pending_lifecycle_work(self)) then
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

--- 校验管理端发布目录，建立活动批次并立即返回 batch_id，然后启动后台发布协程。
--- 成功表示请求已接受，不表示热更完成；调用方用 batch_id 查询最终结果。
---@param request FlyWowHotUpgradeManagementRequest 管理端 begin 请求；path 是相对 patch_root 的发布目录，本函数校验后固定到新批次。
---@return FlyWowResult<{batch_id:string}> 成功仅表示接受请求；最终结果通过 status(batch_id) 查询
function M:begin(request)
    if self.active_batch then
        return flywow_result.failure("HU_UPGRADE_BUSY", "已有发布屏障")
    end

    -- 请求通过并发屏障后，才分配批次身份并固定发布目录。
    self.batch_sequence = self.batch_sequence + 1
    ---@type FlyWowHotUpgradeBatch
    local batch =
    {
        batch_id             = tostring(skynet.self()) .. ":" .. self.batch_sequence, -- 管理端用它查询这次发布；迟到命令也用它确认批次身份。
        patch_dir            = request.path,                                          -- 相对 patch_root 的发布目录；begin 接受时固定并从此冻结源码。
        phase                = "WAITING_CREATIONS",                                   -- run_batch 推进；生命周期门禁和 status 视图据此生成。
        deployed_file_count  = 0,                                                     -- 顺序部署已完成的文件数；失败时只恢复这段文件。
        service_results      = {},                                                    -- 保存每个目标 Service 的最终结果，供 status 返回成功/失败明细。
        service_targets      = {},                                                    -- 保存本批实际需要执行控制命令的 Service；Update 前确定，终态后释放。
    }
    self.active_batch = batch

    -- begin 只接受请求并立即返回；后台协程推进发布和终态恢复。
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

--- 生成管理端 status 返回的生命周期视图，并在指定 batch_id 时附上对应批次结果。
--- 查询只读现有记录，不改变批次状态；找不到指定批次时返回 HU_BATCH_MISSING。
---@param controller FlyWowHotUpgradeController 已初始化并持有批次/登记记录的 Controller；本函数只读取这些记录生成视图。
---@param request FlyWowHotUpgradeManagementRequest 管理端 status 查询；带 batch_id 时附上该批结果，省略时只返回当前创建、加载和发布情况。
---@return FlyWowResult 查询成功包含 lifecycle；指定批次时另含 record，批次不存在时报告 HU_BATCH_MISSING
local function handle_status_request(controller, request)
    -- 活动批次提供当前进度，last_batch 保留最近恢复诊断；查询只生成视图，不改变两份记录。
    local lifecycle_batch = controller.active_batch or controller.last_batch
    -- 查询视图使用的阶段；优先显示活动批次，没有活动批次时显示最近终态或 IDLE。
    local phase = lifecycle_batch and lifecycle_batch.phase or "IDLE"
    if controller.active_batch then
        if phase == "PREPARE" or phase == "UPDATE" or phase == "PUBLISH_DECIDED" then
            phase = "APPLYING"
        end
    elseif lifecycle_batch and lifecycle_batch.error then
        phase = "IDLE"
    end

    -- 管理查询字段由批次事实生成，沿用现有对外值，不独立保存和同步。
    local recovery_required = controller.last_batch ~= nil and controller.last_batch.phase == "RECOVERY_REQUIRED"
    if controller.active_batch and lifecycle_batch.phase == "PUBLISH_DECIDED" and lifecycle_batch.error then
        recovery_required = lifecycle_batch.error.code == "HU_RECOVERY_REQUIRED"
    end

    -- 对外保留在途数量，但每次从唯一事实表统计，不另存同步计数。
    local pending_service_count = controller.native_creations_in_flight
    for _ in pairs(controller.service_creations) do
        pending_service_count = pending_service_count + 1
    end

    -- 现场统计尚未完成登记或取消的首次模块加载许可数，不另存同步计数。
    local pending_module_count = 0
    for _ in pairs(controller.module_load_permits) do
        pending_module_count = pending_module_count + 1
    end

    -- 管理端查询时临时生成的进度视图，不作为 Controller 的另一份长期状态。
    local lifecycle =
    {
        phase = phase, -- 管理端显示的当前发布阶段。
        batch_id = lifecycle_batch and lifecycle_batch.batch_id, -- 当前进度所属批次；空闲时为最近结束批次。
        pending_service_count = pending_service_count, -- 尚未完成登记或取消的 Service 创建数。
        pending_module_count = pending_module_count, -- 尚未结束登记或取消的模块首次加载数。
        active_batch_id = controller.active_batch and controller.active_batch.batch_id, -- 正在执行批次的身份；无活动批次时为 nil。
        recovery_required = recovery_required, -- 最近批次是否报告恢复失败；只报告，不限制下一批。
    }
    if request.batch_id == nil then
        return flywow_result.success({lifecycle = lifecycle, recovery_required = recovery_required})
    end

    -- 指定身份优先匹配活动批次，否则只允许查询最近终态；不将另一批次结果冒充本次响应。
    local requested_batch = controller.active_batch and controller.active_batch.batch_id == request.batch_id and controller.active_batch or controller.last_batch
    if not requested_batch or requested_batch.batch_id ~= request.batch_id then
        return flywow_result.failure("HU_BATCH_MISSING", "仅保留活动及最近终态批次")
    end

    -- 活动期间结果列表为空，计数自然为 0；终态直接统计保留的结果快照。
    local succeeded_service_count = 0 -- 本批成功的终态目标数。
    local failed_service_count    = 0 -- 本批失败的终态目标数。
    for _, service_result in ipairs(requested_batch.service_results) do
        if service_result.hotupgrade_result.ok then
            succeeded_service_count = succeeded_service_count + 1
        else
            failed_service_count = failed_service_count + 1
        end
    end

    -- 确认查询到目标批次后，组装终态计数和逐 Service 结果。
    ---@type FlyWowHotUpgradeBatchStatus
    local batch_status =
    {
        batch_id = requested_batch.batch_id, -- 本次查询对应的发布批次身份。
        phase = requested_batch.phase, -- 批次当前或最终阶段。
        succeeded_service_count = succeeded_service_count, -- 已成功完成更新的目标 Service 数量。
        failed_service_count = failed_service_count, -- 更新或恢复失败的目标 Service 数量。
        target_service_count = requested_batch.service_targets and #requested_batch.service_targets or requested_batch.target_service_count, -- 当前目标列表长度或已释放列表前保存的终态数量。
        current_service_handle = requested_batch.current_service_handle, -- 当前或最近一次推进 Prepare、Update 或 Finish 时记录的目标。
        service_results = requested_batch.service_results, -- 各目标 Service 的控制结果及错误详情。
        error = requested_batch.error, -- 批次级失败或恢复报告；不作为下一批门禁。
    }
    return flywow_result.success(
    {
        record = batch_status, -- 指定 batch_id 对应的当前或终态发布记录。
        lifecycle = lifecycle, -- Controller 当前生命周期视图。
        recovery_required = recovery_required, -- 最近批次是否报告无法完全恢复。
    })
end

--- 按管理命令名称把请求交给对应 Controller 方法，并统一返回 FlyWowResult。
--- 各命令方法分别检查消息来源和该命令实际读取的请求字段。
---@param command FlyWowHotUpgradeManagementCommand 管理端或业务 Service 发送的命令名，例如 begin、status、register。
---@param request FlyWowHotUpgradeManagementRequest|FlyWowHotUpgradeTargetMetadata|FlyWowHotUpgradeServiceCreationRequest|FlyWowHotUpgradeModuleLoadRequest|FlyWowHotUpgradeNewModuleRequest 随命令解包得到的请求表；具体字段由对应命令方法读取。
---@param source integer Skynet 消息头中的真实发送方 handle；用于确认登记、创建和模块许可的归属。
---@return FlyWowResult<table> begin 返回 batch_id、status 返回 lifecycle/record、创建返回 service_handle；登记/许可命令通常无载荷，失败返回稳定 code。
function M:handle_command(command, request, source)
    if type(request) ~= "table" then
        return flywow_result.failure("HU_INVALID_REQUEST", "请求必须是 table")
    end

    -- 请求形状通过入口校验后，按命令名转交给各自负责权限和字段检查的方法。
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
        return handle_status_request(self, request)
    end

    return flywow_result.failure("HU_UNKNOWN_COMMAND", tostring(command))
end

return M
