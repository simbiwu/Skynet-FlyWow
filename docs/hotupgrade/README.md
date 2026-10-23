# FlyWow HotUpgrade 接入说明

贯穿 PlayerService V1/V2 发布的可运行流程见 [HotUpgrade Sample](../../hotupgrade/sample/README.md)。

HotUpgrade 在现存 Skynet Service、现存 Lua State 内更新受信 Lua 代码和必要业务状态。更新保持 Service handle、模块导出表和 Service 私有状态根表的身份。普通模块提交完整新版本；可选 Service 更新脚本在同一事务内迁移私有状态并直接替换指定业务函数。

## 启动与登记

宿主从 composition root 启动控制面，保存 handle，再通过 init 交付配置：

```lua
skynet.start(function()
    local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hotupgrade = require "flywow_hotupgrade"
    local initialized = skynet.call(hotupgrade_handle, "lua", "init",
    {
        patch_path = "./config/hotupgrade",
        root_path = ".",
        service_path = "service",
    })
    assert(initialized.ok, initialized.message)
    -- 在此之后再启动受管理业务 Service。
end)
```

以宿主 server 为工作目录时，在现有 Skynet 配置的 luaservice、lua_path、lua_cpath 中分别加入以下相对搜索项，并保留宿主原有路径：

- luaservice：./third_party/skynet-flywow/hotupgrade/service/?.lua
- lua_path：./third_party/skynet-flywow/hotupgrade/lualib/?.lua
- lua_cpath：./third_party/skynet-flywow/build/native/?.so

公开入口是 hotupgrade/lualib/flywow_hotupgrade.lua；控制 Service 入口是 hotupgrade/service/flywow_hotupgrade_service.lua。Controller 加载 flywow_hotupgrade_native 时，Lua 从 Native 搜索路径定位统一构建入口产出的 build/native/flywow_hotupgrade_native.so。宿主先在 composition root 初始化 Controller 并确认成功，再创建受管理业务 Service。业务 Service 可以在文件顶部 require 公开入口并调用 hotupgrade.require()；这两步不会获取 Controller handle 或执行 RPC。Controller handle 仅在首次实际需要 RPC 时通过原生 skynet.uniqueservice() 获取并缓存。register_service() 会发送登记 RPC，必须在可 yield 的 Skynet 协程内调用。管理 State 无需登记为业务目标。

patch_path 必须存在且可读取。root_path 是已存在的宿主项目根目录，service_path 是它下面已存在的相对 Service 目录；拒绝绝对路径、空路径段、.、..、反斜杠和符号链接目录。目录允许多级，例如 service/battle。

Controller 初始化成功时通过现有 Skynet 共享环境发布内部键 flywow_hotupgrade_root_path。须先完成 Controller init，再启动会调用 hotupgrade.require 的业务 Service。同一 Skynet 进程的 Controller 必须使用同一规范化 root_path；不一致时初始化失败。宿主不需要另行配置此内部环境键。

init 失败可修正后重试，成功后重复 init 返回 HU_ALREADY_INITIALIZED，初始化前控制请求返回 HU_NOT_INITIALIZED。

纳入 HotUpgrade 管理的 Service 必须由创建者使用受管理入口启动；Controller 自身和非受管理 Service 继续使用原生入口。宿主可通过原生 uniqueservice 获取相同 handle，用于 begin/status 等管理命令；业务 Service 的 HotUpgrade API 不再接收 handle：

```lua
local service_handle = hotupgrade.newservice("player_service", "原有启动参数")
-- newservice 仅转交原生启动参数，返回后不额外等待业务 init 或 register_service。
local called, initialized = pcall(skynet.call, service_handle, "lua", "init", player_config)
if not called or type(initialized) ~= "table" or not initialized.ok then
    -- 只可取消尚未登记的 Service；Controller 核验创建者、终止 Service 并清理待创建记录。
    local cancelled = hotupgrade.cancel_service_creation(service_handle)
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
local service_handle = hotupgrade.uniqueservice("player", zone_id)
-- 明确拒绝：抛出含 HU_GLOBAL_UNIQUESERVICE_UNSUPPORTED 的异常，不启动 Service。
local global_service_handle = hotupgrade.uniqueservice(true, "player", zone_id)
```

