--- 真实多 State：Service handle/状态身份、组合恢复、queue 排空、部分成功与恢复门禁。
-- 当前测试 Service 的 RPC、协程和等待接口。
local skynet = require "skynet"
require "skynet.manager"

-- 集中保存真实 Skynet 集成测试的 Controller handle、worker handle 和场景控制数据。
local module_state =
{
    hotupgrade_api            = nil,    -- 当前测试进程的 HotUpgrade Lua API；Skynet 启动时加载。
    hotupgrade_handle = nil,    -- 唯一 HotUpgrade Service handle；所有测试场景共用该实例。
    controller_initialized   = false,  -- 首次成功初始化后锁定配置，后续场景复用同一 Controller。
}

--- 初始化本进程唯一 Controller；后续场景复用同一 handle 和已发布配置。
---@param service_path? string 测试启动时传入的替代 Service 目录；省略时使用 HotUpgrade 默认 Service 目录。
local function create_controller(service_path)
    -- hotupgrade_handle 已由测试 start 创建；controller_initialized 表示 init RPC 已成功，不能重复改路径。
    -- 本进程共享的 Controller handle；只在首次调用时初始化配置。
    local hotupgrade_handle = module_state.hotupgrade_handle -- 真实 Skynet 中创建的 HotUpgrade Controller Service handle。
    if module_state.controller_initialized then
        assert(service_path == nil, "共享 Controller 不能重复更改配置")
        return hotupgrade_handle
    end
    assert(skynet.call(hotupgrade_handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    assert(skynet.call(hotupgrade_handle, "lua", "init", {}).code == "HU_INVALID_OPTIONS")
    -- 本测试运行夹具中的 patch/root/service 路径配置。
    local hotupgrade_config = require "hotupgrade_test_options"
    assert(skynet.call(hotupgrade_handle, "lua", "init",
        {patch_path = hotupgrade_config.patch_path, root_path = hotupgrade_config.root_path,
            service_path = service_path or hotupgrade_config.service_path}).ok)
    assert(skynet.call(hotupgrade_handle, "lua", "init", {}).code == "HU_ALREADY_INITIALIZED")
    module_state.controller_initialized = true
    return hotupgrade_handle
end

--- 创建测试 worker 并完成业务初始化；登记失败时由原创建者取消未完成实例。
---@param worker_config? table 测试场景传给 Worker init 的故障开关；省略时不注入故障。
local function create_worker_service(worker_config)
    -- 新创建的 Worker Service handle，后续 init 会向 Controller 登记它。
    local worker_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    worker_config = worker_config or {}
    -- Worker 初始化和 register_service 的最终结果。
    local registration_result = skynet.call(worker_handle, "lua", "init", worker_config) -- worker 首次登记的 RPC 结果。
    if not registration_result.ok then
        assert(module_state.hotupgrade_api.cancel_service_creation(worker_handle).ok)
        error(registration_result.message)
    end
    return worker_handle
end

--- 读取测试 Worker 的业务状态，供集成场景检查热更前后的值。
---@param worker_handle integer create_worker_service 返回的 Worker handle；本函数向该 Service 发送 read RPC。
local function read_worker_state(worker_handle)
    return skynet.call(worker_handle, "lua", "read", {})
end

--- 发起本批发布并返回 Controller 分配的 batch_id，供集成测试等待终态。
---@param hotupgrade_handle integer create_controller 返回的 Controller Service handle；本函数向它发送 begin。
---@param selected_patch_path string 相对 Patch 根目录的发布目录；本函数把它作为 begin 的 path。
local function begin_update_batch(hotupgrade_handle, selected_patch_path)
    -- Controller 是否接受了本次发布；成功值提供本批 batch_id。
    local begin_result = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = selected_patch_path})
    assert(begin_result.ok, tostring(begin_result.code) .. ":" .. tostring(begin_result.message))
    return begin_result.value.batch_id
end

--- 轮询指定批次到终态并核对预期；返回该批次状态记录供场景继续断言。
---@param hotupgrade_handle integer create_controller 返回的 Controller Service handle；本函数通过它查询批次状态。
---@param batch_id string begin 接受发布请求后返回的批次 ID；本函数只等待并查询这批发布。
---@param expected_phase string|table 本场景期望的终态名，或可接受的终态名数组；查询到其他终态时本函数让断言失败。
local function wait_for_batch_phase(hotupgrade_handle, batch_id, expected_phase)
    -- status.value.record 对应指定 batch_id；其中 error 是该批诊断，不代表 Controller 被锁定。
    for _ = 1, 1000 do
        -- Controller 对指定批次的最新查询结果。
        local batch_status = skynet.call(hotupgrade_handle, "hotupgrade", "status", {batch_id = batch_id})
        assert(batch_status.ok, batch_status.message)
        -- 指定批次的阶段和错误记录；此处用它判断终态。
        local batch_record = batch_status.value.record
        if batch_record.phase == "COMPLETED"
            or batch_record.phase == "ABORTED" or batch_record.phase == "PARTIAL" or batch_record.phase == "RECOVERY_REQUIRED" then
            assert(batch_record.phase == expected_phase or (type(expected_phase) == "table" and expected_phase[batch_record.phase]), batch_record.phase .. ":" ..
                tostring(batch_record.error and batch_record.error.message))
            return batch_record
        end
        skynet.sleep(1)
    end
    error("HotUpgrade integration timeout")
end

--- 对 worker 的只读快照核对初始业务值及对象身份，返回快照供调用方补充断言。
---@param worker_handle integer create_worker_service 返回的已登记 Worker handle；本函数读取并核对其初始状态。
local function assert_original_state(worker_handle)
    -- read 返回的是跨 State 的观察数据；各 identity 布尔值已在 worker 内与其原始引用比较。
    -- 跨 Service 读取的 Worker 状态快照，用来核对初始字段及对象身份。
    local worker_state = read_worker_state(worker_handle)
    assert(worker_state.service_handle == worker_handle and worker_state.state_identity and worker_state.lua_state_identity and worker_state.module_identity)
    assert(worker_state.equip == "刀" and worker_state.level == 50 and worker_state.schema_version == 1)
    assert(worker_state.attack == 100 and worker_state.module_value == 1 and worker_state.save_identity and not worker_state.paused)
    assert(worker_state.nested_count == 7)
    return worker_state
end

--- 查询 Controller 当前的生命周期视图；调用会经过真实 Skynet RPC。
---@param hotupgrade_handle integer create_controller 返回的 Controller Service handle；本函数读取当前生命周期视图。
local function lifecycle_status(hotupgrade_handle)
    -- 当前 Controller 的生命周期查询结果。
    local controller_status = skynet.call(hotupgrade_handle, "hotupgrade", "status", {})
    assert(controller_status.ok)
    return controller_status.value.lifecycle
end

