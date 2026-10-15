-- 职责：宿主 Skynet 进程配置中的 Logger 接入片段，合入现有配置后重启生效。
-- 相对路径以宿主 server/ 工作目录为基准；Gateway/Battle 使用不同日志目录。
-- lua_path/cpath 还需包含 FlyWow Logger 与 Skynet 的现有运行路径，见本目录 README。
logservice = "flywow_logger"
logger = "./logs/battle"
flywow_logger_level = "normal"
-- 缺省为 true：完整日志同时写文件和 stdout，stdout 逐条刷新。
-- 若只需要按天文件，显式改为 false；该开关不改变等级过滤和文件失败语义。
flywow_logger_console = true
preload = "./third_party/skynet-flywow/logger/lualib/flywow_logger_preload.lua"
