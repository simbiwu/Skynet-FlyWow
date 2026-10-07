--- 职责：宿主通过此入口创建 UTF-8 词库，查询命中或替换文本；聊天处置由业务决定。
--- 查询同步、无 I/O、无 yield；创建 file 词库时会同步读取文件。对象和返回数据属于当前 Lua State。
--- Native 来源 word_filter/native/；构建：bash scripts/build_flywow.sh SKYNET_ROOT word_filter。
--- package.path 加载本文件，package.cpath 加载 build/native/flywow_word_filter_native.so。
local native = require "flywow_word_filter_native"

local MAX_KEYWORDS              = 16384
local MAX_REPLACEMENT_BYTES     = 256
local MAX_DICTIONARY_FILE_BYTES = 2097152
local M = {}

---@alias flywow_word_filter_error
---| '"invalid_options"' # 选项类型错误或存在未知字段
---| '"invalid_keyword"' # 词库不连续、词类型错误、空词或非法 UTF-8
---| '"invalid_text"' # 查询输入不是字符串
---| '"invalid_utf8"' # 查询文本存在非法 UTF-8，未返回部分结果
---| '"invalid_replacement"' # 替换文本类型、编码或长度不合法
---| '"dictionary_io"' # 外部词库无法打开或读取
---| '"dictionary_limit"' # 词数、词长度、总字节、节点或后缀输出超限
---| '"text_limit"' # 输入文本超过固定字节上限
---| '"match_limit"' # 命中项数超过固定上限，未返回部分结果
---| '"out_of_memory"' # Native 分配失败；Lua 自身的内存失败仍抛 Lua 异常
---| '"internal_error"' # Native 遇到未识别异常
---| '"closed"' # Native userdata 已释放，仅直接操作 Native 时可能出现

---@class flywow_word_filter_match
---@field keyword_id integer 宿主词库的 1-based 数组索引，重复词保留独立 ID
---@field offset integer 原文的 1-based byte 起点，可直接交给 string.sub
---@field length integer 原文字节跨度；compact 时包含中间被忽略的分隔符

---@class flywow_word_filter_options
---@field keywords string[] 宿主提供的连续数组，创建时复制；空词库合法
---@field file? string UTF-8 外部词库路径；每行一个词，空行忽略；与 keywords 二选一
---@field compact? boolean 默认 false；true 时忽略固定类别分隔符，可能增加误报

---@class flywow_word_filter
---@field private native_handle userdata 当前 Lua State 独占的 Native owner，GC 释放词库
local Filter = {}
Filter.__index = Filter

local function native_error_code(error_value)
    if type(error_value) == "table" then
        return error_value.code or "internal_error"
    end
    return error_value
end

