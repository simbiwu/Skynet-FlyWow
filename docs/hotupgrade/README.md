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
- lua_path：./third_party/skynet-flywow/common/lualib/?.lua；./third_party/skynet-flywow/hotupgrade/lualib/?.lua
- lua_cpath：./third_party/skynet-flywow/build/native/?.so

公开入口是 hotupgrade/lualib/flywow_hotupgrade.lua；控制 Service 入口是 hotupgrade/service/flywow_hotupgrade_service.lua。Controller 加载 flywow_hotupgrade_native 时，Lua 从 Native 搜索路径定位统一构建入口产出的 build/native/flywow_hotupgrade_native.so。宿主先在 composition root 初始化 Controller 并确认成功，再创建受管理业务 Service。业务 Service 可先在文件顶部 require 公开入口，并在 register_service() 前调用 hotupgrade.require() 声明初始模块；此时 Service 尚未登记，不会获取 Controller handle 或执行 Controller RPC。Service 登记后首次加载未声明模块时，hotupgrade.require() 会向 Controller 申请许可并在加载后登记；等待首次登记结果、Controller 响应或同一 State 的同模块首次加载也可能 yield。调用会在等待完成后返回模块表；缓存命中且已声明的模块通常直接返回。Controller handle 仅在首次实际需要 RPC 时通过原生 skynet.uniqueservice() 获取并缓存。register_service() 会发送登记 RPC，必须在可 yield 的 Skynet 协程内调用。管理 State 无需登记为业务目标。

HotUpgrade 内部可失败操作统一返回公共 FlyWowResult<T>：成功载荷放在 value，失败使用稳定 code 和诊断 message；模块专属诊断放在 details。例如，begin 成功后从 result.value.batch_id 读取批次 ID，status 成功后从 result.value.record 读取批次记录。hotupgrade.require()、newservice() 和 uniqueservice() 是面向 Lua/Skynet 的适配入口，保留直接返回模块表/Service handle、失败抛异常的原生使用习惯。

patch_path 必须存在且可读取。root_path 是已存在的宿主项目根目录，service_path 是它下面已存在的相对 Service 目录；拒绝绝对路径、空路径段、.、..、反斜杠和符号链接目录。目录允许多级，例如 service/battle。

patch_path 是 init 配置中的 Patch 根目录；管理端 begin 的 path 选择根目录下的发布目录。Controller 内分别保存为 patch_root 和 batch.patch_dir，后者是相对前者的路径。例如 patch_root 为 /srv/app/hotupgrade、batch.patch_dir 为 releases/2026-10-28 时，实际扫描目录是 /srv/app/hotupgrade/releases/2026-10-28。

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

唯一键是本 Controller 内的原始逻辑 Service 名称。首次创建先通过当前接纳门禁，再建立该名称的在途预留并复用受管理 newservice 流程；同名并发请求等待同一创建结果，原生创建返回后一起取得相同 handle。只有首次请求的启动参数生效，后续重复请求的参数不改变实例。不同名称可启动不同 Service；已有 handle 即使在发布期间也直接返回。排空和 Prepare 期间，新逻辑键可正常创建；进入 Update 后，新逻辑键等待发布结束，本批结束后按当时现场继续处理。等待门禁恢复后重查唯一名，避免并发请求各自创建。

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

已登记 Service 首次声明普通模块时，先向 Controller 请求 begin_module_load 许可，再执行实际 require、校验来源并建立缓存、别名、来源映射和本地声明，最后携许可 ID 调用 register_module。许可绑定真实来源及规范模块名，不能转用或重复消费；失败时回退本地新增状态，并通过 cancel_module_load 释放尚未完成的许可。begin 接受后等待已有许可完成，覆盖模块执行及登记的整个关键区间。同一 State 内并发首次声明同一规范模块会等待前一项成功或完整回退；已声明模块不重复请求许可。Controller 只更新目标已声明的模块。begin 后的 WAITING_CREATIONS 和 PREPARE 窗口继续接纳创建与首次声明，覆盖父子创建、嵌套 require 和 queue 内已有业务的正常依赖。进入 UPDATE 后，普通新请求挂起到批次终态，不申请许可、不执行模块代码，也不增加本批排空计数。

