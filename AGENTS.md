# AGENTS.md - Skynet-FlyWow

## P0

`skynet-flywow` 是将应用到多个商业游戏项目的模块化 Skynet Server 基础框架，不是个人 Demo，也不是课程代码的镜像。

功能可以聚焦，已承诺的边界必须达到可接入、可验证、可运维和可升级的质量。商业级来自正确的 ownership、显式失败、资源有界、真实测试和兼容策略，不来自模块数量。

## P0 编码规范 Skill

新增、修改或评审 Lua、C、C++、Shell、Proto、CMake、配置、测试和示例前，必须完整读取并应用：

```text
.agents/skills/skynet-flywow-coding-standard/SKILL.md
```

源码注释、工程文档、模块 README、接入说明和示例说明统一使用中文。代码标识符、协议字段、命令和通用技术名词保留其稳定英文名称。

缺少文件头职责说明、函数合同、参数/返回/失败/ownership 注释或关键 WHY 注释，视为 P0 未完成。代码行为、单位、数据布局或生命周期变化时，同步修改注释、文档、示例和测试。

## 模块原则

- 模块解决一个清晰问题，公开 API 小而稳定，内部实现可替换。
- 框架模块不依赖 Battle、SLG 或任何具体商业项目业务。
- 网络、地图、导航、热更等横向模块不相互反向引用；由宿主 composition root 组装。
- `common` 只容纳稳定的最小合同，不容纳无归属工具、业务 DTO、全局状态或循环依赖。
- 配置、Service handle、时钟、随机源和外部适配器显式注入。
- 不用全局服务名、当前工作目录、开发机绝对路径或隐式单例作为必要合同。
- Skynet Service/Lua State、fd、buffer、native 对象、队列和状态的 owner 与释放路径必须明确。
- 所有资源增长有上限，过载、超时、重试和关闭行为显式。
- 公开协议、配置、资产和持久状态有版本以及兼容/迁移/回滚策略。

## Gateway 协议生成边界

- `.proto` 是宿主项目维护的唯一协议源；`tools/generate_gateway_registry.py` 是 FlyWow 框架实现，业务仓库不得复制。
- `*_registry.lua` 是构建生成物，运行时只加载生成结果，不在 Service 启动时解析 `.proto`。
- 宿主通过 `FLYWOW_ROOT` 或固定 vendored framework 调用生成器；宿主的 `run_server.sh` 只做 orchestration 和输出路径选择。
- `config/gateway.lua` 是宿主默认配置；Gateway Service 只要求显式注入业务 handler handle，特殊部署才覆盖 transport、协议 bundle 或资源上限。

## 不提前造框架

模块只有在出现真实调用者、实现已运行、成功与失败路径都有测试后，才从学习项目整理进入本仓库。不得提前创建空 Service、占位 interface、未来 DTO 或最终目录树。

出现第二个真实消费者或第二种真实实现后，再决定是否提取公共接口、独立包或插件点。先保持正确依赖方向，避免未来通过重写消除业务耦合。

## 模块交付门槛

每个模块至少提供：

```text
公开 API 与版本合同
依赖和禁止依赖
配置说明与安全默认值
生命周期、ownership、yield/I/O 边界
错误、资源上限和可观测性
最小可运行接入示例
单元、边界、失败路径和必要的集成测试
升级、兼容、迁移与回滚说明
独立 build/test/diagnose 入口
```

## Skynet 规则

- `service/` 只放由 `newservice/uniqueservice` 启动的入口；普通模块放 `lualib/`。
- 启动者保存并显式传递 Service handle；只有真实跨启动树发现需求才注册名字。
- 稳定 Lua 接口使用命名参数或 request/result record，不使用 `...`。
- 任何可能 yield 的入口必须声明，并在 yield 后重新验证可能失效的身份。
- 多个 Service 可在不同 OS Thread 调用 native module；mutable scratch 不得无保护地全局共享。
- 热更必须包含兼容检查、状态迁移、失败回滚和可观察结果，不以任意清空 `package.loaded` 代替。

## 工作方式

```text
真实问题
-> 最小稳定合同
-> 实现
-> build
-> run
-> debug
-> success/boundary/failure tests
-> 文档与接入示例
-> 版本与发布
```

## 当前质量门禁

任何提交前至少运行：

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
python3 scripts/ci/check_repository.py
```

具体模块进入仓库时，必须在同一次变更中增加自己的 build、运行、成功/边界/失败测试。通用仓库检查不能替代模块验证。

没有用户明确的“开始、修改、执行、更新、同步”等指令时，只讨论，不修改文件。`origin` 固定为 `https://github.com/simbiwu/Skynet-FlyWow.git`；只有用户明确要求提交或同步时才 Push。不要自行选择开源许可证。
