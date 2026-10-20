# FlyWow HotUpgrade 接入说明

HotUpgrade 在现存 Skynet Service、现存 Lua State 内更新受信 Lua 代码和必要业务状态。更新保持 Service handle、模块导出表和 Service 私有状态根表的身份。普通模块提交完整新版本；可选 Service 更新脚本在同一事务内迁移私有状态并直接替换指定业务函数。

## 启动与登记

宿主从 composition root 启动控制面，保存 handle，再通过 init 交付配置：

```lua
local hotupgrade = require "flywow_hotupgrade" -- 声明当前管理 State 的原生控制协议。
local controller_handle = skynet.newservice("flywow_hotupgrade_service")
local initialized = skynet.call(controller_handle, "lua", "init",
{
    patch_root = "./config/hotupgrade",
    root_path = ".",
    service_dir = "service",
    timeout_ms = 10000,
})
assert(initialized.ok, initialized.message)
```

以宿主 server 为工作目录时，在现有 Skynet 配置的 luaservice、lua_path、lua_cpath 中分别加入以下相对搜索项，并保留宿主原有路径：

- luaservice：./third_party/skynet-flywow/hotupgrade/service/?.lua
- lua_path：./third_party/skynet-flywow/hotupgrade/lualib/?.lua
- lua_cpath：./third_party/skynet-flywow/build/native/?.so

公开入口是 hotupgrade/lualib/flywow_hotupgrade.lua；控制 Service 入口是 hotupgrade/service/flywow_hotupgrade_service.lua。Controller 加载 flywow_hotupgrade_native 时，Lua 从 Native 搜索路径定位统一构建入口产出的 build/native/flywow_hotupgrade_native.so。每个发送 hotupgrade 协议管理消息的 State 都先加载公开入口以声明该协议，管理 State 无需登记为业务目标。

patch_root 必须存在且可读取。root_path 是已存在的宿主项目根目录，service_dir 是它下面已存在的相对 Service 目录；拒绝绝对路径、空路径段、.、..、反斜杠和符号链接目录。目录允许多级，例如 service/battle。

Controller 初始化成功时通过现有 Skynet 共享环境发布内部键 flywow_hotupgrade_root_path。须先完成 Controller init，再启动会调用 hotupgrade.require 的业务 Service。同一 Skynet 进程的 Controller 必须使用同一规范化 root_path；不一致时初始化失败。宿主不需要另行配置此内部环境键。

timeout_ms 是目标 Guard 等待在途业务排空的毫秒上限，默认 10000；它不是远端 RPC 取消期限。init 失败可修正后重试，成功后重复 init 返回 HU_ALREADY_INITIALIZED，初始化前控制请求返回 HU_NOT_INITIALIZED。

纳入 HotUpgrade 管理的 Service 必须由创建者使用受管理入口启动；Controller 自身和非受管理 Service 继续使用原生入口：

```lua
local handle = hotupgrade.newservice(controller_handle, "player", "原有启动参数")
-- newservice 仅转交原生启动参数，返回后不额外等待业务 init 或 register_service。
local called, initialized = pcall(skynet.call, handle, "lua", "init", player_config)
if not called or type(initialized) ~= "table" or not initialized.ok then
    -- 只可取消尚未登记的 Service；Controller 核验创建者、终止 Service 并清理待创建记录。
    local cancelled = hotupgrade.cancel_service_creation(controller_handle, handle)
    assert(cancelled.ok, tostring(cancelled.code) .. ": " .. tostring(cancelled.message))
    error(type(initialized) == "table" and initialized.message or tostring(initialized))
end
```

hotupgrade.newservice 会 yield，成功返回原生 handle，失败抛出含 HU_SERVICE_CREATE_FAILED（或入口拒绝码）的异常。原生创建失败自动释放记录；创建成功后的业务 init 由调用方负责。业务 init 应在所有可能失败的初始化工作完成后，最后调用 register_service，并把登记结果作为 init 的结果；成功后再宣布 READY。业务初始化在登记前失败时，原创建者必须显式调用 cancel_service_creation，不能仅丢弃 handle。取消返回统一结果，非创建者返回 HU_UNAUTHORIZED，未知/已取消的 handle 返回 HU_CREATION_MISSING，已登记 Service 返回 HU_SERVICE_ALREADY_REGISTERED 且不会被终止。若登记 RPC 结果不明或登记后又失败，取消可能被拒绝，须由宿主核对真实登记状态并处理受控终止/重启，不能把它当成仍未登记。