Service Patch 可通过 `new_modules` 声明本 Service 在本批首次使用的模块，例如 `{new_modules = {"combat_rules", "skill_rules"}}`。Controller 先部署本批完整 `.lua` 并清理缓存，再把 `.patch` 交给目标。目标先构建 Service Patch、读取该列表，再用内部登记命令加载清单内模块；这个命令只接受当前批次 UPDATE 阶段正在处理的目标。它不走普通首次加载许可，因此目标等待 Controller 登记时不会与批次互等。清单内模块在该 State 尚未登记的依赖也必须列入；已登记依赖可直接复用。清单以外的未登记依赖会立即失败，不进入生命周期等待。Service Patch 构建函数需要先返回清单，不能在构建函数内首次 require 这批新模块。

新模块在当前 Lua State 登记后加入 Controller 的模块清单，但不加入已冻结的本批普通模块更新清单；后续批次重新匹配时才会正常 Stage/Commit。同一临时清单上下文保持到普通候选模块完成 Stage，因此候选代码遗漏的未登记依赖也会快速失败，不会申请普通首次加载许可后与当前 UPDATE 相互等待。若清单新模块与门禁期间等待普通首次加载的协程冲突，Update 快速以 `HU_MODULE_LOADING` 失败并走现有恢复流程，不等待或接管该协程。仅含非空 `new_modules` 的 Service Patch 有效。内部登记 RPC 可能 yield；候选模块执行、状态钩子及 Service 更新回调仍须遵守各自同步合同。普通并发首次声明仍由本 State 的加载协调处理。

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

register_service 必须提供 before_upgrade 函数；缺失或非函数会在登记时以 HU_INVALID_OPTIONS 拒绝。每次 Prepare 建立本地事务并设置 hot.patching=true 后都会调用该回调。回调允许 yield，必须通过上述同一个 queue 等待此前已进入的业务全部退出，例如 return business_queue(function() return true end)。Prepare 不维护额外阶段状态或比较回调前后的事务表身份；目标控制 RPC 由 Controller 串行等待；begin 接受后不允许管理端主动取消，失败时由 Controller 执行内部 Abort。只有 true 或 {ok=true} 确认业务安全点；回调失败、拒绝或异常均使 Prepare 失败，不能进入 Update。框架不轮询或超时放行业务。

业务 Service 的 hot.patching 与 Controller 创建/加载门禁职责不同：Prepare 设置 hot.patching 后，业务入口按现有接入方式停止新业务；此前已进入 queue 的业务仍可调用创建和首次加载 API，Controller 在 PREPARE 窗口正常处理这些依赖。

Prepare 期间继续使用旧宿主文件，允许正常创建和首次加载。每轮回调结束后，Controller 等在途操作完成，再用同一份冻结 Patch 重新匹配登记信息：新匹配的 Service 补做一次 Prepare；已准备目标新增受影响模块，只补模块清单，不重复 before_upgrade。不匹配本批 Patch 的新 Service 不做 Prepare，但仍须完成初始化和登记。所有匹配目标准备完成后，在不 yield 的连续步骤中固定最终清单并进入 UPDATE、关闭普通创建和首次加载门禁。Controller 随后先部署完整 `.lua` 并清理缓存，再向目标发送 Update。目标先准备 Service Patch 并处理 `new_modules`，再 Stage 本批冻结的普通模块，之后 Activate 同步提交模块、Service 状态和函数，最后执行 after_upgrade。after_upgrade 只检查已提交状态，不得 yield 或产生外部副作用；false 或异常触发组合恢复。

普通模块 Stage 依赖 Controller 已完成的路径映射、语法检查、模块名去重与连续数组构建，不重复校验这些输入。Stage 在目标 Lua State 内检查线上及候选导出，准备隔离状态，并按输入顺序保存模块记录；每条记录集中持有线上根表、候选与旧字段，供 Commit 安装和 Abort 恢复。Commit/Abort 核对根表身份后，字段覆盖函数直接执行原地替换。


Finish 释放旧快照并结束本地事务后将 hot.patching 设为 false。Abort 尽力恢复 Service 状态、函数和普通模块导出；无论恢复结果如何，都报告结果并释放本批事务、快照和 patching。Prepare 失败仍由本批 Abort 收尾。

## Patch 布局与普通模块

