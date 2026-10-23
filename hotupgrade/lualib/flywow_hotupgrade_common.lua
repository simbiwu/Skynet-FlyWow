-- HotUpgrade Lua 模块共用的协议、配置和 Lua 文件头处理。
local M =
{
    ROOT_PATH_ENV      = "flywow_hotupgrade_root_path", -- Controller 发布的进程内宿主根路径；所有目标 State 共用。
    PROTOCOL_ID        = 20,                            -- 所有 HotUpgrade Lua State 注册的 Skynet 协议 ID。
    MAX_STATE_DEPTH    = 128,                           -- 默认状态恢复快照的嵌套深度上限。
    MAX_STATE_FIELDS   = 10000,                         -- 默认状态恢复快照的字段数上限。
}

--- 将 Lua 文件头转换为字符串 load 可接受的源码；只影响编译输入，部署仍使用原始字节。
--- 与 Lua loadfile 一致：跳过开头的 UTF-8 BOM，再跳过首行 # 注释；保留换行以维持报错行号。
---@param source string 已读取的文本源码
---@return string source 可直接交给 load 的源码
function M.normalize_source(source)
    if source:sub(1, 3) == "\239\187\191" then
        source = source:sub(4)
    end
    if source:sub(1, 1) == "#" then
        local newline = source:find("\n", 1, true)
        source = newline and source:sub(newline) or "\n"
    end
    return source
end

return M