Controller 在调用原生 newservice 前建立待创建记录和不复用的进程内创建标识，实际启动内部 flywow_hotupgrade_bootstrap。引导在同一个 Lua State 内绑定创建身份，随后复用宿主配置的 Skynet loader 加载真实 Service，交付原业务参数以及正确的 SERVICE_NAME/SERVICE_PATH，不启动代理 Service、不接管业务 init。register_service 自动携带该内部身份；Controller 用它找到本次创建记录，以消息头真实 source 绑定 handle，并在原生调用返回时核对同一 handle。登记和原生启动都完成后才释放记录。若原生调用先返回，记录按返回 handle 保留至该来源登记或创建者取消。未知来源的 register 返回 HU_CREATION_MISSING，重复登记返回 HU_DUPLICATE_SERVICE。记录不会自动超时清除，漏掉登记或取消会持续关闭发布入口。

内部文件为 hotupgrade/service/flywow_hotupgrade_bootstrap.lua 和 hotupgrade/lualib/flywow_hotupgrade_creation.lua，沿用现有 Service/Lua 搜索路径。创建身份仅用于受信进程内关联，不是远程认证。标准 Skynet loader 下保留同一个 Lua State、真实业务 SERVICE_NAME/SERVICE_PATH 及原生空白分隔的启动参数语义。

**非空 preload 不受支持。** 原生 loader 会在 Bootstrap 入口执行前运行 LUA_PRELOAD，此时它只能看到内部引导名称与参数。Controller 因此在建立创建记录和实际启动 Service 之前检查 skynet.getenv("preload")，非空时返回 HU_PRELOAD_UNSUPPORTED；不会先执行错误的 preload 再跳过真实业务初始化。普通原生 Service 不受影响。自定义 lualoader 仍须由宿主核对兼容性，本模块只保证标准 Skynet loader 合同。

### 受管理唯一服务

```lua
local local_handle = hotupgrade.uniqueservice(controller_handle, "player", "原生启动参数")
local global_handle = hotupgrade.uniqueservice(controller_handle, true, "player", "原生启动参数")
```

两种入口会 yield，并遵循与 newservice 相同的登记、业务 init 失败取消和发布排队合同。本地逻辑名与全局逻辑名分别对应原生 service_mgr 中的 name 和 @name；snaxd 沿用原生子名键和 snax init 参数交付语义；重复调用返回同一 handle，首次调用的启动参数生效，不同逻辑名可启动不同 Service。唯一性不使用内部 Bootstrap 名作为键，也不由 Controller 的 Lua 表模拟全局注册表。一个逻辑唯一键只能属于一个 Controller；其他 Controller 不能接管该目标。不要用普通原生入口提前占用同一逻辑名。

受管理唯一服务要求在启动 Skynet 前，对固定 Skynet v1.8.0 的 service/service_mgr.lua 应用随模块交付的最小补丁：

```bash
patch -d <Skynet根目录> -p1 < <FlyWow根目录>/hotupgrade/patches/skynet_service_mgr.patch
```

补丁增加 MANAGED_LAUNCH/GMANAGED_LAUNCH 和配对释放命令，复用原生注册表、等待协程及 SERVICE 全局节点路由，将逻辑唯一键与实际启动入口分离。普通 LAUNCH/GLAUNCH/QUERY 的既有入口保留。受管理启动失败会撤销唯一名预留；创建者合法取消未登记 Service 时，由实际承载该预留的管理器就地终止 Service 并释放预留，允许重试；Controller 不会在本地误用远端 handle 执行 kill。取消发起后，该创建记录先禁止登记（HU_CREATION_CANCELLED），覆盖远端终止 RPC 的 yield 窗口；确认失败时保留记录供原创建者重试，不自动放行。不能只修改一个节点：涉及全局唯一服务时，所有参与节点必须使用此补丁、相同框架/业务搜索路径和部署版本，并在实际承载业务 Service 的节点完成 root_path 配置。跨节点行为依赖现有 Skynet harbor/SERVICE 拓扑，不新增全局协调系统。宿主部署和 cache.clear 必须覆盖所有实际承载目标或后续创建的节点，单个进程的 cache.clear 不会清除另一节点的缓存。

