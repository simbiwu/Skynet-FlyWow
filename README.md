# skynet-flywow

`skynet-flywow` 是面向商业游戏项目的模块化 Skynet Server 基础框架。它沉淀多个项目都能复用的基础能力，不承载某个游戏的 Battle、SLG 规则或业务数据。

Gateway 模块已从学习项目形成真实调用者和可运行实现，当前提供 TCP 与 Skynet 内置 WebSocket transport、构建期协议 registry、统一错误/告警和资源上限。协议 registry 生成器归框架所有，业务仓库只维护 `.proto` 并在构建时调用 FlyWow 工具。其它模块仍按真实调用者和独立测试逐步进入；不会用空目录和占位接口伪装框架完整度。

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

## 当前文档

- [工程架构](docs/ARCHITECTURE.md)
- [模块准入与完成标准](docs/MODULE_STANDARD.md)
- [商业项目接入原则](docs/ADOPTION.md)
- [质量门禁](docs/QUALITY_GATES.md)
- [版本与兼容策略](docs/VERSIONING.md)
- [演进路线](docs/ROADMAP.md)
- [工程决策](docs/ENGINEERING_DECISIONS.md)
- [P0 编码规范 Skill](.agents/skills/skynet-flywow-coding-standard/SKILL.md)
- [Gateway 模块接入与合同](docs/gateway/README.md)

## 开发规则

所有实现和评审必须先遵守根目录 `AGENTS.md`，并加载 `skynet-flywow-coding-standard` Skill。远端固定为 `https://github.com/simbiwu/Skynet-FlyWow.git`；许可证和首个可发布版本在后续明确，不因仓库公开而自动假设开源许可证。

当前仓库基线验证：

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/ci/check_repository.py
```
