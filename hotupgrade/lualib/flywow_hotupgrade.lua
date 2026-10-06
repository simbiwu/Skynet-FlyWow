--- 热更公开入口；Service 显式注册，不接管业务 dispatch，不共享 Lua State 对象。
local skynet = require "skynet"
local runtime_module = require "flywow_hotupgrade_runtime"
local rpc = require "flywow_hotupgrade_rpc"
local registry = require "flywow_hotupgrade_registry"
local result = require "flywow_hotupgrade_error"
local M = {}
local runtime
local managed_modules = {}

---@class flywow_hotupgrade_dependency
---@field target string registry.key(type, id) 生成的逻辑目标；由声明者持有
---@field edge? 'strong'|'weak' 默认 strong 阻止旧代退休；weak 失效时明确报错
---@field cross_generation? boolean 默认为 false；true 仍需调用方安全点才能切代

---@class flywow_hotupgrade_adapter
---@field dispatch? fun(command:string, payload:any):any 业务入口，可 yield，由 Guard 排空
---@field can_upgrade? fun():boolean 同步附加安全条件，false 继续等待
---@field export_state? fun(request:table):table 同步导出；框架复制，不传输运行时对象
---@field import_state? fun(snapshot:table, request:table):any 仅候选执行，接管框架提供的独占副本
---@field rebuild_runtime? fun(request:table):any 同步重建派生资源，不提前启动状态写入
---@field healthcheck? fun(request:table):boolean 同步无副作用候选检查
---@field postcheck? fun():boolean 原地更新激活后同步检查，false 恢复 exports 和配置
---@field on_resume? fun(request:table):any 同步启用候选后台任务，应可重复调用
---@field on_abort? fun(request:table):any 同步恢复旧运行资源；失败保持恢复状态
---@field prepare_retire? fun(request:table):any 同步释放排他资源，必须配套 cancel_retire
---@field cancel_retire? fun(request:table):any 同步恢复旧实例排他资源
---@field begin_drain? fun(request:table):any 同步开始业务排空
---@field can_retire? fun(request:table):boolean 同步退休条件，false 继续保留旧实例
---@field retire? fun(request:table):any 同步释放资源，成功后退出实例

---@class flywow_hotupgrade_registration
---@field controller integer 宿主启动的控制面 handle
---@field service_type string 业务无关的逻辑类型
---@field service_id string|integer 逻辑身份
---@field generation integer 实例代际
---@field code_version integer 当前代码版本
---@field state_version? integer schema 版本
---@field adapter flywow_hotupgrade_adapter 本 State 独占的生命周期函数，不跨 Service 序列化
---@field dependencies? flywow_hotupgrade_dependency[] 注册前声明，不含函数
---@field candidate? boolean 不提前发布
---@field replacement_mode? string drain/migrate
---@field trusted_modules? table 明确允许 Stage 访问的模块，需无副作用
---@field router_handle? integer 宿主显式启动的稳定 Router；nil 表示业务自行管理入口

---@class flywow_hotupgrade_service_ref_options
---@field target string 已声明的逻辑目标；最后一个引用 release 后撤销资格
---@field can_switch? fun():boolean 本 State 的同步安全条件
---@field timeout_ms? integer 毫秒；默认 10000，超时不意味着取消远端操作

--- 安装专用控制协议并注册元数据；可能 yield，注册失败不进入 READY。
---@param options flywow_hotupgrade_registration
---@return flywow_hotupgrade_result
function M.register_service(options)
    if runtime then return result.failure("HU_DUPLICATE_SERVICE", "当前 State 已注册") end
    if type(options) ~= "table" or type(options.controller) ~= "number"
        or type(options.service_type) ~= "string" or options.service_type == ""
        or (type(options.service_id) ~= "string" and math.type(options.service_id) ~= "integer")
        or math.type(options.generation) ~= "integer" or options.generation < 1
        or math.type(options.code_version) ~= "integer" or type(options.adapter) ~= "table" then
        return result.failure("HU_INVALID_OPTIONS", "注册参数不满足合同")
    end
    options.instance_id = options.instance_id or assert(require("flywow_hotupgrade_native").nonce())
    options.modules = {}
    for name in pairs(managed_modules) do options.modules[#options.modules + 1] = name end
    table.sort(options.modules)
    runtime = runtime_module.new(options)
    if options.candidate then runtime.guard:prepare_upgrade("candidate") end
    rpc.install(function(command, request, source) return runtime:control(command, request, source) end)

    local metadata =
    {
        key = registry.key(options.service_type, options.service_id),
        service_type = options.service_type, service_id = options.service_id,
        instance_id = options.instance_id,
        router_handle = options.router_handle,
        address = skynet.self(), generation = options.generation,
        code_version = options.code_version, state_version = options.state_version or 0,
        dependencies = options.dependencies or {}, modules = options.modules,
        candidate = options.candidate,
        replacement_mode = options.replacement_mode,
        capabilities = {},
    }
    for name, value in pairs(options.adapter or {}) do
        if type(value) == "function" then metadata.capabilities[name] = true end
    end
    return rpc.call(options.controller, "register", metadata, 10000)
end

---@param name string 需要保留 table 身份的模块名
---@return table
function M.require(name)
    local value = require(name)
    if type(value) ~= "table" then error("patchable module must return table") end
    if not managed_modules[name] then
        managed_modules[name] = true
        if runtime then
            local declared = rpc.call(runtime.options.controller, "register_module", {name = name}, 10000)
            if not declared.ok then error(declared.message or declared.code) end
        end
    end
    return value
end

---@param namespace string 当前 State 的非权威运行时命名
---@return table
function M.stable_state(namespace)
    assert(runtime, "register_service required")
    runtime.stable[namespace] = runtime.stable[namespace] or {}
    return runtime.stable[namespace]
end

--- 当前 State Guard；请求和后台状态写入都应进入此边界。
---@return table
function M.guard()
    assert(runtime, "register_service required")
    return runtime.guard
end

---@param name string 配置名
---@return table?
---@return integer?
function M.config(name)
    assert(runtime, "register_service required")
    return runtime.config:get(name)
end

M.runtime = function() return runtime end
---@param options table 稳定 Router handle、逻辑 key 与排队策略
---@return table
function M.router_ref(options)
    return require("flywow_hotupgrade_router_ref").new(options)
end
---@param options flywow_hotupgrade_service_ref_options
---@return flywow_hotupgrade_result
function M.service_ref(options)
    assert(runtime, "register_service required")
    options.controller = runtime.options.controller
    return require("flywow_hotupgrade_service_ref").new(options)
end
return M
