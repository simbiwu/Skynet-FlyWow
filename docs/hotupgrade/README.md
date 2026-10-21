# FlyWow HotUpgrade 接入说明

贯穿 PlayerService V1/V2 发布的可运行流程见 [HotUpgrade Sample](../../hotupgrade/sample/README.md)。

HotUpgrade 在现存 Skynet Service、现存 Lua State 内更新受信 Lua 代码和必要业务状态。更新保持 Service handle、模块导出表和 Service 私有状态根表的身份。普通模块提交完整新版本；可选 Service 更新脚本在同一事务内迁移私有状态并直接替换指定业务函数。

## 启动与登记

宿主从 composition root 启动控制面，保存 handle，再通过 init 交付配置：

```lua
skynet.start(function()
    local controller_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hotupgrade = require "flywow_hotupgrade" -- 必须在协程内加载；模块顶部的唯一服务查询会 yield。
    local initialized = skynet.call(controller_handle, "lua", "init",
    {
        patch_root = "./config/hotupgrade",
        root_path = ".",
        service_dir = "service",
        timeout_ms = 10000,
    })
    assert(initialized.ok, initialized.message)
    -- 在此之后再启动受管理业务 Service。
end)
```

以宿主 server 为工作目录时，在现有 Skynet 配置的 luaservice、lua_path、lua_cpath 中分别加入以下相对搜索项，并保留宿主原有路径：

- luaservice：./third_party/skynet-flywow/hotupgrade/service/?.lua
- lua_path：./third_party/skynet-flywow/hotupgrade/lualib/?.lua
- lua_cpath：./third_party/skynet-flywow/build/native/?.so

公开入口是 hotupgrade/lualib/flywow_hotupgrade.lua；控制 Service 入口是 hotupgrade/service/flywow_hotupgrade_service.lua。Controller 加载 flywow_hotupgrade_native 时，Lua 从 Native 搜索路径定位统一构建入口产出的 build/native/flywow_hotupgrade_native.so。每个加载公开入口的 State 会在模块加载时调用一次原生 skynet.uniqueservice("flywow_hotupgrade_service")，并缓存 handle。该调用会 yield，因此须从 Skynet 协程内（例如 skynet.start 回调）首次 require 公开入口。宿主仍负责在启动受管理业务 Service 前初始化 Controller。管理 State 无需登记为业务目标。

patch_root 必须存在且可读取。root_path 是已存在的宿主项目根目录，service_dir 是它下面已存在的相对 Service 目录；拒绝绝对路径、空路径段、.、..、反斜杠和符号链接目录。目录允许多级，例如 service/battle。

Controller 初始化成功时通过现有 Skynet 共享环境发布内部键 flywow_hotupgrade_root_path。须先完成 Controller init，再启动会调用 hotupgrade.require 的业务 Service。同一 Skynet 进程的 Controller 必须使用同一规范化 root_path；不一致时初始化失败。宿主不需要另行配置此内部环境键。

timeout_ms 是目标 Guard 等待在途业务排空的毫秒上限，默认 10000；它不是远端 RPC 取消期限。init 失败可修正后重试，成功后重复 init 返回 HU_ALREADY_INITIALIZED，初始化前控制请求返回 HU_NOT_INITIALIZED。

纳入 HotUpgrade 管理的 Service 必须由创建者使用受管理入口启动；Controller 自身和非受管理 Service 继续使用原生入口。宿主可通过原生 uniqueservice 获取相同 handle，用于 begin/status/apply 等管理命令；业务 Service 的 HotUpgrade API 不再接收 handle：

```lua
local handle = hotupgrade.newservice("player", "原有启动参数")
-- newservice 仅转交原生启动参数，返回后不额外等待业务 init 或 register_service。
local called, initialized = pcall(skynet.call, handle, "lua", "init", player_config)
if not called or type(initialized) ~= "table" or not initialized.ok then
    -- 只可取消尚未登记的 Service；Controller 核验创建者、终止 Service 并清理待创建记录。
    local cancelled = hotupgrade.cancel_service_creation(handle)
    assert(cancelled.ok, tostring(cancelled.code) .. ": " .. tostring(cancelled.message))
    error(type(initialized) == "table" and initialized.message or tostring(initialized))
end
```

