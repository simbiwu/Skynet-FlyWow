# Navigation 运行示例

示例在真实 Skynet Lua State 中使用公开 API 加载 BMAP 与 Unit Profile，创建 Battle Context，登记单位，查询起点到目标的路径，沿路径推进单位并释放单位和 Context。关键结果从 Native API 返回值断言。

从 FlyWow 根目录执行：bash navigation/sample/run_navigation_sample.sh ../skynet

脚本在 build/navigation-sample/ 将 Unity Editor 的 BMAP golden fixture 转成隔离资产；缺少 Navigation Native 库时调用现有构建脚本。skynet_config.lua 与 navigation_sample.lua 分别提供真实 Skynet 搜索路径和主流程。
