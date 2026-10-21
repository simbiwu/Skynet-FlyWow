--- PlayerService V2：新实例从已部署的 V2 模块和状态启动。
local skynet = require "skynet"
local business_queue = require "skynet.queue"()

skynet.start(function()
    local hotupgrade = require "flywow_hotupgrade"
    local player_logic
    local player_state
    local business_functions
    local registered = false

    skynet.dispatch("lua", function(session, _source, command)
        local answer

        if command == "init" then
            if registered then
                answer = {ok = false, code = "HU_ALREADY_INITIALIZED"}
            else
                player_logic = hotupgrade.require("player_logic")
                player_state =
                {
                    equip = "剑",
                    level = 50,
                    schema_version = 2,
                }
                business_functions = {load = player_logic.make_load(player_state)}
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
