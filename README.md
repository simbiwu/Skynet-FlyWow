# skynet-flywow

`skynet-flywow` 是面向商业游戏项目的模块化 Skynet Server 基础框架。它沉淀多个项目都能复用的基础能力，不承载某个游戏的 Battle、SLG 规则或业务数据。

Gateway 模块已从学习项目形成真实调用者和可运行实现，当前提供 TCP 与 Skynet 内置 WebSocket transport、构建期协议 registry、统一错误/告警和资源上限。协议 registry 生成器归框架所有，业务仓库只维护 `.proto` 并在构建时调用 FlyWow 工具。其它模块仍按真实调用者和独立测试逐步进入；不会用空目录和占位接口伪装框架完整度。商业项目建议通过 Git submodule 固定 FlyWow 提交；本项目统一在主仓库内的 `server/third_party/skynet-flywow` 子模块开发和验证。

## 目标

- 易用：接入步骤短，默认值安全，错误可定位，示例可运行。
- 易接入：显式配置和依赖注入，不要求业务工程采用隐藏的全局名字或固定机器路径。
- 易扩展：稳定公共合同与内部实现分离，扩展点来自真实的第二种实现或消费者。
- 易升级：公开 API、资产和配置有版本，兼容、迁移与回滚规则明确。
- 易运维：启动、停止、限流、日志、指标、诊断和故障路径可观察。
- 可验证：模块可单独 build、test、benchmark；性能结论带版本和测试条件。
- 可裁剪：商业项目只组合需要的模块，不为未使用能力承担运行时依赖。

## 非目标

- 不复制某个课程或商业项目的业务代码。
- 不一次实现“完整 MMO 框架”。
- 不用大量抽象层、空 Service 和目录数量证明商业级。
- 不隐藏 Skynet 的 Service、Lua State、消息、yield 和 ownership 合同。

## 目录结构

FlyWow 根目录按功能模块组织，当前模块与模块内部边界为：

```text
gateway/
├── clients/   # H5、Unity 等 Gateway 客户端握手 SDK
├── lualib/    # Gateway 普通 Lua 模块
├── luaclib/   # Gateway Native Lua 动态库产物
├── native/    # Gateway Native 实现
├── scripts/   # Gateway 构建脚本
├── service/   # Gateway Service 入口
├── tests/     # Gateway 独立测试
└── tools/     # Gateway 协议生成工具

navigation/
├── lualib/
├── native/
├── scripts/
├── tests/
├── tools/
└── unity/
```

根目录的 `scripts/ci/` 是仓库级质量门禁；它不承载 Gateway 或 Navigation 运行时代码。根目录不再直接放 `lualib/`、`native/`、`service/`、`unity/`、`clients/`、`tools/` 或模块测试目录。

## 预期模块方向

以下是候选方向，不代表已经提供或已经稳定：

```text
网络接入与连接生命周期
协议 framing / codec / dispatch
配置、日志、指标与错误合同
Service 启停、依赖注入和健康检查
代码/配置热更、状态迁移与回滚
静态地图资产加载与查询
导航查询运行时
测试、诊断、构建和部署工具
```

模块之间保持单向依赖。网络模块不依赖地图，地图模块不依赖网络；业务工程通过 composition root 选择并连接模块。

地图、寻路和战斗能力也遵守这个边界。FlyWow 可以逐步接入静态地图加载、导航查询和确定性战斗，但这些模块不读取客户端工程目录，不依赖 Gateway，也不携带 Battle/SLG 业务对象。

框架从现在起保留两类真实地图空间：

```text
2.5D ground：X/Z Grid 与地表高度
top-down 2D：二维逻辑平面，可固定高度或不带高度
side-view 2D：重力、跳跃和平台层，属于不同运动模型
```

宿主通过地图资产 manifest、寻路 profile 和客户端 Adapter 选择实际空间。Unity BMAP、H5/Tiled/JSON 等来源由离线工具转换，运行时只消费固定版本和内容 hash。

## 当前文档

- [全部文档与模块索引](docs/README.md)
- [Gateway 完整前后端接入流程](docs/gateway/接入指南.md)
- [Gateway 握手字节与SDK合同](docs/gateway/握手合同.md)

- [工程架构](docs/架构说明.md)
- [模块准入与完成标准](docs/模块标准.md)
- [商业项目接入原则](docs/采用指南.md)
- [质量门禁](docs/质量门禁.md)
- [版本与兼容策略](docs/版本管理.md)
- [演进路线](docs/路线图.md)
- [工程决策](docs/工程决策.md)
- [P0 编码规范 Skill](.agents/skills/skynet-flywow-coding-standard/SKILL.md)
- [Gateway 模块接入与合同](docs/gateway/README.md)

## 开发规则

所有实现和评审必须先遵守根目录 `AGENTS.md`，并加载 `skynet-flywow-coding-standard` Skill。远端固定为 `https://github.com/simbiwu/Skynet-FlyWow.git`；许可证和首个可发布版本在后续明确，不因仓库公开而自动假设开源许可证。

当前仓库基线验证：

```bash
python3 -m unittest discover -s gateway/tests -p 'test_*.py'
python3 -m unittest discover -s navigation/tests -p 'test_*.py'
python3 -m unittest discover -s scripts/ci -p 'test_*.py'
python3 scripts/ci/check_repository.py
```

## Lua Binding

Lua Binding 将 Native 的 Lua 操作集中到 C++ 对象，导航已接入。源码位于 lua-binding/，提供静态 target，使用见 [Lua Binding 指南](docs/lua-binding/README.md)。

## WordFilter

WordFilter 提供 UTF-8 词库匹配与替换，核心从 FCLib FCKeywordFilter 移植。
入口 require "flywow_word_filter"，接入见 [WordFilter 指南](docs/word_filter/README.md)。

## Logger

Logger 模块提供 C++ Native 分级日志和每日文件，接入见 [Logger 指南](docs/logger/README.md)。源码归 logger/，最终 Native .so 归 build/native/，中间文件归 build/cmake/logger/。只配置 log_path 与 level。