--- 对管理入口发送不支持的操作并确认它们没有启动发布流程。
---@param hotupgrade_handle integer create_controller 返回的 Controller Service handle；本函数发送管理端请求确认不支持的命令被拒绝。
local function lifecycle_blocked(hotupgrade_handle)
    for _, command in ipairs({"unknown_command", "validate", "apply"}) do
        -- 未知管理命令的返回结果；本测试确认它不会创建活动批次。
        local rejected = skynet.call(hotupgrade_handle, "hotupgrade", command, {path = "module"}) -- 管理端主动 abort 请求的返回结果。
        -- 每个不支持管理命令都应返回的稳定错误码。
        local expected_code = "HU_UNKNOWN_COMMAND"
        assert(rejected.code == expected_code and rejected.value == nil)
    end
    assert(lifecycle_status(hotupgrade_handle).active_batch_id == nil)
end

--- 验证创建、业务登记和退出通知共同维护待登记屏障，取消权限属于原创建者。
local function creation_lifecycle_tests()
    -- lifecycle.pending_service_count 统计创建尚未完成的实例；收到 newservice handle 后仍可能为 1。
    local hotupgrade_handle = create_controller() -- 真实 Skynet 中创建的 HotUpgrade Controller Service handle。
    -- 原生 kill 不经包装，退出通知必须释放尚未登记的创建记录。
    local killed = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 1)
    skynet.kill(killed)
    for _ = 1, 1000 do
        if lifecycle_status(hotupgrade_handle).pending_service_count == 0 then
            break
        end
        skynet.sleep(1)
    end
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 0)
    -- 已创建但尚未 register_service 的 Worker handle，用于验证创建屏障。
    local pending = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 1)
    lifecycle_blocked(hotupgrade_handle)
    assert(not skynet.call(pending, "lua", "init", {init_failure = true}).ok)
    -- 已完成初始化和 Controller 登记的 Worker handle，用于冒充非创建者发取消请求。
    local registered = create_worker_service()
    -- 非创建者对 pending 发起取消后的拒绝结果。
    local unauthorized = skynet.call(registered, "lua", "cancel_creation",
        {service_handle = pending})
    assert(unauthorized.code == "HU_UNAUTHORIZED" and lifecycle_status(hotupgrade_handle).pending_service_count == 1)
    assert(module_state.hotupgrade_api.cancel_service_creation(pending).ok)
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 0)
    assert(module_state.hotupgrade_api.cancel_service_creation(registered).code == "HU_SERVICE_ALREADY_REGISTERED")
    pending = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(module_state.hotupgrade_api.cancel_service_creation(pending).ok)

    -- Worker 的独立协程可在原生返回前发出登记，但不阻止 start 回调结束。
    -- 启用 auto 启动参数后在原生创建返回前自行登记的 Worker handle。
    local early = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker", "auto", "original_tail")
    assert(assert_original_state(early).service_handle == early and lifecycle_status(hotupgrade_handle).pending_service_count == 0)
    -- 并发启动按各自真实 Service handle 关联；一项登记不能解除另一项的待登记屏障。
    -- 并发创建中会先自行登记的 Worker handle。
    -- 并发同名请求应复用的同一个 Service handle。
    local concurrent_early
    -- 并发创建中等待外部 init 才登记的 Worker handle。
    local concurrent_late
    skynet.fork(function()
        concurrent_early = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker",
            "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent_late = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    end)
    for _ = 1, 1000 do
        if concurrent_early and concurrent_late then
            break
        end
        skynet.sleep(1)
    end
    assert(concurrent_early and concurrent_late and concurrent_early ~= concurrent_late)
    assert_original_state(concurrent_early)
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 1)
    lifecycle_blocked(hotupgrade_handle)
    assert(skynet.call(concurrent_late, "lua", "init", {}).ok)
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 0)
    assert_original_state(concurrent_early)
    -- 没有匹配目标的发布终态记录，用于确认创建屏障解除后管理查询仍正常。
    local rejected = wait_for_batch_phase(hotupgrade_handle, begin_update_batch(hotupgrade_handle, "unmatched_service"), "ABORTED") -- 管理端主动 abort 请求的返回结果。
    assert(rejected.error.code == "HU_TARGET_MISSING")
    -- 发布结束后的生命周期快照，确认没有待登记 Service 或活动批次。
    local idle = lifecycle_status(hotupgrade_handle) -- 开始故障注入前的生命周期视图，确保没有遗留的在途创建或加载。
    assert(idle.pending_service_count == 0 and idle.phase == "IDLE")
    for _, fixture in ipairs({
        {name = "hotupgrade_missing_service"},
        {name = "skynet_hotupgrade_worker", mode = "fail"},
    }) do
        -- 创建失败调用是否抛错及其错误文本；夹具覆盖入口缺失和启动失败。
        local created, message = pcall(module_state.hotupgrade_api.newservice, fixture.name,
            fixture.mode)
        assert(not created and tostring(message):find("HU_SERVICE_CREATE_FAILED", 1, true))
        assert(lifecycle_status(hotupgrade_handle).pending_service_count == 0)
        -- 创建失败后再发起的空目标批次终态，确认失败没有遗留屏障。
        local rejected = wait_for_batch_phase(hotupgrade_handle, begin_update_batch(hotupgrade_handle, "unmatched_service"), "ABORTED") -- 管理端主动 abort 请求的返回结果。
        assert(rejected.error.code == "HU_TARGET_MISSING")
        -- 重复验证创建失败后生命周期回到空闲。
        local idle = lifecycle_status(hotupgrade_handle) -- 开始故障注入前的生命周期视图，确保没有遗留的在途创建或加载。
        assert(idle.pending_service_count == 0 and idle.phase == "IDLE")
    end
    print("HOTUPGRADE_SKYNET_CREATION_LIFECYCLE_OK")
end

