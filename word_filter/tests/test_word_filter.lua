--- 职责：通过公开 API 验证 Lua/Native 加载、UTF-8、替换、边界和 GC。
--- CTest 传入 Wrapper 目录与 Native 产物目录，不依赖开发机绝对路径。
package.path = arg[1] .. "/?.lua;" .. package.path
package.cpath = arg[2] .. "/?.so;" .. package.cpath
local word_filter = require "flywow_word_filter"
local filter = assert(word_filter.new(
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
value, error_code = word_filter.new({keywords = {""}})
assert(value == nil and error_code == "invalid_keyword")
value, error_code = word_filter.new({keywords = {"ok", "\255"}})
assert(value == nil and error_code == "invalid_keyword")
value, error_code = word_filter.new({keywords = {[2] = "gap"}})
assert(value == nil and error_code == "invalid_keyword")
value, error_code = filter:replace("bad", "\255")
assert(value == nil and error_code == "invalid_replacement")
assert(word_filter.new({keywords = {}}):contains("bad") == false)

--- compact 开关只改变输入匹配方式，跨度上限仍按原文 bytes 计算。
local compact_filter = assert(word_filter.new(
{
    keywords = {"外挂"},
    compact  = true,
}))
assert(compact_filter:replace("外-挂") == "*")
assert(compact_filter:contains("外" .. string.rep(" ", 256) .. "挂") == false)

--- 临时创建的过滤对象在失去引用后由 GC 清理。
for _ = 1, 100 do
    assert(word_filter.new({keywords = {"bad"}}):contains("BAD"))
end
collectgarbage("collect")

--- 16384 词上限的下一项，以及单词 4096 bytes 上限的下一 byte。
local too_many_keywords = {}
for index = 1, 16385 do
    too_many_keywords[index] = "a"
end
value, error_code = word_filter.new({keywords = too_many_keywords})
assert(value == nil and error_code == "dictionary_limit")
value, error_code = word_filter.new({keywords = {string.rep("a", 4097)}})
assert(value == nil and error_code == "dictionary_limit")

--- 重复长词不增加很多节点，但会超过原词库 1 MiB 总字节上限。
local oversized_dictionary = {}
for index = 1, 257 do
    oversized_dictionary[index] = string.rep("a", 4096)
end
value, error_code = word_filter.new({keywords = oversized_dictionary})
assert(value == nil and error_code == "dictionary_limit")

--- 16000 个短后缀复制到长词节点，专门触发后缀输出项上限。
local dense_suffixes = {}
for index = 1, 16000 do
    dense_suffixes[index] = "a"
end
dense_suffixes[16001] = string.rep("a", 1000)
value, error_code = word_filter.new({keywords = dense_suffixes})
assert(value == nil and error_code == "dictionary_limit")

--- 不同前缀的长词在 1 MiB 以内，却需要超过 262144 个 trie 节点。
local many_node_keywords = {}
for index = 1, 70 do
    many_node_keywords[index] = tostring(index) .. string.rep("x", 4090)
end
value, error_code = word_filter.new({keywords = many_node_keywords})
assert(value == nil and error_code == "dictionary_limit")
collectgarbage("collect")
print("FLYWOW_WORD_FILTER_LUA_OK")
