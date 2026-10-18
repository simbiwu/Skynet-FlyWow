# FlyWow HotUpgrade 接入说明

## 原地模块更新

原地更新保留当前 Service 的 Lua State、业务状态和模块导出表；候选 Service 替换是另一条流程。本模块只公开一条模块更新路径：使用 HotUpgrade 的业务 Service 必须先调用 `register_service`，之后的 `dry_run`、`apply` 与回滚都由 Controller 编排。这样更新目标来自已注册 Service 的模块声明，执行结果进入同一事务历史；业务代码不能绕过控制面单独改写 `package.loaded`。

~~~lua
local skynet = require "skynet"
local hotupgrade = require "flywow_hotupgrade"
local logic = hotupgrade.require "my_logic"
local guard = hotupgrade.guard()
local state = {count = 7} -- 可变业务状态由 Service 持有，不放进模块导出表。

-- Service 启动期间注册一次；注册成功前宿主不得将 Service 标记为 READY。
local registered = hotupgrade.register_service(
{
    controller_handle = controller_handle,
    service_type = "chat",
    adapter = {dispatch = dispatch},
})
assert(registered.ok, registered.message)

-- 业务请求通过 Guard 进入；dispatch 可以正常 yield。
local answer = guard:run(logic.handle, state, request)

-- 管理端将更新命令发给 Controller；事务异步推进，后续查询 status。
local started = skynet.call(controller_handle, "hotupgrade", "apply", {path = "current"})
assert(started.ok, started.message)
~~~

模块声明有两种时序，但只有一个注册式更新模式：在 `register_service` 之前调用 `hotupgrade.require(name)`，模块名会进入初始注册元数据；注册后首次声明新模块时，`hotupgrade.require` 会同步调用 Controller 的 `register_module`，成功后才记录本地声明。登记失败会抛出错误，后续调用可以重试。重复声明不会重复 RPC。只有通过 `hotupgrade.require` 声明的模块才由 Controller 纳入该 Service 的模块更新目标。

Controller 读取并冻结 Patch 源码后，向已注册目标调用 Runtime 的 `prepare`、`stage`、`activate` 和 `finish`。`prepare` 关闭本地 Guard 并排空已接纳业务处理；`stage` 在不改线上导出表的条件下编译、加载并检查所有目标模块；`activate` 将新导出内容写回原导出表；全部目标达到发布决定后，`finish` 释放旧字段快照并重新开放入口。失败时 Controller 在发布决定前调用 `abort`，Runtime/模块引擎恢复原导出并重新开放 Guard；恢复无法确认时保持暂停并报告恢复失败。回滚是再次将旧源码作为一个新 Patch 执行同一流程，不是把业务状态恢复到旧值。

模块接入合同：

- 只替换已声明、已加载的普通导出表；键为字符串，值为函数、字符串、数值或布尔值。旧模块也须符合此合同，拒绝嵌套状态表、metatable、userdata 等导出。已有同名字段不能改变类型。
- 每份源码返回新的完整导出表。安装时删除新文件中不存在的旧字段，保留 `package.loaded[name]` 与调用方原有导出表的身份。
- 调用方通过 `logic.handle(...)` 读取当前函数。缓存的旧函数不自动更新；不保留或对外暴露候选私有导出表，不在运行中修改导出字段。
- 模块函数不持有需要保留的可变私有状态；状态由 Service 持有，通过参数传入。已移除 `stable_state` API 和状态代理，不改写函数 upvalue，也不迁移旧闭包。
- 顶层只能定义代码、常量和取得已加载依赖的表引用。不得调用依赖业务函数、yield、执行 I/O、启动任务、写全局或修改线上状态。依赖函数在后续业务调用时通过表读取；顶层不能缓存依赖函数或计算依赖业务代码的初始化结果。
- Patch 内模块不做递归加载；普通 `require` 仅接受本 State 已加载的普通模块表。需要新增模块、改变初始化流程或状态结构时使用 Service 替换路径。

源码及 `postcheck` 都是**受信代码**，不是沙箱执行。检查回调必须同步、无副作用；错误/false 只恢复导出字段。框架不保证撤销违反合同的状态写入、数据库操作、任务创建或调度器注册，也不保证从死循环、阻塞 Native、OOM 或进程退出中恢复。新路径不使用独立 coroutine 探测 yield，以免误把 Skynet 调度器注册视为已撤销。

原地模块更新使用已经注册的 Service、模块声明、Guard 和 Controller Runtime，不单独创建更新器、事务历史或本地 apply API。模块更新只使用 Stage/Commit/Abort/Finish；Service 替换不走模块安装和撤销。Native/C、Skynet Core、运行中 coroutine、跨 Service 原子更新均不属于模块更新能力。

HotUpgrade 在同一 Skynet 节点内管理 Lua 模块更新和 Service 替换。宿主在 composition root 中启动控制面；控制命令通过 Controller Service handle 发送，控制面不校验调用者白名单。模块不创建 OS 进程，不提供远程认证、上传、跨节点事务或管理 UI。