原生唯一服务允许已有 QUERY 等待者先等待逻辑名；补丁复用该等待记录。管理器支持未安装或版本不匹配时会导致受管理唯一创建明确失败，Controller 清理本次创建意图；不会回退成非唯一 newservice。集成测试脚本只在自己的 build 目录生成应用补丁的 service_mgr 副本，不修改外部 Skynet 工作树。

在受管理业务 Service 自己的 Lua State 登记：

```lua
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
    controller_handle = controller_handle,
    service_module = "player",
    service_update = {state = state, functions = M},
    after_upgrade = function()
        return state.level >= 0
    end,
})
assert(registered.ok, registered.message)
```

service_module 对应 service_dir 下的相对 Lua 路径：去掉 .lua 并将 / 转为 .。例如 service_dir 为 service 时，service/player.lua 对应 player，service/battle/worker.lua 对应 battle.worker。service_update 可省略，此时该 Service 只参与普通模块更新。Controller 使用注册消息真实 source 作为目标 handle；私有状态、函数和回调留在业务 State，不经消息传给 Controller。登记成功前宿主不得宣布 Service READY；登记 RPC 失败可能有不确定结果，应终止该次启动，由宿主管理，而不是继续接收业务。

hotupgrade.require(name) 仍用宿主原有 name 加载模块，通过 package.searchpath(name, package.path) 定位 Lua 文件，再复用 Native resolve 得到规范化路径。Controller 登记名由该文件相对 root_path 的路径去掉 .lua、将 / 转为 . 得到。例如原调用 hotupgrade.require("battle.state_sync.runtime") 加载 lualib/battle/state_sync/runtime.lua，登记名为 lualib.battle.state_sync.runtime；不是给原 name 固定增加目录前缀。?/init.lua 解析出的文件也按真实路径登记，例如 lualib/battle/init.lua 对应 lualib.battle.init。

原 require 名和文件登记名在 package.loaded 中指向同一个模块根表，热更和恢复都通过同一根表对两种名称生效。只有首次通过 hotupgrade.require 确认加载来源的模块表才允许复用；先经普通 require 加载而没有来源记录的缓存模块会被明确拒绝，即使原名恰好等于文件登记名。须从首次加载时就使用 hotupgrade.require，不要清空已有业务缓存来绕过检查。建立别名前同时检查原名来源、文件登记名缓存和 package.preload；冲突时明确拒绝，不覆盖已有缓存或预加载器。加载、来源验证或动态登记失败会恢复本次涉及的原名缓存和规范别名，撤销本次新增的来源映射及声明计数，保留操作前已有的合法缓存，允许重试。仅支持通过标准 package.path 搜索的 Lua 文件；package.preload、自定义加载器来源不一致、无法定位文件或文件位于 root_path 外时明确拒绝。宿主应保持受控模块的搜索路径稳定，不在已加载后改写其加载来源。

登记前声明随初始元数据提交，由待创建记录保护。register_service 会拒绝本 State 尚在执行的首次声明（HU_LIFECYCLE_PENDING），调用方须待声明完成后登记；登记 RPC 期间的新声明等待登记结果，避免落在初始模块快照之外。

已登记 Service 首次声明模块时，先向 Controller 请求 begin_module_load 许可，再执行实际 require、校验来源并建立缓存、别名、来源映射和本地声明，最后携许可 ID 调用 register_module。许可绑定真实来源及规范模块名，不能转用或重复消费；失败时回退本地新增状态，并通过 cancel_module_load 释放尚未完成的许可。许可未完成前禁止启动新批次，覆盖模块执行及登记的整个关键区间。同一 State 内并发首次声明同一规范模块会等待前一项成功或完整回退；已声明模块不重复请求许可。Controller 只更新目标已声明的模块。begin 之后不再批准新的首次加载许可（HU_UPGRADE_BUSY；失败锁定时为 HU_DEPLOYMENT_BLOCKED）。既有许可仍可完成或取消，既有创建仍可在 WAITING_CREATIONS 登记；新的受管理创建进入等待队列，不会实际启动。

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

