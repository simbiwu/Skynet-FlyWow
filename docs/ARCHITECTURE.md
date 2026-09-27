# 工程架构

## 1. 目标形态

Skynet-FlyWow 提供可独立选择的 Server 基础模块。宿主游戏工程拥有业务 composition root，负责创建模块、注入配置和 Service handle，并连接业务 Adapter。

```text
Commercial Game Application
  -> application composition root
      -> selected Skynet-FlyWow modules
          -> small stable contracts
              -> pinned Skynet / Lua / native runtime
```

依赖只能向下。框架不知道宿主项目的战斗、角色、联盟、地图策划表或协议 DTO；宿主通过显式 Adapter 把自己的概念映射到模块合同。

## 2. 边界分类

- Contract：跨模块或面向宿主的稳定值类型、错误和版本合同。
- Module：解决一个基础设施问题，拥有自己的状态与生命周期。
- Adapter：连接外部协议、存储、引擎或宿主业务；不得让外部类型泄漏到核心合同。
- Composition Root：唯一允许知道具体实现组合的位置，由宿主工程拥有。
- Tooling：离线构建、验证、诊断和迁移，不伪装成运行时 Service。

这些是边界分类，不要求现在创建对应空目录。真实模块进入仓库时再建立最小目录。

## 3. 公共层纪律

公共层只接受已经被两个真实模块共同使用、语义稳定且不携带业务含义的合同。便利函数、业务 DTO 和“以后可能会用”的抽象保留在其 owner 内部。

公共合同变更必须说明兼容范围。破坏性变更需要新主版本、迁移步骤和回滚办法，不能依赖所有商业项目同时改完。

## 4. 生命周期与所有权

每个模块明确：

```text
谁创建、启动、停止和销毁
状态属于哪个 Service / Lua State / native object
调用是否 yield、执行 I/O、分配或加锁
buffer/fd/queue/timer/cache 的 owner 与上限
关闭、超时、过载和部分失败时如何收敛
```

模块不能通过全局名字掩盖依赖。需要跨 Service 调用时，由 composition root 或明确的父 Service 传入 handle。

## 5. 扩展策略

第一种实现先把问题解决正确，并把业务依赖挡在 Adapter 外。第二种真实实现出现后，从两者共同、已经被测试证明的行为中提取扩展点。

扩展优先采用数据合同、小函数接口和显式 factory。只有确实需要独立消息队列、Lua State、故障隔离或并行所有权时才增加 Service。

## 6. 热更边界

热更是未来独立模块，但从第一天保留正确前提：模块状态与代码分离，长期状态有 schema/version，入口可停止接收新工作，迁移失败能回滚。

热更模块不直接理解 Battle 等业务状态。业务模块提供自己的兼容检查与迁移回调，框架负责顺序、超时、隔离、审计和回滚编排。

## 7. 交付与兼容

商业项目默认通过 Git submodule 固定 FlyWow 提交；sibling 工作区只作为开发覆盖。无论发布载体如何扩展，模块都必须可固定版本、可离线构建、可重复测试，并且不依赖开发机绝对路径。
