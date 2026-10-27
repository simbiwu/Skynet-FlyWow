-- 本课程管理端：v1 / normal / queue / forward 四个相互独立的场景。
local skynet = require "skynet"
local SCENARIO = os.getenv("FLYWOW_MASTER_SCENARIO") or "v1"

--- 校验受信 Skynet/FlyWow 调用返回成功；失败时抛出机器错误码和消息。
---@param answer FlyWowResult<any> 待检查的统一结果表
---@return FlyWowResult<any> 原样返回成功结果，调用者可继续读取 value。
local function expect(answer)
    assert(type(answer) == "table" and answer.ok,
        type(answer) == "table" and (answer.message or answer.code) or tostring(answer))
    return answer
end

--- 通过 PlayerService 的 inspect 命令读取业务快照；RPC 可能 yield。
---@param player integer 目标 PlayerService handle
---@return table snapshot inspect 返回的玩家状态与课堂观测字段
local function get_player_snapshot(player)
    return expect(skynet.call(player, "lua", "inspect"))
end

--- 将玩家版本、状态和攻击结果打印为一行，便于比较热更前后的可见结果。
---@param label string 本次观察阶段名称
---@param snapshot table get_player_snapshot 返回的字段集合
---@return nil
local function print_player(label, snapshot)
    print(string.format("%s handle=%d version=%s weapon=%s gold=%d schema=%d attack=%d old_attack=%d",
        label, snapshot.handle, snapshot.version, snapshot.weapon,
        snapshot.gold, snapshot.schema_version, snapshot.attack, snapshot.old_attack))
end

--- 每个 Skynet tick 检查一次异步条件；返回首个 truthy 结果，超时则抛错。
---@param check fun():any 可 yield 的查询函数；返回 truthy 值表示条件成立
---@param description string 用于定位超时阶段的说明
---@return any result check 首次返回的 truthy 值
local function wait_for(check, description)
    for _ = 1, 3000 do
        local answer = check()
        if answer then return answer end
        skynet.sleep(1)
    end
    error("等待超时: " .. description)
end

--- 发起一次发布并轮询到终态；BEGIN 与 status RPC/等待都会 yield。
---@param controller integer HotUpgrade Controller Service handle
---@param patch_name string 相对 Patch 根目录的发布目录
---@return table terminal_record status 返回的终态记录，包含 phase/error/各目标结果；失败批次也由场景自行断言
local function publish(controller, patch_name)
    local begun = expect(skynet.call(controller, "hotupgrade", "begin", {path = patch_name}))
    print("BEGIN " .. patch_name .. " batch=" .. begun.value.batch_id)
    return wait_for(function()
        local status = expect(skynet.call(controller, "hotupgrade", "status",
            {batch_id = begun.value.batch_id}))
        local record = status.value.record
        if record.phase == "COMPLETED" or record.phase == "ABORTED"
            or record.phase == "RECOVERY_REQUIRED" then
            print("END " .. patch_name .. " phase=" .. record.phase
                .. " error=" .. tostring(record.error and record.error.code))
            return record
        end
    end, "发布 " .. patch_name)
end

--- 启动或取得唯一 HotUpgrade Controller 并初始化当前运行夹具路径。
---@return integer controller 已完成配置初始化的 Controller Service handle
local function initialize_controller()
    local controller = skynet.uniqueservice("flywow_hotupgrade_service")
    local runtime_root = assert(os.getenv("FLYWOW_MASTER_RUNTIME_ROOT"))
    expect(skynet.call(controller, "lua", "init",
    {
        root_path = runtime_root .. "/host",
        patch_path = runtime_root .. "/patches",
        service_path = "service",
    }))
    return controller
end

--- 创建受管理 PlayerService 并完成其 init/register_service 握手；RPC 可能 yield。
---@param hot table flywow_hotupgrade 模块，提供 newservice 适配入口
---@return integer player_handle 成功初始化并已登记的 PlayerService handle
local function create_player(hot)
    local handle = hot.newservice("player_service")
    expect(skynet.call(handle, "lua", "init"))
    return handle
end

--- 验证 V1 初始状态、Service handle 与模块身份；只断言并输出结果。
---@param _controller integer 为共享场景签名保留，本场景不使用
---@param hot table flywow_hotupgrade 模块句柄；本场景不创建额外 Service
---@param player integer 已初始化的 PlayerService handle
---@return nil
local function run_v1(_controller, hot, player)
    local before = get_player_snapshot(player)
    print_player("V1", before)
    assert(before.version == "v1" and before.gold == 100 and before.attack == 105)
    assert(before.state_same and before.module_alias_same)
    print("MASTER_V1_OK")
end

--- 执行正常 V1→V2 发布，检查旧实例原地更新及新实例从 V2 启动。
---@param controller integer HotUpgrade Controller Service handle
---@param hot table flywow_hotupgrade 模块，用于创建第二个 PlayerService
---@param player integer 已登记的 V1 PlayerService handle
---@return nil 断言失败时抛错；成功时打印 MASTER_NORMAL_OK
local function run_normal(controller, hot, player)
    local before = get_player_snapshot(player)
    print_player("BEFORE", before)
    local first = publish(controller, "v2")
    assert(first.phase == "COMPLETED")

    local after = get_player_snapshot(player)
    print_player("EXISTING", after)
    assert(after.handle == player and after.version == "v2")
    assert(after.weapon == "剑" and after.schema_version == 2 and after.gold == 100)
    assert(after.attack == 120 and after.old_attack == 100)
    assert(after.state_same and after.module_alias_same and after.combat_loaded)

    local another = create_player(hot)
    local second = get_player_snapshot(another)
    print_player("NEW", second)
    assert(another ~= player and second.version == "v2" and second.attack == 120)
    print("MASTER_NORMAL_OK")
