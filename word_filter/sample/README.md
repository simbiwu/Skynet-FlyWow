# WordFilter 运行示例

示例在真实 Skynet Lua State 中通过公开 API 从内存关键词创建过滤器，执行未命中查询、命中定位和文本替换，并检查实际返回值。

从 FlyWow 根目录执行：bash word_filter/sample/run_word_filter_sample.sh ../skynet

缺少 Native 模块时脚本调用现有构建入口；skynet_config.lua 提供 Skynet 搜索路径，word_filter_sample.lua 展示从创建到查询的完整主流程。