```text
<patch_root>/<patch_dir>/
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

Service Patch 返回表中的 `new_modules` 是普通 require 名称数组。框架按实际路径解析模块身份、拒绝重复文件项，并在目标 Update 内通过 `hotupgrade.require` 加载。清单中的模块可以递归依赖清单内的其他新模块；已经登记的模块可直接复用，循环声明沿用现有拒绝行为。清单外首次依赖若未被业务捕获，会使当前阶段失败：外层 `code` 保留阶段错误（如 `HU_MODULE_STAGE_FAILED`），`details.cause_code` 随实际传播的错误记录（如 `HU_NEW_MODULE_NOT_DECLARED`）；调用方不需要解析 `message`。业务捕获该错误后，它不会污染后续失败的 `details.cause_code`。Patch 构建函数只能声明清单，不能在返回前首次加载清单内模块。仅声明非空 `new_modules` 的 Patch 不需要伪造 `update_state` 或 `replace_functions`。

成功登记的新模块不参与本批冻结的普通模块 Stage/Commit，从下一批开始可更新。如果本批后续模块 Stage、Activate 或其他目标失败，已经加载并登记的新模块留在该 Lua State， Controller 尝试恢复部署文件后也不撤销该登记；status 报告失败，后续批次按当时内存和登记现场继续。

两类均可单独存在。每份普通模块文件必须是完整模块新版本。只改一个函数也必须保留新版仍需要的全部导出字段。提交会更新所有新字段，并删除新版已去掉的字段，原导出表和两种 package.loaded 名称的身份保持不变。

模块根导出必须是无元表 table，且候选必须是新根表。顶层导出字段名必须是字符串；导出值可为函数、数字、字符串、布尔值或普通嵌套表。嵌套表不得带元表，键只能是字符串、数字或布尔值，值可使用上述类型并继续嵌套；共享引用和循环引用允许，但数据图不得直接或间接引用模块根表，否则提交后会指向候选根表。引擎不限制新旧版本同名字段的类型。提交按候选根表完整替换字段，嵌套对象不递归合并、不保证身份；缓存的旧嵌套引用仍指向旧对象，回滚恢复旧字段及其原引用。可变私有状态放在模块闭包或由 Service 持有。候选源码接收首次 hotupgrade.require 使用的原始模块名和加载路径作为两个可变参数；该记录留在本 Lua State，不使用 Controller 的规范登记名替代。候选源码中的 require 使用 Lua 原生实现，可以按普通 Lua 规则加载当前 State 尚未加载的依赖。成功加载的依赖会留在 package.loaded；即使 Stage 或后续发布步骤失败，模块更新引擎也不清理这些新依赖、不回滚它们的模块初始化状态。本次事务只回滚明确纳入更新的模块导出和状态。候选模块顶层及状态钩子仍须受信、同步，不得 yield、I/O、写全局、修改线上状态或启动任务。

### 函数引用与候选根表

保留模块根表身份，只保证通过该表重新读取字段能看到已安装版本。已经缓存的旧函数和旧嵌套对象继续保留原引用，这是允许的 Lua 行为；框架不会扫描业务变量、定时器或回调并替换其中的函数。

```lua
local logic = hotupgrade.require("player_logic")
local saved_attack = logic.attack -- 更新前保存的函数。
-- 完成热更后：
logic.attack(player)              -- 从稳定根表读取新版 attack。
saved_attack(player)             -- 继续执行保存的旧函数。
```

候选代码创建的根表与线上根表是两张表。提交只把候选字段安装到线上表，不修改函数捕获的 upvalue。下面是不能依赖的根表身份假设，用于说明边界：

```lua
local M = {version = 2}
function M:is_same_table()
    return self == M
end
return M
```

提交后调用 `logic:is_same_table()`，self 是原有线上表，闭包中的 M 仍是候选表，因此返回 false。导出检查不扫描函数 upvalue，也不自动重绑定这个 M。模块函数不能把捕获的候选根表当作提交后的线上根表；需要访问线上导出字段的方法通过 self 访问，并使用冒号调用：

```lua
local M = {version = 2}
function M:read_version()
    return self.version
