--- 职责：宿主通过此入口创建 UTF-8 词库，查询命中或替换文本；聊天处置由业务决定。
--- 查询同步、无 I/O、无 yield；创建 file 词库时会同步读取文件。对象和返回数据属于当前 Lua State。
--- Native 来源 word_filter/native/；构建：bash scripts/build_flywow.sh SKYNET_ROOT word_filter。
--- package.path 加载本文件，package.cpath 加载 build/native/flywow_word_filter_native.so。
local word_filter_native = require "flywow_word_filter_native"

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
---| '"internal_error"' # Native 遇到未识别异常

---@class flywow_word_filter_match
---@field keyword_id integer 宿主词库的 1-based 数组索引，重复词保留独立 ID
---@field offset integer 原文的 1-based byte 起点，可直接交给 string.sub
---@field length integer 原文字节跨度；compact 时包含中间被忽略的分隔符

---@class flywow_word_filter_config
---@field keywords? string[] 宿主提供的连续数组，创建时构建词库；空词库合法
---@field file? string UTF-8 外部词库路径；每行一个词，空行忽略；与 keywords 二选一
---@field compact? boolean 默认 false；true 时忽略固定类别分隔符，可能增加误报

---@class flywow_word_filter
---@field private native_handle userdata 当前 Lua State 独占的 Native owner，GC 释放词库
local Filter = {}
Filter.__index = Filter

--- 将 Native 查询或构建失败转换成 WordFilter 对外返回的错误码。
---@param native_error table Native 返回的诊断表；code 由 LuaBinding 或 WordFilter 写入。
---@return flywow_word_filter_error error_code 调用方可直接判断的错误码。
local function native_error_code(native_error)
    local code = native_error.code -- Native 的机器错误码，供 Lua API 调用者判断失败原因。
    if code == "INTERNAL_ERROR" then
        return "internal_error"
    end
    return code
end

