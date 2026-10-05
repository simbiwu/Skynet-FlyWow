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

FlyWow 的默认语言是中文。新增或修改的注释、提交日志、工程文档、示例和文档文件名优先使用中文；专用术语、稳定 API 名称、协议字段、命令、路径、工具名称和常用缩写保留英文。历史文件名不因语言规则自动批量改名；涉及文件时优先采用中文文件名，并同步更新全部引用。

缺少文件头职责说明、函数合同、参数/返回/失败/ownership 注释或关键 WHY 注释，视为 P0 未完成。FlyWow 全仓库花括号代码统一采用 Allman 风格；具名 record 字段及成组赋值按语言语法对齐名称、分隔符和取值，包含 Native C++。格式不符也视为 P0 未完成。代码行为、单位、数据布局或生命周期变化时，同步修改注释、文档、示例和测试。

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

## 功能模块目录合同

FlyWow 根目录按功能模块组织。每个可独立接入的模块使用自己的一级目录，例如：

```text
gateway/
navigation/
```

模块内部拥有自己的实现边界：

```text
<module>/lualib/
<module>/native/
<module>/service/
<module>/unity/
<module>/clients/
<module>/tools/
<module>/scripts/
<module>/tests/
```

FlyWow 根目录不直接放模块运行时的 `lualib/`、`native/`、`service/`、`unity/`、`clients/`、`tools/` 或模块测试目录。根目录只保留仓库级元数据、公共文档、CI 入口和仓库级脚本；仓库级 `scripts/ci/` 不属于任何运行时模块。

模块可以只创建实际需要的子目录，不为未来能力预建空目录。跨模块的组装工具必须明确标注为仓库级工具，不能偷偷归入某个功能模块。

## Lua 与 Native 模块命名

- Lua 模块入口使用 `flywow_<module>.lua`，例如 `flywow_navigation.lua`。
- 业务侧通过 `require "flywow_<module>"` 加载 Lua 外部入口。
- Native Lua 模块使用 `flywow_<module>_native.so`，并提供 `luaopen_flywow_<module>_native` 入口。
- Lua Wrapper 与 Native 使用不同模块名，避免 `package.path` 优先命中 Wrapper 后递归加载自身。
- FlyWow 所有最终 Lua Native `.so` 统一输出到 `build/native/`，CMake 中间文件统一位于 `build/cmake/<module>/`。
- 模块内部 C/C++ 类型、命名空间和测试标识使用 `flywow_` 前缀。

## Gateway 协议生成边界

- `.proto` 是宿主项目维护的唯一协议源；`tools/generate_gateway_registry.py` 是 FlyWow 框架实现，业务仓库不得复制。
- `*_registry.lua` 是构建生成物，运行时只加载生成结果，不在 Service 启动时解析 `.proto`。
- 宿主从固定 FlyWow submodule 调用框架工具；运行时路径直接写在 Skynet process config 中，禁止为路径增加环境变量、路径生成器或生成配置文件。宿主 run_server.sh build 负责调用统一构建入口。
- `config/gateway.lua` 是宿主默认配置；Gateway Service 只要求显式注入业务 handler handle，特殊部署才覆盖 transport、协议 bundle 或资源上限。

## 配置示例规则

- FlyWow 的任何可配置功能都必须提供可复制的配置 example；Gateway 使用 `docs/gateway/flywow_gateway_config.example.lua` 作为格式和完整度基线。
- example 必须逐项说明字段用途、类型、默认值、合法范围、单位、路径基准、配置 owner、生命周期、覆盖方式和失败行为。
- 配置依赖 `.proto`、descriptor、registry、代码生成器或构建脚本时，example 必须同时给出输入文件、固定工具/版本、可复制命令、输出位置、运行时读取者、读取时机和生成物兼容关系。
- example 必须说明实际调用入口和调用顺序，包含谁创建 Service、谁传入运行时 handle，以及配置修改后如何让新配置生效。
- example 是文档和接入产物，不得被 Runtime 自动加载；宿主复制后才使用。模块 README 必须链接 example，源码文件头只保留配置入口和边界说明。

## 不提前造框架

模块只有在出现真实调用者、实现已运行、成功与失败路径都有测试后，才从学习项目整理进入本仓库。不得提前创建空 Service、占位 interface、未来 DTO 或最终目录树。

出现第二个真实消费者或第二种真实实现后，再决定是否提取公共接口、独立包或插件点。先保持正确依赖方向，避免未来通过重写消除业务耦合。

## 模块交付门槛

每个已交付模块必须有完整详细的文档与接入流程，文档入口为 `docs/<module>/README.md`，执行 `docs/模块标准.md` 第7节门槛。跨端模块必须覆盖两端握手、配置、收发、失败与关闭；源码或合同变化时同步更新。

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

- `<module>/service/` 只放由 `newservice/uniqueservice` 启动的入口；普通模块放对应的 `<module>/lualib/`。
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

## Logger 接入边界

统一使用 skynet.error，只配置 log_path 与 level；每日追加，不清理旧日志，不添加 instance。Native Service 通过 cpath 加载，最终 .so 统一归 build/native/；与 Lua Binding 的 package.cpath 不同。Lua preload、SDK 与 Native 按固定提交发布，未配置时 SDK 回退官方 Logger。详情见框架 docs/logger/README.md。
