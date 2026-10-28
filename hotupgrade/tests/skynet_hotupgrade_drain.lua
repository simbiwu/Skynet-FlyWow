--- 排空依赖夹具：使用真实 queue、创建和模块许可，由测试消息控制正常操作继续执行。
local skynet = require "skynet"
local business_queue = require "skynet.queue"() -- 测试用业务队列；运行中的任务可 yield，以验证热更是否等待队列排空。

-- 本集成测试 Worker 的运行配置、队列观测值和待验证模块加载结果。
local module_state =
{
    hotupgrade     = nil, -- 当前 State 的公开热更 API；start 内加载。
    logic          = nil, -- 初始声明模块，观察排空期间旧代码与更新后的新代码。
    extra          = nil, -- 排空期间首次声明的附加模块。
    dependency     = nil, -- 持有外层加载许可时首次声明的嵌套依赖。
    born_value     = nil, -- start 时读到的版本；新增目标在部署前应仍为旧版本。
    before_count   = 0,   -- 本批 Prepare 回调次数，发现重复排空时测试失败。
    waiting        = nil, -- 当前暂停的测试操作；inspect 可在 queue 外观察。
    waiter         = nil, -- release 消息唤醒的业务协程，不参与生产实现。
    children       = {},  -- 本 Service 正常创建并完成初始化的子 Service。
    functions      = {},  -- 原有业务函数表，Patch 直接替换 load。

    -- 与 Service Patch 对应的私有状态；更新保持这张根表的身份。
    state =
    {
        equip = "刀",
        level = 50,
        schema_version = 1,
    },
}

function module_state.functions.load(item)
    return item.base_attack
end

--- 暂停指定测试操作，inspect 显示暂停点，release 命令唤醒同一业务协程。
---@param operation string worker 当前暂停的操作名；管理测试用它选择并释放对应等待点。
local function wait_for_release(operation)
    -- waiting 是观察标签，waiter 才是等待中的协程；它们不属于 HotUpgrade 的生产状态。
    module_state.waiting = operation
    module_state.waiter = coroutine.running()
    skynet.wait(module_state.waiter)
    module_state.waiter = nil
    module_state.waiting = nil
end

--- 通过公开热更入口创建并登记子 Service，保留 handle 供管理测试遍历创建树。
---@param config table 传给子 Service init 的配置；本函数用它设置后续创建深度和故障注入。
---@param unique? boolean 是否走本 Controller 的唯一 Service 创建入口
local function create_child(config, unique)
    local hotupgrade = module_state.hotupgrade -- 父测试 Service 保存的 HotUpgrade API，用它创建受管理子 Service。
    -- 通过逻辑唯一名创建或复用排空 Worker 的 Service handle。
    local service_handle = unique and hotupgrade.uniqueservice("skynet_hotupgrade_drain")
        or hotupgrade.newservice("skynet_hotupgrade_drain")
    assert(skynet.call(service_handle, "lua", "init", config).ok)
    module_state.children[#module_state.children + 1] = service_handle
    return service_handle
end

--- 按场景配置初始化及 Prepare 中的依赖创建，再登记当前排空测试 Service。
---@param config table init_depth 控制初始化创建链，prepare_depth 控制 Prepare 内创建链
local function initialize(config)
    -- config 被 before_upgrade 闭包保留；每个子实例收到递减的深度，父实例的配置不被改写。
    if config.wait_init then
        wait_for_release("init")
    end
    if (config.init_depth or 0) > 0 then
        create_child({init_depth = config.init_depth - 1})
    end

    return module_state.hotupgrade.register_service({
        service_update = {state = module_state.state, functions = module_state.functions},
        before_upgrade = function()
            module_state.before_count = module_state.before_count + 1
            return business_queue(function()
                if config.fail_before then return false end
                if (config.prepare_depth or 0) > 0 then
                    create_child({
                        prepare_depth = config.prepare_depth - 1,
                        fail_before = config.child_fail_before,
                        fail_after = config.child_fail_after,
                    })
                end
                return true
            end)
        end,
        after_upgrade = function()
            return not config.fail_after
        end,
    })
end

skynet.start(function()
    module_state.hotupgrade = require "flywow_hotupgrade"
    module_state.logic = module_state.hotupgrade.require("test_worker_logic")
    module_state.born_value = module_state.logic.value()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        -- 当前 Worker 消息处理结果，返回给测试驱动协程。
        local answer
        if command == "init" then
            answer = initialize(request)
        elseif command == "inspect" then
            -- children 保存本实例创建的直接子 handle，born_value 固定记录启动时版本，value 则读取当前模块版本。
            answer = {
                waiting = module_state.waiting,
                paused = module_state.hotupgrade.patching,
                before_count = module_state.before_count,
                children = module_state.children,
                born_value = module_state.born_value,
                value = module_state.logic.value(),
                extra = module_state.extra and module_state.extra.value(),
                dependency = module_state.dependency and module_state.dependency.value(),
                equip = module_state.state.equip,
                schema_version = module_state.state.schema_version,
                attack = module_state.functions.load({base_attack = 100}),
            }
        elseif command == "release" then
            assert(module_state.waiter, "没有等待中的测试业务")
            skynet.wakeup(module_state.waiter)
            answer = true
        elseif command == "work" or command == "hold" then
            assert(not module_state.hotupgrade.patching, "测试业务必须在 Prepare 前进入")
            answer = business_queue(function()
                wait_for_release("queue")
                if command == "work" then
                    create_child({init_depth = 1}, request.unique)
                    module_state.extra = module_state.hotupgrade.require("hotupgrade_extra")
                end
                return {value = module_state.logic.value(),
                    extra = module_state.extra and module_state.extra.value()}
            end)
        elseif command == "declare" then
            module_state.extra = module_state.hotupgrade.require("hotupgrade_extra")
            answer = module_state.extra.value()
        elseif command == "nested_load" then
            answer = business_queue(function()
                -- 只在测试加载器中暂停外层许可；恢复后通过公开入口申请内层许可。
                local original_require = _G.require
                local source_path = assert(package.searchpath("hotupgrade_extra", package.path)) -- 原生 require 搜索到的额外模块路径，测试在此处控制加载时机。
                _G.require = function(name)
                    if name == "hotupgrade_extra" then
                        wait_for_release("module")
                        module_state.dependency = module_state.hotupgrade.require("battle.state_sync.runtime")
                        return original_require(name), source_path
                    end
                    return original_require(name), package.searchpath(name, package.path)
                end
                -- 模块加载调用是否成功及其返回表；用于验证排空期间首次加载的结果。
                local ok, loaded = pcall(module_state.hotupgrade.require, "hotupgrade_extra")
                _G.require = original_require
                assert(ok, loaded)
                module_state.extra = loaded
                return {extra = loaded.value(), dependency = module_state.dependency.value()}
            end)
        else
            error("未知排空测试命令: " .. tostring(command))
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