--- 从内存数组或 UTF-8 外部文本文件创建只读词库；文件每行一个词，空行忽略。
--- 统一做 ASCII 小写、全角 ASCII 折叠和开头 BOM 去除。
--- 原词库在成功创建后可由宿主修改，不影响此对象；更新词库需创建新对象。
--- 容量和编码错误返回 nil,error；Lua 分配错误仍遵循 Lua 自身异常语义。
---@param word_filter_config flywow_word_filter_config 宿主提供的词库来源；从 keywords 数组或 file 路径读取，并按 compact 选项构建 Native 词库。
---@return flywow_word_filter? 成功时返回持有只读词库的 Filter 对象。
---@return flywow_word_filter_error? 选项、词库、文件或容量不合法时返回稳定错误码。
function M.create_filter(word_filter_config)
    if type(word_filter_config) ~= "table" then
        return nil, "invalid_options"
    end

    -- 用原始键检查选项，避免 __pairs 隐藏未支持的字段。
    for key in next, word_filter_config do
        if key ~= "keywords" and key ~= "file" and key ~= "compact" then
            return nil, "invalid_options"
        end
    end

    -- 保留配置字段的 Lua 索引语义，只读取一次，使校验值和实际使用值相同。
    local keywords = word_filter_config.keywords -- 内存词库；若配置文件则在读取后填充。
    local dictionary_path = word_filter_config.file -- 词库文件路径，与内存词库二选一。
    local compact = word_filter_config.compact -- 是否启用查询时的分隔码点过滤。
    if (keywords ~= nil and type(keywords) ~= "table")
        or (dictionary_path ~= nil and (type(dictionary_path) ~= "string" or dictionary_path:find("\0", 1, true)))
        or (compact ~= nil and type(compact) ~= "boolean")
        or (keywords == nil) == (dictionary_path == nil) then
        return nil, "invalid_options"
    end

    -- 文件词库转换为内存数组，与直接传入的数组共用 Native 构建。
    if dictionary_path ~= nil then
        local file = io.open(dictionary_path, "rb") -- 当前函数负责读取并关闭的文件。
        if not file then
            return nil, "dictionary_io"
        end
        -- 定长读取在正常 EOF 返回 nil，在 I/O 失败时另外返回诊断。
        local content, read_error = file:read(MAX_DICTIONARY_FILE_BYTES + 1)
        local close_ok = file:close() -- 关闭失败仍按词库 I/O 故障处理。
        if read_error or not close_ok then
            return nil, "dictionary_io"
        end
        -- 零字节文件和仅含空行的文件都生成空词库。
        content = content or ""
        if #content > MAX_DICTIONARY_FILE_BYTES then
            return nil, "dictionary_limit"
        end
        keywords = {}
        -- 直接匹配非空行，既能读取无换行的末行，也无需复制整份文件补换行。
        for keyword in content:gmatch("[^\n]+") do -- 逐行取原始词条，接下来去掉行尾 CR。
            if keyword:sub(-1) == "\r" then
                keyword = keyword:sub(1, -2)
            end
            if #keyword > 0 then
                keywords[#keywords + 1] = keyword
            end
        end
    end

    -- Native 校验词库原始键和每项字符串。构建成功后，输入数组不再参与查询。
    local native_handle, native_error = word_filter_native.create_filter(keywords, compact == true)
    if not native_handle then
        return nil, native_error_code(native_error)
    end

    return setmetatable(
    {
        native_handle = native_handle, -- 当前 Filter 持有的只读词库，由 userdata 回收释放。
    }, Filter)
end

--- 返回全部命中，包括重叠项；按原文 byte 起点、词库 ID 排序，结果归调用者所有。
--- 文本最多 65536 bytes、命中最多 4096 项；错误返回 nil,error，不返回部分结果。
---@param text string 原文，允许内嵌 NUL；不能包含非法 UTF-8
---@return flywow_word_filter_match[]? 成功时返回按原文 byte 起点和 keyword_id 排序的全部命中；未命中返回空数组。
---@return flywow_word_filter_error? 非法 UTF-8、输入过长或结果超限时返回稳定错误码。
function Filter:find(text)
    local matches, native_error = word_filter_native.find(self.native_handle, text)
    if not matches then
        return nil, native_error_code(native_error)
    end

    -- Native 返回全部命中但不保证顺序；按公开合同排序后再交给调用方。
    table.sort(matches, function(left, right)
        if left.offset ~= right.offset then
            return left.offset < right.offset
        end
        return left.keyword_id < right.keyword_id
    end)
    return matches
end

--- 检测是否命中；false 只表示未命中，nil,error 表示失败，业务必须区分。
--- 校验完整文本并统计有效命中，不构造或排序命中数组。
---@param text string 待检查的 UTF-8 原文；允许内嵌 NUL，长度和编码限制与 find 相同。
---@return boolean? 成功时 true 表示至少命中一项，false 是正常的未命中结果。
---@return flywow_word_filter_error? 输入或命中数量超限时返回稳定错误码，不能把 nil 当作未命中。
function Filter:contains(text)
    -- Native 成功时返回布尔值，nil 才表示输入或查询失败。
    local matched, native_error = word_filter_native.contains(self.native_handle, text)
    if matched == nil then
        return nil, native_error_code(native_error)
    end
    return matched
end

--- 合并重叠命中后，每个合并区间替换一次；原文保持不变，新文本归调用者所有。
--- 默认 replacement="*"；相邻但不重叠的命中分别替换，错误返回 nil,error。
---@param text string 需要过滤的 UTF-8 原文；允许内嵌 NUL，长度和编码限制与 find 相同。
---@param replacement? string 每个合并命中区间写入的替换文本；缺省为星号，允许空串，最多 256 bytes。
---@return string? 成功时返回新字符串；原文不变。
---@return flywow_word_filter_error? 原文、替换文本或命中容量不合法时返回稳定错误码。
function Filter:replace(text, replacement)
    if replacement == nil then
        replacement = "*"
    end
    if type(replacement) ~= "string" or #replacement > MAX_REPLACEMENT_BYTES
        or not utf8.len(replacement) then
        return nil, "invalid_replacement"
    end

    -- 替换文本已校验；再取得完整命中，查询失败时不生成部分过滤结果。
    local matches, error_code = self:find(text)
    if not matches then
        return nil, error_code
    end

    -- find 已按起点排序。首次遇到一个区间就写出前面的原文和替换文本，之后只扩展覆盖终点。
    local parts = {}            -- 按原文顺序积累保留片段和替换文本，最后一次拼接。
    local covered_end_byte = 0  -- 已处理命中覆盖的最远原文 byte，0 表示尚无命中。
    for _, match in ipairs(matches) do
        local match_start_byte = match.offset -- find 返回的 1-based 原文起点。
        local match_end_byte = match_start_byte + match.length - 1 -- length 是原文跨度，换算成闭区间终点。
        if match_start_byte > covered_end_byte then
            parts[#parts + 1] = text:sub(covered_end_byte + 1, match_start_byte - 1)
            parts[#parts + 1] = replacement
        end
        covered_end_byte = math.max(covered_end_byte, match_end_byte)
    end

    -- 最后一个命中之后的原文仍需输出；无命中时从第 1 byte 保留整个原文。
    parts[#parts + 1] = text:sub(covered_end_byte + 1)
    return table.concat(parts)
end

return M