end

--- 构造 A 占用 queue、B 排队、Prepare 入队、C 被门禁拒绝的并发时序。
---@param controller integer HotUpgrade Controller Service handle
---@param _hot table 为共享场景签名保留，本场景不调用热更模块 API
---@param player integer 已登记的 PlayerService handle
---@return nil 断言 A/B 在 V1 完成、发布后 C 收到 HU_UPGRADING
local function run_queue(controller, _hot, player)
    local first_done = false
    local second_done = false
    local a_result
    local b_result

    skynet.fork(function()
        a_result = expect(skynet.call(player, "lua", "hold"))
        first_done = true
    end)
    wait_for(function()
        local peek = expect(skynet.call(player, "lua", "peek"))
        return peek.holding
    end, "请求 A 占有业务 queue")

    skynet.fork(function()
        b_result = expect(skynet.call(player, "lua", "spend", {amount = 20}))
        second_done = true
    end)
    wait_for(function()
        local peek = expect(skynet.call(player, "lua", "peek"))
        return peek.waiting_spends == 1
    end, "请求 B 已排入业务 queue")

    -- A 占着 queue，B 排队；现在开始发布，Prepare 也排在 B 后面。
    local begun = expect(skynet.call(controller, "hotupgrade", "begin", {path = "v2"}))
    wait_for(function()
        local peek = expect(skynet.call(player, "lua", "peek"))
        return peek.patching
    end, "Prepare 已关闭新业务入口")

    local c_result = skynet.call(player, "lua", "spend", {amount = 30})
    assert(not c_result.ok and c_result.code == "HU_UPGRADING")
    expect(skynet.call(player, "lua", "release"))
    wait_for(function() return first_done and second_done end, "A/B 完成")
    assert(a_result.version == "v1" and a_result.gold == 90)
    assert(b_result.version == "v1" and b_result.gold == 70)

    local finished = wait_for(function()
        local status = expect(skynet.call(controller, "hotupgrade", "status", {batch_id = begun.value.batch_id}))
        local phase = status.value.record.phase
        if phase == "COMPLETED" or phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
            return status.value.record
        end
    end, "并发热更批次")
    assert(finished.phase == "COMPLETED")
    local after = get_player_snapshot(player)
    print_player("QUEUE_AFTER", after)
    assert(after.version == "v2" and after.gold == 70 and after.attack == 120)
    print("A V1 gold=90, B V1 gold=70, C HU_UPGRADING")
    print("MASTER_QUEUE_OK")
end

--- 演示恢复失败只报告、后续 V3 发布以当前真实状态为基准继续修复。
---@param controller integer HotUpgrade Controller Service handle
---@param hot table flywow_hotupgrade 模块，用于最后创建 V3 新实例
---@param player integer 已登记的 PlayerService handle
---@return nil 断言故障结果、V3 修复状态和新实例结果
local function run_forward(controller, hot, player)
    assert(publish(controller, "v2").phase == "COMPLETED")
    local healthy = get_player_snapshot(player)
    assert(healthy.version == "v2" and healthy.gold == 100)

    -- 教学故障：只让本次 Abort 的自定义 Service 状态恢复失败。
    expect(skynet.call(player, "lua", "inject_restore_failure", {enabled = true}))
    local faulty = publish(controller, "faulty")
    assert(faulty.phase == "RECOVERY_REQUIRED")
    assert(faulty.error and faulty.error.details.original_error and faulty.error.details.recovery_error)

    local damaged = get_player_snapshot(player)
    print_player("DAMAGED", damaged)
    assert(damaged.schema_version == 99 and damaged.gold == 0)
    assert(damaged.version == "v2" and damaged.state_same)

    -- 不需要管理端解锁 Controller；解除课堂注入，下一次普通发布直接修复。
    expect(skynet.call(player, "lua", "inject_restore_failure", {enabled = false}))
    local repaired = publish(controller, "v3")
    assert(repaired.phase == "COMPLETED")
    local fixed = get_player_snapshot(player)
    print_player("REPAIRED", fixed)
    assert(fixed.version == "v3" and fixed.weapon == "霜剑")
    assert(fixed.schema_version == 3 and fixed.gold == 88 and fixed.attack == 125)
    assert(fixed.state_same and fixed.module_alias_same)

    local another = create_player(hot)
    local newcomer = get_player_snapshot(another)
    print_player("NEW_V3", newcomer)
    assert(newcomer.version == "v3" and newcomer.schema_version == 3)
    assert(newcomer.attack == 125)
    print("MASTER_FORWARD_OK")
end

skynet.start(function()
    local scenario_succeeded, scenario_failure = xpcall(function()
        local hot = require "flywow_hotupgrade"
        local controller = initialize_controller()
        local player = create_player(hot)
        if SCENARIO == "v1" then
            run_v1(controller, hot, player)
        elseif SCENARIO == "normal" then
            run_normal(controller, hot, player)
        elseif SCENARIO == "queue" then
            run_queue(controller, hot, player)
        elseif SCENARIO == "forward" then
            run_forward(controller, hot, player)
        else
            error("未知实验: " .. tostring(SCENARIO))
        end
    end, debug.traceback)
    if not scenario_succeeded then
        skynet.error("MASTER_FAILED: " .. tostring(scenario_failure))
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(scenario_succeeded and 0 or 1)
end)
