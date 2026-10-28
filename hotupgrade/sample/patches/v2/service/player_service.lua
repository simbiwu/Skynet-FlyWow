--- PlayerService V2：新实例从已部署的 V2 模块和状态启动。
local skynet = require "skynet" -- 注册 Lua 消息处理器并调用 Skynet 协程接口。
local business_queue = require "skynet.queue"() -- 串行执行玩家业务，Prepare 通过同一队列等待安全点。

skynet.start(function()
    -- 声明热更模块并登记当前 Service 的私有状态和函数表。
    local hotupgrade = require "flywow_hotupgrade"
    -- 当前 Lua State 中稳定的普通模块导出根表，V2 新实例通过它调用业务逻辑。
    local player_logic
    -- 当前新实例的长期玩家状态；本 Patch 在旧实例上会原地修改相同字段。
    local player_state
    -- 当前实例的业务函数表，状态加载逻辑通过它访问 player_state。
    local business_functions
    -- register_service 成功后才允许处理 inspect 等业务请求。
    local registered = false

    skynet.dispatch("lua", function(session, _source, command)
        -- 当前 Lua 请求最终返回给调用方的结果表。
        local answer

        if command == "init" then
            if registered then
                answer = {ok = false, code = "HU_ALREADY_INITIALIZED"}
            else
                -- 当前 State 的稳定模块根表；require 同时声明它参与后续普通模块热更。
                player_logic = hotupgrade.require("player_logic")
                -- 当前玩家的长期私有状态根表；后续 Service Patch 只改字段，不替换根表。
                player_state =
                {
                    equip = "剑", -- V2 新实例启动时的初始装备。
                    level = 50, -- 当前玩家等级，V1 与 V2 都保留。
                    schema_version = 2, -- V2 新实例使用的状态结构版本。
                }
                -- 业务函数表；load 闭包捕获 player_state，Service Patch 替换该字段完成逻辑更新。
                business_functions = {load = player_logic.make_load(player_state)}
                -- Controller 登记结果；只有成功后才开放 inspect 业务入口。
                answer = hotupgrade.register_service(
                {
                    service_update =
                    {
                        state = player_state,
                        functions = business_functions,
                    },
                    before_upgrade = function()
                        return business_queue(function() return true end)
                    end,
                })
                registered = answer.ok
            end
        elseif not registered then
            answer = {ok = false, code = "HU_NOT_INITIALIZED"}
        elseif command == "inspect" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function()
                    return
                    {
                        ok = true,
                        version = player_logic.version(),
                        equip = player_state.equip,
                        level = player_state.level,
                        schema_version = player_state.schema_version,
                        attack = business_functions.load(100),
                    }
                end)
            end
        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
