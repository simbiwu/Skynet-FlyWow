# FlyWow 文档入口

## 已交付模块

| 模块 | 概览与公开合同 | 完整接入步骤 | 可运行 Sample |
| --- | --- | --- | --- |
| Gateway | [模块说明](gateway/README.md) | [Server、Unity与H5接入](gateway/接入指南.md) | [握手与请求往返](../gateway/sample/README.md) |
| Logger | [接入与运维](logger/README.md) | [首次接入与验证](logger/README.md#源码构建与首次接入) | [日志与刷新](../logger/sample/README.md) |
| Navigation | [模块说明](../navigation/README.md) | [地图及 Server 接入](../navigation/导航接入指南.md) | [地图查询主流程](../navigation/sample/README.md) |
| WordFilter | [接口与接入](word_filter/README.md) | [构建和最小调用](word_filter/README.md#构建与加载) | [匹配与替换](../word_filter/sample/README.md) |
| Lua Binding | [模块入口](lua-binding/README.md) | [C++ Native 接入](../lua-binding/使用说明.md) | [读写 Lua Table](../lua-binding/sample/README.md) |
| HotUpgrade | [热更接入](hotupgrade/README.md) | [本地控制消息与 Patch 目录](hotupgrade/README.md#管理命令) | [PlayerService V1 到 V2](../hotupgrade/sample/README.md) |

其他模块按真实实现、调用者和验证进入框架；候选方向见[路线](路线图.md)，不把规划当作已交付模块。每个已交付模块必须满足[详细文档门槛](模块标准.md#7-每个已交付模块的详细文档门槛)。

## 工程规则

- [模块准入与完成标准](模块标准.md)
- [商业项目接入原则](采用指南.md)
- [架构](架构说明.md)
- [质量门禁](质量门禁.md)
- [版本与兼容](版本管理.md)
- [工程决策](工程决策.md)

首次接入直接阅读对应模块的接入指南；专项合同用于查阅精确协议与接口。
