-- HotUpgrade Lua 模块共用的协议、配置、文件头处理和候选代码异常转换。
local flywow_result = require "flywow_result" -- 构造包含阶段错误码和实际根因的失败结果。
local M =
{
    ROOT_PATH_ENV      = "flywow_hotupgrade_root_path", -- Controller 发布的进程内宿主根路径；所有目标 State 共用。
    PROTOCOL_ID        = 20,                            -- 所有 HotUpgrade Lua State 注册的 Skynet 协议 ID。
    MAX_STATE_DEPTH    = 128,                           -- 默认状态恢复快照的嵌套深度上限。
    MAX_STATE_FIELDS   = 10000,                         -- 默认状态恢复快照的字段数上限。
}

--- 移除 Lua 文件开头的 UTF-8 BOM 和首行 shebang，返回可交给 load 编译的文本。
--- 保留首行换行位置，确保编译错误行号仍对应原文件。
---@param source string 从正式文件或发布包读取的 Lua 源码文本；本函数只清理交给 load 的编译文本，不改磁盘文件。
---@return string source 可直接交给 load 的源码
function M.normalize_source(source)
    if source:sub(1, 3) == "\239\187\191" then
        source = source:sub(4)
    end

    -- BOM 清理后再移除首行 shebang，同时保留原源码行号。
    if source:sub(1, 1) == "#" then
        -- 首行内容可能是 shebang；保留它原来的换行符，让 load 报告的行号与磁盘文件一致。
        local newline = source:find("\n", 1, true)
        source = newline and source:sub(newline) or "\n"
    end
    return source
end

--- Service Patch、候选模块或受控 require 执行抛错后，保留调用阶段和本次异常携带的 HotUpgrade 根因。
---@param stage_code string 捕获异常的调用方所属阶段的错误码，作为返回结果的 code。
---@param thrown any pcall 返回的异常值；从其文本识别实际传播的 HU_ 错误码。
---@return FlyWowResult<nil> 阶段失败结果；识别到 HU_ 根因时附带 details.cause_code。
function M.failure_from_lua_error(stage_code, thrown)
    -- 异常转成文本后，分离内部错误码和消息；普通 Lua 错误保留完整文本。
    local failure_text = tostring(thrown)
    local cause_code, cause_message = failure_text:match("(HU_[A-Z0-9_]+):%s*(.*)$")
    return flywow_result.failure(stage_code, cause_message or failure_text,
        cause_code and {cause_code = cause_code} or nil)
end

return M
