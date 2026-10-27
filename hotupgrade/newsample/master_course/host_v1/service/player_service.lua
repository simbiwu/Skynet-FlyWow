-- V1 PlayerService：业务状态留在本 Service，所有受控业务共用一条 queue。
local skynet = require "skynet"
local business_queue = require "skynet.queue"()
local hotupgrade = require "flywow_hotupgrade"

local logic                 -- 首次 init 后的普通模块根表；热更保持表身份。
local state                 -- 玩家私有数据根表；由 Service Patch 原地修改。
local operations            -- 现有业务函数表；Patch 只替换指定函数。
local state_identity        -- 保存最初状态根表，用于观察身份是否稳定。
local old_attack            -- 缓存 V1 闭包，用于观察旧函数引用。
local registered = false    -- register_service 真正成功后才允许业务请求。
local holding_thread        -- hold 占用 queue 时正在 wait 的业务协程。
local waiting_spends = 0    -- 已通过入口但尚未拿到 queue 的 spend 请求数量。
local fail_restore = false  -- 只用于故障实验，正常运行恒为 false。

local function inspect_state()
    return
    {
        ok = true,
        handle = skynet.self(),
        version = logic.version(),
        weapon = state.weapon,
        level = state.level,
        gold = state.gold,
        schema_version = state.schema_version,
        attack = operations.attack(100),
        old_attack = old_attack(100),
        state_same = state == state_identity,
        module_alias_same = package.loaded["lualib.player_logic"] == logic,
        combat_loaded = package.loaded["lualib.combat_rules"] ~= nil,
        patching = hotupgrade.patching,
    }
end

local function initialize_player()
    if registered then
        return {ok = false, code = "ALREADY_INITIALIZED"}
    end

    logic = hotupgrade.require("player_logic")
    state =
    {
        weapon = "刀",
        level = 50,
        gold = 100,
        schema_version = 1,
    }
    operations = {attack = logic.make_attack(state)}
    state_identity = state
    old_attack = operations.attack

    local answer = hotupgrade.register_service(
    {
        service_update =
        {
            state = state,
            functions = operations,
            -- 课堂故障需要显式控制恢复失败，所以这里使用成对自定义快照。
            snapshot = function(source)
                return
                {
                    weapon = source.weapon,
                    level = source.level,
                    gold = source.gold,
                    schema_version = source.schema_version,
                }
            end,
            restore = function(destination, snapshot)
                if fail_restore then
                    error("injected restore failure")
                end
                for key in pairs(destination) do
                    destination[key] = nil
                end
                for key, value in pairs(snapshot) do
                    destination[key] = value
                end
                return true
            end,
        },
        before_upgrade = function()
            -- 必须排在所有已接纳业务之后取得同一条 queue。
            return business_queue(function() return true end)
        end,
        after_upgrade = function()
            -- 同步状态检查；故障实验把 schema 改成 99，以触发 Update 失败。
            return state.schema_version ~= 99
        end,
    })
    registered = answer.ok
    return answer
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer

        if command == "init" then
            answer = initialize_player()
        elseif not registered then
            answer = {ok = false, code = "NOT_INITIALIZED"}
        elseif command == "inspect" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(inspect_state)
            end
        elseif command == "peek" then
            -- 教学观测口：只读、不进入业务 queue，避免观察者自身被 queue 挡住。
            answer =
            {
                ok = true,
                holding = holding_thread ~= nil,
                waiting_spends = waiting_spends,
                patching = hotupgrade.patching,
                gold = state.gold,
                schema_version = state.schema_version,
            }
        elseif command == "hold" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function()
                    holding_thread = coroutine.running()
                    skynet.wait(holding_thread)
                    holding_thread = nil
                    state.gold = state.gold - 10
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "release" then
            -- 教学控制消息必须独立于业务 queue，否则无法唤醒被占用的 queue。
            if holding_thread then
                local thread = holding_thread
                holding_thread = nil
                skynet.wakeup(thread)
                answer = {ok = true}
            else
                answer = {ok = false, code = "NOT_HOLDING"}
            end
        elseif command == "spend" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                assert(type(request.amount) == "number" and request.amount > 0)
                waiting_spends = waiting_spends + 1
                answer = business_queue(function()
                    waiting_spends = waiting_spends - 1
                    state.gold = state.gold - request.amount
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "inject_restore_failure" then
            -- 课堂故障开关；不作为框架或实际业务管理 API。
            fail_restore = request.enabled == true
            answer = {ok = true}
        else
            answer = {ok = false, code = "UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)