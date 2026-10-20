# Logger 运行示例

示例启动真实 Skynet Logger，通过业务 Service 的 skynet.error 写入日志，再调用 flywow_logger.flush() 等待刷新。Runner 检查进程完成标记和落盘内容。

从 FlyWow 根目录运行：bash logger/sample/run_logger_sample.sh ../skynet

脚本在缺少 Native 模块时调用现有构建入口，并在 build/logger-sample/ 使用隔离日志目录。flywow_logger_sample.lua 展示 preload 安装后的业务日志调用与刷新。
