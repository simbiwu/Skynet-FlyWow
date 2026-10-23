local skynet = require "skynet"

skynet.start(function()
    local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hot = require "flywow_hotupgrade"
    local root = os.getenv("HOTUPGRADE_LESSON_ROOT")

    -- 初始化 Controller。
    local result = skynet.call(hotupgrade_handle, "lua", "init",
    {
        patch_path = root .. "/patches",
        root_path = root .. "/host",
        service_path = "service",
    })
    if not result.ok then
        error(result.message)
    end

    -- 创建第一个 PlayerService，执行 V1。
    local first_service_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_service_handle, "lua", "init")
    if not initialized.ok then
        error(initialized.message)
    end

    local before = skynet.call(first_service_handle, "lua", "inspect")
    print("发布前:", before.player.version, before.player.equip,
        before.player.schema_version, before.player.attack)

    -- 开始发布 V2。
    local begun = skynet.call(hotupgrade_handle, "hotupgrade", "begin",
    {
        path = "v2",
    })
    if not begun.ok then
        error(begun.message)
    end

    print("发布批次:", begun.batch_id)

    -- 等待该批次执行完毕。
    while true do
        local status = skynet.call(hotupgrade_handle, "hotupgrade", "status",
        {
            batch_id = begun.batch_id,
        })
        if not status.ok then
            error(status.message)
        end

        local phase = status.record.phase
        if phase == "COMPLETED" then
            break
        end

        if phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
            error(status.record.error and status.record.error.message or phase)
        end

        skynet.sleep(1)
    end

    -- 检查原 PlayerService。
    local after = skynet.call(first_service_handle, "lua", "inspect")

    print("发布后:", after.player.version, after.player.equip,
        after.player.schema_version, after.player.attack)

    print("原 Service handle 保持:", first_service_handle == after.player.service_handle)
    print("原状态根表保持:", after.player.state_same)
    print("原模块根表保持:",
        before.player.module_id == after.player.module_id)
    print("模块缓存别名保持:", after.player.module_alias_same)
    print("业务函数已替换:", after.player.load_changed)
    print("旧闭包的攻击力:", after.player.initial_attack)
    print("原 Service patching:", after.player.patching)

    -- 创建第二个 PlayerService，直接运行 V2。
    local second_service_handle = hot.newservice("player_service")
    local second_initialized = skynet.call(second_service_handle, "lua", "init")
    if not second_initialized.ok then
        error(second_initialized.message)
    end

    local second = skynet.call(second_service_handle, "lua", "inspect")

    print("新 PlayerService:", second.player.version, second.player.equip,
        second.player.schema_version, second.player.attack)
    print("两个 Service 的 handle 不同:", second_service_handle ~= first_service_handle)

    io.stdout:flush()
    os.exit(0)
end)