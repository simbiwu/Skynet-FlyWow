--- 可运行候选 factory：状态集中，Timer 为派生资源，支持 DRAIN/MIGRATE。
return function(context)
    local skynet = require "skynet"
    local hotupgrade = require "flywow_hotupgrade"
    local logic = hotupgrade.require("test_worker_logic")
    -- state 是 Service 权威业务状态；升级迁移只复制它，不搬运运行时 Timer。
    local state = {schema_version = context.state_version or 1, count = 7}
    -- Timer 捕获创建时的 epoch；退休/重建递增 epoch 后，旧回调不会继续生效。
    local timer_epoch = 0
    local ticks = 0
    local resource = true

    local function rebuild()
        timer_epoch = timer_epoch + 1
    end

    local function start_timer()
        timer_epoch = timer_epoch + 1
        local epoch = timer_epoch
        local function tick()
            if epoch ~= timer_epoch then
                return
            end
            hotupgrade.guard():run(function()
                ticks = ticks + 1
            end)
            skynet.timeout(2, tick)
        end
        skynet.timeout(2, tick)
    end

    context.adapter =
    {
        can_upgrade = function()
            return true
        end,
        export_state = function()
            return state
        end,
        import_state = function(snapshot)
            state = snapshot
        end,
        rebuild_runtime = rebuild,
        on_resume = start_timer,
        healthcheck = function()
            return state.count >= 0
        end,
        prepare_retire = function()
            resource = false
            timer_epoch = timer_epoch + 1
        end,
        cancel_retire = function()
            resource = true
            start_timer()
        end,
        can_retire = function()
            return true
        end,
        retire = function()
            timer_epoch = timer_epoch + 1
        end,
        dispatch = function(command, payload)
            if command == "read" then
                return {value = logic.value(), state = state, resource = resource, ticks = ticks}
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
    if not context.candidate then
        start_timer()
    end
    skynet.dispatch("lua", function(_, _, command)
        if command == "read" then
            skynet.retpack({value = logic.value(), state = state, resource = resource})
        end
    end)
end
