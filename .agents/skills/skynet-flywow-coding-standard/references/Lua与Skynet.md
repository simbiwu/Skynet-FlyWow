# Lua 与 Skynet 专项补充规范

本文件补充现有 Coding Standard 中的 Lua、Skynet 和 LuaDoc 规则。涉及具体运行语义时，以项目实际使用的 Skynet 分支、Lua 版本及本地改造为准。

## 调用与协程

- 明确哪些 API 可能 yield；调用方必须能从合同判断。
- `skynet.call`、`skynet.send`、协程等待和消息投递按实际语义使用，不为了统一形式互换。
- 不把每次 Service 调用都视为新的不可信边界。
- 跨 yield 保存的连接身份、fd、borrowed buffer 或临时状态，只有在等待期间其有效性可能变化时才重新验证；先确认 owner 和生命周期，不机械重复检查。
- 不跨 Service 隐式共享可变 Lua/native 状态。
- Service handle 优先显式传递，不因为“方便”增加全局 Service 名称。

## Service、协程与线程

必须区分 Service、Lua coroutine 和 Skynet worker OS Thread：

- 同一 Service 的 Lua 消息处理由该 Service 的调度上下文串行推进；协程可以在 yield 处交错执行，但不因此并行执行 Lua 指令。
- 多个 worker thread 可以并行处理不同 Service；不能据此推断单个 Service 内的 Lua 业务代码能利用多个核并行运行。
- 一个连接对应一个协程，不代表一个连接对应一个线程。
- 异步 Socket I/O 主要避免线程阻塞等待 I/O，不会自动并行执行同一 Service 中的编解码、业务回调或 CPU 计算。
- 任何关于具体调度、线程归属或消息顺序的结论，都必须核对项目实际 Skynet 版本的源码，不要只凭通用印象判断。

对性能问题，先标明代码在哪个 Service/协程执行、是否 yield、是否阻塞后续消息、工作量如何随连接数或任务数增长。结构性阻塞可以由调用路径和算法推导；吞吐、p99、CPU 占用等数值必须通过实际测量确认。

## 时钟与定时器

当前项目基线为 Skynet v1.8.0、Lua 5.4.7 改造版。按该基线：

- `skynet.now()` 是 Skynet 单调时钟的 Tick 计数，C 层使用 `uint64_t`，通过 `lua_pushinteger` 进入 Lua 侧的 `lua_Integer`；每 Tick 为 10ms。
- `skynet.now()` 不是 Unix 时间戳。计算运行时经过时间，直接对同一单调时钟的两个读数做差。
- `skynet.time()` 提供 Unix 时间秒数，适合需要与现实时间或进程重启衔接的绝对时间。
- Skynet C 时间轮内部的 32 位游标，不等于公开 `skynet.now()` 的 64 位计数。不得从内部时间轮字段推断公开 API 的整数宽度或回绕合同。
- `skynet.timeout()` 的单位是 Tick。使用前核实注册、取消、重置和回调执行语义；重复注册不会自动意味着旧定时器被替换。频繁更新/取消的业务任务，应根据真实操作频率和取消能力选择调度结构，不预设每个对象一个 timeout，也不预设必须自建时间轮或堆。

如果项目实际 fork 修改了上述实现，必须以当前 fork 的源码和 Binding 重新核实，不得把此处基线描述当作无需验证的永恒事实。

## 参数和状态

- 在真实输入边界验证参数。
- 内部函数沿用已建立的前置条件，不重复执行相同校验。
- 状态尽量由唯一 owner 管理；没有独立生命周期的临时值保持局部。
- 不为简单流程增加 Controller、Context 或状态机。

## 错误处理

遵循现有 FlyWowResult、原生 API 适配和 pcall/xpcall 规则。异常捕获放在真正可能抛错且需要转换合同的边界，不把每个内部调用都包进 pcall。

## 命名与注释

沿调用链保持同一 record 的领域名称。LuaDoc 说明实际参数、返回和 yield 行为。业务 record 字段和关键状态按主 Skill 的注释交付门禁逐项说明。