唯一键是本 Controller 内的原始逻辑 Service 名称。首次创建先通过当前接纳门禁，再建立该名称的在途预留并复用受管理 newservice 流程；同名并发请求等待同一创建结果，原生创建返回后一起取得相同 handle。只有首次请求的启动参数生效，后续重复请求的参数不改变实例。不同名称可启动不同 Service；已有 handle 即使在发布期间也直接返回。排空和 Prepare 期间，新逻辑键可正常创建；进入 Update 后，新逻辑键等待发布结束，恢复时则等待版本确认收敛。等待门禁恢复后重查唯一名，避免并发请求各自创建。

该映射仅属于一个 Controller，不与原生 uniqueservice 的名称空间互通，不承诺跨 Controller、跨进程或跨节点唯一。全局 true 重载始终在实际启动前拒绝。snaxd 不满足受管理 Service 自行调用 register_service 的登记合同，入口返回 HU_SPECIAL_SERVICE_UNSUPPORTED，不增加 Snax 专用初始化流程；newservice 同样拒绝 snaxd。

首次创建失败时释放创建记录和唯一名预留，唤醒同一次创建的等待者返回错误，后续请求可重试。原创建者合法取消尚未登记的 Service 时，在原生终止成功后释放该唯一名。成功登记后不能取消创建。Controller 使用 Skynet 原生 MONITOR 清理退出 Service 的登记和本地唯一映射；同名 hotupgrade.uniqueservice() 后续调用会重新创建实例。MONITOR 是进程级单例；若初始化时已被占用，Controller 返回 HU_MONITOR_OCCUPIED，不覆盖现有监视器。FlyWow 仅使用现有 Skynet 接口，不修改 Skynet 框架源码。

在受管理业务 Service 自己的 Lua State 登记。公开模块和业务模块可在文件顶部加载；`register_service()` 会执行登记 RPC，因此放在 Skynet 可 yield 的启动协程内：

```lua
skynet.start(function()
local hotupgrade = require "flywow_hotupgrade"
local business_queue = require "skynet.queue"()
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
    service_update = {state = state, functions = M},
    before_upgrade = function()
        return business_queue(function() return true end)
    end,
    after_upgrade = function()
        return state.level >= 0
    end,
})
assert(registered.ok, registered.message)
end)
```

Controller 使用 newservice()/uniqueservice() 创建记录中的 service_name 匹配 service_path 下的一次性 .patch。service_path 为 service 时，service/player_service.patch 对应 player_service，service/battle/worker.patch 对应 battle/worker；嵌套目录以斜杠保留为 Skynet Service 名称，因为 loader 会将该名称原样替换进 LUA_SERVICE 路径模板；因此 battle/worker 对应嵌套文件，battle.worker 则对应名为 battle.worker 的平铺文件。登记请求不重复携带 Service 名称。service_update 可省略，此时该 Service 只参与普通模块更新。Controller 使用注册消息真实 source 作为目标 handle；私有状态、函数和回调留在业务 State，不经消息传给 Controller。登记成功前宿主不得宣布 Service READY；登记 RPC 失败可能有不确定结果，应终止该次启动，由宿主管理，而不是继续接收业务。

hotupgrade.require(name) 仍用宿主原有 name 加载模块，通过 package.searchpath(name, package.path) 定位 Lua 文件，再复用 Native resolve 得到规范化路径。Controller 登记名由该文件相对 root_path 的路径去掉 .lua、将 / 转为 . 得到。例如原调用 hotupgrade.require("battle.state_sync.runtime") 加载 lualib/battle/state_sync/runtime.lua，登记名为 lualib.battle.state_sync.runtime；不是给原 name 固定增加目录前缀。?/init.lua 解析出的文件也按真实路径登记，例如 lualib/battle/init.lua 对应 lualib.battle.init。

