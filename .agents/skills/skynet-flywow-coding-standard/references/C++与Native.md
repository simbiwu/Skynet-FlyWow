# C++ 与 Native 专项补充规范

本文件补充现有 Coding Standard 中的 C/C++、Lua Binding、Lua C API 和 Native 规则。

## Ownership 与生命周期

- 从类型、成员关系或必要注释中明确资源 owner。
- 只为真实存在的资源管理生命周期；不为多余的中间对象增加独立管理层。
- C ABI / Lua C API 边界不得让 C++ exception 穿出。
- userdata、GC、longjmp、栈平衡、luaL_ref/luaL_unref、closure/upvalue、metatable、placement-new 和 `__gc` 按主 Skill 说明真实资源责任。

## 并发与同步

- 多个 Service 可能在不同 OS Thread 调用 Native 模块时，mutable process-global 状态必须有明确同步或禁止共享。
- 确定为单 owner 的状态不为了形式上的线程安全额外加锁。
- 锁、原子变量和跨线程队列必须对应真实并发访问路径。

## Binding

- 保留稳定 Lua API 名称和返回合同。
- Binding 负责真实语言边界转换，不把同一数据在多个内部层重复包装。
- 关键栈操作说明操作前后栈形态、索引、压入/消耗/保留的值及错误路径。

## 可读性

避免为每个 Native 操作增加 Manager/Context/Adapter。只有确实承担资源所有权、边界适配或独立生命周期时才引入对应结构。