hotupgrade.newservice 会 yield，成功返回原生 handle，失败抛出含 HU_SERVICE_CREATE_FAILED（或入口拒绝码）的异常。原生创建失败自动释放记录；创建成功后的业务 init 由调用方负责。业务 init 应在所有可能失败的初始化工作完成后，最后调用 register_service，并把登记结果作为 init 的结果；成功后再宣布 READY。业务初始化在登记前失败时，原创建者必须显式调用 cancel_service_creation，不能仅丢弃 handle。取消返回统一结果，非创建者返回 HU_UNAUTHORIZED，未知/已取消的 handle 返回 HU_CREATION_MISSING，已登记 Service 返回 HU_SERVICE_ALREADY_REGISTERED 且不会被终止。若登记 RPC 结果不明或登记后又失败，取消可能被拒绝，须由宿主核对真实登记状态并处理受控终止/重启，不能把它当成仍未登记。

Controller 在调用原生 skynet.newservice(service_name, ...) 前建立创建记录，原样转发目标名称和全部启动参数。原生返回后立即保存真实 handle 索引并返回调用方，不等待业务登记。目标由原生 loader 在自己的 Lua State 中启动；SERVICE_NAME、SERVICE_PATH、preload 和参数语义均由 Skynet 原生处理，Controller 不改写启动环境或重新执行 loader。

register_service 只发送原有元数据，Controller 仅按消息头真实 source 与原生返回 handle 精确关联。登记先到时，登记协程让出执行权，等待在途原生创建返回后重新查询索引；其他消息和创建返回仍能继续处理。所有原生调用均返回后仍无匹配时返回 HU_CREATION_MISSING，重复登记返回 HU_DUPLICATE_SERVICE。内部创建序号仅作 Controller 表索引，不传入业务 Service。登记成功、原生失败或创建者合法取消后释放对应记录；记录不会自动超时清除。

**登记不能阻止原生启动完成。** Skynet 的 newservice 等待 skynet.start 回调返回后才交付 handle，因此不能在该回调中同步等待 register_service；这会与早到登记的 handle 等待形成循环。推荐按上述例子在创建返回后调用业务 init，或在独立协程执行登记并让 start 回调先结束。独立协程仍可能先发出登记，Controller 会按真实 handle 关联；业务 READY 必须等待登记成功。

### 受管理本地唯一服务

```lua
local handle = hotupgrade.uniqueservice("player", zone_id)
-- 明确拒绝：抛出含 HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED 的异常，不启动 Service。
local global_handle = hotupgrade.uniqueservice(true, "player", zone_id)
```

唯一键是本 Controller 内的原始逻辑 Service 名称。首次创建先建立该名称的在途预留，再复用受管理 newservice 流程；同名并发请求等待同一创建结果，原生创建返回后一起取得相同 handle。只有首次请求的启动参数生效，后续重复请求的参数不改变实例。不同名称可启动不同 Service；已有 handle 即使在发布期间也直接返回，尚未创建的新逻辑键须等待发布成功。

该映射仅属于一个 Controller，不与原生 uniqueservice 的名称空间互通，不承诺跨 Controller、跨进程或跨节点唯一。全局 true 重载始终在实际启动前拒绝。snaxd 不满足受管理 Service 自行调用 register_service 的登记合同，入口返回 HU_SPECIAL_SERVICE_UNSUPPORTED，不增加 Snax 专用初始化流程；newservice 同样拒绝 snaxd。

首次创建失败时释放创建记录和唯一名预留，唤醒同一次创建的等待者返回错误，后续请求可重试。原创建者合法取消尚未登记的 Service 时，在原生终止成功后释放该唯一名。成功登记后不能取消创建。本地唯一入口不进行死亡监控或自动重建；已登记 Service 的受控终止和替换须由宿主管理。FlyWow 仅使用现有 Skynet 公开接口，不要求修改、复制、覆盖或生成任何 Skynet 框架源码。

在受管理业务 Service 自己的 Lua State 登记。由于公开模块首次加载会调用可 yield 的原生 `skynet.uniqueservice()`，以下初始化应放在 Skynet 协程内：

```lua
skynet.start(function()
local hotupgrade = require "flywow_hotupgrade"
local logic = hotupgrade.require("player_logic")
local state = {equip = "刀", level = 50, schema_version = 1}
local M = {}

function M.load(item)
    return item.base_attack
end

function M.save(item)
    -- 此处保留业务现有保存实现。
end

local registered = hotupgrade.register_service(
{
    service_module = "player",
    service_update = {state = state, functions = M},
    after_upgrade = function()
        return state.level >= 0
    end,
})
assert(registered.ok, registered.message)
end)
```

