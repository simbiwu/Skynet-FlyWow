-- V3 PlayerService：新实例通过正式部署的 V3 入口初始化。
local skynet = require "skynet" -- 当前 Service 使用的 Skynet API。
local business_queue = require "skynet.queue"() -- 业务串行队列；业务处理和热更安全点都经过它。
local hotupgrade = require "flywow_hotupgrade" -- 当前 Service 的受控模块加载、登记和生命周期 API。

local logic                 -- 首次 init 后的普通模块根表；热更保持表身份。
local state                 -- 玩家私有数据根表；由 Service Patch 原地修改。
local operations            -- 现有业务函数表；Patch 只替换指定函数。
local state_identity        -- 保存最初状态根表，用于观察身份是否稳定。
local old_attack            -- 缓存这个 Service 创建时的初始闭包，用于观察旧函数引用。
local registered = false    -- register_service 真正成功后才允许业务请求。
local holding_thread        -- hold 占用 queue 时正在 wait 的业务协程。
local waiting_spends = 0    -- 已通过入口但尚未拿到 queue 的 spend 请求数量。
local fail_restore = false  -- 只用于故障实验，正常运行恒为 false。

--- 返回 PlayerService 当前版本、私有状态和函数引用的观测快照。
---@return table snapshot 管理和并发实验读取的玩家版本、状态、函数身份及门禁状态
local function inspect_state()
    return
    {
        ok = true, -- inspect 命令成功标记，供管理端 expect 检查。
        handle = skynet.self(), -- 当前玩家 Service handle，用于确认热更前后实例未被替换。
        version = logic.version(), -- 当前 player_logic 导出的版本号。
        weapon = state.weapon, -- Update 当前保留的武器名称。
        level = state.level, -- 玩家当前等级，用于观察状态迁移是否保留。
        gold = state.gold, -- 玩家当前金币，用于验证排队业务和故障恢复结果。
        schema_version = state.schema_version, -- 状态结构版本，用于检查 Update 与 V3 修复效果。
        attack = operations.attack(100), -- 通过当前函数表计算的攻击力。
        old_attack = old_attack(100), -- 通过 Service 创建时缓存的旧闭包计算，观察旧引用行为。
        state_same = state == state_identity, -- 玩家状态根表是否仍是初始化时的同一张表。
        module_alias_same = package.loaded["lualib.player_logic"] == logic, -- package.loaded 是否仍指向原模块根表。
        combat_loaded = package.loaded["lualib.combat_rules"] ~= nil, -- V2 声明的新依赖是否仍在 package.loaded。
        patching = hotupgrade.patching, -- HotUpgrade 是否正在关闭本 Service 的业务入口。
    }
end

--- 声明业务模块和私有状态，最后登记当前 PlayerService。
---@return FlyWowResult<nil> 登记成功或返回初始化失败码；受控 require 的原生异常按其接口合同抛出
local function initialize_player()
    if registered then
        return {ok = false, code = "ALREADY_INITIALIZED"}
    end

    -- 只有受控加载成功后才构造玩家私有状态，并把模块函数绑定到该状态表。
    logic = hotupgrade.require("player_logic")
    state =
    {
        weapon = "霜剑", -- 当前玩家装备；player_logic.make_attack 会据此计算武器加成。
        level = 50, -- 当前玩家等级，作为状态迁移保留字段。
        gold = 100, -- 当前玩家初始金币，供 spend 和 queue 实验修改。
        schema_version = 3, -- V3 初始状态版本，供故障修复实验检查和迁移。
    }
    operations =
    {
        attack = logic.make_attack(state), -- 当前 Service 调用的攻击函数，热更时原地替换此字段。
    }
    state_identity = state
    old_attack = operations.attack

    -- 把本 Service 的状态、函数和安全点交给 Controller；只有登记成功才开放业务命令。
    local answer = hotupgrade.register_service( -- register_service 返回的成功或失败结果。
    {
        service_update = -- 告诉 HotUpgrade 哪些 Service 私有对象需要快照、更新和恢复。
        {
            state = state, -- 被本批 Update 修改并由快照回调恢复的玩家状态表。
            functions = operations, -- Update 原地替换的业务函数表；Abort 可恢复旧函数。
            -- 课堂故障需要显式控制恢复失败，所以这里使用成对自定义快照。
            snapshot = function(source) -- Controller 在 Prepare 时调用，保存可恢复的玩家字段。
                return require("flywow_result").success(
                {
                    weapon = source.weapon, -- 恢复玩家原先装备。
                    level = source.level, -- 恢复玩家原先等级。
                    gold = source.gold, -- 恢复玩家原先金币。
                    schema_version = source.schema_version, -- 恢复玩家原先状态结构版本。
                })
            end,
            restore = function(destination, snapshot) -- Abort 时把 Prepare 保存的字段写回原状态表。
                if fail_restore then
                    error("injected restore failure")
                end
                -- 先移除 Update 可能新增的字段，再把快照中的旧字段恢复到原表。
                for key in pairs(destination) do
                    destination[key] = nil
                end
                for key, value in pairs(snapshot) do
                    destination[key] = value
                end
                return require("flywow_result").success()
            end,
        },
        before_upgrade = function() -- Prepare 等待已接纳业务离开 queue 后才允许 Update。
            return business_queue(function() return true end)
        end,
        after_upgrade = function() -- Update 后检查状态；故障实验故意将 schema 改为 99。
            return state.schema_version ~= 99
        end,
    })
    registered = answer.ok
    return answer
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer -- 管理命令的调用结果。

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
                ok = true, -- 表示 peek 返回了观测结果。
                holding = holding_thread ~= nil, -- 是否有 hold 请求占用业务 queue。
                waiting_spends = waiting_spends, -- 已通过门禁并等待 queue 的 spend 请求数。
                patching = hotupgrade.patching, -- 当前是否处于 Prepare 后的业务入口关闭期。
                gold = state.gold, -- 当前金币，用于队列实验检查 A/B 的执行顺序。
                schema_version = state.schema_version, -- 当前状态版本，用于观察故障恢复现场。
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
                local thread = holding_thread -- 从 holding_thread 取出的协程句柄，交给 skynet.wakeup 唤醒。
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
                if type(request.amount) ~= "number" or request.amount <= 0 then
                    answer = {ok = false, code = "INVALID_AMOUNT", message = "amount 必须是正数"}
                else
                    waiting_spends = waiting_spends + 1
                    answer = business_queue(function()
                        waiting_spends = waiting_spends - 1
                        state.gold = state.gold - request.amount
                        return {ok = true, gold = state.gold, version = logic.version()}
                    end)
                end
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
