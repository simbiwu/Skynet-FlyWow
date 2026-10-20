-- 用公开 Lua API 演示内存词库、命中位置及文本替换。
local skynet = require "skynet"
local function run()
    local word_filter = require "flywow_word_filter"
    local filter, create_error = word_filter.new({keywords = {"外挂", "she"}})
    assert(filter, create_error)
    assert(filter:contains("普通聊天") == false)
    local matches, find_error = filter:find("前外挂后")
    assert(matches and not find_error and #matches == 1)
    assert(matches[1].offset == 4 and matches[1].length == 6)
    local replaced, replace_error = filter:replace("前外挂后")
    assert(replaced and not replace_error and replaced == "前*后")
    assert(filter:replace("she", "[屏蔽]") == "[屏蔽]")
    print("输入：前外挂后")
    print("命中起点 byte=" .. matches[1].offset .. "，长度 byte=" .. matches[1].length)
    print("替换：" .. replaced)
end
skynet.start(function()
    local ok, message = xpcall(run, debug.traceback)
    if ok then print("FLYWOW_WORD_FILTER_SAMPLE_OK")
    else skynet.error("FLYWOW_WORD_FILTER_SAMPLE_FAILED: " .. tostring(message)) end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)
