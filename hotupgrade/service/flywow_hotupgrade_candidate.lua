--- 候选实例的固定薄启动壳；只运行控制面已冻结并校验的 factory，不提前接生产流量。
local skynet = require "skynet"
local rpc = require "flywow_hotupgrade_rpc"
local result = require "flywow_hotupgrade_error"
local controller, token = ...
controller = tonumber(controller)

skynet.start(function()
    local answer = rpc.call(controller, "bootstrap", {token = token}, 10000)
    assert(answer.ok and answer.bootstrap, "候选启动凭据无效")
    local bootstrap = answer.bootstrap
    local chunk = assert(load(bootstrap.source, "@hotupgrade_candidate", "t", _G))
    local loaded = result.execute(chunk)
    assert(loaded.ok, loaded.message)
    local factory = loaded.values[1]
    assert(type(factory) == "function", "候选入口必须返回 factory(context)")
    local initialized = result.initialize(function() factory(bootstrap.context) end, 10000000)
    assert(initialized.ok, initialized.message)
end)