end
return M
-- 更新后，logic:read_version() 从原有线上根表读取 version，得到 2。
```

可迁移的私有状态放在局部变量中，沿用下节的 export_state/import_state。不要对外暴露候选根表或在业务中改写模块导出。

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

每个版本内的 export_state 与 import_state 须成对提供。只有旧版提供 export_state 且候选版提供 import_state 时，旧状态快照才会复制并传给候选版；缺少任一方时跳过迁移，由候选版使用自己的初始化状态。状态复制或钩子报错、import_state 返回 false，都会拒绝 Stage。更新前闭包在 Stage 中不变，Abort 恢复原函数字段后继续使用更新前状态；不使用 debug.upvaluejoin 搬运 upvalue。 Finish 后，业务仍持有的旧函数继续访问旧版私有状态；新版函数访问迁移后自己的私有状态，两者不是同一个 upvalue，后续修改不会自动互相同步。

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

replace_functions 只列出需要替换的现有业务函数；未列出的函数保持原样，新函数捕获原 state。update_state、非空 replace_functions、非空 new_modules 至少提供一项。

准备阶段保存旧状态快照和旧函数。提交前先标记 touched，再调用 update_state()，随后安装 replace_functions，最后执行 after_upgrade。部分写入抛错及后续失败沿现有 Abort 恢复；恢复失败报告 RECOVERY_REQUIRED，结束本批后仍释放入口。迁移运行错误在 Update 提交时发现。成功 Finish 后清理快照。

默认快照支持普通数据图，保留共享和循环关系，最多 128 层、10000 个字段。这是保存恢复快照的限制，不是更新值合并限制。恢复保持线上根表身份，不承诺嵌套表身份。特殊对象由 Service 提供成对回调：

- snapshot(state)：返回与线上可变数据隔离的旧状态快照，可将特殊对象编码为普通表。
- restore(state, old_state)：恢复现存状态及特殊业务对象；返回 false 或抛错表示恢复失败。

构建、更新、快照、恢复和检查都必须同步，不得 yield、执行外部 I/O 或产生不可撤销副作用；不得替换整个线上状态根表。框架不提供安全沙箱。

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

Controller 从 begin 到终态复用同一个 batch。load_patch(batch) 将冻结源码和初次匹配目标直接写入该记录，Prepare 重匹配复用原目标对象。batch.phase 是唯一保存的发布进度，门禁直接读取活动批次。status 的 lifecycle.pending_service_count 和 pending_module_count 分别表示尚未完成创建或登记的受管理 Service 数、尚未完成首次加载或登记的普通模块数；phase 和 recovery_required 仍由当前及最近终态批次生成，新批次进行中保留最近终态的恢复诊断。

每个目标 Lua State 使用一个 transaction 持有 Service Patch 提交内容、恢复快照和 module_stage。相同对象沿内部调用链保持名称，Abort、Finish 和控制异常共用事务结束操作。输入在首次可信边界检查，内部不重复校验没有变化的数据；Service Patch 返回值、自定义快照和候选导出在产生处检查，执行 import_state 后才再次检查候选图。跨 yield 后的来源、许可、缓存身份和模块代码可能改变的状态仍在使用处核对。

begin 建立批次后立即返回 batch_id，由 Controller 的原有协程继续发布。排空和 PREPARE 窗口继续接纳依赖，创建、登记和首次加载完成或取消后，由原有完成回调唤醒发布协程；完成通知只唤醒，不自动关闭门禁。协程恢复后重新检查在途计数，并重新匹配新增目标，没有定时扫描或轮询排空。遗漏登记或取消会持续等待，不自动清理记录。重复 begin 返回 HU_UPGRADE_BUSY。

正式顺序为：

1. WAITING_CREATIONS：继续接纳创建和首次加载，等待在途操作完成。
2. 同步读取、语法检查并冻结完整发布包，完成初次整包匹配；为正式 `.lua` 保存旧内容或“不存在”标记。
3. APPLYING/PREPARE：逐个目标禁止新业务并通过各自 queue 确认安全点，期间仍接纳创建和首次加载；宿主文件保持旧版。
4. 等待本轮产生的创建和加载完成，复用冻结 Patch 重匹配；新目标补做 Prepare，旧目标只补新增模块清单。必要时重复此步，每个目标只 Prepare 一次。
5. 计数为零且全部匹配目标已准备后，在同一次不 yield 的执行中完成最终匹配并进入 UPDATE；普通创建和首次加载门禁关闭。
6. Controller 部署冻结的完整 `.lua` 并调用 `skynet.cache.clear()`；`.patch` 不进入部署集合。部署失败时恢复已写文件并 Abort 已 Prepare 的目标。
7. 逐个目标 Update。目标先构建 Service Patch、加载并登记 `new_modules`，再对冻结的普通模块执行 Stage → Activate → after_upgrade。
8. 所有目标 Update 成功后记录 PUBLISH_DECIDED，逐个目标 Finish，清理快照并开放业务。
9. 保存 COMPLETED 或具体失败记录，唤醒门禁等待者；之后的创建和首次加载使用已部署文件，恢复成功时则使用恢复后的文件。

正常门禁等待由框架内部完成，业务调用方无需为发布窗口捕获错误或重试。排空期间的新增依赖可能延长 Prepare；最终关门的依据是操作完成和目标准备完成，而不是等待固定时长。

prepare/update/finish 是正常目标控制 RPC，abort 用于失败恢复。没有运行时目标时不发目标 RPC，照常部署完整文件。新目录按需建立；文件恢复删除本批新增文件，可能留下空目录。不部署非 Lua 资源，不提供文件删除清单。

包检查或旧文件准备失败时，记录原始错误和 ABORTED，回到 IDLE，不向目标发送控制命令。Prepare、后续重匹配或 Update 失败时，Abort 所有已参与目标，包括本轮新增并已 Prepare 的目标。文件部署或缓存清理失败时，先恢复已修改文件并清理缓存，再 Abort 目标。恢复失败或结果不明时以 RECOVERY_REQUIRED 报告，在失败结果的 details 中保留 original_error/recovery_error。无论是否恢复成功，Controller 都结束本批并回到 IDLE，释放快照及临时门禁，不阻止后续发布、创建和首次模块加载。

Finish 发生在新版文件和全部 Update 已确认成功之后。某个 Finish 失败或结果不明时，继续尝试其余目标，逐项报告收尾错误并结束本批；不回滚已经 Finish 的目标，也不撤回新版文件。批量更新不承诺严格跨 Service 原子性。

status 不带 batch_id 返回生命周期概览；带 batch_id 还返回当前或最近终态 record。begin 接受后的异步检查、更新和恢复错误均保存在 record.error。只保留活动及最近批次，不持久化历史。target_service_count 在 Prepare 期间随重新匹配更新，进入 Update 前确定最终目标 Service 数；succeeded_service_count/failed_service_count 分别统计成功和失败的目标 Service，service_results 保存参与控制的逐 Service 结果；整批已恢复的失败中，其他参与目标以 HU_BATCH_ABORTED 表示已尝试恢复。

### 失败报告与后续发布

本批失败后先尽力恢复，报告实际更新结果、恢复错误和未恢复项。已成功加载并登记的新模块不会随普通模块/Service 回滚撤销；若随后发生失败，文件恢复可能使磁盘版本与当前 Lua State 中的新模块不同，status 和失败结果如实报告本批失败，下一批按当时内存、登记及文件现场继续。RECOVERY_REQUIRED 与 status 的 recovery_required 只表示最近批次存在未确认恢复的错误，不是后续操作的门禁。宿主或运维决定如何处理这些错误、是否暂停业务和下一批内容。

下一批重新读取文件并保存当前状态快照，回滚目标是本批开始时的现场，不使用上一批快照。上一批的实际代码、状态和文件变化会成为下一批起点；下一批成功只说明它自身完成，不表示未涉及的历史问题已解决。状态必须仍满足当前加载、快照和身份合同，否则继续报告具体错误。活动及最近终态查询不代替宿主保存故障报告。

begin 成功后不提供管理端主动取消。向 Controller 发送 abort 返回 HU_UNKNOWN_COMMAND，不改变活动批次；管理端使用 status 等待最终结果。内部目标控制协议的 abort 仍用于失败恢复。创建失败后的 cancel_service_creation 和首次加载失败后的 cancel_module_load 继续用于结束各自的生命周期记录，不是取消热更批次。

本模块不支持 Service 替换、跨节点原子事务、运行中 coroutine 栈更新或 Native/C 热替换。业务仍需自行验证权威数据、持久化一致性和部署权限；重新执行旧 Patch 也不能恢复过去的数据库内容。

## 文件边界与验证

发布包语法检查、普通模块候选和 Service Patch 执行均按 Lua 文件加载规则跳过开头的 UTF-8 BOM 和首行 `#` 注释，保留换行以维持诊断行号。处理只作用于编译输入；冻结、部署和恢复仍保留文件原始字节。