## 启动控制面

~~~lua
local controller_handle = skynet.newservice("flywow_hotupgrade_service")
local initialized = skynet.call(controller_handle, "lua", "init",
{
    patch_root   = "./config/hotupgrade",
    history_path = "./logs/hotupgrade.history",
})
assert(initialized.ok, initialized.message)
~~~

init 接收的配置至少提供 patch_root 与 history_path。宿主保证路径存在且可由 Skynet 进程读写，并保存 `skynet.newservice` 返回的 Controller Service handle，供管理代码本地调用，也传给需要热更控制面的业务 Service。控制面不校验调用者身份。

## Service 注册

Service 在自己的 Lua State 注册一次：

~~~lua
local hotupgrade = require "flywow_hotupgrade"

local registered = hotupgrade.register_service(
{
    controller_handle = controller_handle,
    service_type  = "chat",
    router_handle = hotupgrade_router_handle,
    adapter       = { dispatch = dispatch },
})
assert(registered.ok, registered.message)
~~~

初代注册只提供 Controller Service handle、Service 类型、业务 dispatch，以及 Service 替换所需的稳定 router_handle。Controller 从注册 RPC 的 source 取得初代 instance_handle，并保存为 origin_service_handle；候选继承该 origin_service_handle，同时用自己的 instance_handle 注册。origin_service_handle 是当前 Controller 生命周期内稳定的路由键，不是当前 RPC 目标；Skynet 为每个运行实例分配新的 instance_handle。Controller 重启后当前实现不从历史重建 Registry，Service 重新注册会建立新的 origin_service_handle。业务代码不生成这些身份字段。service_type 对应 Patch 的 services/<service_type>.lua。没有 Router 的 Service 仍可使用模块热更，但替换会在 validate 阶段被拒绝。健康检查、模块 postcheck 和 can_upgrade 是可选业务检查。初代在稳定 Router 绑定成功后才进入可升级集合；注册失败的 Service 不得 READY，应结束启动并由宿主处理。

候选替换的固定顺序：

1. 关闭稳定 Router 的目标入口并等待已转发调用返回，再由旧实例 Guard 等待实际业务处理结束。
2. 控制面同步 `launch` 取得候选 instance_handle，以真实 RPC source 关联启动窗口，并在首次等待前记录 instance_handle。不生成启动 token，不把候选提前写入当前实例索引。
3. 候选在自己的 State 安装冻结模块加载入口，再执行冻结的 Service factory。已有磁盘文件也优先使用本次源码；未被 require 的 Patch 模块不执行。只拦截本次冻结模块，其余依赖继续使用 Skynet require。
4. factory 自行重建权威状态并完成注册；factory 完整返回后才报告 ready。需要交接时，旧实例同步导出，新实例同步导入；两端能力必须成对。随后确认候选安全点并执行可选 healthcheck；提供检查时必须明确返回 true。
5. 发布决定成功落盘后，按旧 instance_handle 切换 Router，更新当前实例索引，以一次 finish RPC 完成本地清理和开放，再恢复 Router。
6. 新实例接流量后，旧实例安排下一 tick 退出；控制面删除旧 source 记录。

从获得候选 instance_handle 起等待就绪最多 10 秒；超时、abort、未注册或初始化失败均先关闭启动窗口再终止候选。迟到 bootstrap、候选注册和 ready 均被拒绝。候选在发布前不接受业务，失败直接销毁整个候选，不通过模块 Abort 恢复它。发布前恢复旧 Guard 与原路由；发布决定后出现不确定结果则停止新发布并要求人工核对，不自动切回旧实例。

冻结模块只在本候选 State 中装载，允许引用同一 Patch 的新增模块；不自动初始化整包，也不依赖 `package.preload` 覆盖 Skynet 的磁盘优先规则。被冻结模块顶层须同步，不使用 `skynet.init` 注册初始化钩子；需要 yield、读取权威状态、建立运行资源的初始化放在 factory 中。factory 在当前 Skynet 协程执行，允许正常 yield，并保留 Lua 指令预算。该预算不能抢占阻塞 Native 调用，宿主不得用无限 C 调用阻塞工作线程。启动壳已经加载的模块不能再被本次冻结源码覆盖。已加载模块会释放源码；未加载模块保留本次有界冻结源码，供该候选后续按需 require。

新 Service 在 factory 注册前从权威持久化来源自行重建状态。只有确需交接进程内状态时，旧实例和新实例都提供 export_state / import_state。export_state 必须只读且无外部副作用；import_state 只接管候选私有状态，不写外部权威数据。回调自行验证并转换 Service 私有数据；export_state 返回的业务 record 会原样传给 import_state，必须可经 Skynet 消息传递，且不能以 false 作为有效状态值（false 表示拒绝交接）。状态可包含 ok 等普通字段。Timer、文件句柄、Native 对象等运行时资源由新 Service 自行构造，后台状态写入通过 Guard；框架使用 Skynet 退出流程退休旧实例，不额外要求业务生命周期钩子。retire 成功只确认已安排下一 tick 退出；不代表进程已经销毁或业务外部资源已经释放。

