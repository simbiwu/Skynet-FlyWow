# FlyWow HotUpgrade 接入说明

HotUpgrade 是同一 Skynet 节点内的 Lua 热更协调模块。宿主在 composition root 中启动一个协调 Service，再由已有的可信管理入口通过本地 Service handle 发送控制消息。

模块不创建独立 OS 进程，不提供远程认证、文件上传、管理 UI 或 Cluster 广播；多节点发布由宿主部署层逐节点触发。

当前支持：

- Patch Root 下 Lua 模块扫描、路径校验、源码冻结和 SHA-256 身份；
- 模块原地 Stage/Commit/Abort；
- DRAIN 候选 Service 替换；
- MIGRATE 候选 Service 替换与版本化状态迁移；
- Guard 安全点、ServiceRef 代际和依赖检查；
- Dry Run、历史记录、状态查询和指标读取；
- 受限批次和失败后 PARTIAL/RECOVERY_REQUIRED 结果。

Native/C 模块、Skynet Core、正在运行的 coroutine 栈和未知 Runtime userdata 不自动替换。控制面重启后的未决事务目前 fail-closed，返回 HU_RECOVERY_REQUIRED；需要宿主按原事务人工协调，不能当作已完成自动接管恢复。

## 构建与验证

在 FlyWow 子模块根目录执行：

~~~bash
bash scripts/build_flywow.sh /path/to/skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh /path/to/skynet
~~~

测试覆盖基础模块、Patch 扫描、真实 Skynet 多 State、DRAIN、MIGRATE、回滚和控制面重启 fail-closed。测试使用 build/hotupgrade-tests/ 下的临时文件，不应指向生产目录。

## 启动协调 Service

宿主由 composition root 启动：

~~~lua
local hotupgrade_handle = skynet.newservice(
    "flywow_hotupgraded",
    "my_hotupgrade_options",
    skynet.self())
~~~

配置模块至少提供：

~~~lua
return
{
    patch_root   = "./config/hotupgrade",
    history_path = "./logs/hotupgrade.history",
    metrics      = nil,
}
~~~

宿主必须保存返回的 Service handle，并只允许受信管理入口使用它。第三个启动参数是管理调用方 handle；远程认证、文件上传和多节点广播由宿主提供。

## Service 注册

业务 Service 在自己的 Lua State 中注册一次：

~~~lua
local hotupgrade = require "flywow_hotupgrade"

local registered = hotupgrade.register_service(
{
    controller       = hotupgrade_handle,
    service_type     = "chat",
    service_id       = "global",
    generation       = 1,
    code_version     = 1,
    state_version    = 1,
    replacement_mode = "migrate",
    adapter =
    {
        dispatch        = dispatch,
        export_state    = export_state,
        import_state    = import_state,
        healthcheck     = healthcheck,
        rebuild_runtime = rebuild_runtime,
    },
})
assert(registered.ok, registered.message)
~~~

长期调用应通过稳定模块 table，不能缓存旧 module.function closure 期待它自动变化。业务请求、Timer 和后台任务都要进入 Guard 或等价安全点。

## Patch 目录

常规模块不需要手写 Manifest。Patch Root 下使用相对目录：

~~~text
config/hotupgrade/
  current/
    modules/
      chat/player.lua
      chat/room.lua
~~~

modules/chat/player.lua 对应 Lua 模块名 chat.player。Patch 扫描会拒绝越界路径、符号链接、语法错误和容量超限。

可选目录：

~~~text
current/
  services/
    chat.lua
  migrations/
    chat/1-2.lua
  configs/
    chat/rules.lua
~~~

Service 文件用于候选 Service 替换；迁移文件返回纯 Lua 迁移函数，不能访问 Skynet、文件、网络或外部副作用。

## 管理命令

管理入口使用 hotupgrade 协议发送：

- validate：扫描并校验 Patch，不改变线上状态；
- dry_run：执行暂存、依赖和迁移预检，完成后释放候选；
- apply：创建事务并异步执行，返回 txn_id；
- status：查询事务审计记录；
- history：读取本地有界历史；
- metrics：读取当前轻量计数；
- abort：发布决定前请求取消；
- rollback：提交反向 Patch，或使用明确声明可逆的事务。

最小调用：

~~~lua
local hotupgrade_rpc = require "flywow_hotupgrade_rpc"

local checked = hotupgrade_rpc.call(
    hotupgrade_handle, "validate", {path = "current"}, 5000)
assert(checked.ok, checked.message)

local started = hotupgrade_rpc.call(
    hotupgrade_handle, "apply", {path = "current"}, 5000)
assert(started.ok, started.message)

local status = hotupgrade_rpc.call(
    hotupgrade_handle, "status", {txn_id = started.txn_id}, 5000)
assert(status.ok, status.message)
~~~

超时只表示本地等待结束，不表示远端事务被取消。管理入口必须保存 txn_id 并继续查询；迟到结果不能推进旧事务。

## 结果与失败处理

所有控制命令返回 ok、code、message、step、txn_id 字段。常见错误包括：

- HU_INVALID_PATCH：Patch 路径、布局或内容不合法；
- HU_TARGET_MISSING：没有匹配已注册目标；
- HU_DEPENDENCY_CYCLE：strong 依赖图存在环；
- HU_SAFEPOINT_TIMEOUT：目标无法进入安全点；
- HU_DRAIN_TIMEOUT：新实例已发布，旧实例仍有合法访问者；
- HU_ABORT_FAILED：发布前恢复失败；
- HU_RECOVERY_REQUIRED：不能安全判断或自动恢复当前事务；
- HU_ALREADY_APPLIED：同一 Patch 身份已有事务记录。

HU_DRAIN_TIMEOUT 不等于回滚；新实例仍是当前实例，旧实例保留清理。出现 HU_RECOVERY_REQUIRED 时禁止继续启动新事务，先按原 txn_id 和参与者状态人工处理。

## 生命周期边界

HotUpgrade 只管理明确注册的 Service、模块 table、Guard、Registry 和迁移快照。不接管未经注册的 skynet.call/send、已运行的 Lua coroutine 栈、Native/C 动态库、C++ 全局状态、未知 userdata、外部 fd、网络连接和跨节点事务。
