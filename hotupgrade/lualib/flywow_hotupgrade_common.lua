-- HotUpgrade Lua 模块共同遵循的稳定协议与容量定义。
local M =
{
    ROOT_PATH_ENV      = "flywow_hotupgrade_root_path", -- Controller 发布的进程内宿主根路径；所有目标 State 共用。
    PROTOCOL_ID        = 20,                            -- 所有 HotUpgrade Lua State 注册的 Skynet 协议 ID。
    DEFAULT_TIMEOUT_MS = 10000,                         -- Guard 等待业务排空的默认毫秒数。
    MAX_TARGETS        = 1024,                          -- 一个 Controller 生命周期内可登记的最大现存目标数。
    MAX_MODULES        = 1024,                          -- 单个目标及一次完整模块 Patch 可包含的最大模块数。
}

return M
