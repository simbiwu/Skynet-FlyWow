--- 热更控制 Service；宿主配置通过 Lua init 请求交付。
local skynet = require "skynet"
local controller_module = require "flywow_hotupgrade_controller"
local protocol = require "flywow_hotupgrade_protocol"
local result = require "flywow_hotupgrade_error"

local controller -- Controller.new 成功后由本 Service 持有；未成功打开时保持 nil。

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, options)
        local answer
        if command ~= "init" then
            answer = result.failure("HU_UNKNOWN_COMMAND", tostring(command))
        elseif controller then
            answer = result.failure("HU_ALREADY_INITIALIZED", "控制 Service 已初始化")
        elseif type(options) ~= "table" then
            answer = result.failure("HU_INVALID_OPTIONS", "init 需要配置 table")
        else
            local opened = controller_module.new(options)
            if not opened.ok then
                answer = opened
            else
                controller = opened.controller
                protocol.install_handler(function(command, request, source)
                    return controller:control(command, request, source)
                end)
                answer = result.success()
            end
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