service_module 匹配 service_dir 下的一次性 .patch 相对路径：去掉 .patch 并将 / 转为 .。例如 service_dir 为 service 时，service/player.patch 对应 player，service/battle/worker.patch 对应 battle.worker。service_update 可省略，此时该 Service 只参与普通模块更新。Controller 使用注册消息真实 source 作为目标 handle；私有状态、函数和回调留在业务 State，不经消息传给 Controller。登记成功前宿主不得宣布 Service READY；登记 RPC 失败可能有不确定结果，应终止该次启动，由宿主管理，而不是继续接收业务。

hotupgrade.require(name) 仍用宿主原有 name 加载模块，通过 package.searchpath(name, package.path) 定位 Lua 文件，再复用 Native resolve 得到规范化路径。Controller 登记名由该文件相对 root_path 的路径去掉 .lua、将 / 转为 . 得到。例如原调用 hotupgrade.require("battle.state_sync.runtime") 加载 lualib/battle/state_sync/runtime.lua，登记名为 lualib.battle.state_sync.runtime；不是给原 name 固定增加目录前缀。?/init.lua 解析出的文件也按真实路径登记，例如 lualib/battle/init.lua 对应 lualib.battle.init。

原 require 名和文件登记名在 package.loaded 中指向同一个模块根表，热更和恢复都通过同一根表对两种名称生效。只有首次通过 hotupgrade.require 确认加载来源的模块表才允许复用；先经普通 require 加载而没有来源记录的缓存模块会被明确拒绝，即使原名恰好等于文件登记名。须从首次加载时就使用 hotupgrade.require，不要清空已有业务缓存来绕过检查。建立别名前同时检查原名来源、文件登记名缓存和 package.preload；冲突时明确拒绝，不覆盖已有缓存或预加载器。加载、来源验证或动态登记失败会恢复本次涉及的原名缓存和规范别名，撤销本次新增的来源映射及声明计数，保留操作前已有的合法缓存，允许重试。仅支持通过标准 package.path 搜索的 Lua 文件；package.preload、自定义加载器来源不一致、无法定位文件或文件位于 root_path 外时明确拒绝。宿主应保持受控模块的搜索路径稳定，不在已加载后改写其加载来源。

登记前声明随初始元数据提交，由待创建记录保护。register_service 会拒绝本 State 尚在执行的首次声明（HU_LIFECYCLE_PENDING），调用方须待声明完成后登记；登记 RPC 期间的新声明等待登记结果，避免落在初始模块快照之外。

已登记 Service 首次声明模块时，先向 Controller 请求 begin_module_load 许可，再执行实际 require、校验来源并建立缓存、别名、来源映射和本地声明，最后携许可 ID 调用 register_module。许可绑定真实来源及规范模块名，不能转用或重复消费；失败时回退本地新增状态，并通过 cancel_module_load 释放尚未完成的许可。许可未完成前禁止启动新批次，覆盖模块执行及登记的整个关键区间。同一 State 内并发首次声明同一规范模块会等待前一项成功或完整回退；已声明模块不重复请求许可。Controller 只更新目标已声明的模块。begin 之后的首次加载请求与新创建请求一起等待发布终态，等待期间不发放许可、不执行模块代码，也不增加当前排空计数；失败锁定时返回 HU_DEPLOYMENT_BLOCKED。既有许可仍可完成或取消，既有创建仍可在 WAITING_CREATIONS 登记。同一逻辑模块等待者仍复用本 State 的并发声明协调。首次声明应在启动初始化或 Guard 之外的受控阶段完成，不要在尚未排空的 Guard 业务协程内等待发布结束，否则该业务无法在当前发布的 prepare 中排空。

## 业务 Guard

所有可能读取/修改受控状态的业务请求、Timer 和后台任务都必须经过同一个 hotupgrade.guard()。框架不自动接管业务 dispatch：

```lua
local answer = hotupgrade.guard():run(function()
    return M.load(item)
end)
if answer.ok then
    local value = answer.values[1]
    -- 按业务协议返回 value。
end
```

Guard:run 允许业务正常 yield，捕获异常并在结束时减少在途计数；成功结果的 values 保留 nil 和返回值数量。更新时先关闭新入口，新调用返回 HU_UPGRADING，再等待已接纳协程排空。可选 before_upgrade() 是额外的同步、只读安全条件。排空超时由 Controller 请求 abort，确认恢复后才重开入口。

## Patch 布局与普通模块

```text
<patch_root>/<path>/
  config/
    settings.lua
  lualib/
    player_logic.lua
    battle/state_sync/runtime.lua
  service/
    player.lua
    player.patch
    battle/worker.patch
```

