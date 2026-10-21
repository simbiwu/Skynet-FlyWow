--- 运行 PlayerService V1 到 V2 的受管理发布，并从真实 RPC 返回值验收每个阶段。
local skynet = require "skynet"

local WAIT_LIMIT_TICKS = 3000 -- 单次 Controller 阶段等待上限；Skynet 每 tick 为 10 毫秒。
local current_step = "启动"
local controller_handle
local hotupgrade

local function checked(result, operation)
    if type(result) ~= "table" or not result.ok then
        local code = type(result) == "table" and result.code or "HU_INVALID_RESPONSE"
        local message = type(result) == "table" and result.message or tostring(result)
        error(tostring(code) .. ": " .. tostring(operation) .. ": " .. tostring(message))
    end
    return result
end

local function lifecycle_text()
    if not controller_handle then
        return "Controller 尚未取得"
    end

    local called, status = pcall(skynet.call, controller_handle, "hotupgrade", "status", {})
    if not called then
        return "status 查询失败: " .. tostring(status)
    end
    if type(status) ~= "table" or not status.ok then
        return "status 错误: " .. tostring(type(status) == "table" and status.code or status)
    end

    local lifecycle = status.lifecycle
    return string.format("phase=%s batch_id=%s pending_creations=%d pending_module_loads=%d failed_locked=%s",
        tostring(lifecycle.phase), tostring(lifecycle.batch_id),
        lifecycle.pending_creations, lifecycle.pending_module_loads, tostring(lifecycle.failed_locked))
end

local function wait_for_completion(batch_id)
    for _ = 1, WAIT_LIMIT_TICKS do
        local status = checked(skynet.call(controller_handle, "hotupgrade", "status", {batch_id = batch_id}),
            "查询批次结果")
        local phase = status.record.phase
        if phase == "COMPLETED" then
            return status
        end
        if phase == "PARTIAL" or phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
            local failure = status.record.error
            error(tostring(failure and failure.code or phase) .. ": "
                .. tostring(failure and failure.message or "更新未成功"))
        end
        skynet.sleep(1)
    end
    error("HU_SAMPLE_TIMEOUT: 等待事务完成超时")
end

local function create_player()
    local created, handle = pcall(hotupgrade.newservice, "player_service")
    if not created then
        error(tostring(handle))
    end

    local called, registered = pcall(skynet.call, handle, "lua", "init", {})
    if not called or type(registered) ~= "table" or not registered.ok then
        local cancelled = hotupgrade.cancel_service_creation(handle)
        if not cancelled.ok then
            error(tostring(registered and registered.code or "HU_PLAYER_INIT_FAILED") .. ": "
                .. tostring(registered and registered.message or registered or handle)
                .. "; cancel failed: " .. tostring(cancelled.code) .. ": " .. tostring(cancelled.message))
        end
        error(tostring(registered and registered.code or "HU_PLAYER_INIT_FAILED") .. ": "
            .. tostring(registered and registered.message or registered or handle))
    end

    return handle
end

local function read_player(handle)
    local response = checked(skynet.call(handle, "lua", "inspect", {}), "读取 PlayerService")
    local player = response.player
    assert(type(player) == "table", "HU_SAMPLE_INVALID_RESPONSE: PlayerService 未返回状态")
    return player
end

local function print_player(label, player)
    print(string.format("%s handle=%d module=%s equip=%s schema_version=%d load(100)=%d patching=%s",
        label, player.handle, player.module_version, player.equip, player.schema_version,
        player.load_attack, tostring(player.patching)))
end

local function run_sample()
    current_step = "获取并初始化 Controller"
    controller_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    hotupgrade = require "flywow_hotupgrade"
    local sample_root = assert(os.getenv("HOTUPGRADE_SAMPLE_ROOT"))
    checked(skynet.call(controller_handle, "lua", "init",
        {patch_root = sample_root .. "/patches", root_path = sample_root .. "/host",
            service_dir = "service"}), "初始化 Controller")

    current_step = "创建并登记 V1 PlayerService"
    local first_handle = create_player()
    local before = read_player(first_handle)
    print_player("V1", before)
    assert(before.handle == first_handle and before.equip == "刀" and before.schema_version == 1)
    assert(before.module_version == "v1" and before.load_attack == 105)
    assert(before.state_root_identity and before.module_root_identity and before.module_alias_identity)

    current_step = "发布 V2：由 begin 异步完成运行时更新与文件部署"
    local begun = checked(skynet.call(controller_handle, "hotupgrade", "begin", {path = "v2"}), "begin")
    print("已接受发布批次 " .. begun.batch_id)
    local completed = wait_for_completion(begun.batch_id)
    assert(completed.record.phase == "COMPLETED")
    print("原 PlayerService 批次 COMPLETED")

    current_step = "验收原 PlayerService"
    local after = read_player(first_handle)
    print_player("V2 existing", after)
    assert(after.handle == first_handle and after.state_root_identity)
    assert(after.module_identity == before.module_identity)
    assert(after.module_root_identity and after.module_alias_identity)
    assert(after.module_version == "v2" and after.equip == "剑" and after.schema_version == 2)
    assert(after.load_replaced and after.load_attack == 121 and after.cached_v1_load_attack == 100)
    assert(not after.patching)

    current_step = "创建并验收 V2 PlayerService"
    local second_handle = create_player()
    local created = read_player(second_handle)
    print_player("V2 new", created)
    assert(created.handle == second_handle and second_handle ~= first_handle)
    assert(created.module_version == "v2" and created.equip == "剑" and created.schema_version == 2)
    assert(created.load_attack == 121 and not created.patching)
    print("原实例与新实例业务版本一致：v2")
end

local function report_failure(message)
    local text = tostring(message)
    local code, detail = text:match("(HU_[%u_]+):%s*([^\n]*)")
    skynet.error("HOTUPGRADE_SAMPLE_FAILED step=" .. current_step
        .. " code=" .. tostring(code or "HU_SAMPLE_FAILED")
        .. " message=" .. tostring(detail or text)
        .. " lifecycle={" .. lifecycle_text() .. "}\n" .. text)
end

skynet.start(function()
    local ok, message = xpcall(run_sample, debug.traceback)
    if ok then
        print("HOTUPGRADE_SAMPLE_OK")
    else
        report_failure(message)
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)
