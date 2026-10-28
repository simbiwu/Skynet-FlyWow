-- HotUpgrade Lua 模块共用的协议、配置和 Lua 文件头处理。
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

return M
