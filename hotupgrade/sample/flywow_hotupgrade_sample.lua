--- 在真实 Skynet 中演示现存 PlayerService 热更和新实例加载 V2。
-- 提供真实 Skynet Service 启动、RPC、sleep 和退出接口。
local skynet = require "skynet"

skynet.start(function()
    -- Sample 主流程是否成功及失败堆栈；据此输出结果并设置进程退出码。
local sample_succeeded, sample_failure = xpcall(function()
        -- 受管理 Service 创建和模块登记 API。
local hotupgrade = require "flywow_hotupgrade"
        -- 当前进程唯一 HotUpgrade Controller handle。
local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")

        -- Skynet 从 Server 根目录启动；运行脚本会把夹具复制到这个目录。
        -- 运行脚本准备的宿主与发布包夹具根目录。
local sample_root = "./third_party/skynet-flywow/build/hotupgrade-sample"
        -- Controller 初始化结果；失败时停止 Sample，不继续创建业务 Service。
local initialized = skynet.call(hotupgrade_handle, "lua", "init",
        {
            patch_path = sample_root .. "/patches",
            root_path = sample_root .. "/host",
            service_path = "service",
        })
        if not initialized.ok then
            error(initialized.code .. ": " .. initialized.message)
        end

        -- 第一个由 HotUpgrade 管理的 PlayerService handle。
local first_service_handle = hotupgrade.newservice("player_service")
        -- 第一个 PlayerService 的初始化和登记结果。
local first_started = skynet.call(first_service_handle, "lua", "init")
        if not first_started.ok then
            error(first_started.code .. ": " .. first_started.message)
        end

        -- 热更前现存实例的状态快照，用来显示 V1 结果。
local before = skynet.call(first_service_handle, "lua", "inspect")
        print(string.format("V1 service_handle=%d module=%s equip=%s level=%d schema=%d attack=%d",
            first_service_handle, before.version, before.equip, before.level, before.schema_version, before.attack))

        -- V2 发布请求的受理结果；成功值提供后续 status 查询使用的批次 ID。
local batch = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = "v2"})
        if not batch.ok then
            error(batch.code .. ": " .. batch.message)
        end
        print("发布批次 " .. batch.value.batch_id)

        -- 是否在轮询期限内观察到 COMPLETED；超时则作为 Sample 失败。
local completed
        for _ = 1, 3000 do
            -- 当前发布批次的管理查询结果。
local status = skynet.call(hotupgrade_handle, "hotupgrade", "status",
                {batch_id = batch.value.batch_id})
            if not status.ok then
                error(status.code .. ": " .. status.message)
            end

            -- begin 只确认受理；record 是所查询批次的进度，error 则保留该批失败诊断。
            -- Controller 记录的本批阶段，用于继续等待或结束轮询。
local phase = status.value.record.phase
            if phase == "COMPLETED" then
                completed = true
                break
            end
            if phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
                -- 发布失败或恢复失败的结构化诊断。
local failure_result = status.value.record.error
                error((failure_result and failure_result.code or phase) .. ": "
                    .. (failure_result and failure_result.message or "发布失败"))
            end

            skynet.sleep(1)
        end
        if not completed then
            error("等待发布完成超时")
        end

        -- 热更后同一个 Service 的状态快照，用于显示原实例结果。
local after = skynet.call(first_service_handle, "lua", "inspect")
        print(string.format("V2 existing service_handle=%d module=%s equip=%s level=%d schema=%d attack=%d",
            first_service_handle, after.version, after.equip, after.level, after.schema_version, after.attack))

        -- 发布完成后新建的第二个 PlayerService handle。
local second_service_handle = hotupgrade.newservice("player_service")
        -- 第二个实例的初始化和登记结果。
local second_started = skynet.call(second_service_handle, "lua", "init")
        if not second_started.ok then
            error(second_started.code .. ": " .. second_started.message)
        end
        -- 新实例从正式 V2 文件启动后的状态快照。
local created = skynet.call(second_service_handle, "lua", "inspect")
        print(string.format("V2 new service_handle=%d module=%s equip=%s level=%d schema=%d attack=%d",
            second_service_handle, created.version, created.equip, created.level, created.schema_version, created.attack))

        print("HOTUPGRADE_SAMPLE_OK")
    end, debug.traceback)

    if not sample_succeeded then
        skynet.error("HOTUPGRADE_SAMPLE_FAILED: " .. tostring(sample_failure))
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(sample_succeeded and 0 or 1)
end)
