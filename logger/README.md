# FlyWow Logger

C++17 Native Skynet Logger，统一接管 skynet.error 与原生 C 日志。Lua 只解析等级、过滤和转发。通过 logger 指定目录、flywow_logger_level 指定等级、flywow_logger_console 控制终端镜像（默认 true）。每天一个日期文件，同日追加；同一格式化日志默认也写 stdout 并逐条刷新，不自动清理，不创建写盘线程。显式设置 flywow_logger_console = false 可只写文件。

完整接入、合同、故障、关闭及验证见 [Logger 指南](../docs/logger/README.md)，可复制配置见 [配置示例](../docs/logger/flywow_logger_config.example.lua)。Native 发送 SDK 位于 logger/native/flywow_logger.h。