--- 验证模块首次加载许可的等待、消费及排空期间新增依赖。
local function module_lifecycle_tests()
    -- pending_module_count 观察 Controller 的在途许可；loaded 标记则观察目标 RPC 是否已返回，不能互相替代。
    -- 共享 Controller handle；此函数内两段测试复用它并验证加载许可。
    local hotupgrade_handle = create_controller() -- 真实 Skynet 中创建的 HotUpgrade Controller Service handle。
    -- 已登记的 Worker handle；模块许可都由它发起。
    local worker_service_handle = create_worker_service() -- 本测试主 worker 的真实 Skynet handle。
    assert(skynet.call(worker_service_handle, "lua", "declare_failure", {}))
    assert(lifecycle_status(hotupgrade_handle).pending_module_count == 0)
    -- 慢速首次 require 是否已经返回，用于观察许可是否阻止批次。
    local loaded = false
    -- 并行普通 require 是否已经返回，与 pending_module_count 分开观察。
    local concurrent_loaded = false
    skynet.fork(function()
        assert(skynet.call(worker_service_handle, "lua", "declare_slow", {}) == 1)
        loaded = true
    end)
    for _ = 1, 1000 do
        if lifecycle_status(hotupgrade_handle).pending_module_count == 1 then
            break
        end
        skynet.sleep(1)
    end
    assert(lifecycle_status(hotupgrade_handle).pending_module_count == 1)
    lifecycle_blocked(hotupgrade_handle)
    skynet.fork(function()
        assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 1)
        concurrent_loaded = true
    end)
    for _ = 1, 1000 do
        if loaded and concurrent_loaded then
            break
        end
        skynet.sleep(1)
    end
    assert(loaded and concurrent_loaded and lifecycle_status(hotupgrade_handle).pending_module_count == 0)
    -- 排空前加载完成后发布的普通模块批次 ID。
    local extra_batch = begin_update_batch(hotupgrade_handle, "extra")
    assert(wait_for_batch_phase(hotupgrade_handle, extra_batch, "COMPLETED").target_service_count == 1)
    assert(read_worker_state(worker_service_handle).extra_value == 2)

    -- queue 排空期间仍接纳创建和首次声明，新目标使用旧文件并参与当前批次。
    hotupgrade_handle = create_controller()
    worker_service_handle = create_worker_service()
    skynet.fork(function()
        assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 100}).ok)
    end)
    while skynet.call(worker_service_handle, "lua", "holding", {}) == false do
        skynet.sleep(1)
    end
    -- 排空中启动的发布批次 ID；后续确认新增目标参与同一批。
    local id = begin_update_batch(hotupgrade_handle, "module") -- 本次集成发布的 batch_id，用于等待并查询终态。
    -- 门禁关闭前已被接纳创建、因此仍允许完成初始化的新 Worker handle。
    local admitted_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
    assert(skynet.call(admitted_handle, "lua", "init", {}).ok)
    assert(read_worker_state(admitted_handle).module_value == 1)
    assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 2)
    -- Controller 对本批排空阶段的生命周期快照。
    local status = lifecycle_status(hotupgrade_handle) -- 通过管理 RPC 查询的批次状态。
    assert(status.pending_service_count == 0 and status.pending_module_count == 0 and status.active_batch_id == id)
    wait_for_batch_phase(hotupgrade_handle, id, "COMPLETED")
    assert(read_worker_state(admitted_handle).module_value == 2)
    assert(module_state.hotupgrade_api.cancel_service_creation(admitted_handle).code == "HU_SERVICE_ALREADY_REGISTERED")
    print("HOTUPGRADE_SKYNET_MODULE_LIFECYCLE_OK")
end