--- 从内存数组或 UTF-8 外部文本文件创建只读词库；文件每行一个词，空行忽略。
--- 统一做 ASCII 小写、全角 ASCII 折叠和开头 BOM 去除。
--- 原词库在成功创建后可由宿主修改，不影响此对象；更新词库需创建新对象。
--- 容量和编码错误返回 nil,error；Lua 分配错误仍遵循 Lua 自身异常语义。
---@param options flywow_word_filter_options
---@return flywow_word_filter? filter
---@return flywow_word_filter_error? error
function M.new(options)
    if type(options) ~= "table" then
        return nil, "invalid_options"
    end
    if options.keywords ~= nil and type(options.keywords) ~= "table"
        or options.file ~= nil and type(options.file) ~= "string"
        or (options.compact ~= nil and type(options.compact) ~= "boolean") then
        return nil, "invalid_options"
    end

    for key in pairs(options) do
        if key ~= "keywords" and key ~= "file" and key ~= "compact" then
            return nil, "invalid_options"
        end
    end

    if options.keywords ~= nil and options.file ~= nil then
        return nil, "invalid_options"
    end
    if options.keywords == nil and options.file == nil then
        return nil, "invalid_options"
    end

    local keywords = options.keywords
    if options.file ~= nil then
        local file = io.open(options.file, "rb")
        if not file then
            return nil, "dictionary_io"
        end
        local content = file:read(MAX_DICTIONARY_FILE_BYTES + 1)
        local close_ok = file:close()
        if not content or not close_ok then
            return nil, "dictionary_io"
        end
        if #content > MAX_DICTIONARY_FILE_BYTES then
            return nil, "dictionary_limit"
        end
        keywords = {}
        for line in (content .. "\n"):gmatch("(.-)\n") do
            if line:sub(-1) == "\r" then
                line = line:sub(1, -2)
            end
            if #line > 0 then
                keywords[#keywords + 1] = line
            end
        end
    end

    local keyword_count = #keywords
    if keyword_count > MAX_KEYWORDS then
        return nil, "dictionary_limit"
    end

    --- 此处检查键和类型；Native 逐项 rawgeti，继续检查数组中间的空洞。
    for key, keyword in pairs(keywords) do
        if type(key) ~= "number" or math.type(key) ~= "integer"
            or key < 1 or key > keyword_count or type(keyword) ~= "string" then
            return nil, "invalid_keyword"
        end
    end

    local native_handle, error_value = native.new(keywords, options.compact == true)
    if not native_handle then
        return nil, native_error_code(error_value)
    end

    return setmetatable(
    {
        native_handle = native_handle,
    }, Filter)
end

--- 返回全部命中，包括重叠项；按原文 byte 起点、词库 ID 排序，结果归调用者所有。
--- 文本最多 65536 bytes、命中最多 4096 项；错误返回 nil,error，不返回部分结果。
---@param text string 原文，允许内嵌 NUL；不能包含非法 UTF-8
---@return flywow_word_filter_match[]? matches
---@return flywow_word_filter_error? error
function Filter:find(text)
    local matches, error_value = native.find(self.native_handle, text)
    if not matches then
        return nil, native_error_code(error_value)
    end

    table.sort(matches, function(left, right)
        if left.offset ~= right.offset then
            return left.offset < right.offset
        end
        return left.keyword_id < right.keyword_id
    end)
    return matches
end

--- 检测是否命中；false 只表示未命中，nil,error 表示失败，业务必须区分。
--- 复用完整 find，容量与分配行为相同，不是找到首项便提前退出的接口。
---@param text string
---@return boolean? matched
---@return flywow_word_filter_error? error
function Filter:contains(text)
    local matches, error_code = self:find(text)
    if not matches then
        return nil, error_code
    end
    return #matches > 0
end

--- 合并重叠命中后，每个合并区间替换一次；原文保持不变，新文本归调用者所有。
--- 默认 replacement="*"；相邻但不重叠的命中分别替换，错误返回 nil,error。
---@param text string
---@param replacement? string 合法 UTF-8，允许空串，最多 256 bytes
---@return string? filtered
---@return flywow_word_filter_error? error
function Filter:replace(text, replacement)
    if replacement == nil then
        replacement = "*"
    end
    if type(replacement) ~= "string" or #replacement > MAX_REPLACEMENT_BYTES
        or not utf8.len(replacement) then
        return nil, "invalid_replacement"
    end

    local matches, error_code = self:find(text)
    if not matches then
        return nil, error_code
    end

    local parts = {}
    local next_source_byte = 1
    local span_start_byte, span_end_byte

    --- find 已按起点排序。合并区间使用闭区间 [start,end]，所有位置都是原文 bytes。
    --- 例如 she 同时命中 she/he：两个区间合并为 [1,3]，只输出一次替换文本。
    for _, match in ipairs(matches) do
        local match_end_byte = match.offset + match.length - 1
        if span_start_byte and match.offset <= span_end_byte then
            span_end_byte = math.max(span_end_byte, match_end_byte)
        else
            if span_start_byte then
                parts[#parts + 1] = text:sub(next_source_byte, span_start_byte - 1)
                parts[#parts + 1] = replacement
                next_source_byte = span_end_byte + 1
            end
            span_start_byte, span_end_byte = match.offset, match_end_byte
        end
    end

    --- 循环只在遇到下一个区间时写出上一个；最后一个区间和余下原文在此收尾。
    if span_start_byte then
        parts[#parts + 1] = text:sub(next_source_byte, span_start_byte - 1)
        parts[#parts + 1] = replacement
        next_source_byte = span_end_byte + 1
    end
    parts[#parts + 1] = text:sub(next_source_byte)
    return table.concat(parts)
end

return M
