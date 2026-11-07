--- 职责：通过公开 API 验证 Lua/Native 加载、UTF-8、替换、边界和 GC。
--- 由 Skynet 集成测试加载，复用测试配置提供的 Lua 和 Native 搜索路径。
local word_filter = require "flywow_word_filter"
local dictionary_path = os.tmpname()
local dictionary_file = assert(io.open(dictionary_path, "wb"))
assert(dictionary_file:close())
local empty_filter = assert(word_filter.create_filter({file = dictionary_path}))
assert(empty_filter:contains("SHE") == false)

dictionary_file = assert(io.open(dictionary_path, "wb"))
assert(dictionary_file:write("\n\r\n"))
local blank_close_ok = dictionary_file:close()
assert(blank_close_ok)
local blank_filter = assert(word_filter.create_filter({file = dictionary_path}))
assert(blank_filter:contains("SHE") == false)

dictionary_file = assert(io.open(dictionary_path, "wb"))
dictionary_file:write("外挂\r\nhe\n\nshe\n")
assert(dictionary_file:close())
local file_filter, file_error = word_filter.create_filter({file = dictionary_path})
local truncated_filter, truncated_error = word_filter.create_filter({file = dictionary_path .. "\0ignored"})
assert(truncated_filter == nil and truncated_error == "invalid_options")
os.remove(dictionary_path)
assert(file_filter and not file_error)
assert(file_filter:contains("SHE"))
local missing_filter, missing_error = word_filter.create_filter({file = dictionary_path})
assert(missing_filter == nil and missing_error == "dictionary_io")

local filter = assert(word_filter.create_filter(
{
    keywords = {"外挂", "he", "she", "bad"},
}))

