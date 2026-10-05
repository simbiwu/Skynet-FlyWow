--- 职责：在标准 loader 执行业务脚本前安装日志适配；每个 Lua State 独立执行一次。
--- 首次 require 的源是 logger/lualib/flywow_logger.lua，人工维护；不存在 Lua Binding .so。
--- Native Service 由 scripts/build_flywow.sh 生成 build/native/flywow_logger.so，Skynet cpath 加载。
--- 接入配置先设置模块路径与 preload，业务无需重复 require；不写盘、不启动第二个 Logger。
-- loader 在业务入口前执行安装；install() 保存原始 skynet.error 后再替换适配器。
-- 适配器最终仍调用原始入口，因此日志继续沿用 Skynet 的 logger Service 消息链路。
require("flywow_logger").install()
