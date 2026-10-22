-- HotUpgrade Lua 模块共同遵循的稳定协议和运行配置。
local M =
{
    ROOT_PATH_ENV      = "flywow_hotupgrade_root_path", -- Controller 发布的进程内宿主根路径；所有目标 State 共用。
    PROTOCOL_ID        = 20,                            -- 所有 HotUpgrade Lua State 注册的 Skynet 协议 ID。
    MAX_STATE_DEPTH    = 128,                           -- Service 状态快照和部分更新递归的共同嵌套上限。
}

return M
