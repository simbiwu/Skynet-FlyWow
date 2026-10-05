--- 职责：在真实 Skynet Service 中验证 Wrapper/Native 加载、独立词库和公开 API。
--- 测试启动者持有两个 worker handle；没有网络输入，结束时 ABORT 整个测试进程。
local skynet = require "skynet"
require "skynet.manager" --- 注册测试退出所需的 skynet.abort，不创建额外 Service。
local word_filter = require "flywow_word_filter"

---@alias flywow_word_filter_test_command 'run'
---@type flywow_word_filter_test_command
local TEST_COMMAND = "run"

---@type 'worker'|nil
local role = ... --- Skynet 启动参数；此处仅取固定的第一个参数，不向业务转发 varargs。

--- 在当前 Lua State 创建并查询词库；同步、无 I/O、无 yield，成功返回 true。
local function verify_public_api()
    local filter = assert(word_filter.new(
    {
        keywords = {"外挂", "bad"},
        compact  = true,
    }))
    for _ = 1, 100 do
        assert(filter:contains("ＢＡＤ"), "全角 ASCII 应命中")
        assert(filter:replace("测试外-挂") == "测试*", "compact 替换应覆盖原文分隔符")
        local result, error_code = filter:find("\255")
        assert(result == nil and error_code == "invalid_utf8", "非法 UTF-8 不应返回部分命中")
    end
    collectgarbage("collect")
    return true
end

--- worker 安装测试消息入口；启动者创建 worker、发起会 yield 的 call，并负责进程退出。
skynet.start(function()
    if role == "worker" then
        --- run 无 payload，返回 boolean；执行 verify_public_api 时不 yield。
        --- session/source 由 Skynet 提供，仅用于测试消息分发，不保存跨调用状态。
        ---@param session integer
        ---@param source integer 调用方 Service handle
        ---@param command flywow_word_filter_test_command
        skynet.dispatch("lua", function(session, source, command)
            assert(command == TEST_COMMAND)
            skynet.retpack(verify_public_api())
        end)
    else
        local succeeded, traceback = xpcall(function()
            assert(verify_public_api())

            --- handle 由启动者拥有；两个 worker 各自创建 Native owner，不共享可变查询容器。
            local first_worker_handle  = skynet.newservice("skynet_word_filter", "worker")
            local second_worker_handle = skynet.newservice("skynet_word_filter", "worker")

            --- call 会 yield；command=run，无 payload，返回 boolean。没有借用 buffer 跨 yield。
            assert(skynet.call(first_worker_handle, "lua", TEST_COMMAND))
            assert(skynet.call(second_worker_handle, "lua", TEST_COMMAND))
            print("FLYWOW_WORD_FILTER_SKYNET_OK")
        end, debug.traceback)

        if not succeeded then
            print("FLYWOW_WORD_FILTER_SKYNET_FAIL", traceback)
        end

        --- 同步刷新后再退出，避免退出标记丢在异步 Logger 队列中。
        io.stdout:flush()
        skynet.abort()
    end
end)
