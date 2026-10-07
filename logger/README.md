# FlyWow Logger

C++17 Native Skynet Logger，统一接管 skynet.error 与原生 C 日志。Lua 只解析等级、过滤和转发。配置仅有 log_path 与 level，每天一个日期文件，同日追加，不自动清理，不创建写盘线程。

完整接入、合同、故障、关闭及验证见 [Logger 指南](../docs/logger/README.md)，可复制配置见 [配置示例](../docs/logger/flywow_logger_config.example.lua)。Native 发送 SDK 位于 logger/native/include/flywow_logger.h。