--- 普通模式：大小写/全角折叠、原文 byte 映射、重叠与相邻替换。
assert(filter:contains("普通聊天") == false)
assert(filter:contains("外-挂") == false)
assert(filter:contains("ＢＡＤ"))
local matches = assert(filter:find("前外挂后"))
assert(#matches == 1 and matches[1].offset == 4 and matches[1].length == 6)
assert(filter:replace("前外挂后") == "前*后")
assert(filter:replace("she", "[屏蔽]") == "[屏蔽]")
assert(filter:replace("badshe") == "**")
assert(filter:contains("x\0bad"))

--- 输入和命中数量的合法边界；NUL 由显式长度传入 Native，不当作结束符。
assert(filter:contains(string.rep("a", 65536)) == false)
assert(filter:contains(string.rep("bad", 4096)))

--- 过长编码、代理项、超出 Unicode 上限和截断序列均必须拒绝。
for _, invalid in ipairs({"\192\128", "\237\160\128", "\244\144\128\128", "\226\130"}) do
    local result, code = filter:find(invalid)
    assert(result == nil and code == "invalid_utf8")
end

--- 错误是 nil,error，不应被业务当成“未命中”。
local value, error_code = filter:find("\255")
assert(value == nil and error_code == "invalid_utf8")
value, error_code = filter:find(string.rep("a", 65537))
assert(value == nil and error_code == "text_limit")
value, error_code = filter:find(string.rep("bad", 4097))
assert(value == nil and error_code == "match_limit")
value, error_code = word_filter.create_filter({keywords = {""}})
assert(value == nil and error_code == "invalid_keyword")
value, error_code = word_filter.create_filter({keywords = {"ok", "\255"}})
assert(value == nil and error_code == "invalid_keyword")
value, error_code = word_filter.create_filter({keywords = {[2] = "gap"}})
assert(value == nil and error_code == "invalid_keyword")
value, error_code = filter:replace("bad", "\255")
assert(value == nil and error_code == "invalid_replacement")
assert(word_filter.create_filter({keywords = {}}):contains("bad") == false)

--- compact 开关只改变输入匹配方式，跨度上限仍按原文 bytes 计算。
local compact_filter = assert(word_filter.create_filter(
{
    keywords = {"外挂"},
    compact  = true,
}))
assert(compact_filter:replace("外-挂") == "*")
assert(compact_filter:contains("外" .. string.rep(" ", 256) .. "挂") == false)

--- 全长文本与大量重复长词都在公开上限内；所有候选跨度均为 257 bytes。
local long_keyword = string.rep("a", 257)
local long_keywords = {}
for index = 1, 4080 do
    long_keywords[index] = long_keyword
end
local long_filter = assert(word_filter.create_filter({keywords = long_keywords, compact = true}))
local max_text = string.rep("a", 65536)
assert(long_filter:contains(max_text) == false)
assert(#assert(long_filter:find(max_text)) == 0)

--- 同一节点的长候选被跳过，较短后缀仍然按原文位置返回。
local suffix_filter = assert(word_filter.create_filter({keywords = {long_keyword, "a"}, compact = true}))
local suffix_matches = assert(suffix_filter:find(long_keyword))
assert(#suffix_matches == 257 and suffix_matches[257].keyword_id == 2 and suffix_matches[257].offset == 257)

--- GC 回调在同一个过滤器上重入 find。外层使用大量命中确保建表期间有分配。
local outer_text = string.rep("bad", 4096)
local nested_matches
local nested_error
local in_outer_find = false
local reentered = false
collectgarbage("collect")
collectgarbage("stop")
local finalizer_meta =
{
    -- 记录回调实际发生的阶段及查询结果；断言留在外层，避免 GC 吞掉错误。
    __gc = function() -- 外层 find 期间，在同一词库上发起内层查询。
        if in_outer_find and not reentered then
            reentered = true
            nested_matches, nested_error = filter:find("she") -- 保存内层命中或错误，供外层断言。
        end
    end,
}
for _ = 1, 64 do
    setmetatable({}, finalizer_meta)
end
in_outer_find = true
collectgarbage("restart")
local outer_matches = assert(filter:find(outer_text))
in_outer_find = false
assert(reentered and nested_matches and not nested_error)
assert(#nested_matches == 2 and nested_matches[1].keyword_id == 3 and nested_matches[2].keyword_id == 2)
assert(#outer_matches == 4096 and outer_matches[4096].keyword_id == 4 and outer_matches[4096].offset == 12286)

--- 临时创建的过滤对象在失去引用后由 GC 清理。
for _ = 1, 100 do
    assert(word_filter.create_filter({keywords = {"bad"}}):contains("BAD"))
end
collectgarbage("collect")

--- 16384 词上限的下一项，以及单词 4096 bytes 上限的下一 byte。
local too_many_keywords = {}
for index = 1, 16385 do
    too_many_keywords[index] = "a"
end
value, error_code = word_filter.create_filter({keywords = too_many_keywords})
assert(value == nil and error_code == "dictionary_limit")
assert(word_filter.create_filter({keywords = {string.rep("a", 4096)}}))
value, error_code = word_filter.create_filter({keywords = {string.rep("a", 4097)}})
assert(value == nil and error_code == "dictionary_limit")

--- 重复长词不增加很多节点，但会超过原词库 1 MiB 总字节上限。
local oversized_dictionary = {}
for index = 1, 257 do
    oversized_dictionary[index] = string.rep("a", 4096)
end
value, error_code = word_filter.create_filter({keywords = oversized_dictionary})
assert(value == nil and error_code == "dictionary_limit")

--- 16000 个短后缀复制到长词节点，专门触发后缀输出项上限。
local dense_suffixes = {}
for index = 1, 16000 do
    dense_suffixes[index] = "a"
end
dense_suffixes[16001] = string.rep("a", 1000)
value, error_code = word_filter.create_filter({keywords = dense_suffixes})
assert(value == nil and error_code == "dictionary_limit")

--- 不同前缀的长词在 1 MiB 以内，却需要超过 262144 个 trie 节点。
local many_node_keywords = {}
for index = 1, 70 do
    many_node_keywords[index] = tostring(index) .. string.rep("x", 4090)
end
value, error_code = word_filter.create_filter({keywords = many_node_keywords})
assert(value == nil and error_code == "dictionary_limit")
collectgarbage("collect")
print("FLYWOW_WORD_FILTER_LUA_OK")
