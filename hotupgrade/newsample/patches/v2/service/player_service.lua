local skynet = require "skynet"
local business_queue = require "skynet.queue"()

local hot
local logic
local state
local state_root
local business
local initial_load

local function inspect()
    return
    {
        handle = skynet.self(),
        version = logic.version(),
        equip = state.equip,
        schema_version = state.schema_version,
        attack = business.load(100),
        initial_attack = initial_load(100),
        load_changed = business.load ~= initial_load,
        state_same = state == state_root,
        module_id = tostring(logic),
        module_alias_same = package.loaded.player_logic == logic
            and package.loaded["lualib.player_logic"] == logic,
        patching = hot.patching,
    }
end

local function initialize()
    logic = hot.require("player_logic")

    state =
    {
        equip = "剑",
        schema_version = 2,
    }
    state_root = state

    business = {load = logic.make_load(state)}
    initial_load = business.load

    return hot.register_service(
    {
        service_update = {state = state, functions = business},

        before_upgrade = function()
            return business_queue(function()
                return true
            end)
        end,

        after_upgrade = function()
            return logic.version() == "v2"
                and state.equip == "剑"
                and state.schema_version == 2
                and business.load(100) == 121
        end,
    })
end

skynet.start(function()
    hot = require "flywow_hotupgrade"

    skynet.dispatch("lua", function(session, _source, command)
        local answer

        if command == "init" then
            answer = initialize()

        elseif command == "inspect" then
            if hot.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = {ok = true, player = business_queue(inspect)}
            end

        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)