Native 提供 resolve(path[, relative_dir])、list_lua(patch_root, relative_patch_dir) 和 Controller 内部使用的 read_file(root_path, relative_file)、replace_file(root_path, relative_file, source_or_nil)；相对目录检查与递归扫描共用路径安全校验，拒绝越界路径、链接及特殊文件。Controller 不设目标 Service、模块声明、Patch Lua 文件数或源码字节数硬上限；扫描与冻结规模由实际 Patch 和运行时可用资源决定。宿主在扫描/冻结期间保持 Patch 目录不变；扫描和读取不是抵抗并发目录替换的原子安全边界。冻结后更新和部署只使用本次源码，不重新读取发布包。正式目录应由本次 Controller 独占部署，不支持外部并发修改；文件操作沿用逐级路径检查，临时文件替换不提供跨文件磁盘原子性或断电恢复。replace_file 的 nil 内容仅用于删除本批原本不存在的新增文件；已有文件保留原权限，新文件使用 0644。

待创建记录也占用 Controller 内存。每个目标的同一模块仍同时只保留一项首次加载许可。登记和许可记录由当前 Controller 持有，不建立后台发现、自动超时清理或持久化恢复；宿主负责保持实际 Service 生命周期与控制面一致。Service 或调用方在关键区间异常退出、许可取消 RPC 无法送达时，屏障会保留；须核对实际状态并受控重启，不得假定操作已完成。

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

