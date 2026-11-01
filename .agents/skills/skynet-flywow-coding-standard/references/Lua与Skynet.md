# Lua 与 Skynet 专项补充规范

本文件补充现有 Coding Standard 中的 Lua、Skynet 和 LuaDoc 规则。

## 调用与协程

- 明确哪些 API 可能 yield；调用方必须能从合同判断。
- `skynet.call`、`skynet.send`、协程等待和消息投递按实际语义使用，不为了统一形式互换。
- 不把每次 Service 调用都视为新的不可信边界。
- 跨 yield 保存的连接身份、fd、borrowed buffer 或临时状态，在恢复后按真实失效风险重新验证。
- 不跨 Service 隐式共享可变 Lua/native 状态。

## 参数和状态

- 在真实输入边界验证参数。
- 内部函数沿用已建立的前置条件，不重复执行相同校验。
- 状态尽量由唯一 owner 管理；没有独立生命周期的临时值保持局部。
- 不为简单流程增加 Controller、Context 或状态机。

## 错误处理

遵循现有 FlyWowResult、原生 API 适配和 pcall/xpcall 规则。异常捕获放在真正可能抛错且需要转换合同的边界，不把每个内部调用都包进 pcall。

## 命名与注释

沿调用链保持同一 record 的领域名称。LuaDoc 说明实际参数、返回和 yield 行为。业务 record 字段和关键状态按主 Skill 的注释交付门禁逐项说明。
