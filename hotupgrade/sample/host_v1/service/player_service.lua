--- PlayerService 入口；登记后所有业务查询和攻击函数都通过同一个 Guard。
local skynet = require "skynet"

local hotupgrade
local logic
local state
local state_root
local business
local cached_v1_load
local registered = false

local function inspect()
    return
    {
        handle = skynet.self(),
        module_version = logic.version(),
        equip = state.equip,
        level = state.level,
        schema_version = state.schema_version,
        load_attack = business.load(100),
        cached_v1_load_attack = cached_v1_load(100),
        load_replaced = business.load ~= cached_v1_load,
        state_root_identity = state == state_root,
        module_identity = tostring(logic),
        module_root_identity = package.loaded.player_logic == logic,
        module_alias_identity = package.loaded.player_logic == logic
            and package.loaded["lualib.player_logic"] == logic,
        guard_open = hotupgrade.guard().owner == nil,
    }
end

local function initialize()
    logic = hotupgrade.require("player_logic")
    local version = logic.version()
    if version ~= "v1" and version ~= "v2" then
        return {ok = false, code = "HU_PLAYER_VERSION_UNSUPPORTED", message = tostring(version)}
    end

    local is_v2 = version == "v2"
    state =
    {
        equip = is_v2 and "剑" or "刀",
        level = 50,
        schema_version = is_v2 and 2 or 1,
    }
    state_root = state
    business = {load = logic.make_load(state)}
    cached_v1_load = business.load

    local registered_result = hotupgrade.register_service(
    {
        service_module = "player",
        service_update = {state = state, functions = business},
        after_upgrade = function()
            return logic.version() == "v2" and state.equip == "剑"
                and state.schema_version == 2 and business.load(100) == 121
        end,
    })
    if registered_result.ok then
        registered = true
    end
    return registered_result
end

skynet.start(function()
    hotupgrade = require "flywow_hotupgrade"
    skynet.dispatch("lua", function(session, _source, command)
        local answer
        if command == "init" then
            if registered then
                answer = {ok = false, code = "HU_ALREADY_INITIALIZED", message = "PlayerService 已初始化"}
            else
                answer = initialize()
            end
        elseif not registered then
            answer = {ok = false, code = "HU_NOT_INITIALIZED", message = "PlayerService 尚未登记"}
        elseif command == "inspect" then
            answer = hotupgrade.guard():run(inspect)
        elseif command == "attack" then
            answer = hotupgrade.guard():run(function()
                return business.load(100)
            end)
        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND", message = tostring(command)}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
