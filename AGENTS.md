# AGENTS.md - Skynet-FlyWow

## 项目定位

`skynet-flywow` 是供多个商业游戏项目复用的模块化 Skynet Server 基础框架，不是个人 Demo，也不是课程代码镜像。

商业级只要求当前已承诺能力做到正确、可接入、可验证、可维护。不要用更多模块、更多抽象、更多策略或更多文档证明“商业级”。

## 执行前必须读取

新增、修改或评审代码前，必须先读取：

```text
AGENTS.md
.agents/skills/skynet-flywow-coding-standard/SKILL.md
```

再读取本次修改直接涉及的模块 README、Contract 或工程决策。只读与当前任务有关的规则，不因为“可能有帮助”扩大修改范围。

## 最高优先级规则

### 1. 严格控制需求边界

实现用户明确要求的功能，以及该功能正常工作所必需的工程处理。

可以主动补齐：

- 明显的参数和边界检查；
- 必要的错误处理；
- 资源释放和生命周期处理；
- 当前并发模型下必需的线程安全；
- 不处理就会造成崩溃、泄漏、数据错误或明确错误行为的问题。

不得未经确认主动增加：

- 新功能或子功能；
- 新的业务行为或系统策略；
- 限流、重试、缓存、采样、熔断、降级；
- metrics、监控、后台任务、队列；
- 插件点、Factory、Manager、Provider、Adapter 等仅为未来扩展存在的抽象；
- 当前需求没有使用者的配置项、状态、接口或目录。

额外能力可能有价值时，只在最终说明中提出建议，不直接实现。

如果无法判断一项修改属于“必要工程处理”还是“额外能力”，默认不实现。

### 2. 不用规则反向制造功能

只有当前功能实际创建、持有或积累的资源与状态，才要求定义对应的上限、失败和清理行为。

不得为了满足“商业级”“健壮性”“资源有界”“可扩展”等规则，主动引入新的限流、重试、缓存、队列、监控或其它运行策略。

### 3. FlyWow 默认使用中文

新增或修改的：

- 源码注释；
- 工程文档；
- README；
- 示例说明；
- 提交说明；
- 文档文件名；

必须使用中文。

专用术语、稳定 API 名称、协议字段、命令、路径、工具名称和常用缩写保留英文，例如 `FlyWow`、`Navigation`、`Battle`、`Gateway`、`Skynet`。

Git 提交说明的标题和正文必须使用中文；稳定技术术语、API 名称、命令和路径可保留英文。涉及多项内容时，必须在正文中逐项列出具体改动，不得只用笼统标题概括。

新增文档文件名不得默认使用全英文。历史文件名不因本规则自动批量改名。

### 4. 不擅自修改

没有用户明确的“开始、修改、执行、更新、同步”等指令时，只讨论，不修改文件。

不要顺手重构无关代码，不顺手改名，不顺手清理旧代码，不顺手补功能。

`origin` 固定为：

```text
https://github.com/simbiwu/Skynet-FlyWow.git
```

只有用户明确要求提交或同步时才 Push。不要自行创建 Release、选择许可证或建立新的兼容承诺。

### 5. 默认开发流程

新增模块或较大功能时，默认先提交**简短的最小设计方案**，说明拟修改的文件、公开 API、核心流程及新增抽象的必要性。未经用户确认，不开始编码；用户明确要求按已确认方案直接实现时除外。

设计和实现均遵守编码 Skill 的最小实现原则。不得自行增加方案之外的功能、封装和扩展点。实现完成后，主动检查并移除无价值的 Helper、重复检查和间接层。

简单 Bug 修复及局部小改动不需要额外设计评审，按最小改动直接完成。

## 模块边界

- 一个模块解决一个清晰的基础设施问题。
- 框架模块不得依赖 Battle、SLG 或具体商业项目 DTO、配置表和业务 Service。
- Gateway、Navigation、Logger、HotUpgrade 等横向模块保持独立，由宿主 composition root 组装。
- 宿主依赖通过明确配置、Service handle 或 Adapter 注入，不猜测开发机路径和业务目录。
- `common` 只放已经被多个真实模块共同使用、语义稳定的最小合同。
- 第二个真实消费者或第二种真实实现出现前，不提取通用插件点和公共抽象。

## 目录规则

FlyWow 根目录按功能模块组织：

```text
gateway/
logger/
navigation/
...
```

模块只创建实际需要的子目录：

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

不要预建空目录。

根目录只放仓库级元数据、公共文档、CI 和仓库级脚本。模块运行时代码不得为了“统一”重新塞进额外的 `src/`、`core/`、`packages/` 或类似总层级。

## Lua 与 Native 命名

- Lua 对外入口：`flywow_<module>.lua`
- Native Lua 模块：`flywow_<module>_native.so`
- Native Lua 入口：`luaopen_flywow_<module>_native`
- Lua Wrapper 与 Native 使用不同模块名，避免递归加载。
- 最终 Native `.so` 输出到 `build/native/`。
- CMake 中间目录使用 `build/cmake/<module>/`。
- 模块内部 C/C++ 类型、命名空间和测试标识使用 `flywow_` 前缀。

## Skynet 基本规则

- `<module>/service/` 只放由 `newservice/uniqueservice` 启动的 Service 入口。
- 普通 Lua 模块放 `<module>/lualib/`。
- 启动者保存并显式传递 Service handle；只有真实发现需求才注册全局名字。
- 跨 yield 保存的身份、fd、buffer 或状态必须在恢复后重新验证有效性。
- 多个 Service 可能运行在不同 OS Thread 时，不允许无保护共享 mutable native 状态。
- 热更必须有明确兼容、迁移和失败回滚边界，不能把清空 `package.loaded` 当成通用热更方案。

## 编码规范

排版、注释、API、Lua/C/C++、Shell、测试和示例的具体要求统一由：

```text
.agents/skills/skynet-flywow-coding-standard/SKILL.md
```

定义。

`AGENTS.md` 不重复维护同一套编码细节。

## 模块准入与交付

模块准入、最小交付内容和文档要求统一以：

```text
docs/模块标准.md
```

为准。

架构依赖、生命周期和扩展原则统一以：

```text
docs/架构说明.md
```

为准。

已经记录的稳定工程选择以：

```text
docs/工程决策.md
```

为准。不要在实现任务中自行推翻已有工程决策。

## 验证原则

修改后只运行与本次变更和受影响模块匹配的 build/test。

必须区分：

```text
build：实际构建了什么
run：实际运行了什么
test：实际执行了什么测试
not verified：哪些边界没有验证
```

没有执行的验证不得写成“已通过”。

测试被 skip 不等于对应能力已验证。

不要通过关闭检查、删除断言、吞掉错误或降低测试要求让结果变绿。
