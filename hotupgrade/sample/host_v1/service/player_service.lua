--- PlayerService V1：保留本实例状态，并在更新前排空业务调用。
local skynet = require "skynet" -- 注册 Lua 消息处理器并调用 Skynet 协程接口。
local business_queue = require "skynet.queue"() -- 串行执行玩家业务，Prepare 通过同一队列等待安全点。

skynet.start(function()
    -- 登记 Service 并通过 hotupgrade.require 声明热更模块。
    local hotupgrade = require "flywow_hotupgrade"
    local player_logic       -- 本 State 受管理模块的稳定根表，更新后仍通过它读取逻辑。
    local player_state       -- init 创建的现存玩家状态；Service Patch 原地修改，根表不替换。
    local business_functions -- 闭包捕获 player_state 的现有业务函数表，Patch 可替换其字段。
    local registered = false -- register_service 成功后才接收 inspect，避免暴露未完成初始化。

    skynet.dispatch("lua", function(session, _source, command)
        -- Controller 返回的初始化或状态查询结果，成功值里包含当前业务信息。
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
                    equip = "刀", -- 当前装备；V2 Service Patch 会迁移为剑。
                    level = 50, -- 当前玩家等级，V1 与 V2 都保留。
                    schema_version = 1, -- V1 状态结构版本。
                }
                -- 业务函数表；load 闭包捕获 player_state，Service Patch 替换该字段完成逻辑更新。
                business_functions = {load = player_logic.make_load(player_state)}
                -- Controller 登记结果；只有成功后才开放 inspect 业务入口。
                answer = hotupgrade.register_service(
                {
                    service_update = -- 本地状态和业务函数表的更新接口；对象只在当前 Service Lua State 内使用。
                    {
                        state = player_state,           -- Service 的长期状态根表；更新和恢复都保留它的身份。
                        functions = business_functions, -- Service 当前业务函数表；普通模块提交后替换相应函数。
                    },
                    before_upgrade = function() -- 等待已接纳业务排空；返回 false 或抛错会拒绝本批 Prepare。
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
                -- 三份对象都留在本 State；排空与 inspect 使用同一 queue，观察完整更新后的业务值。
                answer = business_queue(function()
                    return
                    {
                        ok = true, -- inspect 请求是否成功；调用方据此读取玩家快照。
                        version = player_logic.version(), -- 当前模块版本，用于确认现存实例已更新。
                        equip = player_state.equip, -- 当前装备，验证 Service Patch 的迁移结果。
                        level = player_state.level, -- 当前等级，验证未涉及状态保持不变。
                        schema_version = player_state.schema_version, -- 当前状态结构版本。
                        attack = business_functions.load(100), -- 新业务函数计算出的攻击值，验证函数表已更新。
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