发布包内部路径对应宿主 root_path 下的实际路径。递归扫描全部 .lua 和 .patch，并先冻结内容、检查语法。配置 service_dir 中的 .lua 是完整新版 Service，只部署；该目录中的 .patch 是一次性 Service 更新脚本，只更新现存实例、不部署。其他目录中的 .lua 是完整普通模块：已登记时同时更新运行时和部署文件，未登记时仅部署。.patch 不能出现在 service_dir 之外。

.lua 与 .patch 无须成对出现；允许仅 Service 源码、仅 Service Patch、仅普通模块，以及没有任何运行时目标的纯文件发布。Service .patch 必须匹配至少一个已登记且支持内部更新的目标；未匹配返回 HU_TARGET_MISSING，不支持则返回 HU_SERVICE_PATCH_UNSUPPORTED。普通模块名称仍按实际路径登记，例如 config.settings、lualib.player_logic。不同路径映射到同一普通模块名或同一 Service Patch 名时拒绝整包；其他普通文件忽略，符号链接和特殊文件拒绝。

两类均可单独存在。每份普通模块文件必须是完整模块新版本。只改一个函数也必须保留新版仍需要的全部导出字段。提交会更新所有新字段，并删除新版已去掉的字段，原导出表和两种 package.loaded 名称的身份保持不变。

模块顶层是无元表普通表，只导出字符串键，值允许函数、数值、字符串、布尔值和普通嵌套表；嵌套表键允许字符串、数值或布尔值，允许共享和循环，但不得引用模块根导出表。任何层级均不接受元表、userdata 或 thread，同名顶层字段不得改变类型。嵌套表随版本整体替换，不递归合并、不保证身份；缓存的旧嵌套引用仍指向旧数据，回滚恢复旧字段及原有嵌套引用。可变私有状态放在模块闭包或由 Service 持有。模块顶层只能定义代码、常量和引用已加载依赖；不得 yield、I/O、写全局、修改线上状态或启动任务。候选源码中的 require 只返回本 State 已加载的模块，不加载新增依赖。

调用方通过 logic.load(...) 读取当前函数。缓存的旧函数仍是旧函数，不会自动更新；不要对外暴露候选导出表或在业务中改写模块导出。

### 模块私有状态

需要跨版本保留或转换的闭包状态使用成对 export_state/import_state：

```lua
local count = 0
local M = {}

function M.export_state()
    return {count = count}
end

function M.import_state(snapshot)
    count = snapshot.count
    return true
end

function M.next()
    count = count + 1
    return count
end

return M
```

旧版 export_state 的结果被复制为独立普通数据图，再传给新版 import_state。两版均须提供配对函数；必要钩子缺失、钩子报错或 import_state 返回 false，都会拒绝 Stage。不需要保留私有状态时不强制钩子。旧闭包在 Stage 中不变，Abort 恢复原函数字段后继续使用旧状态；不使用 debug.upvaluejoin 搬运 upvalue。

钩子必须同步、无外部副作用，不得改其他模块。默认快照只接受 nil、布尔、数值、字符串和无元表普通表，键是字符串/数值/布尔；图内共享和循环会保留，最多 64 层、10000 个字段。超限或不可复制值使 Stage 失败。

## 一次性 Service 更新脚本

service_dir 为 service 时，service/player.patch 返回构建函数，接收现存 Service 私有 state 根表：

```lua
return function(state)
    return
    {
        migrate = function(old_state)
            assert(old_state.schema_version == 1)
            return
            {
                equip = old_state.equip == "刀" and "剑" or old_state.equip,
                level = old_state.level,
                schema_version = 2,
            }
        end,
        functions =
        {
            load = function(item)
                return item.base_attack + (state.equip == "剑" and 20 or 0)
            end,
        },
    }
end
```

migrate 接收独立旧状态快照，返回完整候选状态。Activate 先原地覆盖现存 state 的全部字段（含删除不再存在的字段），再直接替换 functions 指定的现有函数字段。未列出的函数保持不变；新函数直接捕获原 state，不增加稳定包装或函数注册表。没有迁移可省略 migrate，没有函数更新可省略 functions，两者都无则不提供 Service Patch。函数级更新仅在 Service 脚本中支持；普通模块仍是完整文件 Patch。

仅需迁移的 Service 局部变量集中到其私有状态表，不要求把所有状态移入表或独立模块。默认复制普通数据图，保持状态根表身份，嵌套表身份不承诺保持。对 userdata、元表对象或不适合进入表的局部状态，可在登记的 service 中成组提供以下最小内部回调：

