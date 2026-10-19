# FlyWow HotUpgrade 接入说明

HotUpgrade 在现存 Skynet Service、现存 Lua State 内更新受信 Lua 代码和必要业务状态。更新保持 Service handle、模块导出表和 Service 私有状态根表的身份。普通模块提交完整新版本；可选 Service 更新脚本在同一事务内迁移私有状态并直接替换指定业务函数。

## 启动与登记

宿主从 composition root 启动控制面，保存 handle，再通过 init 交付配置：

```lua
require "flywow_hotupgrade" -- 声明当前管理 State 的原生控制协议。
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

在现存业务 Service 自己的 Lua State 登记：

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
    service_type = "player",
    service = {state = state, functions = M},
    after_upgrade = function()
        return state.level >= 0
    end,
})
assert(registered.ok, registered.message)
```

service_type 对应 service_dir 下的相对 Lua 路径：去掉 .lua 并将 / 转为 .。例如 service_dir 为 service 时，service/player.lua 对应 player，service/battle/worker.lua 对应 battle.worker。service 可省略，此时只参与普通模块更新。Controller 使用注册消息真实 source 作为目标 handle；私有状态、函数和回调留在业务 State，不经消息传给 Controller。登记成功前宿主不得宣布 Service READY；登记 RPC 失败可能有不确定结果，应终止该次启动，由宿主管理，而不是继续接收业务。

hotupgrade.require(name) 仍用宿主原有 name 加载模块，通过 package.searchpath(name, package.path) 定位 Lua 文件，再复用 Native resolve 得到规范化路径。Controller 登记名由该文件相对 root_path 的路径去掉 .lua、将 / 转为 . 得到。例如原调用 hotupgrade.require("battle.state_sync.runtime") 加载 lualib/battle/state_sync/runtime.lua，登记名为 lualib.battle.state_sync.runtime；不是给原 name 固定增加目录前缀。?/init.lua 解析出的文件也按真实路径登记，例如 lualib/battle/init.lua 对应 lualib.battle.init。

原 require 名和文件登记名在 package.loaded 中指向同一个模块根表，热更和恢复都通过同一根表对两种名称生效。文件登记名若已被另一模块占用，则抛出明确冲突错误，不覆盖已有表；动态登记失败会撤销本次新建的别名。仅支持通过标准 package.path 搜索的 Lua 文件；package.preload、自定义加载器来源不一致、无法定位文件或文件位于 root_path 外时明确拒绝。宿主应保持受控模块的搜索路径稳定，不在已加载后改写其加载来源。

登记前声明随初始元数据提交；登记后首次声明通过原生 Skynet call 登记，可能 yield。失败抛错且允许重试；重复声明不重复 RPC。Controller 只更新目标已声明的模块。

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

## 管理命令与事务结果

```lua
local started = skynet.call(controller_handle, "hotupgrade", "apply", {path = "current"})
assert(started.ok, started.message)
local status = skynet.call(controller_handle, "hotupgrade", "status", {txn_id = started.txn_id})
assert(status.ok, status.message)
```

validate 同步冻结源码、检查路径/语法和匹配的登记目标，不执行目标脚本。validate、dry_run 和 apply 使用同一匹配规则：每个 Patch 文件必须至少匹配一个已登记目标；未匹配时返回 HU_TARGET_MISSING，并在 message 中给出文件路径和原因，所有目标事务均不启动。Service 类型匹配但未提供内部更新入口时返回 HU_SERVICE_PATCH_UNSUPPORTED，同样在事务启动前拒绝整包。apply 和 dry_run 返回 txn_id 后异步推进，每次只运行一个发布，不排队。status 查询当前活动事务或最近一个终态；更早事务返回 HU_TRANSACTION_MISSING。状态不持久化，Controller 重启不恢复登记或事务。

各目标按 handle 顺序逐个执行：

1. prepare 关闭 Guard 并排空业务。
2. stage 检查所有目标模块、迁移私有模块状态并准备可选 Service 更新，线上代码和状态不变。
3. activate 在目标一次同步处理内提交全部模块和 Service 更新，执行可选 after_upgrade；false/异常触发立即组合恢复。
4. apply 达到 PUBLISH_DECIDED 后执行 finish，释放旧快照并开放入口；dry_run 则实际提交后 abort，验证恢复并回到旧代码/状态。

发布决定前可请求 abort，Controller 在当前步骤返回后恢复目标；已完成目标不会自动撤销，跨 Service 不承诺全局原子性。结果 phase 为 COMPLETED、DRY_RUN_COMPLETED、ABORTED、PARTIAL 或 RECOVERY_REQUIRED；success/failed 表示处理成功和失败目标数，results 给出实际尝试目标的逐项结果。未尝试的目标不计入成功/失败。dry_run 的 success 表示更新及恢复验证成功。

任一恢复或发布后结果无法确认时，目标保持 Guard 暂停，Controller 设置 recovery_required 并拒绝新发布。RPC 失败/超时不等于远端取消；不要重新假定旧代码已恢复。宿主必须核对目标实际状态和业务外部数据，完成人工恢复或受控重启；框架不提供自动清除门禁命令。

本模块不支持 Service 替换、跨节点原子事务、运行中 coroutine 栈更新或 Native/C 热替换。业务仍需自行验证权威数据、持久化一致性和部署权限；重新执行旧 Patch 也不能恢复过去的数据库内容。

## 文件边界与验证

Native 提供 resolve(path[, relative_dir]) 和 list_lua(patch_root, path)；相对目录检查与递归扫描共用路径安全校验，拒绝越界路径、链接及特殊文件。扫描限制整个选定 Patch 最多 1024 个 Lua 文件、单文件 2 MiB，整包读取累计最多 16 MiB。宿主在扫描/冻结期间保持 Patch 目录不变；扫描和读取不是抵抗并发目录替换的原子安全边界。冻结后目标只使用本次源码，不重新读取磁盘。

Controller 最多登记 1024 个目标，每目标最多声明 1024 个模块；达到上限返回 HU_TARGET_LIMIT/HU_MODULE_LIMIT。登记记录由当前 Controller 持有，不建立后台发现或自动注销；宿主负责保持实际 Service 生命周期与控制面一致。

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

脚本测试 Guard、完整模块增改删、私有状态迁移、Service 状态/函数组合提交、真实 handle/State/表身份保持、dry_run、Stage/Activate 失败恢复、部分成功和恢复门禁。Skynet 集成只启动测试专用进程，不监听业务端口；结果不替代宿主真实业务状态与数据库验证。
