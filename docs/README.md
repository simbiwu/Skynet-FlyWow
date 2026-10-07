# FlyWow 文档入口

## 已交付模块

| 模块 | 概览与公开合同 | 完整接入步骤 | 专项合同 |
| --- | --- | --- | --- |
| Gateway | [模块说明](gateway/README.md) | [Server、Unity与H5接入](gateway/接入指南.md) | [四步握手与SDK](gateway/握手合同.md) |
| WordFilter | [接口与接入](word_filter/README.md) | [构建和最小调用](word_filter/README.md#构建与加载) | UTF-8 关键词匹配与替换 |
| Lua Binding | [模块入口](lua-binding/README.md) | [C++ Native 接入](../lua-binding/使用说明.md) | Table、闭包和 userdata 生命周期 |
| HotUpgrade | [热更接入](hotupgrade/README.md) | [本地控制消息与 Patch 目录](hotupgrade/README.md#管理命令) | Lua 模块、Service 替换和状态迁移 |

其他模块按真实实现、调用者和验证进入框架；候选方向见[路线](路线图.md)，不把规划当作已交付模块。每个已交付模块必须满足[详细文档门槛](模块标准.md#7-每个已交付模块的详细文档门槛)。

## 工程规则

- [模块准入与完成标准](模块标准.md)
- [商业项目接入原则](采用指南.md)
- [架构](架构说明.md)
- [质量门禁](质量门禁.md)
- [版本与兼容](版本管理.md)
- [工程决策](工程决策.md)

首次接入直接阅读对应模块的接入指南；专项合同用于查阅精确协议与接口。