WAITING_CREATIONS、DEPLOYING、APPLYING 期间的新建及唯一服务请求排队，尚未进入原生启动。成功后唤醒等待者再启动；发布失败时唤醒并返回 HU_DEPLOYMENT_BLOCKED，即使稍后完成恢复，也不会把已经经历失败的等待请求自动重试。业务调用方必须处理此异常。成功终态允许下一次 begin，也允许新的创建和首次模块声明。

apply/dry_run 必须携带当前 begin 的 batch_id，且仅在 DEPLOYING 接受一次；过期或缺失身份返回 HU_BATCH_MISSING，阶段不匹配返回 HU_DEPLOYMENT_PHASE，WAITING_CREATIONS 返回 HU_LIFECYCLE_PENDING。重复 begin 返回 HU_UPGRADE_BUSY；FAILED_LOCKED 统一拒绝新发布和创建。apply 接受时冻结 Patch 源码并固定已登记目标集合，沿用现有事务执行。Patch 路径/匹配等校验失败同样锁定发布：宿主可能已部署文件，不能静默重新放行创建。

validate 仅同步冻结/校验 Patch，不创建发布批次、不向目标发控制 RPC。它在待创建或待许可时返回 HU_LIFECYCLE_PENDING，APPLYING 时返回 HU_DEPLOYMENT_PHASE，失败锁定时返回 HU_DEPLOYMENT_BLOCKED。每个 Patch 文件都必须匹配已登记目标，否则 HU_TARGET_MISSING；Service 不支持内部更新时返回 HU_SERVICE_PATCH_UNSUPPORTED。validate 可在 IDLE 预检，也可在当前 DEPLOYING 阶段预检，但其成功不能替代 begin 屏障。

**dry_run** 使用同样的 begin → 等待 DEPLOYING → dry_run 流程，携带同一批次号；宿主不得在其中部署新版文件或调用 skynet.cache.clear()。dry-run 真正执行目标更新和 abort 恢复，只有所有目标确认恢复、进入 DRY_RUN_COMPLETED 后才解除创建屏障。任何失败均进入 FAILED_LOCKED。

status 不带 batch_id 返回生命周期概览；带 batch_id 还返回 record。lifecycle 包含 phase、batch_id、pending_creations、pending_module_loads、failed_locked、active_batch_id、recovery_required。record.phase 表示具体事务步骤或终态；lifecycle.phase 表示发布门禁。仅保留活动与最近终态批次，未知/过旧身份仍为 HU_BATCH_MISSING。进程内状态不持久化；Controller 重启不是恢复确认手段。

### 显式恢复确认

COMPLETED 和 DRY_RUN_COMPLETED 自动开放创建。PARTIAL、ABORTED、RECOVERY_REQUIRED 均保持 FAILED_LOCKED，不自动重试更新，也不声称运行中的 Service 已同版本。宿主必须先检查逐目标结果、真实版本、宿主文件和外部业务数据，完成实际恢复或版本收敛，并在文件回滚/收敛后执行 skynet.cache.clear()。随后才可以请求：

```lua
local resolved = skynet.call(controller_handle, "hotupgrade", "resolve_deployment",
{
    batch_id = batch_id,
    confirmed = true,
    confirmation = "CONVERGED_CACHE_CLEARED",
})
assert(resolved.ok, tostring(resolved.code) .. ": " .. tostring(resolved.message))
```

该命令要求匹配批次和明确确认，随后向已登记目标查询内部 deployment_status；任何目标仍有未完成事务、Guard owner，或状态无法取得时，返回 HU_RECOVERY_REQUIRED 并保持门禁。它不会执行 abort/finish、强制清除目标 Guard、修复业务数据或验证文件内容；宿主确认是管理者对实际版本一致性的明确承诺。目标恢复失败必须先由宿主修复其实际状态；若需要受控进程重启，必须按宿主完整启动与版本恢复流程重建管理状态，不能只重启 Controller 绕过失败。确认成功将生命周期回到 IDLE，并标注最近 record.resolved，保留原失败诊断。