原 require 名和文件登记名在 package.loaded 中指向同一个模块根表，热更和恢复都通过同一根表对两种名称生效。只有首次通过 hotupgrade.require 确认加载来源的模块表才允许复用；先经普通 require 加载而没有来源记录的缓存模块会被明确拒绝，即使原名恰好等于文件登记名。须从首次加载时就使用 hotupgrade.require，不要清空已有业务缓存来绕过检查。建立别名前同时检查原名来源、文件登记名缓存和 package.preload；冲突时明确拒绝，不覆盖已有缓存或预加载器。加载、来源验证或动态登记失败会恢复本次涉及的原名缓存和规范别名，撤销本次新增的来源映射及声明计数，保留操作前已有的合法缓存，允许重试。仅支持通过标准 package.path 搜索的 Lua 文件；package.preload、自定义加载器来源不一致、无法定位文件或文件位于 root_path 外时明确拒绝。宿主应保持受控模块的搜索路径稳定，不在已加载后改写其加载来源。

登记前声明随初始元数据提交，由待创建记录保护。register_service 会拒绝本 State 尚在执行的首次声明（HU_LIFECYCLE_PENDING），调用方须待声明完成后登记；登记 RPC 期间的新声明等待登记结果，避免落在初始模块快照之外。

已登记 Service 首次声明模块时，先向 Controller 请求 begin_module_load 许可，再执行实际 require、校验来源并建立缓存、别名、来源映射和本地声明，最后携许可 ID 调用 register_module。许可绑定真实来源及规范模块名，不能转用或重复消费；失败时回退本地新增状态，并通过 cancel_module_load 释放尚未完成的许可。begin 接受后等待已有许可完成，覆盖模块执行及登记的整个关键区间。同一 State 内并发首次声明同一规范模块会等待前一项成功或完整回退；已声明模块不重复请求许可。Controller 只更新目标已声明的模块。begin 后的 WAITING_CREATIONS 和 PREPARE 窗口继续接纳创建与首次声明，覆盖父子创建、嵌套 require 和 queue 内已有业务的正常依赖。创建计数保留到初始化、登记完成；首次声明许可保留到登记或取消。进入 UPDATE 后的新请求才挂起等待终态，此时尚不发许可、不执行模块代码，也不增加本批排空计数；失败锁定仍返回 HU_DEPLOYMENT_BLOCKED。同一规范模块的等待者继续复用本 State 的并发声明协调。

## 业务 queue 与安全点

业务 Service 自己持有 queue。所有读写受控状态的入口先检查公开字段 hot.patching，再立即进入同一个 queue，中间不得 yield：

~~~lua
local hot = require "flywow_hotupgrade"
local business_queue = require "skynet.queue"()

local function attack(item)
    if hot.patching then
        return {ok = false, code = "HU_UPGRADING"}
    end
    return business_queue(function()
        return {ok = true, attack = business.load(item)}
    end)
end
~~~

业务返回值和异常由业务自己定义。HotUpgrade 不管理 queue、不包装业务返回值，也不计数业务协程。queue 内的业务可以正常 yield；脱离该 queue 的协程不在排空保证范围内。

register_service 必须提供 before_upgrade 函数；缺失或非函数会在登记时以 HU_INVALID_OPTIONS 拒绝。每次 Prepare 建立本地事务并设置 hot.patching=true 后都会调用该回调。回调允许 yield，必须通过上述同一个 queue 等待此前已进入的业务全部退出，例如 return business_queue(function() return true end)。Prepare 不维护额外阶段状态或比较回调前后的事务表身份；目标控制 RPC 由 Controller 串行等待，管理端取消只设置批次取消标志，待当前调用返回后才发送 Abort。只有 true 或 {ok=true} 确认业务安全点；回调失败、拒绝或异常均使 Prepare 失败，不能进入 Update。框架不轮询或超时放行业务。

业务 Service 的 hot.patching 与 Controller 创建/加载门禁职责不同：Prepare 设置 hot.patching 后，业务入口按现有接入方式停止新业务；此前已进入 queue 的业务仍可调用创建和首次加载 API，Controller 在 PREPARE 窗口正常处理这些依赖。

