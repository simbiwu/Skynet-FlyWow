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

service_module 对应 service_dir 下的相对 Lua 路径：去掉 .lua 并将 / 转为 .。例如 service_dir 为 service 时，service/player.lua 对应 player，service/battle/worker.lua 对应 battle.worker。service_update 可省略，此时该 Service 只参与普通模块更新。Controller 使用注册消息真实 source 作为目标 handle；私有状态、函数和回调留在业务 State，不经消息传给 Controller。登记成功前宿主不得宣布 Service READY；登记 RPC 失败可能有不确定结果，应终止该次启动，由宿主管理，而不是继续接收业务。

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
    battle/worker.lua
```

Patch 内部路径对应宿主 root_path 下的实际路径。递归扫描本次 path 下所有 Lua 文件；仅配置 service_dir 及其子目录识别为 Service Patch，其余 Lua 文件都作为普通模块，包括 config、lualib 和其他宿主目录。service_dir 为 service 时，上例两个 Service 脚本分别匹配 player、battle.worker；普通模块分别匹配 config.settings、lualib.player_logic、lualib.battle.state_sync.runtime。目录中的非 Lua 普通文件忽略，符号链接和特殊文件一律拒绝；不同路径映射到同一模块名或 Service 类型时拒绝整包。

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

service_dir 为 service 时，service/player.lua 返回构建函数，接收现存 Service 私有 state 根表：

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

## 发布生命周期、宿主部署与恢复

生命周期为 IDLE → WAITING_CREATIONS → DEPLOYING → APPLYING → COMPLETED 或 DRY_RUN_COMPLETED。任意发布失败进入 FAILED_LOCKED，原有批次 record.phase 仍保留 ABORTED、PARTIAL、RECOVERY_REQUIRED 等事务结果；不能仅因 self.active 已清空就认为所有 Service 版本一致。

宿主必须串行执行完整发布流程：

```lua
local begun = skynet.call(controller_handle, "hotupgrade", "begin", {})
assert(begun.ok, tostring(begun.code) .. ": " .. tostring(begun.message))
local batch_id = begun.batch_id
while true do
    local status = skynet.call(controller_handle, "hotupgrade", "status", {batch_id = batch_id})
    assert(status.ok, status.message)
    if status.lifecycle.phase == "DEPLOYING" then break end
    assert(status.lifecycle.phase == "WAITING_CREATIONS", status.lifecycle.phase)
    skynet.sleep(1)
end

-- 由宿主在此部署完整新版文件到 root_path，并确认部署完整成功。
-- 完成文件部署后，再清除宿主 Skynet 代码加载缓存。
skynet.cache.clear()
local started = skynet.call(controller_handle, "hotupgrade", "apply",
    {batch_id = batch_id, path = "current"})
