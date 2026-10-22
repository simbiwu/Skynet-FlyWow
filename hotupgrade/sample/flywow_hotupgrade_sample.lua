--- 在真实 Skynet 中演示现存 PlayerService 热更和新实例加载 V2。
local skynet = require "skynet"

skynet.start(function()
    local ok, failure = xpcall(function()
        local hotupgrade = require "flywow_hotupgrade"
        local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")

        -- Skynet 从 Server 根目录启动；运行脚本会把夹具复制到这个目录。
        local sample_root = "./third_party/skynet-flywow/build/hotupgrade-sample"
        local initialized = skynet.call(hotupgrade_handle, "lua", "init",
        {
            patch_path = sample_root .. "/patches",
            root_path = sample_root .. "/host",
            service_path = "service",
        })
        if not initialized.ok then
            error(initialized.code .. ": " .. initialized.message)
        end

        local first_handle = hotupgrade.newservice("player_service")
        local first_started = skynet.call(first_handle, "lua", "init")
        if not first_started.ok then
            error(first_started.code .. ": " .. first_started.message)
        end

        local before = skynet.call(first_handle, "lua", "inspect")
        print(string.format("V1 handle=%d module=%s equip=%s level=%d schema=%d attack=%d",
            first_handle, before.version, before.equip, before.level, before.schema_version, before.attack))

        local batch = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = "v2"})
        if not batch.ok then
            error(batch.code .. ": " .. batch.message)
        end
        print("发布批次 " .. batch.batch_id)

        local completed
        for _ = 1, 3000 do
            local status = skynet.call(hotupgrade_handle, "hotupgrade", "status",
                {batch_id = batch.batch_id})
            if not status.ok then
                error(status.code .. ": " .. status.message)
            end

            local phase = status.record.phase
            if phase == "COMPLETED" then
                completed = true
                break
            end
            if phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
                local failure_result = status.record.error
                error((failure_result and failure_result.code or phase) .. ": "
                    .. (failure_result and failure_result.message or "发布失败"))
            end

            skynet.sleep(1)
        end
        if not completed then
            error("等待发布完成超时")
        end

        local after = skynet.call(first_handle, "lua", "inspect")
        print(string.format("V2 existing handle=%d module=%s equip=%s level=%d schema=%d attack=%d",
            first_handle, after.version, after.equip, after.level, after.schema_version, after.attack))

        local second_handle = hotupgrade.newservice("player_service")
        local second_started = skynet.call(second_handle, "lua", "init")
        if not second_started.ok then
            error(second_started.code .. ": " .. second_started.message)
        end
        local created = skynet.call(second_handle, "lua", "inspect")
        print(string.format("V2 new handle=%d module=%s equip=%s level=%d schema=%d attack=%d",
            second_handle, created.version, created.equip, created.level, created.schema_version, created.attack))

        print("HOTUPGRADE_SAMPLE_OK")
    end, debug.traceback)

    if not ok then
        skynet.error("HOTUPGRADE_SAMPLE_FAILED: " .. tostring(failure))
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)