Prepare 期间继续使用旧宿主文件，允许正常创建和首次加载。每轮回调结束后，Controller 等在途操作完成，再用同一份冻结 Patch 重新匹配登记信息：新匹配的 Service 补做一次 Prepare；已准备目标新增受影响模块，只补模块清单，不重复 before_upgrade。不匹配本批 Patch 的新 Service 不做 Prepare，但仍须完成初始化和登记。只有所有匹配目标已准备、创建和加载计数为零，才在不 yield 的连续步骤中固定最终清单并进入 UPDATE、关闭接纳门禁。Update 中 Stage 只构建候选和保存快照，Activate 同步提交模块、Service 状态和函数，再执行 after_upgrade。after_upgrade 只检查已提交状态，不得 yield 或产生外部副作用；false 或异常触发组合恢复。

普通模块 Stage 依赖 Controller 已完成的路径映射、语法检查、模块名去重与连续数组构建，不重复校验这些输入。Stage 在目标 Lua State 内检查线上及候选导出，准备隔离状态，并按输入顺序保存模块记录；每条记录集中持有线上根表、候选与旧字段，供 Commit 安装和 Abort 恢复。Commit/Abort 核对根表身份后，字段覆盖函数直接执行原地替换。


Finish 释放旧快照并结束本地事务后将 hot.patching 设为 false。Abort 恢复 Service 状态及函数、普通模块导出和快照，全部确认恢复成功后才清理事务并解除 patching。Prepare 失败仍保留本地事务以便 Abort；恢复失败或无法确认时保留恢复信息和 patching=true。

## Patch 布局与普通模块

```text
<patch_path>/<path>/
  config/
    settings.lua
  lualib/
    player_logic.lua
    battle/state_sync/runtime.lua
  service/
    player.lua
    player_service.patch
    battle/worker.patch
```

发布包内部路径对应宿主 root_path 下的实际路径。递归扫描全部 .lua 和 .patch，并先冻结内容、检查语法。配置 service_path 中的 .lua 是完整新版 Service，只部署；该目录中的 .patch 是一次性 Service 更新脚本，只更新现存实例、不部署。其他目录中的 .lua 是完整普通模块：已登记时同时更新运行时和部署文件，未登记时仅部署。.patch 不能出现在 service_path 之外。

.lua 与 .patch 无须成对出现；允许仅 Service 源码、仅 Service Patch、仅普通模块，以及没有任何运行时目标的纯文件发布。Service .patch 必须匹配至少一个已登记且支持内部更新的目标；未匹配返回 HU_TARGET_MISSING，不支持则返回 HU_SERVICE_PATCH_UNSUPPORTED。普通模块名称仍按实际路径登记，例如 config.settings、lualib.player_logic。不同路径映射到同一普通模块名或同一 Service Patch 名时拒绝整包；其他普通文件忽略，符号链接和特殊文件拒绝。

两类均可单独存在。每份普通模块文件必须是完整模块新版本。只改一个函数也必须保留新版仍需要的全部导出字段。提交会更新所有新字段，并删除新版已去掉的字段，原导出表和两种 package.loaded 名称的身份保持不变。

模块根导出必须是无元表 table，且候选必须是新根表。顶层导出字段名必须是字符串；导出值可为函数、数字、字符串、布尔值或普通嵌套表。嵌套表不得带元表，键只能是字符串、数字或布尔值，值可使用上述类型并继续嵌套；共享引用和循环引用允许，但数据图不得直接或间接引用模块根表，否则提交后会指向候选根表。引擎不限制新旧版本同名字段的类型。提交按候选根表完整替换字段，嵌套对象不递归合并、不保证身份；缓存的旧嵌套引用仍指向旧对象，回滚恢复旧字段及其原引用。可变私有状态放在模块闭包或由 Service 持有。模块顶层只能定义代码、常量和引用已加载依赖；不得 yield、I/O、写全局、修改线上状态或启动任务。候选源码中的 require 只返回本 State 已加载的模块，不加载新增依赖。

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