业务请求、Timer 和会修改状态的后台任务必须经过 hotupgrade.guard():run(...) 或等价安全点。调用方保存 origin_service_handle，并通过 hotupgrade.router_ref({router_handle=router_handle, origin_service_handle=...}) 转发。Router 按 origin_service_handle 查找当前实例，再向该记录的 instance_handle 发送 RPC；Service 替换只改变 instance_handle，不改变路由身份。

## Patch 目录

~~~text
<patch_root>/
  current/
    modules/
      chat/player.lua
    services/
      chat.lua
~~~

modules/chat/player.lua 更新 require "chat.player"；services/chat.lua 替换 service_type = "chat"。扫描器接受普通 Lua 文件；缺省分类允许为空，但分类为链接、非目录或发生 I/O 错误时拒绝整个 Patch。它检查路径、语法和容量。宿主须在扫描与源码冻结期间保持 Patch 目录不变，完成冻结后本次事务只使用冻结源码；扫描与读取不是抵抗并发目录替换的原子安全边界。Patch ID 由目录相对路径与分类内文件名构成，不计算内容 hash。

## 管理命令

管理命令只提交或查询控制面状态，不等待整个更新事务完成；直接使用 Skynet 原生 call，事务进度通过后续 status 查询：

~~~
local started = skynet.call(controller_handle, "hotupgrade", "apply",
    {path = "current", selector = {percent = 0.25}})
assert(started and started.ok, started and started.message or "apply 请求失败")

local status = skynet.call(controller_handle, "hotupgrade", "status", {txn_id = started.txn_id})
assert(status and status.ok, status and status.message or "status 请求失败")
~~~

命令包括 validate、dry_run、apply、status、history 和发布决定前 abort。回滚通过 apply 重新执行旧 Patch。同一控制面一次只执行一个发布；新的 apply/dry_run 返回 `HU_UPGRADE_BUSY`，不排队。灰度仍按逻辑 Service 实例稳定选择，逐实例推进；已完成实例不会因之后的实例失败而自动回滚。

原地更新 dry_run 在门禁内暂时安装、执行可选 postcheck 后恢复旧导出；替换 dry_run 完成新代码初始化、状态准备和 healthcheck 后销毁候选、恢复旧实例。两者都不写发布决定或开放候选路由。postcheck 仅用于原地更新，healthcheck 仅用于替换候选。can_upgrade、export/import、postcheck/healthcheck 均为受信同步回调；不得 yield，检查与导出不得修改业务状态，所有回调不得执行不可撤销的外部写入。框架捕获错误和拒绝，不用裸 coroutine 探测 yield，也不承诺撤销违反合同的副作用。

重新执行旧 Patch 会创建新的 Service 实例，不会恢复旧进程内存。状态结构发生变化时，旧版 import_state 必须能处理当前导出的状态，或者 Service 从权威来源重建状态。

Controller 实例步骤和 Router 排空使用有界等待；超时只结束本地等待，不会自动取消远端操作。若已取得 txn_id，保存它并继续查询。Router bind、switch、resume、abort 与管理命令使用同步 call，不设置额外 RPC 超时。历史仅在明确不存在时作为空文件初始化，其余读取错误拒绝启动；已有历史行保持原样，旧行仍以写入时的字段名展示，新行使用当前字段名；Native 同步追加失败后禁止继续追加，并全局阻止新发布。发布后失败或恢复失败同样设置全局恢复门禁，需人工核对参与者、路由与历史后处理；status 返回 recovery_required，若该事务持久化失败还返回 error，record 仍为最后成功落盘的记录，不能当作当前已完成状态。正常持久化终态释放完整事务/Patch 对象，Runtime 同时释放模块引擎持有的候选导出与撤销字段，状态查询继续读取有界历史。

## 错误与限制

常见错误包括 HU_INVALID_PATCH、HU_TARGET_MISSING、HU_SAFEPOINT_TIMEOUT、HU_ROUTE_PAUSED、HU_CREATE_FAILED、HU_HISTORY_READ_FAILED、HU_ABORT_FAILED 和 HU_RECOVERY_REQUIRED。发布后无法完成切换、恢复或旧实例退休时返回恢复错误，不表示自动回滚。

控制面只管理已注册 Service、已声明模块、Guard 和稳定 Router。不会接管未经 Router 的调用、运行中的 coroutine 栈、Native/C 动态库、外部 fd/连接或跨节点事务。无法确定是否安全时保持暂停并要求恢复，不猜测业务状态。

夹具测试验证 FlyWow 的框架合同与 Skynet 调度集成；它们不验证宿主真实数据库/权威状态源、业务一致性或部署权限。这些边界由宿主项目分别验证。
