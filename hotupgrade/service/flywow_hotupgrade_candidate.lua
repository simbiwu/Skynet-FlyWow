--- 候选拥有独立 Lua State；先接入冻结模块，再运行 factory，完整返回后报告就绪。
local skynet = require "skynet"
local protocol = require "flywow_hotupgrade_protocol"
local result = require "flywow_hotupgrade_error"
local controller_handle = tonumber(...) -- 启动参数传入的 Controller Service handle。

skynet.start(function()
    local ok, initialized = pcall(function()
        local answer = skynet.call(controller_handle, "hotupgrade", "bootstrap", {})
        assert(answer and answer.ok and answer.bootstrap, "候选启动窗口无效")
        local bootstrap = answer.bootstrap
        return result.initialize(function()
            local frozen, loading = {}, {}
            for _, entry in ipairs(bootstrap.modules) do
                assert(package.loaded[entry.name] == nil, "冻结模块已被启动壳加载: " .. entry.name)
                frozen[entry.name] = entry.source
            end

            -- skynet.require 优先搜索磁盘文件，单独设置 package.preload 无法覆盖已有文件。
            -- 只接管本候选的冻结模块；其它模块保持原 Skynet require 行为。
            local original_require = require
            _G.require = function(name)
                if not frozen[name] then return original_require(name) end
                if package.loaded[name] ~= nil then return package.loaded[name] end
                assert(not loading[name], "冻结模块循环依赖: " .. name)
                loading[name] = true
                local chunk = assert(load(frozen[name], "@hotupgrade/" .. name, "t", _G))
                local loaded, value = pcall(chunk, name)
                loading[name] = nil
                assert(loaded, value)
                if value == nil then value = true end
                package.loaded[name] = value
                frozen[name] = nil -- 已加载模块由缓存持有，不再保留它的源码。
                return value
            end

            -- 入口执行与 factory 都在 Skynet 当前协程中；权威状态重建允许正常 yield。
            local chunk = assert(load(bootstrap.source, "@" .. bootstrap.entry_file, "t", _G))
            local factory = chunk()
            assert(type(factory) == "function", "候选入口必须返回 factory(context)")
            factory(bootstrap.context)
        end, 10000000)
    end)
    if not ok then initialized = result.failure("HU_CREATE_FAILED", tostring(initialized)) end

    -- source 就是控制面同步 launch 持有的 instance_handle；窗口结束后迟到报告被拒绝。
    local ok, reported = pcall(skynet.call, controller_handle, "hotupgrade", "candidate_ready",
        {answer = initialized})
    if not ok or not initialized.ok or not reported or not reported.ok then
        skynet.exit()
    end
end)