assert(started.ok, tostring(started.code) .. ": " .. tostring(started.message))
-- 继续轮询同一 batch_id 的 status，直到成功终态或 FAILED_LOCKED。
```

begin 分配唯一批次号，立即返回 WAITING_CREATIONS；异步等待 creation_count 和 module_load_count 均为零后才进入 DEPLOYING。不会等待同步创建完成，不自动超时删除记录。begin 前已经接纳的创建允许登记，许可允许完成或取消。遗漏登记/取消时会持续等待，必须由原创建者处理，宿主此时不能部署文件。

WAITING_CREATIONS、DEPLOYING、APPLYING 期间的新创建、未建立实例的本地唯一请求及首次模块加载请求排队，尚未进入原生启动或模块执行。成功后唤醒等待者再启动；发布失败时唤醒并返回 HU_DEPLOYMENT_BLOCKED，即使稍后完成恢复，也不会把已经经历失败的等待请求自动重试。业务调用方必须处理此异常。成功终态允许下一次 begin，也允许新的创建和首次模块声明。

apply/dry_run 必须携带当前 begin 的 batch_id，且仅在 DEPLOYING 接受一次；过期或缺失身份返回 HU_BATCH_MISSING，阶段不匹配返回 HU_DEPLOYMENT_PHASE，WAITING_CREATIONS 返回 HU_LIFECYCLE_PENDING。重复 begin 返回 HU_UPGRADE_BUSY；FAILED_LOCKED 统一拒绝新发布和创建。apply 接受时冻结 Patch 源码并固定已登记目标集合，沿用现有事务执行。正式 apply 的 Patch 路径/匹配等校验失败同样锁定发布：宿主可能已部署文件，不能静默重新放行创建。

正式发布只使用 begin → 等待 DEPLOYING → 部署完整文件 → 清理 Skynet 代码缓存 → apply → 查询 status。dry_run 使用 begin → 等待 DEPLOYING → dry_run → 查询 status，不部署宿主文件，也不清理宿主代码缓存。apply 和 dry_run 在调用时都会通过现有 Controller:load() 完整读取、冻结并校验 Patch，包含路径、语法、目标匹配和整包完整性；不再提供独立 Patch 预检管理命令。

**dry_run** 使用 begin → 等待 DEPLOYING → dry_run，携带同一批次号；宿主不得部署新版文件或清理宿主代码缓存。路径、读取、语法、匹配等前置失败若尚未向目标发控制命令，会返回原始错误，保存 ABORTED 诊断并直接回到 IDLE，释放等待请求，不要求宿主作版本收敛确认。已经发送目标命令后，沿用现有 Stage/Abort 流程：正常完成且全部恢复时为 DRY_RUN_COMPLETED；更新失败但所有尝试目标均已确认恢复时保留 ABORTED/PARTIAL 原始诊断并回到 IDLE。任一恢复失败进入 FAILED_LOCKED，结果保留 original_error 和 recovery_error，不自动开放创建。正式 apply 不使用这些 dry-run 特例。

status 不带 batch_id 返回生命周期概览；带 batch_id 还返回 record。lifecycle 包含 phase、batch_id、pending_creations、pending_module_loads、failed_locked、active_batch_id、recovery_required。record.phase 表示具体事务步骤或终态；lifecycle.phase 表示发布门禁。仅保留活动与最近终态批次，未知/过旧身份仍为 HU_BATCH_MISSING。进程内状态不持久化；Controller 重启不是恢复确认手段。

### 显式恢复确认

COMPLETED 和 DRY_RUN_COMPLETED 自动开放创建。除上述没有运行时遗留的 dry-run 特例，PARTIAL、ABORTED、RECOVERY_REQUIRED 均保持 FAILED_LOCKED，不自动重试更新，也不声称运行中的 Service 已同版本。宿主必须先检查逐目标结果、真实版本、宿主文件和外部业务数据，完成实际恢复或版本收敛，并在文件回滚/收敛后执行 skynet.cache.clear()。随后才可以请求：

```lua
local resolved = skynet.call(controller_handle, "hotupgrade", "resolve_deployment",
{
    batch_id = batch_id,
    confirmed = true,
    confirmation = "CONVERGED_CACHE_CLEARED",
})
assert(resolved.ok, tostring(resolved.code) .. ": " .. tostring(resolved.message))
```

该命令只校验批次号、当前门禁状态、confirmed 和 confirmation，不向目标发送状态/恢复 RPC，也不验证宿主文件或业务数据。CONVERGED_CACHE_CLEARED 是宿主对实际运行版本、文件及必要缓存清理已完成的明确承诺，不能代替实际恢复。确认不会执行 abort/finish 或清除目标 Guard；任何尚未完成的目标恢复必须由宿主先处理。确认成功将生命周期回到 IDLE、唤醒等待请求并标注最近 record.resolved，保留原失败诊断。

发布前取消（WAITING_CREATIONS/DEPLOYING）也通过 resolve_deployment，或携同样确认字段调用 abort。UNCHANGED 仅适用于宿主文件未变更、尚未向任何目标发控制命令、运行时未发生变更的情况；Controller 拒绝对 control_started=true 的批次使用此确认。文件确实未变更由宿主负责确认；已经覆盖过文件时，须先恢复/收敛版本并清理必要缓存，再使用 CONVERGED_CACHE_CLEARED。缺少确认返回 HU_RECOVERY_CONFIRMATION_REQUIRED。APPLYING 中的 abort 沿用原事务取消语义；正式 apply 的 ABORTED/PARTIAL 结果仍锁定，实际恢复后再确认。

各目标按 handle 顺序逐个执行：

1. prepare 关闭 Guard 并排空业务。
2. stage 检查所有目标模块、迁移私有模块状态并准备可选 Service 更新，线上代码和状态不变。
3. activate 在目标一次同步处理内提交全部模块和 Service 更新，执行可选 after_upgrade；false/异常触发立即组合恢复。
4. apply 达到 PUBLISH_DECIDED 后执行 finish，释放旧快照并开放入口；dry_run 则实际提交后 abort，验证恢复并回到旧代码/状态。

发布决定前可请求 abort，Controller 在当前步骤返回后恢复目标；已完成目标不会自动撤销，跨 Service 批次不承诺全局原子性。结果 phase 为 COMPLETED、DRY_RUN_COMPLETED、ABORTED、PARTIAL 或 RECOVERY_REQUIRED；success/failed 表示处理成功和失败目标数，results 给出实际尝试目标的逐项结果。未尝试的目标不计入成功/失败。dry_run 的 success 表示更新及恢复验证成功。

任一恢复或发布后结果无法确认时，目标保持 Guard 暂停，Controller 设置 recovery_required 并拒绝新发布。RPC 失败/超时不等于远端取消；不要重新假定旧代码已恢复。宿主必须核对目标实际状态和业务外部数据，完成人工恢复或受控重启；resolve_deployment 仅在宿主已完成实际恢复且目标 Guard/事务无遗留时确认解除门禁。

本模块不支持 Service 替换、跨节点原子事务、运行中 coroutine 栈更新或 Native/C 热替换。业务仍需自行验证权威数据、持久化一致性和部署权限；重新执行旧 Patch 也不能恢复过去的数据库内容。

## 文件边界与验证

Native 提供 resolve(path[, relative_dir]) 和 list_lua(patch_root, path)；相对目录检查与递归扫描共用路径安全校验，拒绝越界路径、链接及特殊文件。Controller 不设目标 Service、模块声明、Patch Lua 文件数或源码字节数硬上限；扫描与冻结规模由实际 Patch 和运行时可用资源决定。宿主在扫描/冻结期间保持 Patch 目录不变；扫描和读取不是抵抗并发目录替换的原子安全边界。冻结后目标只使用本次源码，不重新读取磁盘。

待创建记录也占用 Controller 内存。每个目标的同一模块仍同时只保留一项首次加载许可。登记和许可记录由当前 Controller 持有，不建立后台发现、自动超时清理或持久化恢复；宿主负责保持实际 Service 生命周期与控制面一致。Service 或调用方在关键区间异常退出、许可取消 RPC 无法送达时，屏障会保留；须核对实际状态并受控重启，不得假定操作已完成。

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

脚本测试创建中/待登记屏障、两种登记时序、启动与业务初始化失败、创建者取消权限、模块许可匹配/消费/失败清理、并发首次声明、活动批次拒绝，以及 Guard、完整模块增改删、私有状态迁移、Service 状态/函数组合提交、真实 handle/State/表身份保持、dry_run、Stage/Activate 失败恢复、部分成功和恢复门禁。Skynet 集成只启动测试专用进程，不监听业务端口；结果不替代宿主真实业务状态与数据库验证。