每个版本内的 export_state 与 import_state 须成对提供。只有旧版提供 export_state 且候选版提供 import_state 时，旧状态快照才会复制并传给候选版；缺少任一方时跳过迁移，由候选版使用自己的初始化状态。状态复制或钩子报错、import_state 返回 false，都会拒绝 Stage。更新前闭包在 Stage 中不变，Abort 恢复原函数字段后继续使用更新前状态；不使用 debug.upvaluejoin 搬运 upvalue。

钩子必须同步、无外部副作用，不得改其他模块。默认快照只接受 nil、布尔、数值、字符串和无元表普通表，键是字符串/数值/布尔；图内共享和循环会保留，最多 128 层、10000 个字段。超限或不可复制值使 Stage 失败。

## 一次性 Service 更新脚本

service_path 为 service 时，service/player_service.patch 如下：

```lua
return function(state)
    return
    {
        update_state = function()
            assert(state.schema_version == 1, "PlayerService 需要 schema 1")
            state.equip = "剑"
            state.schema_version = 2
        end,
        replace_functions =
        {
            load = function(base_attack)
                if state.equip == "剑" then
                    return base_attack + 20 + 1
                end

                return base_attack
            end,
        },
    }
end
```

构建函数接收现存 state，只准备闭包，不修改线上状态。update_state() 不接收参数、不返回候选状态，在 Update 同步提交阶段直接修改现存 state。嵌套赋值、共享引用、循环引用和赋 nil 删除字段均遵循普通 Lua 语义；未修改字段自然保留，不生成候选状态、不递归合并。

replace_functions 只列出需要替换的现有业务函数；未列出的函数保持原样，新函数捕获原 state。没有状态修改可省略 update_state，没有函数替换可省略 replace_functions，至少提供一项。旧 migrate / functions 字段不再接受。

准备阶段保存旧状态快照和旧函数。提交前先标记 touched，再调用 update_state()，随后安装 replace_functions，最后执行 after_upgrade。部分写入抛错及后续失败沿现有 Abort 恢复；恢复失败报告 RECOVERY_REQUIRED 并保持入口关闭。迁移运行错误在 Update 提交时发现。成功 Finish 后清理快照。

默认快照支持普通数据图，保留共享和循环关系，最多 128 层、10000 个字段。这是保存恢复快照的限制，不是更新值合并限制。恢复保持线上根表身份，不承诺嵌套表身份。特殊对象由 Service 提供成对回调：

- snapshot(state)：返回与线上可变数据隔离的旧状态快照，可将特殊对象编码为普通表。
- restore(state, old_state)：恢复现存状态及特殊业务对象；返回 false 或抛错表示恢复失败。

service_update.commit 已删除，不保留兼容。构建、更新、快照、恢复和检查都必须同步，不得 yield、执行外部 I/O 或产生不可撤销副作用；不得替换整个线上状态根表。框架不提供安全沙箱。

## 发布生命周期、文件部署与恢复

管理端仅调用 begin({path=...}) 接受正式发布，通过 status({batch_id=...}) 查询终态。begin 成功表示请求已接受，不表示发布完成：

~~~lua
local begun = skynet.call(hotupgrade_handle, "hotupgrade", "begin", {path = "current"})
assert(begun.ok, begun.message)
while true do
    local status = skynet.call(hotupgrade_handle, "hotupgrade", "status", {batch_id = begun.batch_id})
    assert(status.ok, status.message)
    local phase = status.record.phase
    if phase == "COMPLETED" then
        break
    end
    assert(phase ~= "ABORTED" and phase ~= "RECOVERY_REQUIRED",
        status.record.error and status.record.error.message)
    skynet.sleep(1)
end
~~~

begin 建立批次后立即返回 batch_id，由 Controller 的原有协程继续发布。排空和 PREPARE 窗口继续接纳依赖，创建、登记和首次加载完成或取消后，由原有完成回调唤醒发布协程；完成通知只唤醒，不自动关闭门禁。协程恢复后重新检查批次、计数和新增目标，没有定时扫描或轮询排空。遗漏登记或取消会持续等待，不自动清理记录。重复 begin 返回 HU_UPGRADE_BUSY，失败锁定时返回 HU_DEPLOYMENT_BLOCKED。

正式顺序为：

