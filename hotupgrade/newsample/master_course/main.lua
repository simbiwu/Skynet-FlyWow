-- 本课程管理端：v1 / normal / queue / forward 四个相互独立的场景。
local skynet = require "skynet"
local SCENARIO = os.getenv("FLYWOW_MASTER_SCENARIO") or "v1"

local function expect(answer)
    assert(type(answer) == "table" and answer.ok,
        type(answer) == "table" and (answer.message or answer.code) or tostring(answer))
    return answer
end

local function get_player_snapshot(player)
    return expect(skynet.call(player, "lua", "inspect"))
end

local function print_player(label, snapshot)
    print(string.format("%s handle=%d version=%s weapon=%s gold=%d schema=%d attack=%d old_attack=%d",
        label, snapshot.handle, snapshot.version, snapshot.weapon,
        snapshot.gold, snapshot.schema_version, snapshot.attack, snapshot.old_attack))
end

local function wait_for(check, description)
    for _ = 1, 3000 do
        local answer = check()
        if answer then return answer end
        skynet.sleep(1)
    end
    error("等待超时: " .. description)
end

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

local function create_player(hot)
    local handle = hot.newservice("player_service")
    expect(skynet.call(handle, "lua", "init"))
    return handle
end

local function run_v1(_controller, hot, player)
    local before = get_player_snapshot(player)
    print_player("V1", before)
    assert(before.version == "v1" and before.gold == 100 and before.attack == 105)
    assert(before.state_same and before.module_alias_same)
    print("MASTER_V1_OK")
end

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
    local ok, failure = xpcall(function()
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
    if not ok then
        skynet.error("MASTER_FAILED: " .. tostring(failure))
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)