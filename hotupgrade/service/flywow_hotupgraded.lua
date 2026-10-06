--- 热更控制 Service；启动者通过 Lua 配置 record 指定 Patch Root、审计文件及管理 handle。
local skynet = require "skynet"
local controller_module = require "flywow_hotupgrade_controller"
local rpc = require "flywow_hotupgrade_rpc"
local options_module, admin = ...
local options = require(options_module)
options.admin_handles = {[tonumber(admin)] = true}

skynet.start(function()
    local opened = controller_module.new(options)
    assert(opened.ok, opened.message)
    local controller = opened.controller
    rpc.install(function(command, request, source)
        return controller:control(command, request, source)
    end)
end)