1. WAITING_CREATIONS：继续接纳创建和首次加载，等待在途操作完成。
2. 同步读取、语法检查并冻结完整发布包，完成初次整包匹配；为正式 .lua 保存旧内容或“不存在”标记。文件准备阶段显示 DEPLOYING。
3. APPLYING/PREPARE：逐个目标禁止新业务并通过各自 queue 确认安全点，期间仍接纳创建和首次加载，宿主文件仍为旧版。
4. 等待本轮产生的创建和加载完成，复用冻结 Patch 重匹配；新目标补做 Prepare，旧目标只补新增模块清单。必要时重复此步，每个目标只 Prepare 一次。
5. 计数为零且全部匹配目标已准备后，在同一次不 yield 的执行中完成最终匹配并进入 UPDATE；此刻关闭创建和首次加载门禁。
6. 逐个目标 Update；在目标自己的同一次 RPC 内执行 Stage → Activate → after_upgrade。
7. 部署冻结的完整 .lua，再调用 skynet.cache.clear()；.patch 不进入部署集合。
8. 记录 PUBLISH_DECIDED，逐个目标 Finish，清理快照并开放业务。
9. 保存 COMPLETED 或具体失败记录，唤醒门禁等待者；后来的创建和首次加载使用已部署的新文件，或确认恢复后的旧文件。

正常门禁等待由框架内部完成，业务调用方无需为发布窗口捕获错误或重试。排空期间的新增依赖可能延长 Prepare；最终关门的依据是操作完成和目标准备完成，而不是等待固定时长。

prepare/update/finish 是正常目标控制 RPC，abort 用于失败恢复。没有运行时目标时不发目标 RPC，照常部署完整文件。新目录按需建立；文件恢复删除本批新增文件，可能留下空目录。不部署非 Lua 资源，不提供文件删除清单。

包检查或旧文件准备失败时，记录原始错误和 ABORTED，回到 IDLE，不向目标发送控制命令。Prepare、后续重匹配、Update 失败或发布决定前取消时，Abort 所有已参与目标，包括本轮新增并已 Prepare 的目标。Prepare 后等待在途操作时，取消会唤醒批次走 Abort；不删除仍在正常完成的创建或模块许可。文件部署或缓存清理失败时，先恢复已修改文件并清理缓存，再 Abort 目标。确认恢复成功后返回 IDLE；恢复失败或结果不明时进入 RECOVERY_REQUIRED/FAILED_LOCKED，保留 original_error/recovery_error，禁止新发布、创建和首次模块加载。

Finish 发生在新版文件和全部 Update 已确认成功之后。某个 Finish 失败或结果不明时，继续尝试其余目标，逐项报告并保留 FAILED_LOCKED；不回滚已经 Finish 的目标，也不撤回新版文件。批量更新不承诺严格跨 Service 原子性。

status 不带 batch_id 返回生命周期概览；带 batch_id 还返回当前或最近终态 record。begin 接受后的异步检查、更新和恢复错误均保存在 record.error。只保留活动及最近批次，不持久化历史。target_count 在 Prepare 期间随重新匹配更新，进入 Update 前确定最终目标数；success/failed 统计参与目标的逐项结果；整批已恢复的失败中，其他参与目标以 HU_BATCH_ABORTED 表示已尝试恢复。

### 显式恢复确认

正常失败已由 HotUpgrade 确认恢复时不需要 resolve_deployment。仅在 FAILED_LOCKED 下，宿主先核实实际文件、运行时、目标 patching/本地事务和缓存，完成必要的人工恢复或版本收敛，再使用现有确认：

~~~lua
local resolved = skynet.call(hotupgrade_handle, "hotupgrade", "resolve_deployment",
{
    batch_id = batch_id,
    confirmed = true,
    confirmation = "CONVERGED_CACHE_CLEARED",
})
assert(resolved.ok, resolved.message)
~~~

该命令只确认宿主声明，不执行目标恢复、Finish、文件部署或 patching 解除。成功后回到 IDLE，保留原诊断。WAITING_CREATIONS/DEPLOYING 阶段取消仍使用同一确认接口，或携相同确认字段调用 abort；文件和运行时未变化、未发目标命令时可用 UNCHANGED。APPLYING 中 abort 只在发布决定前有效。RPC 报错不代表远端已取消，不能据此声称恢复成功。

