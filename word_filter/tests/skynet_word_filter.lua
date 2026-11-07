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

--- 在当前 Lua State 创建并查询词库；同步、无 I/O、无 yield。
---@return boolean 所有创建、查询及 UTF-8 错误断言通过时为 true。
local function verify_public_api()
    local filter = assert(word_filter.create_filter(
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

    -- __pairs 不能隐藏未知配置键，__index 提供的合法字段仍可用。
    local hidden_option_config = setmetatable({keywords = {"bad"}, unexpected = true}, {__pairs = function()
        return next, {}, nil
    end})
    local hidden_option_filter, hidden_option_error = word_filter.create_filter(hidden_option_config)
    assert(hidden_option_filter == nil and hidden_option_error == "invalid_options")

    -- 字段校验与构建复用同一个词库；第二次读取会返回不同的值。
    local keyword_reads = 0
    local inherited_config = setmetatable({},
    {
        -- 首次读取提供可构建的词库；再次读取会导致输入不合法。
        __index = function(_, key)
            if key == "keywords" then
                keyword_reads = keyword_reads + 1
                return keyword_reads == 1 and {"bad"} or false
            end
        end,
    })
    local inherited_filter = assert(word_filter.create_filter(inherited_config))
    assert(keyword_reads == 1 and inherited_filter:contains("bad"))

    -- 两种畸形词库都应在发布 userdata 前被拒绝。
    local invalid_filter, invalid_keyword_code = word_filter.create_filter({keywords = {[2] = "bad"}})
    assert(invalid_filter == nil and invalid_keyword_code == "invalid_keyword")
    invalid_filter, invalid_keyword_code = word_filter.create_filter({keywords = {"bad", unexpected = true}})
    assert(invalid_filter == nil and invalid_keyword_code == "invalid_keyword")

    -- 查询失败与正常未命中必须可区分；首个命中之后仍要检查尾部 UTF-8。
    local result, error_code = filter:find(123)
    assert(result == nil and error_code == "invalid_text")
    result, error_code = filter:contains("bad" .. string.char(255))
    assert(result == nil and error_code == "invalid_utf8")
    result, error_code = filter:contains(string.rep("bad", 4097))
    assert(result == nil and error_code == "match_limit")

    -- 4097 条重复词产生相同跨度；257 bytes 的候选全部淘汰，不占命中额度。
    local repeated_keywords = {}
    for index = 1, 4097 do
        repeated_keywords[index] = "ab"
    end

    -- 使用同一份词库验证 256 bytes 上限两侧的可观察行为。
    local compact_filter = assert(word_filter.create_filter(
    {
        keywords = repeated_keywords, -- 重复词保留独立 ID，分别计数。
        compact = true, -- 允许跨空格匹配，但仍检查原文跨度。
    }))
    local over_span = "a" .. string.rep(" ", 255) .. "b"
    assert(#assert(compact_filter:find(over_span)) == 0)
    assert(compact_filter:contains(over_span) == false)
    result, error_code = compact_filter:find("a" .. string.rep(" ", 254) .. "b")
    assert(result == nil and error_code == "match_limit")

    -- 查询断言结束后触发一次完整 GC，验证短期 Native 词库可由 userdata 回收。
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

            -- 文件与容量断言只在启动者执行一次，复用当前 Service 的模块搜索路径。
            dofile("./word_filter/tests/test_word_filter.lua")

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