- snapshot(state)：每次返回独立的完整状态快照；Stage 分别调用两次，保留旧状态和用于迁移的快照，两份快照及线上对象不得共享可变状态。
- commit(state, next_state)：原地提交候选状态，不替换根表；返回 false 或抛错视为提交失败。
- restore(state, old_state)：恢复完整旧状态，不替换根表；返回 false 或抛错导致恢复故障。

自定义回调负责业务对象的隔离、兼容验证和恢复；不能把浅拷贝当作隔离保证。所有构建、迁移、检查、提交和恢复回调均为受信同步代码，不得 yield、执行外部 I/O 或产生不可撤销副作用。框架捕获错误，但不提供安全沙箱，不承诺抢占死循环/阻塞 Native、撤销违反合同的副作用或从 OOM/进程退出恢复。

## 发布生命周期、文件部署与恢复

正式调用顺序为 begin → 等待 status.lifecycle.phase == DEPLOYING → apply → 查询 status。宿主提供发布包、发起请求和查询结果；HotUpgrade 负责部署完整 .lua、清理 Skynet 代码缓存，以及正常失败时的文件恢复。所有发布包扫描、读取和检查都在 begin 屏障建立后，由 apply 中的 Controller:load() 执行，没有独立预检接口。

~~~lua
local begun = skynet.call(controller_handle, "hotupgrade", "begin", {})
assert(begun.ok, begun.message)
while true do
    local status = skynet.call(controller_handle, "hotupgrade", "status", {batch_id = begun.batch_id})
    assert(status.ok, status.message)
    if status.lifecycle.phase == "DEPLOYING" then break end
    assert(status.lifecycle.phase == "WAITING_CREATIONS", status.lifecycle.phase)
    skynet.sleep(1)
end
local started = skynet.call(controller_handle, "hotupgrade", "apply",
    {batch_id = begun.batch_id, path = "current"})
-- apply 同步检查失败时 started 为原始错误；仍可查询同一批次的 ABORTED 记录。
-- accepted 后继续查询同一 batch_id，直到终态。
~~~

begin 分配批次并立即返回 WAITING_CREATIONS；已有创建和首次模块加载许可均完成或取消后进入 DEPLOYING。新创建、本地唯一实例首次创建、首次模块加载在屏障期间排队。初始化遗漏登记或取消时会持续等待，Controller 不自动删除记录。apply/dry_run 须携带同一 batch_id，且只能在 DEPLOYING 接受一次。缺失或过期身份为 HU_BATCH_MISSING，等待旧操作结束时为 HU_LIFECYCLE_PENDING，其他阶段为 HU_DEPLOYMENT_PHASE；重复 begin 为 HU_UPGRADE_BUSY。

apply 冻结完整发布包并固定目标集合，随后在运行时更新前准备正式文件的旧内容或“不存在”标记。执行次序为：

1. 所有目标 Prepare，暂停业务并排空。
2. 所有目标 Stage，准备完整模块及可选 Service 更新。
3. 所有目标 Activate，同步安装候选并执行 after_upgrade。
4. 将冻结的全部完整 .lua 部署到 root_path 对应路径；同目录临时文件完整写入后替换正式文件，成功后内部执行 skynet.cache.clear()。.patch 不进入部署集合。
5. 使用现有 PUBLISH_DECIDED 表示发布决定，再对所有目标 Finish，释放快照并恢复业务。

每个阶段仍按 handle 排序调用现有目标协议，没有运行时目标时跳过目标阶段，照常部署完整文件。新目录按需建立；文件恢复会删除本批新增文件，可能留下空目录。不部署非 Lua 资源，不提供文件删除清单。

路径、语法、匹配检查失败或旧文件准备失败时，保留原始错误和 ABORTED 记录、清除活动批次、返回 IDLE，未发出任何目标控制命令。Prepare/Stage/Activate 失败或发布决定前取消时，停止后续阶段、Abort 所有已参与目标，不部署文件。文件部署或缓存清理失败时，先恢复本批已修改的文件并清理缓存，再 Abort 目标。全部确认恢复成功后返回 IDLE 并唤醒等待者；恢复失败或结果不明时进入 RECOVERY_REQUIRED/FAILED_LOCKED，保留 original_error 和 recovery_error，禁止新发布、创建及首次模块加载。

