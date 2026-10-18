--- 热更公开入口；Service 显式注册，不接管业务 dispatch，不共享 Lua State 对象。
local skynet = require "skynet"
local result = require "flywow_hotupgrade_error"
local protocol = require "flywow_hotupgrade_protocol"
local M = {}
local service_runtime       -- 当前 Lua State 的热更 Runtime；在注册 RPC 前创建，持有本地控制状态。
local declared_modules = {} -- 本 State 通过 M.require 声明可参与受控模块更新的模块名集合。
local service_guard         -- 当前 Service 的 Guard；注册前创建时会由 Runtime 复用同一对象。

---@class FlyWowHotUpgradeAdapter
---@field dispatch fun(command:string, payload:any):any 必需业务入口，可 yield，由 Guard 排空
---@field can_upgrade? fun():boolean 同步附加安全条件，false 继续等待
---@field export_state? fun(request:table):any 同步只读返回 Service 状态 record；无外部副作用，false 表示拒绝
---@field import_state? fun(state:any, request:table):any 同步验证并接管候选私有状态；不写外部权威数据
---@field healthcheck? fun(request:table):boolean 同步无副作用候选检查；必须明确返回 true 才通过
---@field postcheck? fun():boolean 新模块安装后的同步无副作用检查；不得修改业务状态，false 恢复 exports

---@class FlyWowHotUpgradeRegistration
---@field controller_handle integer 宿主启动并传入的 Controller Service handle
---@field service_type string Patch services/<service_type>.lua 对应的逻辑类型
---@field origin_service_handle? integer 候选由 Controller 从旧实例继承；初代值取注册 RPC source，沿替换链不变，仅作身份键，不是当前 RPC 目标。
---@field adapter FlyWowHotUpgradeAdapter 本 State 的业务入口及可选状态合同
---@field candidate? boolean 不提前发布
---@field router_handle? integer 宿主显式启动的稳定 Router；nil 表示业务自行管理入口

