--- 可运行 Service factory：状态由 Service 持有，Timer 为可重建的派生资源。
return function(context)
    local skynet = require "skynet"
    local hotupgrade = require "flywow_hotupgrade"
    local logic = hotupgrade.require("test_worker_logic")
    local service_type = context.service_type
    -- state 是 Service 权威业务状态；只有本 Service 自己决定是否交接它。
    local state = {count = 7}
    local initialized_value = logic.value()
    local initialized_count
    if context.candidate and service_type == "worker_frozen" then
        -- 原文件没有 initial_count；候选必须在运行 factory 前取得本次冻结模块。
        local addition = hotupgrade.require("test_candidate_only")
        assert(initialized_value == 2 and initialized_count == 43)
    end
    local ticks = 0
    local resource = true

    -- 候选在注册前读取权威状态；这里用固定夹具值模拟宿主数据源。
    if context.candidate and service_type == "worker_rebuild" then
        state             = {count = 73}
    end

    -- 各失败型 Service 使用不同 Adapter 组合，集成测试可验证状态交接合同。
    local export_state
    local import_state
    if service_type ~= "worker_rebuild" then
        export_state = function()
            if service_type == "worker_export_failure" then
                return false
            end

            -- 测试状态含有 ok 字段，确保它不会被误判成 FlyWow Hook 结果。
            return {ok = true, count = state.count}
        end
    end
    if service_type ~= "worker_missing_import" and service_type ~= "worker_rebuild" then
        import_state = function(state_value)
            if service_type == "worker_frozen" then
                assert(logic.initial_count() == 42 and initialized_count == 43)
            end
            if service_type == "worker_import_failure"
                or service_type == "worker_partial_z" then
                return false
            end

            state             = state_value
        end
    end

    local function start_timer()
        local function tick()
            hotupgrade.guard():run(function()
                ticks             = ticks + 1
            end)
            skynet.timeout(2, tick)
        end

        skynet.timeout(2, tick)
    end

    context.adapter =
    {
        export_state = export_state,
        import_state = import_state,
        healthcheck = context.candidate and (service_type == "worker_health" or service_type == "worker_frozen") and function()
            return logic.value() == 2 and (service_type ~= "worker_frozen" or initialized_count == 43)
        end or nil,
        dispatch = function(command, payload)
            if command == "read" then
                return
                {
                    value             = logic.value(),
                    initialized_value = initialized_value,
                    initialized_count = initialized_count,
                    instance_handle       = context.instance_handle,
                    state             = state,
                    resource          = resource,
                    ticks             = ticks,
                }
            end
            if command == "add" then
                state.count = state.count + payload
                return state.count
            end
            if command == "slow" then
                skynet.sleep(payload)
                return state.count
            end
            if command == "fail" then
                error("handler failure")
            end
        end,
    }
    assert(hotupgrade.register_service(context).ok)
    -- Guard 由注册时的 candidate 标记控制；同一个后台循环在候选恢复后自然继续运行。
    start_timer()

    skynet.dispatch("lua", function(_, _, command)
        if command == "read" then
            skynet.retpack(
            {
                value             = logic.value(),
                initialized_value = initialized_value,
                initialized_count = initialized_count,
                instance_handle       = context.instance_handle,
                state             = state,
                resource          = resource,
            })
        end
    end)
end