--- 验证真实 Skynet 环境中的唯一 Service 创建、复用、等待和退出清理。
local function unique_lifecycle_tests()
    -- 本进程共享的 Controller handle，用于测试唯一 Service 生命周期。
    local hotupgrade_handle = create_controller() -- 真实 Skynet 中创建的 HotUpgrade Controller Service handle。
    -- 全局唯一重载是否被拒绝，以及拒绝时携带的 HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED 错误。
    local global_ok, global_error = pcall(module_state.hotupgrade_api.uniqueservice, true, "skynet_hotupgrade_unique_a")
    assert(not global_ok and tostring(global_error):find("HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED", 1, true))
    -- snaxd 特殊入口是否被拒绝，以及对应错误文本。
    local special_ok, special_error = pcall(module_state.hotupgrade_api.uniqueservice, "snaxd", "fixture")
    assert(not special_ok and tostring(special_error):find("HU_SPECIAL_SERVICE_UNSUPPORTED", 1, true))
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 0)

    -- 首次按逻辑名创建的唯一 Service handle。
    local first -- 第一台参与同批更新的 worker。
    local concurrent -- 同时执行的创建协程集合，用于验证同名唯一 Service 请求只启动一次。
    skynet.fork(function()
        first = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a",
            "auto", "original_tail")
    end)
    skynet.fork(function()
        concurrent = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a",
            "auto", "original_tail")
    end)
    while not first or not concurrent do skynet.sleep(1) end
    assert(concurrent == first and module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a") == first)
    -- 另一个逻辑名创建的独立唯一 Service handle。
    local second = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_b") -- 第二台参与同批更新的 worker，用于验证多目标部分失败处理。
    assert(second ~= first)
    assert(module_state.hotupgrade_api.cancel_service_creation(second).ok)
    for _, mode in ipairs({"fail"}) do
        -- 故障启动参数下的唯一 Service 创建是否抛错。
        local ok = pcall(module_state.hotupgrade_api.uniqueservice, "skynet_hotupgrade_unique_b", mode) -- 整个集成场景执行是否成功。
        assert(not ok and lifecycle_status(hotupgrade_handle).pending_service_count == 0)
    end
    second = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_b")
    -- 唯一 Service 场景发布的受理结果；排空和终态通过它的 batch_id 查询。
    local begun = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = "module"})
    assert(begun.ok and lifecycle_status(hotupgrade_handle).phase == "WAITING_CREATIONS")
    -- 排空期间既有唯一名直接复用，新唯一名也可完成创建和登记，并进入本批。
    assert(module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a") == first)
    -- 发布排空阶段中新创建并等待登记的唯一 Worker handle。
    local admitted = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_worker")
    assert(admitted ~= first and admitted ~= second)
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 2)
    assert(skynet.call(admitted, "lua", "init", {}).ok)
    assert(skynet.call(second, "lua", "init", {}).ok)
    assert(skynet.call(hotupgrade_handle, "hotupgrade", "unknown_command", {path = "module"}).code == "HU_UNKNOWN_COMMAND")
    wait_for_batch_phase(hotupgrade_handle, begun.value.batch_id, "COMPLETED")
    assert(read_worker_state(admitted).module_value == 2 and read_worker_state(second).module_value == 2)
    assert(module_state.hotupgrade_api.cancel_service_creation(admitted).code == "HU_SERVICE_ALREADY_REGISTERED")
    skynet.kill(first)
    -- 原唯一 Service 退出后暂存的旧 handle；循环中替换成重建出来的新 handle。
    local replacement = first
    for _ = 1, 1000 do
        skynet.sleep(1)
        replacement = module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a", "auto", "original_tail")
        if replacement ~= first then break end
    end
    assert(replacement ~= first)
    assert(read_worker_state(replacement).module_value == 2)
    assert(module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a") == replacement)
    print("HOTUPGRADE_SKYNET_UNIQUE_LIFECYCLE_OK")
end

-- 原生 loader 对受管理和普通入口都执行相同 preload，并收到真实业务名及参数。
local function preload_contract_tests()
    local hotupgrade_handle = create_controller() -- 真实 Skynet 中创建的 HotUpgrade Controller Service handle。
    skynet.setenv("preload", "./third_party/skynet-flywow/hotupgrade/tests/skynet_hotupgrade_preload.lua")
    local handles = -- 本场景创建的 worker handles，用于逐个核对状态和释放实例。
    {
        module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker"),
        module_state.hotupgrade_api.uniqueservice("skynet_hotupgrade_unique_a"),
        skynet.newservice("skynet_hotupgrade_worker"),
    }
    for index, worker_service_handle in ipairs(handles) do
        assert(skynet.call(worker_service_handle, "lua", "preload_seen", {}))
        if index < 3 then
            assert(module_state.hotupgrade_api.cancel_service_creation(worker_service_handle).ok)
        else
            skynet.kill(worker_service_handle)
        end
    end
    assert(lifecycle_status(hotupgrade_handle).pending_service_count == 0)
    print("HOTUPGRADE_SKYNET_PRELOAD_CONTRACT_OK")
end

--- 用可控的业务 release 时序验证 Prepare 等待创建、队列和模块加载的行为。
---@param group string 命令行选择的 drain 场景名；本函数按它创建相应依赖并执行断言。
local function drain_lifecycle_tests(group)
    local controller = create_controller() -- 本场景真实启动的 HotUpgrade Controller handle。
    local hotupgrade = module_state.hotupgrade_api -- worker 通过注册 API 使用的 HotUpgrade 模块。
    --- 查询 drain Worker 的检查视图，读取指定暂停点和创建状态。
    ---@param service_handle integer parent 或 child Service 的 handle；本函数向它发送 inspect RPC。
    local function inspect(service_handle)
        return skynet.call(service_handle, "lua", "inspect", {})
    end
    --- 等待 drain Worker 的检查视图字段达到指定值，超时则让测试失败。
    ---@param service_handle integer parent 或 child Service 的 handle；本函数通过 inspect 查询它。
    ---@param field string inspect 返回表中的字段名；本函数反复读取该字段。
    ---@param value any 本场景等待的字段值；相等时结束等待。
    local function wait_field(service_handle, field, value)
        for _ = 1, 1000 do
            if inspect(service_handle)[field] == value then return end
            skynet.sleep(1)
        end
        error("排空测试等待超时: " .. field)
    end

    local parent = hotupgrade.newservice("skynet_hotupgrade_drain") -- 创建子 worker 的父 Service handle。
    local completed_operation -- 子 Service 完成队列内操作后返回的记录。
    local peer -- 与 parent 并行创建的同批 Service handle。
    if group == "drain_creation" then
        skynet.fork(function()
            completed_operation = skynet.call(parent, "lua", "init", {wait_init = true, init_depth = 2})
        end)
        wait_field(parent, "waiting", "init")
    else
        local config = group == "drain_queue" and {prepare_depth = 1} -- 传给目标 worker 的故障开关；指定 Prepare/Update 或恢复中的注入点。
            or group == "drain_new_failure" and {prepare_depth = 1, child_fail_before = true}
            or group == "drain_update_failure" and {prepare_depth = 1, child_fail_after = true} or {}
        assert(skynet.call(parent, "lua", "init", config).ok)
        if group == "drain_queue" or group == "drain_modules" then
            local command = group == "drain_queue" and "work" or "nested_load" -- 从测试组名解析出的目标退出命令。
            skynet.fork(function()
                completed_operation = skynet.call(parent, "lua", command, {unique = true})
            end)
            wait_field(parent, "waiting", group == "drain_queue" and "queue" or "module")
        elseif group == "drain_late_module" then
            peer = hotupgrade.newservice("skynet_hotupgrade_drain")
            assert(skynet.call(peer, "lua", "init", {}).ok)
            skynet.fork(function()
                completed_operation = skynet.call(peer, "lua", "hold", {})
            end)
            wait_field(peer, "waiting", "queue")
        end
    end

    local id = begin_update_batch(controller, "drain_service") -- 本次集成发布的 batch_id，用于等待并查询终态。
    if group == "drain_creation" or group == "drain_modules" then
        assert(lifecycle_status(controller).phase == "WAITING_CREATIONS")
        assert(skynet.call(parent, "lua", "release", {}))
    elseif group == "drain_queue" then
        wait_field(parent, "paused", true)
        assert(skynet.call(parent, "lua", "release", {}))
    elseif group == "drain_late_module" then
        wait_field(peer, "paused", true)
        assert(inspect(parent).before_count == 1 and inspect(parent).paused)
        assert(skynet.call(parent, "lua", "declare", {}) == 1)
        assert(skynet.call(peer, "lua", "release", {}))
    end

    local failed = group == "drain_new_failure" or group == "drain_update_failure" -- 新增模块失败批次的终态记录。
    local record = wait_for_batch_phase(controller, id, failed and "ABORTED" or "COMPLETED") -- 等待到的本批终态记录。
    local visited = {} -- 递归遍历 Service 子树时已检查的 handle 集合，防止重复访问。
    --- 递归检查该 Service 创建的受管理子 Service，核对状态与本批目标数量。
    ---@param service_handle integer 当前创建树的根 Service handle；本函数递归读取其子 Service 并核对批次目标数。
local function check_tree(service_handle)
        assert(not visited[service_handle])
        visited[service_handle] = true
        local state = inspect(service_handle) -- worker 当前的模块和 Service 状态快照。
        assert(state.born_value == 1 and state.before_count == 1 and not state.paused)
        assert(state.value == (failed and 1 or 2))
        assert(state.equip == (failed and "刀" or "剑") and state.schema_version == (failed and 1 or 2))
        assert(state.attack == (failed and 100 or 120))
        for _, child in ipairs(state.children) do check_tree(child) end
    end
    check_tree(parent)
    if peer then check_tree(peer) end
    local target_count = 0 -- 递归遍历中已找到的受管理目标数。
    for _ in pairs(visited) do target_count = target_count + 1 end
    assert(record.target_service_count == target_count)
    assert(record.succeeded_service_count == (failed and 0 or target_count))
    assert(record.failed_service_count == (failed and target_count or 0))
    local expected_targets = group == "drain_queue" and 4 or group == "drain_creation" and 3 -- 当前 drain 场景应匹配的目标 Service 数。
        or group == "drain_modules" and 1 or 2
    assert(target_count == expected_targets)
    if group == "drain_creation" then
        assert(completed_operation and completed_operation.ok)
    elseif group == "drain_queue" then
        assert(completed_operation.value == 1 and completed_operation.extra == 1)
        assert(inspect(parent).extra == 2)
    elseif group == "drain_modules" then
        assert(completed_operation.extra == 1 and completed_operation.dependency == 1)
        assert(inspect(parent).extra == 2 and inspect(parent).dependency == 2)
    elseif group == "drain_late_module" then
        assert(completed_operation.value == 1 and inspect(parent).extra == 2)
    end
    local lifecycle = lifecycle_status(controller) -- Controller 当前的生命周期门禁视图。
    assert(lifecycle.pending_service_count == 0 and lifecycle.pending_module_count == 0)
    print("HOTUPGRADE_SKYNET_DRAIN_OK " .. group)
end

--- 按 HOTUPGRADE_TEST_GROUP 运行一个独立的 Skynet 集成场景；断言失败时结束当前场景。
---@return nil Scenario-specific checks pass or raise an error collected by the service runner.
local function run_test_group()
    local group = assert(os.getenv("HOTUPGRADE_TEST_GROUP"), "HOTUPGRADE_TEST_GROUP is required") -- 测试进程启动时选择的场景名，决定本轮执行的集成分支。
    local controller = nil -- 本场景真实启动的 HotUpgrade Controller handle。
    local worker_service_handle = nil -- 本测试主 worker 的真实 Skynet handle。
    if group == "monitor_occupied" then
        local core = require "skynet.core" -- Skynet 原生核心命令接口，用于检查 MONITOR 占用行为。
        core.command("MONITOR", skynet.address(skynet.self()))
        local before = core.command("MONITOR") -- HotUpgrade 初始化前进程 MONITOR 的原值，用于确认不会覆盖宿主监视器。
        local config = require "hotupgrade_test_options" -- 传给目标 worker 的故障开关；指定 Prepare/Update 或恢复中的注入点。
        local rejected = skynet.call(module_state.hotupgrade_handle, "lua", "init", -- 管理端主动 abort 请求的返回结果。
            {patch_path = config.patch_path, root_path = config.root_path, service_path = config.service_path})
        assert(rejected.code == "HU_MONITOR_OCCUPIED")
        assert(core.command("MONITOR") == before)
        assert(skynet.call(module_state.hotupgrade_handle, "hotupgrade", "status", {}).code == "HU_NOT_INITIALIZED")
    elseif group == "source_headers" then
        controller = create_controller()
        local worker = create_worker_service() -- 本场景创建的业务 worker Service。
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local config = require "hotupgrade_test_options" -- 传给目标 worker 的故障开关；指定 Prepare/Update 或恢复中的注入点。
        for index = 1, 4 do
            local path = "source_headers_" .. index -- 当前循环选择的发布目录名。
            local record = wait_for_batch_phase(controller, begin_update_batch(controller, path), "COMPLETED") -- 等待到的本批终态记录。
            assert(record.target_service_count == 1)
            local state = read_worker_state(worker) -- worker 当前的模块和 Service 状态快照。
            assert(state.module_value == 2 and state.level == 51 and not state.paused)
            for _, file in ipairs({"lualib/test_worker_logic.lua", "config/headers.lua"}) do
                assert(native.read_file(config.root_path, file) == native.read_file(config.patch_path, path .. "/" .. file))
            end
            assert(native.read_file(config.root_path, "service/skynet_hotupgrade_worker.patch") == false)
        end
        assert(read_worker_state(create_worker_service()).module_value == 2)
    elseif group == "exit_module_load" then
        controller = create_controller()
        local worker = create_worker_service() -- 本场景创建的业务 worker Service。
        skynet.fork(function()
            -- kill 不承诺替正在执行的业务 RPC 返回结果；这里只验证 Controller 自有许可。
            pcall(skynet.call, worker, "lua", "declare_slow", {})
        end)
        for _ = 1, 1000 do
            if lifecycle_status(controller).pending_module_count == 1 then break end
            skynet.sleep(1)
        end
        assert(lifecycle_status(controller).pending_module_count == 1)
        skynet.kill(worker)
        for _ = 1, 1000 do
            if lifecycle_status(controller).pending_module_count == 0 then break end
            skynet.sleep(1)
        end
        assert(lifecycle_status(controller).pending_module_count == 0)
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED") -- 等待到的本批终态记录。
        assert(record.target_service_count == 0)
    elseif group:match("^exit_") or group:match("^kill_") then
        controller = create_controller()
        local survivor = create_worker_service() -- 不退出的 worker，用于验证另一个目标退出时它仍可继续热更。
        local command = group:sub(6) -- 从测试组名解析出的目标退出命令。
        local exiting = create_worker_service({exit_command = command, kill = group:match("^kill_") ~= nil}) -- 按场景配置将在控制步骤退出的 worker handle。
        -- 不限定 RPC 错误与退出通知次序；按已知结果尽力恢复并报告失败。
        local expected = command == "finish" and "RECOVERY_REQUIRED" or {ABORTED = true, RECOVERY_REQUIRED = true} -- 当前故障场景期望的终态。
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), expected) -- 等待到的本批终态记录。
        assert(record.failed_service_count >= 1)
        local state = read_worker_state(survivor) -- worker 当前的模块和 Service 状态快照。
        if command == "finish" then
            assert(state.module_value == 2 and not state.paused)
            assert(lifecycle_status(controller).phase == "IDLE")
        else
            assert_original_state(survivor)
            if record.phase == "RECOVERY_REQUIRED" then
                assert(lifecycle_status(controller).phase == "IDLE")
                assert(record.error and record.error.code == "HU_RECOVERY_REQUIRED")
                local repaired = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED") -- 恢复失败后再次发布的批次结果，用于确认下一批可以修复现场。
                assert(repaired.target_service_count == 1)
            else
                assert(lifecycle_status(controller).phase == "IDLE")
                -- 退出登记已删除，下一批不能继续向旧 handle 发送批次命令。
                local next_record = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED")
                assert(next_record.target_service_count == 1)
            end
        end
    elseif group:match("^drain_") then
        drain_lifecycle_tests(group)
    elseif group == "service_file" then
        controller = create_controller()
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        assert(native.read_file(root, "service/new_service.lua") == false)
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "service_file"), "COMPLETED") -- 等待到的本批终态记录。
        assert(record.target_service_count == 0 and not record.control_started)
        assert(assert(load(assert(native.read_file(root, "service/new_service.lua"))))().version == 2)
        assert(native.read_file(root, "service/skynet_hotupgrade_worker.patch") == false)
        local only_files = wait_for_batch_phase(controller, begin_update_batch(controller, "unmatched_module"), "COMPLETED") -- 没有匹配到模块/Service 目标的正式文件部署批次结果。
        assert(only_files.target_service_count == 0)
        assert(read_worker_state(create_worker_service()).module_value == 2)
        print("HOTUPGRADE_SKYNET_SERVICE_FILE_OK")
    elseif group == "deployment" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        local old = assert(native.read_file(root, "lualib/test_worker_logic.lua")) -- 部署前的正式文件源码快照，恢复后与其比对。
        assert_original_state(worker_service_handle)
        assert(assert(load(old))("test_worker_logic", root .. "/lualib/test_worker_logic.lua").value() == 1)
        assert(native.read_file(root, "lualib/new/dependency.lua") == false)
        wait_for_batch_phase(controller, begin_update_batch(controller, "deployment"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).module_value == 2 and read_worker_state(worker_service_handle).equip == "剑")
        assert(read_worker_state(create_worker_service()).module_value == 2)
        assert(require("new.dependency").version == 2)
        assert(native.read_file(root, "service/skynet_hotupgrade_worker.patch") == false)
        print("HOTUPGRADE_SKYNET_DEPLOYMENT_OK")
    elseif group == "deploy_failure" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        local old = assert(native.read_file(root, "lualib/test_worker_logic.lua")) -- 部署前的正式文件源码快照，恢复后与其比对。
        skynet.fork(function() assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 20}).ok) end)
        while skynet.call(worker_service_handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = begin_update_batch(controller, "deploy_failure") -- 本次集成发布的 batch_id，用于等待并查询终态。
        while not read_worker_state(worker_service_handle).paused do skynet.sleep(1) end
        -- begin 已读取本批源码并保存正式文件旧内容；在 queue 排空窗口注入目标路径失效。
        assert(os.execute("mkdir " .. root .. "/service/z_blocked.lua"))
        local record = wait_for_batch_phase(controller, id, "ABORTED") -- 等待到的本批终态记录。
        assert(record.error.code == "HU_INVALID_PATH" and record.control_started
            and record.target_service_count == 1 and record.failed_service_count == 1 and lifecycle_status(controller).phase == "IDLE")
        assert_original_state(worker_service_handle)
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old)
        assert(native.read_file(root, "lualib/a_added.lua") == false)
        assert(os.execute("rmdir " .. root .. "/service/z_blocked.lua"))
        print("HOTUPGRADE_SKYNET_DEPLOY_FAILURE_OK")
    elseif group == "lifecycle" then
        creation_lifecycle_tests()
        module_lifecycle_tests()
        unique_lifecycle_tests()
    elseif group == "preload" then
        preload_contract_tests()
    elseif group == "host_paths" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local before = assert_original_state(worker_service_handle) -- HotUpgrade 初始化前进程 MONITOR 的原值，用于确认不会覆盖宿主监视器。
        assert(before.runtime_alias_identity and before.runtime_value == 1 and before.max_level == 100)
        assert(read_worker_state(worker_service_handle).runtime_value == 1 and read_worker_state(worker_service_handle).max_level == 100)
        assert(read_worker_state(worker_service_handle).package_value == 1 and read_worker_state(worker_service_handle).package_alias_identity)
        wait_for_batch_phase(controller, begin_update_batch(controller, "host_paths"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).runtime_value == 2 and read_worker_state(worker_service_handle).max_level == 200 and read_worker_state(worker_service_handle).runtime_alias_identity)
        assert(read_worker_state(worker_service_handle).package_value == 2 and read_worker_state(worker_service_handle).package_alias_identity)
        local nested_worker = create_worker_service() -- 额外创建的子 worker，参与同批排空与递归状态检查。
        wait_for_batch_phase(controller, begin_update_batch(controller, "nested_service"), "COMPLETED")
        assert(read_worker_state(nested_worker).attack == 120)
        print("HOTUPGRADE_SKYNET_HOST_PATHS_OK")
    elseif group == "custom_paths" then
        controller = create_controller("actors")
        worker_service_handle = create_worker_service()
        wait_for_batch_phase(controller, begin_update_batch(controller, "custom_service"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).attack == 120)
        print("HOTUPGRADE_SKYNET_CUSTOM_PATHS_OK")
    elseif group == "patch_match" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local before = assert_original_state(worker_service_handle) -- HotUpgrade 初始化前进程 MONITOR 的原值，用于确认不会覆盖宿主监视器。
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        local old_source = assert(native.read_file(root, "lualib/test_worker_logic.lua")) -- 部署前 worker 逻辑文件的完整源码，用于失败恢复断言。
        local idle = lifecycle_status(controller) -- 开始故障注入前的生命周期视图，确保没有遗留的在途创建或加载。
        assert(idle.phase == "IDLE" and idle.active_batch_id == nil)
        assert(assert_original_state(worker_service_handle).marker_token == before.marker_token)
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)

        local fixtures = { -- 文件部署失败场景的输入集合，每项指定注入位置与预期错误码。
            {path = "../module", code = "HU_INVALID_PATH"},
            {path = "invalid", code = "HU_MODULE_SYNTAX"},
            {path = "invalid_patch", code = "HU_INVALID_PATCH"},
            {path = "invalid_service", code = "HU_MODULE_SYNTAX"},
            {path = "unmatched_service", code = "HU_TARGET_MISSING"},
        }
        for _, fixture in ipairs(fixtures) do
            local id = begin_update_batch(controller, fixture.path) -- 本次集成发布的 batch_id，用于等待并查询终态。
            local record = wait_for_batch_phase(controller, id, "ABORTED") -- 等待到的本批终态记录。
            local rejected = record.error -- 管理端主动 abort 请求的返回结果。
            assert(rejected.code == fixture.code and rejected.message and #rejected.message > 0)
            local status = skynet.call(controller, "hotupgrade", "status", {batch_id = id}) -- 通过管理 RPC 查询的批次状态。
            assert(status.ok and status.value.record.phase == "ABORTED")
            assert(status.value.record.error.code == fixture.code and not status.value.record.control_started)
            assert(assert_original_state(worker_service_handle).marker_token == before.marker_token)
            assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)
            assert(status.value.lifecycle.phase == "IDLE")
        end
        assert(skynet.call(controller, "hotupgrade", "unknown_command", {path = "module"}).code == "HU_UNKNOWN_COMMAND")
        print("HOTUPGRADE_SKYNET_PATCH_MATCH_OK")
    elseif group == "identity_queue" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local before = assert_original_state(worker_service_handle) -- HotUpgrade 初始化前进程 MONITOR 的原值，用于确认不会覆盖宿主监视器。
        assert(skynet.call(worker_service_handle, "lua", "bump", {}).value == 8)
        local held = false -- 业务协程是否仍处于 queue 中；用于验证热更等待业务排空。
        skynet.fork(function()
            assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 15}).ok)
            held = true
        end)
        while skynet.call(worker_service_handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = begin_update_batch(controller, "combined") -- 本次集成发布的 batch_id，用于等待并查询终态。
        while not read_worker_state(worker_service_handle).paused do skynet.sleep(1) end
        local rejected = skynet.call(worker_service_handle, "lua", "hold", {ticks = 1}) -- 管理端主动 abort 请求的返回结果。
        assert(not rejected.ok and rejected.code == "HU_UPGRADING")
        wait_for_batch_phase(controller, id, "COMPLETED")
        assert(held)
        local after = read_worker_state(worker_service_handle) -- 热更失败或恢复后的 worker 状态快照。
        assert(after.service_handle == worker_service_handle and after.state_identity and after.lua_state_identity and after.module_identity)
        assert(after.marker_token == before.marker_token)
        assert(after.equip == "剑" and after.level == 50 and after.schema_version == 2)
        assert(after.attack == 120 and after.save_identity)
        assert(after.module_value == 2 and after.cached_value == 1 and after.added and after.removed == nil)
        assert(skynet.call(worker_service_handle, "lua", "bump", {}).value == 9)
        print("HOTUPGRADE_SKYNET_IDENTITY_STATE_QUEUE_OK")
    elseif group == "registration_missing" then
        controller = create_controller()
        worker_service_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker")
        local registration_result = skynet.call(worker_service_handle, "lua", "init", {before_missing = true}) -- worker 首次登记的 RPC 结果。
        assert(not registration_result.ok and registration_result.code == "HU_INVALID_OPTIONS")
        assert(module_state.hotupgrade_api.cancel_service_creation(worker_service_handle).ok)
        assert(lifecycle_status(controller).pending_service_count == 0)
    elseif group == "prepare_false" or group == "prepare_error" then
        controller = create_controller()
        local config = {[group == "prepare_false" and "before_false" or "before_error"] = true} -- 传给目标 worker 的故障开关；指定 Prepare/Update 或恢复中的注入点。
        worker_service_handle = create_worker_service(config)
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), "ABORTED") -- 等待到的本批终态记录。
        assert(record.error.code == (group == "prepare_error" and "HU_PREPARE_FAILED" or "HU_SAFEPOINT_REQUIRED"))
        assert_original_state(worker_service_handle)
    elseif group == "optional_service" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        wait_for_batch_phase(controller, begin_update_batch(controller, "functions"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).equip == "刀" and read_worker_state(worker_service_handle).attack == 100)
        wait_for_batch_phase(controller, begin_update_batch(controller, "state_only"), "COMPLETED")
        local updated = read_worker_state(worker_service_handle) -- 状态迁移后 worker 返回的私有状态。
        assert(updated.equip == "剑" and updated.level == 50 and updated.schema_version == 2)
        assert(updated.attack == 120 and updated.module_value == 1)
        assert(updated.obsolete == nil and updated.nested_count == 8 and updated.nested_retained == 23)
        assert(updated.nested_self_cycle and updated.nested_alias_identity and updated.root_cycle)
        assert(updated.rank_2 == 2 and updated.rank_3 == 3 and updated.mode_phase == "v2")
        assert(updated.replaced_value == "v2")
        print("HOTUPGRADE_SKYNET_OPTIONAL_SERVICE_PATCH_OK")
    elseif group == "state_shared" or group == "state_shared_failure" then
        controller = create_controller()
        local rejected = group == "state_shared_failure" -- 管理端主动 abort 请求的返回结果。
        worker_service_handle = create_worker_service({after_upgrade_failure = rejected})
        local before = assert_original_state(worker_service_handle) -- HotUpgrade 初始化前进程 MONITOR 的原值，用于确认不会覆盖宿主监视器。
        wait_for_batch_phase(controller, begin_update_batch(controller, "state_shared"), rejected and "ABORTED" or "COMPLETED")
        local after = read_worker_state(worker_service_handle) -- 热更失败或恢复后的 worker 状态快照。
        assert(after.state_identity and after.marker_token == before.marker_token and not after.paused)
        assert(after.merge_distinct and after.a_keep_a == 1 and after.b_keep_b == 2)
        assert(after.a_keep_b == nil and after.b_keep_a == nil)
        if rejected then
            assert(after.a_changed == nil and after.b_changed == nil)
            assert_original_state(worker_service_handle)
        else
            assert(after.a_changed == 3 and after.b_changed == 3)
        end
        assert(after.nested_alias_identity and after.root_cycle)
        print("HOTUPGRADE_SKYNET_STATE_SHARED_OK " .. group)
    elseif group == "declaration" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        assert(skynet.call(controller, "hotupgrade", "unknown_command", {path = "extra"}).code == "HU_UNKNOWN_COMMAND")
        assert(skynet.call(worker_service_handle, "lua", "check_declarations", {}))
        assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 1)
        assert(skynet.call(worker_service_handle, "lua", "declare", {}) == 1)
        wait_for_batch_phase(controller, begin_update_batch(controller, "extra"), "COMPLETED")
        assert(read_worker_state(worker_service_handle).extra_value == 2)
        assert(skynet.call(worker_service_handle, "hotupgrade", "update",
            {batch_id = "foreign", sequence = 999}).code == "HU_UNAUTHORIZED")
        print("HOTUPGRADE_SKYNET_DECLARATION_OK")
    elseif group == "bad_functions" or group == "stage_failure" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local patch_dir = group == "bad_functions" and "bad_functions" or "stage_failure" -- 当前候选包目录，按场景选择无效函数或 Stage 失败输入。
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        local old_source = assert(native.read_file(root, "lualib/test_worker_logic.lua")) -- 部署前 worker 逻辑文件的完整源码，用于失败恢复断言。
        wait_for_batch_phase(controller, begin_update_batch(controller, patch_dir), "ABORTED")
        assert_original_state(worker_service_handle)
        assert(native.read_file(root, "lualib/test_worker_logic.lua") == old_source)
        print(group == "bad_functions" and "HOTUPGRADE_SKYNET_BAD_FUNCTIONS_OK" or "HOTUPGRADE_SKYNET_STAGE_FAILURE_OK")
    elseif group == "activation_after_failure" or group == "activation_custom_failure"
        or group == "activation_custom_success" or group == "activation_custom_success_failure" then
        controller = create_controller()
        local config -- 传给目标 worker 的故障开关；指定 Prepare/Update 或恢复中的注入点。
        local expected = "ABORTED" -- 当前故障场景期望的终态。
        if group == "activation_after_failure" then
            config = {after_upgrade_failure = true}
        elseif group == "activation_custom_failure" then
            config = {custom = true}
        elseif group == "activation_custom_success" then
            config = {custom_success = true}
            expected = "COMPLETED"
        else
            config = {custom_success = true, after_upgrade_failure = true}
        end
        worker_service_handle = create_worker_service(config)
        wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), expected)
        if group == "activation_custom_success" then
            assert(read_worker_state(worker_service_handle).attack == 120 and read_worker_state(worker_service_handle).nested_identity and read_worker_state(worker_service_handle).nested_count == 7)
        else
            assert_original_state(worker_service_handle)
            if group == "activation_custom_success_failure" then assert(read_worker_state(worker_service_handle).nested_identity) end
        end
        print("HOTUPGRADE_SKYNET_ACTIVATE_RESTORE_OK " .. group)
    elseif group == "multiple_targets" then
        controller = create_controller()
        local first = create_worker_service() -- 第一台参与同批更新的 worker。
        local second = create_worker_service() -- 第二台参与同批更新的 worker，用于验证多目标部分失败处理。
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "module"), "COMPLETED") -- 等待到的本批终态记录。
        assert(record.succeeded_service_count == 2 and read_worker_state(first).module_value == 2 and read_worker_state(second).module_value == 2)
        print("HOTUPGRADE_SKYNET_MULTIPLE_TARGETS_OK")
    elseif group == "partial" then
        controller = create_controller()
        local first = create_worker_service() -- 第一台参与同批更新的 worker。
        local second = create_worker_service({after_upgrade_failure = true}) -- 第二台参与同批更新的 worker，用于验证多目标部分失败处理。
        local record = wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), "ABORTED") -- 等待到的本批终态记录。
        assert(record.succeeded_service_count == 0 and record.failed_service_count == 2)
        assert_original_state(first)
        assert_original_state(second)
        assert(lifecycle_status(controller).phase == "IDLE")
        local new_handle = module_state.hotupgrade_api.newservice("skynet_hotupgrade_worker") -- 本批期间新创建并登记的 Service handle。
        assert(module_state.hotupgrade_api.cancel_service_creation(new_handle).ok)
        print("HOTUPGRADE_SKYNET_PARTIAL_OK")
    elseif group == "new_modules" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local first = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules"), "COMPLETED") -- 第一台参与同批更新的 worker。
        local first_state = read_worker_state(worker_service_handle) -- 新增模块登记批次后 worker 返回的状态。
        assert(first.succeeded_service_count == 1 and first_state.module_value == 42 and first_state.module_identity)
        assert(lifecycle_status(controller).pending_module_count == 0)
        local next_batch = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules_followup"), "COMPLETED") -- 以上一批结束时现场为基准的新一批热更结果。
        assert(next_batch.succeeded_service_count == 1 and read_worker_state(worker_service_handle).module_value == 52)
        print("HOTUPGRADE_SKYNET_NEW_MODULES_OK")
    elseif group == "new_modules_concurrent_conflict" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        assert(skynet.call(worker_service_handle, "lua", "start_new_module_conflict", {}) == true)
        local failed = wait_for_batch_phase(controller, -- 新增模块失败批次的终态记录。
            begin_update_batch(controller, "new_modules_concurrent"), "ABORTED")
        assert(failed.error.code == "HU_NEW_MODULE_FAILED")
        assert(failed.error.details.cause_code == "HU_MODULE_LOADING")
        local ordinary = skynet.call(worker_service_handle, "lua", "new_module_conflict_result", {}) -- 冲突场景下普通模块 require 的结果，确认不会与新模块登记互相等待。
        assert(not ordinary.ok and ordinary.message ~= "")
        assert(lifecycle_status(controller).pending_module_count == 0)
        print("HOTUPGRADE_SKYNET_NEW_MODULES_CONCURRENT_CONFLICT_OK")
    elseif group == "new_modules_candidate_undeclared" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local failed = wait_for_batch_phase(controller, -- 新增模块失败批次的终态记录。
            begin_update_batch(controller, "new_modules_candidate_undeclared"), "ABORTED")
        assert(failed.error.code == "HU_MODULE_STAGE_FAILED")
        assert(failed.error.details.cause_code == "HU_NEW_MODULE_NOT_DECLARED")
        assert_original_state(worker_service_handle)
        assert(native.read_file(root, "lualib/hotupgrade_new_rules.lua") == false)
        assert(lifecycle_status(controller).pending_module_count == 0)
        local next_batch = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules"), "COMPLETED") -- 以上一批结束时现场为基准的新一批热更结果。
        assert(next_batch.succeeded_service_count == 1 and read_worker_state(worker_service_handle).module_value == 42)
        print("HOTUPGRADE_SKYNET_NEW_MODULE_CANDIDATE_UNDECLARED_OK")
    elseif group == "new_modules_candidate_caught_error" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local failed = wait_for_batch_phase(controller, -- 新增模块失败批次的终态记录。
            begin_update_batch(controller, "new_modules_candidate_caught_error"), "ABORTED")
        assert(failed.error.code == "HU_MODULE_STAGE_FAILED")
        assert(failed.error.details == nil or failed.error.details.cause_code == nil)
        assert(failed.error.message:find("injected unrelated candidate failure", 1, true))
        assert_original_state(worker_service_handle)
        print("HOTUPGRADE_SKYNET_NEW_MODULE_CAUGHT_ERROR_OK")
    elseif group == "new_modules_failure" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        local root = require("hotupgrade_test_options").root_path -- 宿主正式文件根目录；读取和恢复断言使用相同根路径。
        local native = require "flywow_hotupgrade_native" -- 真实 HotUpgrade Native 扩展，用于验证部署前后正式文件内容。
        local failed = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules_failure"), "ABORTED") -- 新增模块失败批次的终态记录。
        assert(failed.error.code == "HU_MODULE_STAGE_FAILED")
        assert_original_state(worker_service_handle)
        local remaining_rules = native.read_file(root, "lualib/hotupgrade_new_rules.lua") -- 失败后正式目录中保留的新增模块文件内容。
        assert(remaining_rules == false, "failed batch left new module file: " .. tostring(remaining_rules))
        assert(lifecycle_status(controller).pending_module_count == 0)
        local next_batch = wait_for_batch_phase(controller, begin_update_batch(controller, "new_modules_followup"), "COMPLETED") -- 以上一批结束时现场为基准的新一批热更结果。
        assert(next_batch.succeeded_service_count == 1 and read_worker_state(worker_service_handle).module_value == 52)
        print("HOTUPGRADE_SKYNET_NEW_MODULES_FAILURE_CONTINUES_OK")
    elseif group == "management_abort" then
        controller = create_controller()
        worker_service_handle = create_worker_service()
        skynet.fork(function() assert(skynet.call(worker_service_handle, "lua", "hold", {ticks = 15}).ok) end)
        while skynet.call(worker_service_handle, "lua", "holding", {}) == false do skynet.sleep(1) end
        local id = begin_update_batch(controller, "combined") -- 本次集成发布的 batch_id，用于等待并查询终态。
        while not read_worker_state(worker_service_handle).paused do skynet.sleep(1) end
        local rejected = skynet.call(controller, "hotupgrade", "abort", {batch_id = id}) -- 管理端主动 abort 请求的返回结果。
        assert(not rejected.ok and rejected.code == "HU_UNKNOWN_COMMAND")
        wait_for_batch_phase(controller, id, "COMPLETED")
        local after = read_worker_state(worker_service_handle) -- 热更失败或恢复后的 worker 状态快照。
        assert(after.module_value == 2 and after.equip == "剑" and not after.paused)
        print("HOTUPGRADE_SKYNET_MANAGEMENT_ABORT_REJECTED_OK")
    elseif group == "recovery_restore" or group == "recovery_module" then
        controller = create_controller()
        local config = group == "recovery_restore" and {custom = true, restore_failure = true} or {break_module = true} -- 传给目标 worker 的故障开关；指定 Prepare/Update 或恢复中的注入点。
        worker_service_handle = create_worker_service(config)
        wait_for_batch_phase(controller, begin_update_batch(controller, "combined"), "RECOVERY_REQUIRED")
        assert(not read_worker_state(worker_service_handle).paused)
        assert(lifecycle_status(controller).phase == "IDLE")
        assert(skynet.call(worker_service_handle, "lua", "allow_next_upgrade", {}).ok)
        local repaired = wait_for_batch_phase(controller, begin_update_batch(controller, "repair"), "COMPLETED") -- 恢复失败后再次发布的批次结果，用于确认下一批可以修复现场。
        assert(repaired.succeeded_service_count == 1 and not lifecycle_status(controller).recovery_required)
        local current = read_worker_state(worker_service_handle) -- 修复批次结束后的 worker 状态快照。
        assert(current.module_value == 3 and current.level == 60 and current.schema_version == 3 and not current.paused)
        assert(read_worker_state(create_worker_service()).module_value == 3)
        print("HOTUPGRADE_SKYNET_RECOVERY_REQUIRED_OK")
    else
        error("unknown HOTUPGRADE_TEST_GROUP: " .. tostring(group))
    end
    print("HOTUPGRADE_SKYNET_GROUP_OK " .. group)
end
skynet.start(function()
    module_state.hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    module_state.hotupgrade_api = require "flywow_hotupgrade"
    require "test_files"
    local ok, message = xpcall(run_test_group, debug.traceback) -- 整个集成场景执行是否成功。
    if not ok then
        print(message)
        print("HOTUPGRADE_SKYNET_FAILED")
    end
    skynet.abort()
end)
