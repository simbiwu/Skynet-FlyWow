-- HotUpgrade Lua 模块共同遵循的稳定协议和运行配置。
local M =
{
    ROOT_PATH_ENV      = "flywow_hotupgrade_root_path", -- Controller 发布的进程内宿主根路径；所有目标 State 共用。
    PROTOCOL_ID        = 20,                            -- 所有 HotUpgrade Lua State 注册的 Skynet 协议 ID。
    MAX_STATE_DEPTH    = 128,                           -- 默认状态恢复快照的嵌套深度上限。
    MAX_STATE_FIELDS   = 10000,                         -- 默认状态恢复快照的字段数上限。
}

return M
