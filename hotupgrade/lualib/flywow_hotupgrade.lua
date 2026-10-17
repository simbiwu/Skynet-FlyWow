--- 热更公开入口；Service 显式注册，不接管业务 dispatch，不共享 Lua State 对象。
local skynet = require "skynet"
local runtime_module = require "flywow_hotupgrade_runtime"
local rpc = require "flywow_hotupgrade_rpc"
local registry = require "flywow_hotupgrade_registry"
local result = require "flywow_hotupgrade_error"
local native_error = require "flywow_hotupgrade_native_error"
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

--- 安装本 State 的专用控制协议并向控制面注册元数据；RPC 可能 yield，失败时不能接收业务流量。
---@param options flywow_hotupgrade_registration 注册身份、版本、控制 handle 与本地生命周期 Adapter；调用后补充 instance_id/modules。
---@return flywow_hotupgrade_result 注册成功后 Service 才可对外 READY；失败保留可判别的 HU_ 错误。
function M.register_service(options)
    if runtime then
        return result.failure("HU_DUPLICATE_SERVICE", "当前 State 已注册")
    end
    if type(options) ~= "table" or type(options.controller) ~= "number"
        or type(options.service_type) ~= "string" or options.service_type == ""
        or (type(options.service_id) ~= "string" and math.type(options.service_id) ~= "integer")
        or math.type(options.generation) ~= "integer" or options.generation < 1
        or math.type(options.code_version) ~= "integer" or type(options.adapter) ~= "table" then
        return result.failure("HU_INVALID_OPTIONS", "注册参数不满足合同")
    end
    -- 实例身份在启动时生成一次，并随控制面元数据固定到本 Service 生命周期。
    if not options.instance_id then
        local instance_id, identity_error = require("flywow_hotupgrade_native").nonce()
        if not instance_id then
            return result.failure(native_error.code(identity_error), "实例身份生成失败")
        end
        options.instance_id = instance_id
    end

    -- managed_modules 记录本 State 经本入口加载的模块，注册时一次性交给控制面。
    options.modules = {}
    for name in pairs(managed_modules) do
        options.modules[#options.modules + 1] = name
    end
    table.sort(options.modules)

    -- 先准备本地运行时和私有协议，再向控制面注册；注册成功前宿主不得标记 READY。
    runtime = runtime_module.new(options)
    if options.candidate then
        runtime.guard:prepare_upgrade("candidate")
    end
    rpc.install(function(command, request, source)
        return runtime:control(command, request, source)
    end)

    local metadata =
    {
        key              = registry.key(options.service_type, options.service_id),
        service_type     = options.service_type,
        service_id       = options.service_id,
        instance_id      = options.instance_id,
        router_handle    = options.router_handle,
        address          = skynet.self(),
        generation       = options.generation,
        code_version     = options.code_version,
        state_version    = options.state_version or 0,
        dependencies     = options.dependencies or {},
        modules          = options.modules,
        candidate        = options.candidate,
        replacement_mode = options.replacement_mode,
        capabilities     = {},
    }
    for name, value in pairs(options.adapter or {}) do
        if type(value) == "function" then
            metadata.capabilities[name] = true
        end
    end

    return rpc.call(options.controller, "register", metadata, 10000)
end

--- 通过稳定导出 table 加载模块；模块首次声明会同步通知控制面，因此调用可能 yield。
---@param name string Lua 模块名；Patch 必须使用相同名称，table 身份由当前 Lua State 保留。
---@return table 模块导出表；非 table 模块会抛出接入错误。
function M.require(name)
    local value = require(name)
    if type(value) ~= "table" then
        error("patchable module must return table")
    end

    -- 首次加载即声明模块依赖；登记 RPC 可能 yield，所以标记先写入以保持同 State 幂等。
    if not managed_modules[name] then
        managed_modules[name] = true
        if runtime then
            local declared = rpc.call(runtime.options.controller, "register_module", {name = name}, 10000)
            if not declared.ok then
                error(declared.message or declared.code)
            end
        end
    end
    return value
end

---@param namespace string 当前 Lua State 独占的稳定状态命名空间；不代表跨 Service 持久化。
---@return table 可变状态表；Module Patch Stage 期间只读，提交后仍保留原 table 身份。
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

--- 返回当前 State 的运行时句柄，供宿主诊断；不应跨 Service 或跨实例保存。
---@return table? 注册成功后的 Runtime；注册前为 nil。
M.runtime = function()
    return runtime
end
---@param options table 稳定 Router handle、逻辑 key、拒绝/排队策略与调用超时。
---@return table 本地 Router 引用；它只转发调用，不拥有 Router Service。
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