脚本测试创建中/待登记屏障、两种登记时序、启动与业务初始化失败、创建者取消权限、模块许可匹配/消费/失败清理、并发首次声明、Update 起门禁等待，以及父子孙创建链、queue 内创建与首次声明、嵌套许可、已准备目标补模块、新目标 Prepare/Update 失败恢复、排空及控制 RPC 期间拒绝管理端 abort、冻结源码只读一次、queue 排空与 patching、完整模块增改删、候选根表与 self 的身份边界、缓存旧函数和新旧闭包状态隔离、私有状态迁移、Service 状态/函数组合提交、真实 handle/State/表身份保持、Update 内 Stage/Activate 与整批恢复、纯文件发布、文件部署失败恢复、新实例与首次加载版本一致，以及 Finish 故障报告及失败后连续发布。新模块场景验证了文件先部署、递归登记依赖、当前批次不重复 Stage、Service Patch 与普通候选中漏列的新依赖快速失败、并发首次加载冲突时 Update 失败后解除等待、捕获依赖错误不污染后续根因，以及失败后下一批继续更新。Skynet 集成只启动测试专用进程，不监听业务端口；结果不替代宿主真实业务状态与数据库验证。


### 宿主启动顺序与原生退出通知

宿主启动入口必须先启动唯一的 `flywow_hotupgrade_service`，同步调用其 `lua/init` 并确认成功，然后再通过 `hotupgrade.newservice()` 或 `hotupgrade.uniqueservice()` 创建接入热更的业务 Service。业务 Service 可以在文件顶部 `require "flywow_hotupgrade"` 和调用 `hotupgrade.require()`；入口加载不执行 Controller RPC，此时根路径已由启动入口完成初始化。`register_service()` 仍在可 yield 的启动协程内执行。

控制 Service 初始化时通过原生 `MONITOR` 接收 `skynet.exit()` / `skynet.kill()` 退出通知，清理登记、唯一实例与在途许可。`MONITOR` 是进程级单例，已被占用时初始化返回 `HU_MONITOR_OCCUPIED`，不会覆盖宿主监视器。发布期间退出的目标保留在批次结果内；Prepare/Update 失败恢复其余存活目标，发布决定后的退出报告收尾失败，结束本批后继续接纳后续发布。

退出专项验证包含 Prepare、Update、Finish 中的原生 `exit` / `kill`、持有模块许可时被 kill、唯一 Service 退出后重建，以及 MONITOR 已占用时拒绝初始化且保留原监视器。退出通知清理 Controller 记录后调用 Skynet 原生 `term(handle)`，解除控制 State 对退出目标的挂起 RPC。Controller 不等待或补偿退出通知与 RPC 错误的到达次序；按处理时已知结果继续推进，失败则进入现有失败与恢复流程，错误只作本批诊断，不形成后续批次门禁。
