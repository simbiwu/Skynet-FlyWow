--- PlayerService 入口；登记后所有业务查询和攻击函数都通过同一个 Guard。
local skynet = require "skynet"

local module_state =
{
    hotupgrade         = nil,   -- 当前 Service 使用的热更公开入口，start 时取得。
    player_logic       = nil,   -- 通过受控 require 加载的 V2 普通模块。
    player_state       = nil,   -- 当前实例独占的玩家可迁移状态根表。
    state_root         = nil,   -- 仅用于示例验收根表身份是否保持。
    business_functions = nil,   -- 当前实例业务函数；后续 .patch 可直接替换其中字段。
    initial_load       = nil,   -- 初始化时缓存的函数，展示旧函数引用不会自动替换。
    registered         = false, -- 首次登记完成后才开放业务命令。
}

local function inspect()
    return
    {
        handle = skynet.self(),
        module_version = module_state.player_logic.version(),
        equip = module_state.player_state.equip,
        level = module_state.player_state.level,
        schema_version = module_state.player_state.schema_version,
        load_attack = module_state.business_functions.load(100),
        cached_v1_load_attack = module_state.initial_load(100),
        load_replaced = module_state.business_functions.load ~= module_state.initial_load,
        state_root_identity = module_state.player_state == module_state.state_root,
        module_identity = tostring(module_state.player_logic),
        module_root_identity = package.loaded.player_logic == module_state.player_logic,
        module_alias_identity = package.loaded.player_logic == module_state.player_logic
            and package.loaded["lualib.player_logic"] == module_state.player_logic,
        guard_open = module_state.hotupgrade.guard().owner == nil,
    }
end

local function initialize()
    module_state.player_logic = module_state.hotupgrade.require("player_logic")
    local version = module_state.player_logic.version()
    if version ~= "v2" then
        return {ok = false, code = "HU_PLAYER_VERSION_UNSUPPORTED", message = tostring(version)}
    end

    module_state.player_state =
    {
        equip = "剑",
        level = 50,
        schema_version = 2,
    }
    module_state.state_root = module_state.player_state
    module_state.business_functions = {load = module_state.player_logic.make_load(module_state.player_state)}
    module_state.initial_load = module_state.business_functions.load

    local registered_result = module_state.hotupgrade.register_service(
    {
        service_module = "player",
        service_update = {state = module_state.player_state, functions = module_state.business_functions},
        after_upgrade = function()
            return module_state.player_logic.version() == "v2" and module_state.player_state.equip == "剑"
                and module_state.player_state.schema_version == 2 and module_state.business_functions.load(100) == 121
        end,
    })
    if registered_result.ok then
        module_state.registered = true
    end
    return registered_result
end

skynet.start(function()
    module_state.hotupgrade = require "flywow_hotupgrade"
    skynet.dispatch("lua", function(session, _source, command)
        local answer
        if command == "init" then
            if module_state.registered then
                answer = {ok = false, code = "HU_ALREADY_INITIALIZED", message = "PlayerService 已初始化"}
            else
                answer = initialize()
            end
        elseif not module_state.registered then
            answer = {ok = false, code = "HU_NOT_INITIALIZED", message = "PlayerService 尚未登记"}
        elseif command == "inspect" then
            answer = module_state.hotupgrade.guard():run(inspect)
        elseif command == "attack" then
            answer = module_state.hotupgrade.guard():run(function()
                return module_state.business_functions.load(100)
            end)
        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND", message = tostring(command)}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
