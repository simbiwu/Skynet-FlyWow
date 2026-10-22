local skynet = require "skynet"
local module_state =
{
    business_queue            = require "skynet.queue"(), -- 本 Service 的业务安全队列；before_upgrade 等待其排空。
    hotupgrade                = nil,                      -- 当前 Lua State 的 HotUpgrade API；初始化后供回调共同使用。
    player_logic              = nil,                      -- 本 State 已登记的玩家逻辑模块；热更后根导出表身份保持不变。
    player_state              = nil,                      -- PlayerService 持有的私有状态表；迁移时只更新字段，不替换表身份。
    player_state_root         = nil,                      -- 初始化时保存的状态根表，用于示例检查迁移后的身份。
    player_business_functions = nil,                      -- 本 Service 暴露给业务使用的函数表；Service Patch 只替换指定字段。
    initial_load_function     = nil,                      -- 初始化前保存的旧 load 闭包，用于展示旧闭包与新函数的区别。
}

local function inspect()
    return
    {
        handle = skynet.self(),
        version = module_state.player_logic.version(),
        equip = module_state.player_state.equip,
        schema_version = module_state.player_state.schema_version,
        attack = module_state.player_business_functions.load(100),
        initial_attack = module_state.initial_load_function(100),
        load_changed = module_state.player_business_functions.load ~= module_state.initial_load_function,
        state_same = module_state.player_state == module_state.player_state_root,
        module_id = tostring(module_state.player_logic),
        module_alias_same = package.loaded.player_logic == module_state.player_logic
            and package.loaded["lualib.player_logic"] == module_state.player_logic,
        patching = module_state.hotupgrade.patching,
    }
end

local function initialize()
    module_state.player_logic = module_state.hotupgrade.require("player_logic")

    module_state.player_state =
    {
        equip = "刀",
        schema_version = 1,
    }
    module_state.player_state_root = module_state.player_state

    module_state.player_business_functions = {load = module_state.player_logic.make_load(module_state.player_state)}
    module_state.initial_load_function = module_state.player_business_functions.load

    return module_state.hotupgrade.register_service(
    {
        service_update = {state = module_state.player_state, functions = module_state.player_business_functions},

        before_upgrade = function()
            return module_state.business_queue(function()
                return true
            end)
        end,

        after_upgrade = function()
            return module_state.player_logic.version() == "v2"
                and module_state.player_state.equip == "剑"
                and module_state.player_state.schema_version == 2
                and module_state.player_business_functions.load(100) == 121
        end,
    })
end

skynet.start(function()
    module_state.hotupgrade = require "flywow_hotupgrade"
    skynet.dispatch("lua", function(session, _source, command)
        local answer

        if command == "init" then
            answer = initialize()
        elseif command == "inspect" then
            if module_state.hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = {ok = true, player = module_state.business_queue(inspect)}
            end

        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            return skynet.retpack(answer)
        end
    end)
end)