--- 安装本 State 的专用控制协议并向控制面注册元数据；RPC 可能 yield，失败时不能接收业务流量。
---@param options FlyWowHotUpgradeRegistration 注册 Controller handle、逻辑类型及业务 Adapter；首代元数据由框架补充。
---@return FlyWowHotUpgradeResult 注册成功后 Service 才可对外 READY；失败保留可判别的 HU_ 错误。
function M.register_service(options)
    if service_runtime then
        return result.failure("HU_DUPLICATE_SERVICE", "当前 State 已注册")
    end
    if type(options) ~= "table" or math.type(options.controller_handle) ~= "integer"
        or type(options.service_type) ~= "string" or options.service_type == ""
        or (options.router_handle ~= nil and math.type(options.router_handle) ~= "integer")
        or type(options.adapter) ~= "table" or type(options.adapter.dispatch) ~= "function" then
        return result.failure("HU_INVALID_OPTIONS", "注册需要 Controller handle、Service 类型和业务 dispatch")
    end

    -- 候选身份只由 Controller 注入；初代身份由 Controller 从 Skynet RPC source 派生。
    if options.candidate then
        if math.type(options.origin_service_handle) ~= "integer" then
            return result.failure("HU_INVALID_OPTIONS", "候选逻辑身份必须由控制面提供")
        end
    end
    -- 新旧 Service 并存到候选完成切换，因此当前 Skynet handle 就能区分这两个实例。
    options.instance_handle = skynet.self()

    -- 将声明集合转为稳定数组，作为本实例可受控更新的模块清单。
    options.modules = {}
    for name in pairs(declared_modules) do
        options.modules[#options.modules + 1] = name
    end
    table.sort(options.modules)

    -- 先准备本地运行时和私有协议，再向控制面注册；注册成功前宿主不得标记 READY。
    if service_guard and service_guard.owner then
        return result.failure("HU_UPGRADE_BUSY", "本地安全点尚未释放")
    end
    service_runtime = require("flywow_hotupgrade_runtime").new(options)
    -- 注册前业务持有的 Guard 仍须有效；注册后更新统一走控制面，避免绕过历史与版本记录。
    service_runtime.guard = service_guard or service_runtime.guard
    service_guard = service_runtime.guard
    if options.candidate then
        service_runtime.guard:prepare_upgrade("candidate")
    end
    protocol.install_handler(function(command, request, source)
        return service_runtime:control(command, request, source)
    end)

    ---@class FlyWowHotUpgradeServiceMetadata
    ---@field service_type string Patch services/<service_type>.lua 对应的逻辑类型，用于目标匹配。
    ---@field origin_service_handle? integer 初代 Service handle 的整数值；当前 Controller 生命周期内沿替换链保持不变，用于 Registry、Router 和灰度，不是当前 RPC 目标。
    ---@field instance_handle integer 当前 Service 的 Skynet handle；作为实例身份随元数据传递并由 Runtime 核对。
    ---@field router_handle? integer 此逻辑 Service 的稳定 Router handle；缺省时不支持 Service 替换。
    ---@field modules string[] 当前 Lua State 声明可更新的模块名集合。
    ---@field candidate? boolean 是否为尚未发布、隔离运行的候选 Service。
    ---@field capabilities table<string, boolean> Adapter 实现的可选回调集合，用于核对新旧状态交接能力。
    ---@type FlyWowHotUpgradeServiceMetadata
    local metadata =
    {
        service_type           = options.service_type,
        origin_service_handle = options.origin_service_handle,
        instance_handle       = options.instance_handle,
        router_handle         = options.router_handle,
        modules          = options.modules,
        candidate        = options.candidate,
        capabilities     = {},
    }
    for _, name in ipairs({"export_state", "import_state"}) do
        if type(options.adapter[name]) == "function" then
            metadata.capabilities[name] = true
        end
    end

    local ok, registered = pcall(skynet.call, options.controller_handle, "hotupgrade", "register", metadata)
    if not ok then
        return result.failure("HU_RPC_FAILED", tostring(registered))
    end
    return registered or result.failure("HU_RPC_FAILED", "Controller 注册失败")
end

--- 通过稳定导出 table 加载可更新模块；注册前声明进入初始元数据，注册后新声明同步通知控制面。
--- 注册后的首次模块声明会 yield；本 State 内重复声明直接返回已缓存的导出表。
---@param name string Lua 模块名；Patch 必须使用相同名称，table 身份由当前 Lua State 保留。
---@return table 模块导出表；非 table 模块会抛出接入错误。
function M.require(name)
    local value = require(name)
    if type(value) ~= "table" then
        error("patchable module must return table")
    end

    -- 只在登记成功后标记；同 State 并发可重复发送幂等登记，失败/超时允许再次尝试。
    if not declared_modules[name] then
        if service_runtime then
            local ok, declared = pcall(skynet.call, service_runtime.options.controller_handle,
                "hotupgrade", "register_module", {name = name})
            if not ok then
                error("HU_RPC_FAILED: " .. tostring(declared))
            end
            if not declared then
                error("HU_RPC_FAILED: 模块登记失败")
            end
            if not declared.ok then
                error(declared.message or declared.code)
            end
        end
        declared_modules[name] = true
    end
    return value
end

--- 当前 State 的业务安全点；注册前可创建，注册时 Runtime 会复用同一对象。
---@return table 本 Service 独占的 Guard；所有受控业务处理都应经过它。
function M.guard()
    if not service_guard then
        service_guard = require("flywow_hotupgrade_guard").new(
        {
            now = function() return skynet.now() * 10 end,
            sleep = function(ms) skynet.sleep(math.max(1, math.ceil(ms / 10))) end,
        })
    end
    return service_guard
end

--- 创建稳定路由的本地调用器；origin_service_handle 是初代 Service handle。
---@param options table 含 router_handle、origin_service_handle；timeout_ms 可选，仅显式指定时限时使用 request/select。
---@return table 只转发调用、不拥有 Router Service 的本地调用器。
function M.router_ref(options)
    assert(type(options) == "table" and type(options.router_handle) == "number"
        and math.type(options.origin_service_handle) == "integer",
        "router_ref requires router_handle and origin_service_handle")
    local origin_service_handle = options.origin_service_handle

    return
    {
        call = function(_, command, payload)
            local request =
            {
                origin_service_handle = origin_service_handle,
                command = command,
                payload = payload,
            }
            if options.timeout_ms ~= nil then
                local requests = skynet.request
                {
                    options.router_handle, "hotupgrade", "request", request,
                }
                local called
                for _, response in requests:select(math.max(1, math.ceil(options.timeout_ms / 10))) do
                    called = response
                end
                if requests.timeout then
                    return result.failure("HU_RPC_TIMEOUT", "Router 请求超时")
                end
                return called or result.failure("HU_RPC_FAILED", "Router 请求失败")
            end
            local ok, called = pcall(skynet.call, options.router_handle,
                "hotupgrade", "request", request)
            if not ok then return result.failure("HU_RPC_FAILED", tostring(called)) end
            return called or result.failure("HU_RPC_FAILED", "Router 请求失败")
        end,
    }
end
return M