发布前取消（WAITING_CREATIONS/DEPLOYING）也通过 resolve_deployment，或携同样确认字段调用 abort：宿主文件确实未变更时使用 confirmed=true、confirmation="UNCHANGED"；如果已经部署过文件，必须先回滚并清理 cache，再使用 "CONVERGED_CACHE_CLEARED"。缺少确认返回 HU_RECOVERY_CONFIRMATION_REQUIRED。APPLYING 中的 abort 沿用原事务取消语义；其 ABORTED/PARTIAL 结果仍锁定，必须实际恢复后再确认。

各目标按 handle 顺序逐个执行：

1. prepare 关闭 Guard 并排空业务。
2. stage 检查所有目标模块、迁移私有模块状态并准备可选 Service 更新，线上代码和状态不变。
3. activate 在目标一次同步处理内提交全部模块和 Service 更新，执行可选 after_upgrade；false/异常触发立即组合恢复。
4. apply 达到 PUBLISH_DECIDED 后执行 finish，释放旧快照并开放入口；dry_run 则实际提交后 abort，验证恢复并回到旧代码/状态。

发布决定前可请求 abort，Controller 在当前步骤返回后恢复目标；已完成目标不会自动撤销，跨 Service 批次不承诺全局原子性。结果 phase 为 COMPLETED、DRY_RUN_COMPLETED、ABORTED、PARTIAL 或 RECOVERY_REQUIRED；success/failed 表示处理成功和失败目标数，results 给出实际尝试目标的逐项结果。未尝试的目标不计入成功/失败。dry_run 的 success 表示更新及恢复验证成功。

任一恢复或发布后结果无法确认时，目标保持 Guard 暂停，Controller 设置 recovery_required 并拒绝新发布。RPC 失败/超时不等于远端取消；不要重新假定旧代码已恢复。宿主必须核对目标实际状态和业务外部数据，完成人工恢复或受控重启；resolve_deployment 仅在宿主已完成实际恢复且目标 Guard/事务无遗留时确认解除门禁。

本模块不支持 Service 替换、跨节点原子事务、运行中 coroutine 栈更新或 Native/C 热替换。业务仍需自行验证权威数据、持久化一致性和部署权限；重新执行旧 Patch 也不能恢复过去的数据库内容。

## 文件边界与验证

Native 提供 resolve(path[, relative_dir]) 和 list_lua(patch_root, path)；相对目录检查与递归扫描共用路径安全校验，拒绝越界路径、链接及特殊文件。扫描限制整个选定 Patch 最多 1024 个 Lua 文件、单文件 2 MiB，整包读取累计最多 16 MiB。宿主在扫描/冻结期间保持 Patch 目录不变；扫描和读取不是抵抗并发目录替换的原子安全边界。冻结后目标只使用本次源码，不重新读取磁盘。

Controller 最多登记 1024 个目标，每目标最多声明 1024 个模块；达到上限返回 HU_TARGET_LIMIT/HU_MODULE_LIMIT。待创建记录也占用目标容量；每目标同时最多保留 1024 项模块加载许可，同一模块同时只保留一项。登记和许可记录由当前 Controller 持有，不建立后台发现、自动超时清理或持久化恢复；宿主负责保持实际 Service 生命周期与控制面一致。Service 或调用方在关键区间异常退出、许可取消 RPC 无法送达时，屏障会保留；须核对实际状态并受控重启，不得假定操作已完成。

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

脚本测试创建中/待登记屏障、两种登记时序、启动与业务初始化失败、创建者取消权限、模块许可匹配/消费/失败清理、并发首次声明、活动批次拒绝，以及 Guard、完整模块增改删、私有状态迁移、Service 状态/函数组合提交、真实 handle/State/表身份保持、dry_run、Stage/Activate 失败恢复、部分成功和恢复门禁。Skynet 集成只启动测试专用进程，不监听业务端口；结果不替代宿主真实业务状态与数据库验证。