本模块不支持 Service 替换、跨节点原子事务、运行中 coroutine 栈更新或 Native/C 热替换。业务仍需自行验证权威数据、持久化一致性和部署权限；重新执行旧 Patch 也不能恢复过去的数据库内容。

## 文件边界与验证

Native 提供 resolve(path[, relative_dir])、list_lua(patch_path, path) 和 Controller 内部使用的 read_file(root_path, relative_file)、replace_file(root_path, relative_file, source_or_nil)；相对目录检查与递归扫描共用路径安全校验，拒绝越界路径、链接及特殊文件。Controller 不设目标 Service、模块声明、Patch Lua 文件数或源码字节数硬上限；扫描与冻结规模由实际 Patch 和运行时可用资源决定。宿主在扫描/冻结期间保持 Patch 目录不变；扫描和读取不是抵抗并发目录替换的原子安全边界。冻结后更新和部署只使用本次源码，不重新读取发布包。正式目录应由本次 Controller 独占部署，不支持外部并发修改；文件操作沿用逐级路径检查，临时文件替换不提供跨文件磁盘原子性或断电恢复。replace_file 的 nil 内容仅用于删除本批原本不存在的新增文件；已有文件保留原权限，新文件使用 0644。

待创建记录也占用 Controller 内存。每个目标的同一模块仍同时只保留一项首次加载许可。登记和许可记录由当前 Controller 持有，不建立后台发现、自动超时清理或持久化恢复；宿主负责保持实际 Service 生命周期与控制面一致。Service 或调用方在关键区间异常退出、许可取消 RPC 无法送达时，屏障会保留；须核对实际状态并受控重启，不得假定操作已完成。

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

脚本测试创建中/待登记屏障、两种登记时序、启动与业务初始化失败、创建者取消权限、模块许可匹配/消费/失败清理、并发首次声明、Update 起门禁等待，以及父子孙创建链、queue 内创建与首次声明、嵌套许可、已准备目标补模块、新目标 Prepare/Update 失败恢复、排空等待取消、冻结源码只读一次、queue 排空与 patching、完整模块增改删、私有状态迁移、Service 状态/函数组合提交、真实 handle/State/表身份保持、Update 内 Stage/Activate 与整批恢复、纯文件发布、文件部署失败恢复、新实例与首次加载版本一致，以及 Finish 故障报告和恢复门禁。Skynet 集成只启动测试专用进程，不监听业务端口；结果不替代宿主真实业务状态与数据库验证。


### 宿主启动顺序与原生退出通知

宿主启动入口必须先启动唯一的 `flywow_hotupgrade_service`，同步调用其 `lua/init` 并确认成功，然后再通过 `hotupgrade.newservice()` 或 `hotupgrade.uniqueservice()` 创建接入热更的业务 Service。业务 Service 可以在文件顶部 `require "flywow_hotupgrade"` 和调用 `hotupgrade.require()`；入口加载不执行 Controller RPC，此时根路径已由启动入口完成初始化。`register_service()` 仍在可 yield 的启动协程内执行。

控制 Service 初始化时通过原生 `MONITOR` 接收 `skynet.exit()` / `skynet.kill()` 退出通知，清理登记、唯一实例与在途许可。`MONITOR` 是进程级单例，已被占用时初始化返回 `HU_MONITOR_OCCUPIED`，不会覆盖宿主监视器。发布期间退出的目标保留在批次结果内；Prepare/Update 失败恢复其余存活目标，发布决定后的退出报告收尾失败并保持恢复锁定。

退出专项验证包含 Prepare、Update、Finish 中的原生 `exit` / `kill`、持有模块许可时被 kill、唯一 Service 退出后重建，以及 MONITOR 已占用时拒绝初始化且保留原监视器。退出通知清理 Controller 记录后调用 Skynet 原生 `term(handle)`，解除控制 State 对退出目标的挂起 RPC；RPC 错误先到时让出一次调度，使原生退出通知参与恢复判断。