Finish 发生在文件已部署且所有 Activate 成功之后。某个目标 Finish 失败或结果不明时，继续尝试其余目标 Finish，逐项报告并保留 FAILED_LOCKED；不回滚已经 Finish 的目标，也不撤回新版文件。这是批量更新的收尾边界，不承诺严格跨 Service 原子性。

dry_run 使用 begin → 等待 DEPLOYING → dry_run → 查询 status，执行全部 Prepare/Stage/Activate 后 Abort 验证恢复，不准备或部署正式文件、不清理正式代码缓存。成功为 DRY_RUN_COMPLETED；检查或更新失败但全部恢复成功时保存 ABORTED 诊断并回到 IDLE；恢复失败时保留现有锁定。

status 不带 batch_id 返回生命周期概览；带 batch_id 还返回最近或当前批次 record。生命周期成功终态为 COMPLETED/DRY_RUN_COMPLETED，已恢复的失败为 IDLE，未确认恢复或 Finish 故障为 FAILED_LOCKED。record 保留实际步骤或终态、逐目标结果和原始诊断；仅保留活动及最近终态，不持久化历史。success/failed 统计实际参与目标的逐项结果，未参与目标不计数。整批已恢复的失败中，其他参与目标用 HU_BATCH_ABORTED 表示已尝试恢复，而不计为发布成功。

### 显式恢复确认

正常失败已由 HotUpgrade 确认恢复时不需要 resolve_deployment。仅在 FAILED_LOCKED 下，宿主先核实实际文件、运行时、目标 Guard/事务和缓存，完成必要的人工恢复或版本收敛，再使用现有确认：

~~~lua
local resolved = skynet.call(controller_handle, "hotupgrade", "resolve_deployment",
{
    batch_id = batch_id,
    confirmed = true,
    confirmation = "CONVERGED_CACHE_CLEARED",
})
assert(resolved.ok, resolved.message)
~~~

该命令只确认宿主声明，不执行目标恢复、Finish、文件部署或 Guard 释放。成功后回到 IDLE，保留原诊断。WAITING_CREATIONS/DEPLOYING 阶段取消仍使用同一确认接口，或携相同确认字段调用 abort；文件和运行时未变化、未发目标命令时可用 UNCHANGED。APPLYING 中 abort 只在发布决定前有效。RPC 报错不代表远端已取消，不能据此声称恢复成功。

本模块不支持 Service 替换、跨节点原子事务、运行中 coroutine 栈更新或 Native/C 热替换。业务仍需自行验证权威数据、持久化一致性和部署权限；重新执行旧 Patch 也不能恢复过去的数据库内容。

## 文件边界与验证

Native 提供 resolve(path[, relative_dir])、list_lua(patch_root, path) 和 Controller 内部使用的 read_file(root_path, relative_file)、replace_file(root_path, relative_file, source_or_nil)；相对目录检查与递归扫描共用路径安全校验，拒绝越界路径、链接及特殊文件。Controller 不设目标 Service、模块声明、Patch Lua 文件数或源码字节数硬上限；扫描与冻结规模由实际 Patch 和运行时可用资源决定。宿主在扫描/冻结期间保持 Patch 目录不变；扫描和读取不是抵抗并发目录替换的原子安全边界。冻结后更新和部署只使用本次源码，不重新读取发布包。正式目录应由本次 Controller 独占部署，不支持外部并发修改；文件操作沿用逐级路径检查，临时文件替换不提供跨文件磁盘原子性或断电恢复。replace_file 的 nil 内容仅用于删除本批原本不存在的新增文件；已有文件保留原权限，新文件使用 0644。

待创建记录也占用 Controller 内存。每个目标的同一模块仍同时只保留一项首次加载许可。登记和许可记录由当前 Controller 持有，不建立后台发现、自动超时清理或持久化恢复；宿主负责保持实际 Service 生命周期与控制面一致。Service 或调用方在关键区间异常退出、许可取消 RPC 无法送达时，屏障会保留；须核对实际状态并受控重启，不得假定操作已完成。

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

脚本测试创建中/待登记屏障、两种登记时序、启动与业务初始化失败、创建者取消权限、模块许可匹配/消费/失败清理、并发首次声明、活动批次拒绝，以及 Guard、完整模块增改删、私有状态迁移、Service 状态/函数组合提交、真实 handle/State/表身份保持、dry_run、Stage/Activate 整批恢复、纯文件发布、文件部署失败恢复、新实例与首次加载版本一致，以及 Finish 故障报告和恢复门禁。Skynet 集成只启动测试专用进程，不监听业务端口；结果不替代宿主真实业务状态与数据库验证。
