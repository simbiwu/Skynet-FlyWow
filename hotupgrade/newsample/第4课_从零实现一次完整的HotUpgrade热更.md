# 第 4 课：从零实现一次完整的 HotUpgrade 热更

本课使用的源码版本：

`SKYNET-FLYWOW main`：`8e1424afedc5835bdbf4cc67244a6f272a0b2cbc`

前三课我们已经分别学习了 Service 登记、普通 Lua 模块热更，以及 Service 状态与函数更新。现在要把这些知识真正连接起来。

这次不使用仓库现有的 Sample。我们从零编写一个最小的 PlayerService，先让它运行，再逐步接入热更机制，最终完成一次 V1 → V2 的完整发布。

教学过程中有两类代码：

- **我们自己编写的 Sample**：只保留理解 HotUpgrade 必需的业务、登记和发布代码。
- **FlyWow 已经存在的源码**：讲到某个 API 时，沿真实调用关系进入其实现，理解它是怎样工作的。

所有新编写的文件都会标明路径；所有框架源码都会注明所在函数、调用者以及当前执行到这里的原因。

## 一、我们要实现什么？

假设正在开发一款 MMO 游戏，服务端有一个 PlayerService，负责保存玩家状态并计算攻击力。

初始 V1：

```text
玩家装备：刀
玩家状态版本：1
基础攻击力：100
装备加成：5
最终攻击力：105
```

我们希望在**不销毁正在运行的 PlayerService** 的情况下，把业务升级到 V2：

```text
玩家装备：剑
玩家状态版本：2
基础攻击力：100
装备加成：21
最终攻击力：121
```

热更完成后，还要验证两件事：

第一，已经运行的 PlayerService，仍然是原来的 Service，里面的状态表和普通模块导出表仍然是原来的对象，只是内容已经更新。

第二，之后新创建的 PlayerService，不需要执行旧版本迁移，而是直接从正式文件加载 V2。

这个简单案例实际上包含了三类不同的更新：

| 更新内容 | 采用的方式 |
|---|---|
| `player_logic.lua` 的业务逻辑 | 完整 Lua 模块更新 |
| 已运行 PlayerService 的状态和 `business.load` | 一次性 Service Patch |
| 未来创建的 PlayerService 使用的代码 | 正式 `.lua` 文件部署 |

之所以要分成三类，是因为已经加载到 Lua State 中的对象，与磁盘上的 Lua 源码文件不是同一回事。

例如，修改磁盘上的 `player_logic.lua`，并不会自动修改某个 PlayerService 已经持有的函数。反过来，仅修改现存 Service 的函数，也不能保证以后创建的 Service 运行新版本。

HotUpgrade 需要同时完成这两件事。

**本课最终会让你知道，它到底怎样把运行时更新和正式文件部署协调成一次事务。**

## 二、第一阶段：从零启动 V1 PlayerService

先只考虑运行 V1，不急着发布。

为了不影响仓库现有的 Sample，我们新建一个教学目录：

```text
hotupgrade/lesson4/
├── lesson4_main.lua
├── skynet_config.lua
├── run.sh
├── host_v1/
│   ├── service/
│   │   └── player_service.lua
│   └── lualib/
│       └── player_logic.lua
└── patches/
    └── v2/                 # 第二阶段再添加
```

这里的 `lesson4` 是我们本课新建的目录，并非现有仓库文件。

`host_v1` 保存最初的游戏代码。实际运行时，我们会把它复制到 `build/hotupgrade-lesson4/host`，作为正式宿主目录。

`patches/v2` 保存待发布的新版本。

这样做是为了保证每次运行都能从 V1 开始，而不会因为上一次热更已经覆盖了正式文件，导致无法重复学习。

### 先写最简单的业务模块

文件：`hotupgrade/lesson4/host_v1/lualib/player_logic.lua`

这是我们新编写的完整 V1 文件：

```lua
local M = {}

function M.version()
    return "v1"
end

function M.make_load(state)
    return function(base_attack)
        if state.equip == "刀" then
            return base_attack + 5
        end

        return base_attack
    end
end

return M
```

这里最值得注意的不是攻击力计算，而是 `make_load(state)`。

它返回一个 Lua 闭包：

```lua
local load = logic.make_load(state)
```

这个闭包捕获的是传入的 `state` 表引用。

因此，假设初始状态为：

```lua
state = {equip = "刀", schema_version = 1}
```

调用：

```lua
load(100)
```

就得到 `105`。

以后即使外部把 `state.equip` 改成 `"剑"`，这个旧闭包依然执行 V1 的判断规则。由于不再满足 `"刀"`，它将返回 `100`。

这里已经埋下了一个后面热更时要验证的问题：**改变状态，不等于改变函数；改变模块导出函数，也不等于改变之前缓存的闭包。**

接下来，我们创建真正持有这份状态的 PlayerService。

### 编写 V1 PlayerService

文件：`hotupgrade/lesson4/host_v1/service/player_service.lua`

下面是完整代码：

```lua
local skynet = require "skynet"
local business_queue = require "skynet.queue"()

local hot
local logic
local state
local state_root
local business
local initial_load

local function inspect()
    return
    {
        service_handle = skynet.self(),
        version = logic.version(),
        equip = state.equip,
        schema_version = state.schema_version,
        attack = business.load(100),
        initial_attack = initial_load(100),
        load_changed = business.load ~= initial_load,
        state_same = state == state_root,
        module_id = tostring(logic),
        module_alias_same = package.loaded.player_logic == logic
            and package.loaded["lualib.player_logic"] == logic,
        patching = hot.patching,
    }
end

local function initialize()
    logic = hot.require("player_logic")

    state =
    {
        equip = "刀",
        schema_version = 1,
    }
    state_root = state

    business = {load = logic.make_load(state)}
    initial_load = business.load

    return hot.register_service(
    {
        service_update = {state = state, functions = business},

        before_upgrade = function()
            return business_queue(function()
                return true
            end)
        end,

        after_upgrade = function()
            return logic.version() == "v2"
                and state.equip == "剑"
                and state.schema_version == 2
                and business.load(100) == 121
        end,
    })
end

skynet.start(function()
    hot = require "flywow_hotupgrade"

    skynet.dispatch("lua", function(session, _source, command)
        local answer

        if command == "init" then
            answer = initialize()

        elseif command == "inspect" then
            if hot.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = {ok = true, player = business_queue(inspect)}
            end

        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
```

这是本课第一个需要仔细理解的完整函数调用过程。

虽然我们已经写出了整个文件，但运行时并不是从 `initialize()` 开始。

Skynet 创建 PlayerService 时，会加载这个文件，并执行其顶层语句。它定义文件级局部变量、`inspect()`、`initialize()`，最后调用 `skynet.start()` 注册启动回调。

进入启动回调后，才执行：

```lua
hot = require "flywow_hotupgrade"
```

这里是普通 `require`，加载 HotUpgrade 框架的 Lua 入口，而不是玩家业务模块。

然后通过 `skynet.dispatch("lua", ...)` 注册 PlayerService 对外的 Lua 消息处理函数。

**到这里 PlayerService 已经有了接收消息的能力，但还没有执行 `initialize()`，玩家状态也尚未创建。**

只有其他 Service 向它发送 `"lua"` 协议的 `"init"` 命令时，dispatch 才会调用 `initialize()`。

我们马上就会从主 Service 发出这条消息。

先看 `initialize()` 中将要发生的事情。

它会通过：

```lua
logic = hot.require("player_logic")
```

加载 V1 普通业务模块。

接着创建 `state` 表，再把同一张表保存到 `state_root`。`state_root` 仅用于后面验证：热更是否保留了原来的状态根表。

`business.load` 保存 V1 `make_load(state)` 返回的闭包，`initial_load` 再保存这个闭包引用。后面即使替换 `business.load`，`initial_load` 仍然指向原来的函数。

最后，`hot.register_service()` 向 HotUpgrade 声明：

- Service 入口名是 `player_service`，由 `hot.newservice("player_service")` 创建时记录，不在登记元数据中重复传递。
- 要更新的私有状态是 `state`。
- 要更新的业务函数表是 `business`。
- 热更前要通过 `before_upgrade()` 等待业务 queue 排空。
- 更新后通过 `after_upgrade()` 确认新版本的状态和函数符合预期。

这里 `business_queue` 不是 HotUpgrade 创建的，而是我们这个 PlayerService 自己持有的 `skynet.queue()`。

业务查询 `inspect` 也进入了同一个 queue。等会儿讲到 Prepare 时，我们会看到它为什么重要。

目前先记住：**Controller 并不持有这些业务对象。它们都是这个 PlayerService 自己 Lua State 内的变量。**

### 编写启动入口，让 PlayerService 真正运行

现在新建文件：

`hotupgrade/lesson4/lesson4_main.lua`

第一阶段先使用下面这个完整版本：

```lua
local skynet = require "skynet"

skynet.start(function()
    local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hot = require "flywow_hotupgrade"

    local root = os.getenv("HOTUPGRADE_LESSON_ROOT")

    local result = skynet.call(hotupgrade_handle, "lua", "init",
    {
        patch_path = root .. "/patches",
        root_path = root .. "/host",
        service_path = "service",
    })
    if not result.ok then
        error(result.message)
    end

    local first_service_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_service_handle, "lua", "init")
    if not initialized.ok then
        error(initialized.message)
    end

    local response = skynet.call(first_service_handle, "lua", "inspect")
    local player = response.player

    print("service_handle:", player.service_handle)
    print("version:", player.version)
    print("equip:", player.equip)
    print("schema:", player.schema_version)
    print("attack:", player.attack)

    io.stdout:flush()
    os.exit(0)
end)
```

这个文件既是我们编写的主 Service 入口，也是本课整个执行过程的起点。

我们从 `skynet.start()` 的回调进入，先执行：

```lua
local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
```

这里使用的是 **Skynet 原生 `uniqueservice()`**，创建或取得进程中的唯一 HotUpgrade Service。

HotUpgrade Service 的入口文件是仓库现有的：

`hotupgrade/service/flywow_hotupgrade_service.lua`

HotUpgrade Service 启动后，在自己的 Lua State 中加载 `flywow_hotupgrade_controller.lua`，并注册 `lua` 和 `hotupgrade` 两套协议处理。

随后我们的主 Service 发送：

```lua
skynet.call(hotupgrade_handle, "lua", "init", ...)
```

注意，现在仍然是主 Service 在执行。`skynet.call()` 会使当前调用协程等待 Controller 的回复。

消息到达 Controller 后，由它的 `"lua"` dispatch 处理 `"init"`，调用：

`flywow_hotupgrade_controller.lua` 中的 `M.initialize(controller_config)`。

这个函数会验证并保存三个配置：

- `patch_path`：以后从哪里读取 V2 发布包。
- `root_path`：正式宿主文件在哪里。
- `service_path`：Service 入口文件所在的相对目录。

还会建立目标登记表、创建中的 Service 记录、模块加载许可记录，以及后面发布事务使用的状态。

初始化成功后，Controller 返回 `{ok=true}`。主 Service 的 `skynet.call()` 恢复执行。

此时 Controller 已经准备好了，但没有任何 PlayerService 登记，也没有任何发布事务。

现在主 Service 执行：

```lua
local first_service_handle = hot.newservice("player_service")
```

这个函数不是 `skynet.newservice()` 的简单别名。它需要通过 Controller 建立受管理的创建记录。

我们进入真实 HotUpgrade 源码。

### 追踪 `hot.newservice()` 的真实实现

文件：`hotupgrade/lualib/flywow_hotupgrade.lua`

函数：`M.newservice()`，由刚才的 `lesson4_main.lua` 调用。

当前源码为：

```lua
function M.newservice(service_name, ...)
    -- 基础设施转发未知启动签名，固定 n 以保留参数个数和 nil。
    local answer = skynet.call(hotupgrade_handle, "hotupgrade", "newservice",
        {service_name = service_name, arguments = table.pack(...)})
    assert(type(answer) == "table" and answer.ok,
        tostring(type(answer) == "table" and answer.code) .. ": " ..
        tostring(type(answer) == "table" and answer.message or answer))
    return answer.service_handle
end
```

这里的 `hotupgrade_handle` 是 HotUpgrade 模块在所在 Lua State 内取得的 HotUpgrade Service handle。

函数把创建请求发送给 Controller。主 Service 当前协程等待回复。

Controller 收到 `"hotupgrade"` 协议的 `"newservice"` 命令后，由：

`hotupgrade/service/flywow_hotupgrade_service.lua` 中的 dispatch

调用：

`flywow_hotupgrade_controller.lua` 的 `M:handle_command()`。

`handle_command()` 将这条请求分发给同文件的 `M:newservice()`。

Controller 的 `M:newservice()` 会检查发布门禁，然后建立一个 `creation` 记录，增加 `creation_count`，再真正调用：

```lua
skynet.newservice(request.service_name,
    table.unpack(request.arguments, 1, request.arguments.n))
```

这一段属于：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:newservice()`，由 `M:handle_command()` 分发调用。

真正创建新 Service 的仍是 Skynet。Controller 只是管理这次创建操作的生命周期。

Skynet 创建 PlayerService 并返回 handle 后，Controller 将 handle 保存到创建记录，然后通过原先的 RPC 返回给主 Service。

因此：

```lua
local first_service_handle = hot.newservice("player_service")
```

执行完毕后，`first_service_handle` 是一个真实的 Skynet Service handle。

但现在有一个容易忽略的区别：

**取得 handle，不代表 PlayerService 已经完成业务初始化和 HotUpgrade 登记。**

Controller 仍然保留刚才的待创建记录。

所以主 Service 接着执行：

```lua
local initialized = skynet.call(first_service_handle, "lua", "init")
```

这才是前面我们编写的 PlayerService 真正执行 `initialize()` 的时刻。

这里的 `"lua"` 是 Skynet 协议名，`"init"` 是业务命令名。它通过消息 dispatch 进入 PlayerService，而不是主 Service 直接调用对方的 Lua 函数。

PlayerService 的 `initialize()` 加载 V1 `player_logic.lua`，创建状态与业务闭包，再调用 `hot.register_service()`。

### `register_service()` 实际向 Controller 发送什么？

现在执行位置已经从主 Service 跨到了 PlayerService。

函数来源：

`hotupgrade/lualib/flywow_hotupgrade.lua` 的 `M.register_service()`。

调用者：

我们编写的 `host_v1/service/player_service.lua` 中的 `initialize()`。

该函数会把本地声明转换为一份元数据记录。下面是其真实源码中构造并发送登记请求的连续代码：

```lua
local names = {}
for name in pairs(module_state.declared_modules) do
    names[#names + 1] = name
end
table.sort(names)

---@type FlyWowHotUpgradeTargetMetadata
local metadata =
{
    modules = names,
    has_service_update = service_update ~= nil,
}
local ok, answer = pcall(skynet.call, hotupgrade_handle, "hotupgrade", "register", metadata)
```

注意，这个请求里没有 `state`，没有 `business`，也没有 `initial_load`。

Controller 只需要知道：哪个 Service、登记了哪些普通模块、是否提供 Service 更新配置。

Controller 最终持有的目标记录可以理解为（其中 `service_name` 来自受管理创建记录，不是 `register_service()` 请求字段）：

```lua
{
    service_name = "player_service",
    modules = {"lualib.player_logic"},
    has_service_update = true,
}
```

这是一份根据当前 Sample 登记过程得到的说明性数据，并非另一段需要编写的代码。

为什么模块名是 `lualib.player_logic`？

因为 `hot.require("player_logic")` 会先用 `package.searchpath()` 定位实际文件，再根据它相对 `root_path` 的路径生成规范登记名。

本例找到：

`host/lualib/player_logic.lua`

因此登记为：

`lualib.player_logic`

同时，在 PlayerService 的 Lua State 中：

```text
package.loaded["player_logic"]
                 │
                 ▼
          同一张模块导出表
                 ▲
                 │
package.loaded["lualib.player_logic"]
```

Controller 收到 `"register"` 后，由：

`flywow_hotupgrade_controller.lua` 的 `M:register()`

处理登记。

它使用 Skynet 消息携带的真实 `source` 作为 PlayerService handle，将元数据保存到 `self.service_registrations[source]`，并通过 `finish_creation()` 移除刚才的待创建记录。

登记 RPC 返回成功，PlayerService 的 `initialize()` 才结束；PlayerService 再通过 `skynet.retpack()` 把结果回复给主 Service。

这样主 Service 才能安全地执行后面的 `"inspect"`。

我们至此走完了：

```text
主 Service：lesson4_main.lua
    hot.newservice("player_service")
            ↓ RPC
HotUpgrade Service：M:newservice()
    skynet.newservice() → 返回 first_service_handle
            ↓
主 Service
    skynet.call(first_service_handle, "lua", "init")
            ↓ RPC
PlayerService：Lua dispatch → initialize()
    hot.require() → hot.register_service()
            ↓ RPC
HotUpgrade Service：M:register() → finish_creation()
            ↓ 返回
PlayerService：init 回复 → 主 Service：inspect
```

### 当前状态

第一次创建和登记完成后，我们应该建立这样一份运行时状态：

```text
HotUpgrade Service
    phase = IDLE
    active_batch = nil
    sequence = 0
    creation_count = 0
    module_load_count = 0
    targets[first_service_handle] = 已登记的目标元数据

PlayerService（first_service_handle）
    hot.patching = false
    module_state.active_transaction = nil

    logic.version() = "v1"
    state = {equip="刀", schema_version=1}
    state_root == state

    business.load(100) = 105
    initial_load(100) = 105
    business.load == initial_load

    package.loaded["player_logic"] == logic
    package.loaded["lualib.player_logic"] == logic

正式宿主磁盘
    player_service.lua = V1
    player_logic.lua = V1
```

这些是根据真实源码和我们新写的 Sample 推导出的状态，不是已经运行测试取得的输出。

这里应该能够清楚区分三个对象：

`first_service_handle` 是 Service 的标识；`state` 是 PlayerService Lua State 内的一张 table；`logic` 是同一个 Lua State 内已经加载的普通模块导出 table。

它们不是同一类对象，也没有通过 Controller 直接共享。

### 让第一阶段真正运行起来

现在补上运行环境。这部分只是 Skynet 的启动配置与目录准备，不属于 HotUpgrade 的事务实现。

文件：`hotupgrade/lesson4/skynet_config.lua`

```lua
local framework_root = "./third_party/skynet-flywow"
local runtime_root = framework_root .. "/build/hotupgrade-lesson4"

thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "lesson4_main"

lualoader = "./third_party/skynet/lualib/loader.lua"

luaservice = framework_root .. "/hotupgrade/service/?.lua;"
    .. framework_root .. "/hotupgrade/lesson4/?.lua;"
    .. runtime_root .. "/host/service/?.lua;"
    .. "./third_party/skynet/service/?.lua"

lua_path = runtime_root .. "/host/?.lua;"
    .. runtime_root .. "/host/lualib/?.lua;"
    .. runtime_root .. "/host/lualib/?/init.lua;"
    .. "./third_party/skynet/lualib/?.lua;"
    .. "./third_party/skynet/lualib/?/init.lua;"
    .. framework_root .. "/hotupgrade/lualib/?.lua"

lua_cpath = "./third_party/skynet/luaclib/?.so;"
    .. framework_root .. "/build/native/?.so"

cpath = "./third_party/skynet/cservice/?.so"
```

这里有两个搜索路径需要分清：

`luaservice` 用于查找 Skynet Service 入口文件，比如我们的 `player_service.lua`。

`lua_path` 用于查找普通 Lua 模块，比如 `player_logic.lua` 和 FlyWow 的 `flywow_hotupgrade.lua`。

而 `lua_cpath` 允许 HotUpgrade 加载已经构建的 Native 模块。

接着编写启动脚本。

文件：`hotupgrade/lesson4/run.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?请传入 Skynet 根目录}")"

RUNTIME_ROOT="$FRAMEWORK_DIR/build/hotupgrade-lesson4"

rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/host" "$RUNTIME_ROOT/patches"

cp -a "$SCRIPT_DIR/host_v1/." "$RUNTIME_ROOT/host/"
cp -a "$SCRIPT_DIR/patches/." "$RUNTIME_ROOT/patches/"

export HOTUPGRADE_LESSON_ROOT="$RUNTIME_ROOT"

cd "$SERVER_ROOT"
"$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua"
```

这个脚本每次重新创建运行目录，把 V1 文件作为正式宿主文件，并复制我们准备的 Patch。

没有引入检查包装、重试机制或测试框架。

在 FlyWow 根目录执行：

```bash
mkdir -p hotupgrade/lesson4/patches

bash scripts/build_flywow.sh ../skynet hotupgrade

bash hotupgrade/lesson4/run.sh ../skynet
```

这里沿用仓库现有的目录约定：Skynet 位于与 `skynet-flywow` 同级的 `../skynet`。

第一阶段预期打印：

```text
handle: <实际 Service handle>
version: v1
equip: 刀
schema: 1
attack: 105
```

其中 handle 由 Skynet 分配，每次运行不保证相同。

到此为止，我们还没有执行任何热更操作。

目前只是完成了最基本的事情：**一个 PlayerService 在自己的 Lua State 中运行 V1 业务代码，并把将来需要热更的模块和状态登记给 Controller。**

## 三、第二阶段：亲手编写 V2 发布包

第一阶段运行的是 V1。现在不修改正在运行的实例，而是站在开发者准备新版本的角度，编写 V2 发布包。

这次我们需要修改三样东西。

普通 Lua 模块的攻击力规则要更新；已有玩家的装备和状态版本需要迁移；未来新创建的 PlayerService 要直接使用 V2 初始化逻辑。

所以我们的发布包是：

```text
hotupgrade/lesson4/patches/v2/
├── lualib/
│   └── player_logic.lua
└── service/
    ├── player_service.lua
    └── player_service.patch
```

注意这三个文件的作用不同，不能互相替代。

### 编写 V2 普通模块

文件：`hotupgrade/lesson4/patches/v2/lualib/player_logic.lua`

完整代码：

```lua
local M = {}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        if state.equip == "剑" then
            return base_attack + 20 + 1
        end

        return base_attack
    end
end

return M
```

和 V1 相比，改动非常直接：

V1 判断 `"刀"`，加 5。

V2 判断 `"剑"`，加 21。

但我们没有只写一个新的 `make_load()`，而是提供了整个模块的完整 V2。

这是因为当前 HotUpgrade 对普通 Lua 模块采用**完整导出表更新**，不是只替换补丁中出现的个别函数字段。

更新时，旧导出表将保留身份，其字段集合会按新版模块重建。

### 编写现存 PlayerService 的一次性 Patch

现在解决第二个问题。

`first_service_handle` 对应的 PlayerService 已经运行，它内部的 `state` 还是：

```lua
{
    equip = "刀",
    schema_version = 1,
}
```

它还持有 V1 的 `business.load`。

即使我们把 `player_logic.lua` 热更成 V2，之前保存到 `business.load` 的闭包仍然是旧函数。

因此，我们需要一份针对**现存 Service** 的更新脚本。

文件：`hotupgrade/lesson4/patches/v2/service/player_service.patch`

完整代码：

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

这份文件没有使用 `require()`，也不直接访问 PlayerService 的全局变量。

它返回一个构建函数。

HotUpgrade 之后会在原 PlayerService 的 Lua State 内执行这个函数，并把那个 Service 的真实 `state` 根表传进来。

构建函数返回两部分内容：

构建函数接收现存 state，只准备闭包，不修改线上状态。update_state() 不接收参数、不返回候选状态，在 Update 同步提交阶段直接修改现存 state。嵌套赋值、共享引用、循环引用和赋 nil 删除字段均遵循普通 Lua 语义；未修改字段自然保留，不生成候选状态、不递归合并。

replace_functions 只列出需要替换的现有业务函数；未列出的函数保持原样，新函数捕获原 state。没有状态修改可省略 update_state，没有函数替换可省略 replace_functions，至少提供一项。旧 migrate / functions 字段不再接受。

准备阶段保存旧状态快照和旧函数。提交前先标记 touched，再调用 update_state()，随后安装 replace_functions，最后执行 after_upgrade。部分写入抛错及后续失败沿现有 Abort 恢复；恢复失败报告 RECOVERY_REQUIRED，结束本批后仍释放入口。迁移运行错误在 Update 提交时发现。成功 Finish 后清理快照。

默认快照支持普通数据图，保留共享和循环关系，最多 128 层、10000 个字段。这是保存恢复快照的限制，不是更新值合并限制。恢复保持线上根表身份，不承诺嵌套表身份。特殊对象由 Service 提供成对回调：

- snapshot(state)：返回与线上可变数据隔离的旧状态快照，可将特殊对象编码为普通表。
- restore(state, old_state)：恢复现存状态及特殊业务对象；返回 false 或抛错表示恢复失败。

service_update.commit 已删除，不保留兼容。构建、更新、快照、恢复和检查都必须同步，不得 yield、执行外部 I/O 或产生不可撤销副作用；不得替换整个线上状态根表。框架不提供安全沙箱。


### 编写正式 V2 Service 文件

最后一个文件专门给以后新创建的 PlayerService 使用。

文件：`hotupgrade/lesson4/patches/v2/service/player_service.lua`

这是完整 V2 文件：

```lua
local skynet = require "skynet"
local business_queue = require "skynet.queue"()

local hot
local logic
local state
local state_root
local business
local initial_load

local function inspect()
    return
    {
        service_handle = skynet.self(),
        version = logic.version(),
        equip = state.equip,
        schema_version = state.schema_version,
        attack = business.load(100),
        initial_attack = initial_load(100),
        load_changed = business.load ~= initial_load,
        state_same = state == state_root,
        module_id = tostring(logic),
        module_alias_same = package.loaded.player_logic == logic
            and package.loaded["lualib.player_logic"] == logic,
        patching = hot.patching,
    }
end

local function initialize()
    logic = hot.require("player_logic")

    state =
    {
        equip = "剑",
        schema_version = 2,
    }
    state_root = state

    business = {load = logic.make_load(state)}
    initial_load = business.load

    return hot.register_service(
    {
        service_update = {state = state, functions = business},

        before_upgrade = function()
            return business_queue(function()
                return true
            end)
        end,

        after_upgrade = function()
            return logic.version() == "v2"
                and state.equip == "剑"
                and state.schema_version == 2
                and business.load(100) == 121
        end,
    })
end

skynet.start(function()
    hot = require "flywow_hotupgrade"

    skynet.dispatch("lua", function(session, _source, command)
        local answer

        if command == "init" then
            answer = initialize()

        elseif command == "inspect" then
            if hot.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = {ok = true, player = business_queue(inspect)}
            end

        else
            answer = {ok = false, code = "HU_UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
```

这份 V2 Service 与 V1 Service 的主要区别，只在 `initialize()` 创建初始玩家状态的位置：

V1 初始化为 `"刀"`、schema 1。

V2 初始化为 `"剑"`、schema 2。

其他代码保持一样，是为了避免无意义的功能变化干扰我们理解热更。

**现在我们有了一份完整的 V2 发布包，但还没有执行它。**

从运行时角度看，原来的 PlayerService 仍然持有 V1 状态和 V1 函数。

而从文件角度看，V2 位于独立的 `patches/v2` 目录中，尚未部署到正式宿主目录。

下一阶段开始，把这三份文件交给 Controller。

## 四、第三阶段：发起真正的热更，沿源码跟踪整个事务

现在 V1 能正常运行，V2 发布包也准备好了。

我们只需要让主 Service 发起一次发布，然后等待 Controller 报告结果。

### 修改主 Service，让它发布 V2

文件：`hotupgrade/lesson4/lesson4_main.lua`

这是第二阶段之后使用的**完整最终版本**。直接覆盖第一阶段的主 Service 文件：

```lua
local skynet = require "skynet"

skynet.start(function()
    local hotupgrade_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hot = require "flywow_hotupgrade"
    local root = os.getenv("HOTUPGRADE_LESSON_ROOT")

    -- 初始化 Controller。
    local result = skynet.call(hotupgrade_handle, "lua", "init",
    {
        patch_path = root .. "/patches",
        root_path = root .. "/host",
        service_path = "service",
    })
    if not result.ok then
        error(result.message)
    end

    -- 创建第一个 PlayerService，执行 V1。
    local first_service_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_service_handle, "lua", "init")
    if not initialized.ok then
        error(initialized.message)
    end

    local before = skynet.call(first_service_handle, "lua", "inspect")
    print("发布前:", before.player.version, before.player.equip,
        before.player.schema_version, before.player.attack)

    -- 开始发布 V2。
    local begun = skynet.call(hotupgrade_handle, "hotupgrade", "begin",
    {
        path = "v2",
    })
    if not begun.ok then
        error(begun.message)
    end

    print("发布批次:", begun.batch_id)

    -- 等待该批次执行完毕。
    while true do
        local status = skynet.call(hotupgrade_handle, "hotupgrade", "status",
        {
            batch_id = begun.batch_id,
        })
        if not status.ok then
            error(status.message)
        end

        local phase = status.record.phase
        if phase == "COMPLETED" then
            break
        end

        if phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
            error(status.record.error and status.record.error.message or phase)
        end

        skynet.sleep(1)
    end

    -- 检查原 PlayerService。
    local after = skynet.call(first_service_handle, "lua", "inspect")

    print("发布后:", after.player.version, after.player.equip,
        after.player.schema_version, after.player.attack)

    print("原 Service handle 保持:", first_service_handle == after.player.service_handle)
    print("原状态根表保持:", after.player.state_same)
    print("原模块根表保持:",
        before.player.module_id == after.player.module_id)
    print("模块缓存别名保持:", after.player.module_alias_same)
    print("业务函数已替换:", after.player.load_changed)
    print("旧闭包的攻击力:", after.player.initial_attack)
    print("原 Service patching:", after.player.patching)

    -- 创建第二个 PlayerService，直接运行 V2。
    local second_service_handle = hot.newservice("player_service")
    local second_initialized = skynet.call(second_service_handle, "lua", "init")
    if not second_initialized.ok then
        error(second_initialized.message)
    end

    local second = skynet.call(second_service_handle, "lua", "inspect")

    print("新 PlayerService:", second.player.version, second.player.equip,
        second.player.schema_version, second.player.attack)
    print("两个 Service 的 handle 不同:", second_service_handle ~= first_service_handle)

    io.stdout:flush()
    os.exit(0)
end)
```

这次代码只有几个实质性步骤：创建 V1、调用 `begin`、通过 `status` 等待、检查原 Service、创建新 Service。

`skynet.sleep(1)` 只是主 Service 等待发布结果时让出执行权。这个简单循环属于我们编写的 Sample，并不是 Controller 的内部事务执行机制。

下面不再添加 Sample 代码。我们就从这份 `lesson4_main.lua` 开始，沿真正的 HotUpgrade 源码，一直走到发布完成。

### 1. `begin()` 为什么可以先返回，热更却还没完成？

前面的 V1 创建和登记过程已经讲过，现在从主 Service 的这条 RPC 开始：

```lua
local begun = skynet.call(hotupgrade_handle, "hotupgrade", "begin",
{
    path = "v2",
})
```

代码来源是 `hotupgrade/lesson4/lesson4_main.lua` 的 `skynet.start()` 回调。

`hotupgrade_handle` 来自之前的 `skynet.uniqueservice()`，`path="v2"` 则表示选择 Controller 配置的 `patch_path` 下的 `v2` 目录。

这是一条跨 Service 的 RPC。主 Service 发送请求后 yield，等待 Controller 回复。

消息到达的真实入口是：

`hotupgrade/service/flywow_hotupgrade_service.lua`

其 `skynet.dispatch("hotupgrade", ...)` 调用：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 中的 `M:handle_command()`。

`handle_command()` 根据 `"begin"` 命令进入同文件的 `M:begin()`。

我们来看这个完整函数：

```lua
function M:begin(request)
    if self.active_batch then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "已有发布屏障")
    end
    local path = request.path
    self.sequence = self.sequence + 1
    self.active_batch =
    {
        batch_id = tostring(skynet.self()) .. ":" .. self.sequence,
        sequence = self.sequence,
        phase = "WAITING_CREATIONS",
        results = {},
        targets = {},
        success = 0,
        failed = 0,
        target_count = 0,
    }
    self.phase = "WAITING_CREATIONS"
    local batch = self.active_batch
    skynet.fork(function()
        self:run_batch(batch, {path = path})
    end)
    return hotupgrade_result.success({batch_id = batch.batch_id})
end
```

这就是 Controller 接受一次发布的完整过程。

此处有两个不同的状态对象：

`self` 是 Controller 模块表本身，保存唯一控制面的运行状态。现有实现没有创建额外的 Controller 实例。

`batch` 是刚刚创建的一次发布批次对象。

`self.active_batch = batch` 代表 Controller 当前正在管理这个批次。

`self.sequence` 则是 Controller 生命周期内不断递增的批次序号。它与 HotUpgrade Service 的真实 handle 一起组成 `batch_id`，用于区分不同发布批次。

创建完批次后：

```lua
skynet.fork(function()
    self:run_batch(batch, {path = path})
end)
```

这里的 `skynet.fork()` 创建了一个新的 Skynet 协程来执行发布流程。

**`fork()` 不会等待 `run()` 执行完毕。**

当前处理 `"begin"` RPC 的协程继续往下执行，直接返回：

```lua
return hotupgrade_result.success({batch_id = batch.batch_id})
```

于是主 Service 的 `skynet.call()` 恢复执行，拿到了 `batch_id`。

这只表示 Controller **接受了发布请求**，并不表示业务已经更新。

后续真正的文件加载、Prepare、Update、Finish，都由新协程中的 `M:run_batch()` 负责执行。

这也是为什么我们的 Sample 必须通过 `status({batch_id=...})` 等待最终结果。

#### 第一次状态快照：begin 被接受

```text
Controller
    phase = WAITING_CREATIONS
    active_batch = batch
    sequence = 1
    batch.batch_id = "<HotUpgrade Service handle>:1"
    batch.sequence = 1
    batch.phase = WAITING_CREATIONS
    batch.targets = {}
    batch.files = nil
    recovery_required = false

原 PlayerService
    hot.patching = false
    active_transaction = nil
    state = V1
    logic = V1
    business.load = V1

正式磁盘
    player_service.lua = V1
    player_logic.lua = V1
```

此时还没有向 PlayerService 发送任何更新命令。

### 2. 为什么 `run_batch()` 先等待创建和模块登记？

接下来执行权来到 Controller 新协程。

当前函数：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:run_batch(batch, request)`。

调用者是刚才 `M:begin()` 创建的 `skynet.fork()` 协程。

先看 `run_batch()` 的开头，这是一段连续真实源码：

```lua
function M:run_batch(batch, request)
    -- 登记 waiter 到 wait 之间不 yield；完成回调会唤醒同一批次，恢复后重验身份和计数。
    while self.active_batch == batch and (self.creation_count > 0 or self.module_load_count > 0) do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end
    if self.active_batch ~= batch then
        return
    end
    -- 扫描和文件快照阶段同步执行；Prepare 开始后重新开放接纳窗口。
    self.phase = "DEPLOYING"
    batch.phase = "DEPLOYING"
    local ok, message = pcall(function()
        local loaded = self:load_patch(request)
        if not loaded.ok then
            batch.error = loaded
            return
        end
```

这段代码解决的是一个具体问题：

**接受发布的瞬间，是否还有 Service 正在创建，或者某个 Service 正在首次加载并登记普通模块？**

考虑下面这个执行顺序：

1. 某个业务协程调用 `hot.newservice()`。
2. Controller 已经调用原生 `skynet.newservice()`，但业务 `init` 还没有完成。
3. 管理端同时调用 `begin()` 发起发布。

如果 Controller 不等待，就可能在确定更新目标时漏掉这个尚未登记完毕的 Service。

普通模块首次加载也有类似问题。某个已经登记的 Service 取得模块加载许可后，正在执行 `hot.require()`，它的模块可能还没有登记到 Controller。

所以 Controller 使用两个计数：

`creation_count` 记录尚未完成创建或登记的操作。

`module_load_count` 记录尚未完成或取消的首次模块加载许可。

只要任一计数不为零，`run_batch()` 就通过 `skynet.wait()` 等待。此时创建和首次加载仍允许进入，因此父初始化需要创建子 Service、模块加载需要继续加载依赖，都可以正常完成。新增操作继续计数，不能漏过排空。

当这些操作完成时，相应的登记或取消函数会更新计数，并调用 `wake_batch()`。两个计数都归零时，它只唤醒正在等待的发布协程，不推进阶段。最后关闭门禁的决定要等 Prepare 和新增目标全部收口。

`skynet.wakeup()` 只是让协程有机会恢复，`run_batch()` 恢复后仍然重新检查计数以及当前 `batch` 的身份。

在我们这次 Sample 中，第一次 PlayerService 的 `init` RPC 已经成功返回，创建和模块登记都已完成，因此两个计数都是零，不需要实际等待。

不过这里必须理解清楚：

**生命周期屏障保护的是 Service 和模块登记过程，不是玩家正在执行的业务。**

玩家业务的安全点，要等到稍后的 Prepare 才建立。

这是两种不同的等待机制，不能混为一谈。

### 3. Controller 怎样读取发布包并确定目标？

当前在途操作完成后，`run_batch()` 进入：

```lua
local loaded = self:load_patch(request)
```

这是对同一个 Controller 模块表的方法调用，仍然运行在 HotUpgrade Service 的 Lua State 内，没有跨 Service。

现在进入：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:load_patch()`。

这里的 `request.path` 就是我们从 Sample 传入的 `"v2"`。

`M:load_patch()` 先检查生命周期和请求，再调用同文件的 `build_patch()`。

`build_patch()` 经由 `load_files()` 和 Native `list_lua()` 扫描发布目录，使用 Native `read_file()` 读取文件内容。

对每份源码，`load_files()` 用：

```lua
local chunk, syntax_error = load(hotupgrade_common.normalize_source(source), "@" .. relative, "t", {})
if not chunk then
    return hotupgrade_result.failure("HU_MODULE_SYNTAX", syntax_error)
end
```

`hotupgrade_common.normalize_source()` 定义于 `hotupgrade/lualib/flywow_hotupgrade_common.lua`，按 Lua 文件加载规则跳过 UTF-8 BOM 和首行 `#` 注释并保留换行。这里只转换编译输入；冻结、部署和恢复使用原始源码字节。


这段位于 `flywow_hotupgrade_controller.lua` 的 `load_files()` 中，由 `build_patch()` 调用。

这里调用的 Lua `load()` 是**编译源码并检查语法**，没有执行返回的 `chunk`。

因此，扫描发布包时，Controller 并没有运行我们的 V2 `player_logic.lua` 或 `player_service.patch`。

它只是读取并冻结源码字符串，确保后续所有阶段使用同一次读取的内容。

接着，`build_patch()` 按文件类型形成三个集合。

对于我们刚才编写的文件：

| 文件 | Controller 的分类 |
|---|---|
| `lualib/player_logic.lua` | 普通模块 Patch，同时是正式部署文件 |
| `service/player_service.patch` | 现存 Service 的一次性 Patch |
| `service/player_service.lua` | 正式部署文件 |

这里最关键的是：`service/player_service.patch` **不属于正式部署文件**。

因为它是用于升级现存 PlayerService 的一次性脚本，而不是以后 Skynet 创建 Service 时要加载的入口文件。

分类之后，`M:load_patch()` 调用内部 `match_targets()`，根据 Controller 已保存的 `targets` 登记表确定初始目标。Prepare 期间新增登记或模块声明后，仍调用这个匹配函数，但复用已经冻结的 Patch，不重新读文件。

真实源码的目标匹配函数位于同一个 Controller 文件，由 `M:load_patch()` 和 Prepare 收口过程共同调用：

```lua
-- 对同一份冻结 Patch 匹配当前登记信息；Prepare 后重用，不重新读取或执行源码。
---@param registered_services table<integer, FlyWowHotUpgradeRegisteredService> Controller 当前已登记的 Service
---@param selected_patch_path string 发布包相对路径，仅用于匹配失败诊断
local function match_targets(patch, registered_services, selected_patch_path)
    -- 从当前登记信息选出运行时接收者；只有一次性 Service .patch 强制要求目标存在。
    ---@type FlyWowHotUpgradeBatchTarget[]
    local targets = {} -- 本批需要执行原有更新协议的真实 Service。
    local matched = {} -- 当前登记快照已覆盖的 Service .patch 文件。
    for _, record in pairs(registered_services) do
        local modules = {}
        for _, entry in ipairs(patch.modules) do
            if record.modules[entry.name] then
                modules[#modules + 1] = entry
            end
        end

        local service = patch.service_patches[record.service_name]
        if service and not record.has_service_update then
            return hotupgrade_result.failure("HU_SERVICE_PATCH_UNSUPPORTED", selected_patch_path .. "/" .. service.entry_file
                .. ": 目标 " .. record.service_handle .. " 未提供 Service 内部更新入口")
        end

        if service then
            matched[service.entry_file] = true
        end

        if #modules > 0 or service then
            targets[#targets + 1] =
            {
                service_handle = record.service_handle,
                modules = modules,
                service_source = service and service.source,
                service_entry_file = service and service.entry_file,
            }
        end
    end
    -- 完整 .lua 无运行时接收者时只部署；一次性 .patch 必须匹配现存目标。
    for service_name, entry in pairs(patch.service_patches) do
        if not matched[entry.entry_file] then
            return hotupgrade_result.failure("HU_TARGET_MISSING", selected_patch_path .. "/" .. entry.entry_file
                .. ": 没有已登记目标匹配 Service 名称 " .. service_name)
        end
    end

    table.sort(targets, function(left, right)
        return left.service_handle < right.service_handle
    end)
    return hotupgrade_result.success({targets = targets})
end
```

其中 `patch` 是同一份冻结源码，`registered_services` 是 Controller 当前的登记表，`selected_patch_path` 只用于错误诊断。首次匹配失败仍在任何目标控制 RPC 之前退出；Prepare 后重匹配失败则撤销已经参与的目标。

Controller 从 `self.service_registrations` 取出此前登记的 `first_service_handle`。

它发现这个 Service 已声明：

`lualib.player_logic`

而本次发布包恰好包含同名的完整模块 Patch。

同时，该 Service 的 `service_name` 是 `player_service`，与发布包中的 `service/player_service.patch` 匹配，而且登记时声明支持 Service 内部更新。

所以本次将 `first_service_handle` 加入更新目标。

得到的目标记录可以理解为：

```lua
{
    service_handle = first_service_handle,
    modules = {
        {
            name = "lualib.player_logic",
            entry_file = "lualib/player_logic.lua",
            source = "<冻结的 V2 Lua 源码>",
        },
    },
    service_source = "<冻结的 player_service.patch 源码>",
    service_entry_file = "service/player_service.patch",
}
```

上面是目标数据结构的示意，字符串中的占位文本不是实际传输的源码内容。

注意，这份记录仍然不包含 PlayerService 的 `state` 或 `business` 对象。

Controller 只知道应该把哪些源码发送给哪个 Service。

真正的模块表、状态表和业务函数表，都需要等 RPC 到达 PlayerService 后，在那个 Lua State 中完成更新。

`M:load_patch()` 也会检查发布包中的 Service Patch 是否至少匹配一个目标。如果找不到对应的已登记 Service，就不会继续本次发布。

### 4. Prepare 之前，Controller 还做了什么？

现在返回 `M:run_batch()`。

`M:load_patch()` 已经成功返回，里面包含两样东西：

`loaded.patch`：本次完整发布包的冻结内容。

`loaded.targets`：首次匹配到的运行时更新目标，Prepare 期间还可能补入新目标。

接下来，`run_batch()` 先读取正式宿主目录中每份将被部署的 `.lua` 文件的旧内容，保存为 `file.old_source`，供发布决定前失败时恢复。

然后保存冻结文件和初始目标：

```lua
batch.files = loaded.patch.files
batch.targets = loaded.targets
batch.target_count = #loaded.targets
```

这些语句位于 `flywow_hotupgrade_controller.lua` 的 `M:run_batch()`，在 `self:load_patch(request)` 返回之后执行。

本次 `batch.files` 包含两份完整 `.lua` 文件：

```text
lualib/player_logic.lua
service/player_service.lua
```

`batch.targets` 则只有一个目标，即 `first_service_handle`。

到这里，Controller 终于可以开始联系 PlayerService。

#### 第二次状态快照：文件已冻结，初始目标已匹配

```text
Controller
    phase = DEPLOYING → 即将进入 APPLYING
    active_batch = batch
    batch.targets = {first_service_handle}
    batch.target_count = 1
    batch.files = {player_logic.lua, player_service.lua}

    已保存正式文件旧内容：
        player_logic.lua = V1
        player_service.lua = V1

原 PlayerService
    hot.patching = false
    active_transaction = nil
    业务仍然是 V1

正式磁盘
    player_logic.lua = V1
    player_service.lua = V1

发布包
    V2 源码已经由 Controller 冻结
```

在这一步，Controller 完成的是**发布准备工作**，还没有改变 PlayerService，也没有改写正式文件。

接下来才是真正的运行时更新。

### 5. Prepare：Controller 怎样让 PlayerService 到达安全点？

现在回到 Controller 的 `M:run_batch()`。

接下来执行的是这个函数中的一段连续源码：

```lua
batch.targets = loaded.targets
batch.target_count = #loaded.targets
self.phase = "APPLYING"

-- Prepare 期间仍用旧宿主文件；保留每个目标的参与记录，新目标补做一次 Prepare。
local targets_by_handle = {} -- 本批记录的临时索引；重匹配时保留 participated 和恢复信息。
for _, target in ipairs(batch.targets) do
    targets_by_handle[target.service_handle] = target
end

batch.phase = "PREPARE"
while true do
    for _, target in ipairs(batch.targets) do
        if not target.participated then
            batch.current_service_handle = target.service_handle
            target.participated = true
            local answer = self:step(batch, target, "prepare")
            if not answer.ok then
                target.result = answer
                batch.error = answer
                return
            end
        end
    end

    -- 回调可能等待创建或首次加载；允许这些依赖完成，完成通知会唤醒本批。
    while self.creation_count > 0 or self.module_load_count > 0 do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end

    -- 同一份冻结源码覆盖新增登记和模块声明；匹配失败时仍保留旧记录用于 Abort。
    local matched = match_targets(loaded.patch, self.service_registrations, request.path)
    if not matched.ok then
        batch.error = matched
        return
    end

    local needs_prepare = false
    for index, current in ipairs(matched.targets) do
        local target = targets_by_handle[current.service_handle]
        if target then
            target.modules = current.modules
        else
            target = current
            targets_by_handle[target.service_handle] = target
            needs_prepare = true
        end
        matched.targets[index] = target
    end
    batch.targets = matched.targets
    batch.target_count = #batch.targets
    if not needs_prepare then
        break
    end
end

-- 最终匹配、计数检查到进入 Update 之间不 yield；此刻一次性关闭创建和加载门禁。
batch.phase = "UPDATE"
for _, target in ipairs(batch.targets) do
    batch.current_service_handle = target.service_handle
    local answer = self:step(batch, target, "update")
    if not answer.ok then
        target.result = answer
        batch.error = answer
        return
    end
end

```

这段代码来自：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:run_batch()`。

begin 接受后不提供管理端主动取消；Controller 的管理命令 abort 返回 HU_UNKNOWN_COMMAND。下面的内部 Abort 只在批次失败后恢复目标，不是管理端取消入口。

这里的外层 `while true` 只覆盖 Prepare 收口。它依次做三件事：给尚未参与的目标发 Prepare；等待回调期间产生的创建和首次加载完成；用冻结 Patch 重新匹配当前登记信息。

`targets_by_handle` 是本批记录的临时索引，让重匹配复用同一个目标记录。已经成功 Prepare 的目标保留 `participated=true`，下一轮不会重复调用回调；它新增的受影响模块写入 `target.modules`。新增目标则在下一轮执行一次 Prepare。

举例：A 正在排空的业务创建 B，B 初始化又创建 C。此时 B、C 都可正常启动、加载旧文件并登记；Controller 将匹配本批 Patch 的 B、C 纳入目标，再让它们各做一次 Prepare。没有匹配的 Service 不做 Prepare，但其创建和登记仍计数。

最终一轮确认创建和加载计数为零、没有待 Prepare 的新目标后，退出循环并立即设置 `batch.phase="UPDATE"`。这几步之间没有 yield，因此不会夹入一项已经获准却未被计入最终清单的操作。从这时起，新创建和首次加载才等待发布终态；业务代码不需要处理发布重试。

假设将来有多个 PlayerService 需要更新，那么执行顺序是：

先让**所有目标完成 Prepare**，再开始逐个 Update。

而不是更新完第一个 Service，再去准备第二个。

我们这里只有一个 `first_service_handle`，因此当前执行的是：

`self:step(batch, target, "prepare")`

现在进入同文件的 `M:step()`。它的职责是构造控制请求并发起真正的跨 Service RPC。

完整源码：

```lua
function M:step(batch, target, command)
    ---@type FlyWowHotUpgradeControlRequest
    local request =
    {
        batch_id = batch.batch_id,
        sequence = batch.sequence,
    }
    if command == "update" then
        request.modules = target.modules
        request.service_source = target.service_source
    end

    batch.control_started = true
    local ok, answer = pcall(skynet.call, target.service_handle, "hotupgrade", command, request)
    if not ok or type(answer) ~= "table" or type(answer.ok) ~= "boolean" then
        return hotupgrade_result.failure("HU_RPC_FAILED", tostring(answer), command)
    end

    if not answer.ok and target.service_entry_file then
        answer.message = target.service_entry_file .. ": " .. (answer.message or answer.code)
    end
    return answer
end
```

这段调用里有几个具体对象：

`target.service_handle` 是 `first_service_handle`，也就是我们创建的原 PlayerService。

`command` 当前是 `"prepare"`。

`batch_id` 和 `sequence` 来自刚才 Controller 创建的发布批次。

Prepare 不传送模块源码，只传批次身份。

`skynet.call()` 使 Controller 的当前发布协程 yield，等待 PlayerService 的回复。

这里发生了真正的跨 Service 跳转：

```text
HotUpgrade Service                             PlayerService
 M:run_batch()
   └── M:step(batch,target,"prepare")
         │
         └── skynet.call(first_service_handle, "hotupgrade", "prepare", request)
                                                │
                                                └── skynet.dispatch("hotupgrade")
                                                      └── handle_upgrade("prepare")
                                                            └── before_upgrade()
                                                │
                 <────────── RPC 回复 ────────────┘
         │
         └── 继续 M:run_batch()
```

为什么 PlayerService 能接收 `"hotupgrade"` 协议？

因为第一次执行 `hot.register_service()` 时，HotUpgrade 已在 PlayerService 内部通过 `skynet.dispatch("hotupgrade", ...)` 注册了控制入口。

该入口位于：

`hotupgrade/lualib/flywow_hotupgrade.lua` 的 `M.register_service()`。

实际源码：

```lua
module_state.registration = registration
skynet.dispatch("hotupgrade", function(session, source, command, request)
    local ok, answer = pcall(handle_upgrade, command, request, source)
    if not ok then
        -- 异常也必须结束本批；Finish 已越过发布决定，只释放快照而不回滚。
        local original = hotupgrade_result.failure("HU_CONTROL_FAILED", tostring(answer))
        local txn = module_state.active_transaction
        if txn and command ~= "finish" then
            answer = abort(txn)
            if answer.ok then
                answer = original
            else
                answer.original_error = original
            end
        else
            if txn then
                if txn.modules then hotupgrade_module_patch.finish(txn.modules) end
                module_state.completed_sequence = txn.sequence
                module_state.last_batch_id = txn.batch_id
                module_state.active_transaction = nil
            end
            M.patching = false
            answer = original
        end
    end

    if session ~= 0 then
        skynet.retpack(answer)
    end
end)
```

这个 `handle_upgrade()` 是 PlayerService 所加载的 HotUpgrade 模块中的**本地函数**，与 Controller 的 `M:handle_command()` 不是同一个函数。

前者执行在 PlayerService 的 Lua State，能够访问玩家状态和本地模块表。

后者执行在 HotUpgrade Service 的 Lua State，只负责管理命令及协调。

现在我们进入前者。

文件：

`hotupgrade/lualib/flywow_hotupgrade.lua`

函数：

`local function handle_upgrade(command, request, source)`

收到 `"prepare"` 后，它先检查请求是否来自合法的 Controller，以及批次身份是否正确，再执行下面这一段：

```lua
-- 先禁止新业务，再通过业务自己的 queue 等待；callback 内允许正常 yield。
if command == "prepare" then
    if module_state.active_transaction then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "当前批次已在处理中")
    end

    module_state.active_transaction = {batch_id = request.batch_id, sequence = request.sequence}
    M.patching = true

    local ok, answer = pcall(module_state.registration.before_upgrade)

    if not ok then
        return hotupgrade_result.failure("HU_PREPARE_FAILED", tostring(answer))
    end
    if answer ~= true and not (type(answer) == "table" and answer.ok == true) then
        return hotupgrade_result.failure("HU_SAFEPOINT_REQUIRED",
            type(answer) == "table" and (answer.message or answer.code) or "before_upgrade 未确认业务安全点")
    end
    return hotupgrade_result.success()
end
```

登记时必须提供 before_upgrade 函数，因此这里直接调用它；每次 Prepare 仍要实际运行回调，确认本批业务队列已经排空。这段才真正开始改变 PlayerService 的运行状态。

它只建立本批次的本地记录，供后续 Update、Abort 和 Finish 保存、读取及清理快照，不为 Prepare 另设阶段状态。

然后：

```lua
module_state.active_transaction = {batch_id = request.batch_id, sequence = request.sequence}
M.patching = true
```

这两句属于 `flywow_hotupgrade.lua` 的本地 `handle_upgrade("prepare")` 分支。

`module_state.active_transaction` 保存当前 Service 的本地热更事务。

`M.patching` 就是我们在业务文件中通过 `hot.patching` 访问到的公开字段。

一旦它变成 `true`，新到来的业务请求在进入业务 queue 之前就会被拒绝。

但这并不意味着已经进入 queue 的业务执行完了。

所以紧接着调用：

`module_state.registration.before_upgrade()`

它对应我们 V1 PlayerService 在 `initialize()` 中登记的这个回调：

```lua
before_upgrade = function()
    return business_queue(function()
        return true
    end)
end
```

来源：

`hotupgrade/lesson4/host_v1/service/player_service.lua`，`initialize()` 中的 `register_service()` 参数。

这个回调尝试进入同一个 `business_queue`。

如果之前有其他业务已经进入 queue，即使那个业务正在 `skynet.call()` 中 yield，它仍然没有退出 queue 的临界区。

因此 `before_upgrade()` 会等待，直到前面的业务全部执行结束，才进入 queue 并返回 `true`。

此时，因为 `hot.patching=true` 已经阻止新的受控业务加入，框架便取得了业务安全点。

`handle_upgrade()` 在回调确认排空后直接返回 `{ok=true}`，通过 PlayerService 的 `skynet.retpack()` 回复 Controller。

Controller 中先前 yield 的 `M:step()` 恢复，接着返回 `M:run_batch()`。

**到这里，当前 PlayerService 的 Prepare RPC 已完成。** Controller 还要等待这期间产生的创建、首次加载并重匹配；所有匹配目标都准备好后，才统一进入 Update。Sample 没有新增操作，因此最终仍只有原 PlayerService。

我们这次没有模拟耗时业务，因此在实际运行中，这个等待通常会很快完成。不过它所建立的安全条件，是后面原地修改 Lua 对象的前提。

#### 第三次状态快照：Prepare 完成

```text
Controller
    phase = APPLYING
    batch.phase = PREPARE
    batch.targets = {first_service_handle}
    batch.control_started = true

原 PlayerService
    hot.patching = true
    module_state.active_transaction = {batch_id, sequence}

    logic.version() = "v1"
    state.equip = "刀"
    state.schema_version = 1
    business.load(100) = 105
    initial_load(100) = 105

    新业务：不允许进入 queue
    已有业务：已经排空

正式磁盘
    player_logic.lua = V1
    player_service.lua = V1
```

观察这个快照，你会发现：

**Prepare 没有修改玩家装备，没有更新攻击函数，也没有部署磁盘文件。它只是在 PlayerService 内建立了一个安全的更新窗口。**

### 6. Update：真正修改运行中的 Lua 对象

现在 `M:run_batch()` 已完成所有匹配目标的 Prepare、在途操作排空和最终匹配。它连续设置 `batch.phase="UPDATE"`，关闭创建和首次加载门禁，然后开始 Update。

Controller 将 `batch.phase` 设为 `"UPDATE"`，并进入独立的 Update 循环。

于是 Controller 再次调用：

`self:step(batch, target, "update")`

执行位置仍然在 `flywow_hotupgrade_controller.lua`。

与刚才的 Prepare 不同，这一次 `M:step()` 会把目标对应的源码也放进请求：

```lua
if command == "update" then
    request.modules = target.modules
    request.service_source = target.service_source
end
```

这是 `M:step()` 中的实际代码。

因此，本次 Update RPC 包含：

- 当前 `batch_id` 和 `sequence`。
- 完整的 V2 `player_logic.lua` 源码及其规范登记名。
- `service/player_service.patch` 的一次性脚本源码。

它不包含完整的 V2 `service/player_service.lua`，因为那个文件是之后部署给未来新 Service 使用的。

Controller 通过 `skynet.call()` 把更新请求发送给 `first_service_handle`，当前协程再次 yield。

PlayerService 收到消息后，经本地 `skynet.dispatch("hotupgrade", ...)` 进入：

`flywow_hotupgrade.lua` 的 `handle_upgrade("update")`。

现在先看真实代码的 Stage 部分：

```lua
if command == "update" then
    if txn.phase ~= nil then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "当前批次已进入更新或恢复阶段")
    end
    -- Controller 已按本 State 的登记模块筛选 Patch；Stage 准备候选和快照，不写线上状态。
    local staged = hotupgrade_module_patch.stage(request.modules, module_state.declared_modules)
    if not staged.ok then
        return staged
    end

    txn.modules = staged.stage
    local ok, service = pcall(stage_service, request.service_source)
    if not ok then
        return hotupgrade_result.failure("HU_SERVICE_STAGE_FAILED", tostring(service))
    end

    txn.service = service
    txn.phase = "STAGED"
```

这是 `handle_upgrade()` 的连续代码，暂时只读到 `STAGED`。下一步 Activate 还在同一个 `handle_upgrade("update")` 中，等我们理解 Stage 后再继续。

这里先调用：

`hotupgrade_module_patch.stage()`

它属于另一个真实文件：

`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`

这个函数开始处理普通 Lua 模块。

#### 普通 Lua 模块 Stage 到底做了什么？

现在仍然在原 PlayerService 的 Lua State 内，没有再次跨 Service。

`stage()` 根据请求中的规范名称：

`lualib.player_logic`

找到当前加载的模块：

`package.loaded["lualib.player_logic"]`

也就是前面 `hot.require("player_logic")` 返回、并被局部变量 `logic` 持有的那张模块表。

Stage 会保存这张表的旧导出字段，然后编译 V2 源码，执行候选模块，并验证候选导出。

这里有一个重要区别：

Controller 之前使用 `load()`，只检查发布包的语法，没有执行模块。

现在 Module Patch Engine 使用 `load()` 编译源码后，会真正执行候选 `chunk()`，取得新模块的导出表。

对应 `flywow_hotupgrade_module_patch.lua` 的 `M.stage()`，关键连续代码为：

```lua
-- 再执行候选模块，检查导出并迁移隔离的私有状态。
for _, entry in ipairs(module_stage.entries) do
    local candidate = entry.chunk(entry.loader_name, entry.loader_path)
    check_exports(candidate, entry.name)
    assert(candidate ~= entry.live, "候选须返回新的导出表")

    -- 只有旧版提供快照且新版提供导入钩子时才迁移；缺少任一方就使用新版初始化状态。
    if entry.live.export_state and candidate.import_state then
        local snapshot = M.snapshot_state(entry.live.export_state())
        assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
    end
    entry.candidate = candidate
    entry.chunk = nil
end
```

我们编写的 V2 `player_logic.lua` 执行后会返回一张新的导出表，里面有 V2 `version()` 和 `make_load()`。

但此时这张表只是候选对象。

原来的 `logic` 还没有被改动。

同样，`business.load` 和 `initial_load` 都仍然指向 V1 闭包。

框架把候选模块、原模块表、旧导出字段等保存在 Stage 记录中，返回给 `handle_upgrade("update")`，后者将其保存到 `txn.modules`。

这部分是普通模块更新引擎的入口。第 5 课再研究它如何进行完整导出检查和私有状态迁移；现在只需要理解：**Stage 产生候选版本，并保留旧版本的恢复依据，暂不修改线上对象。**

#### 接着准备 Service 更新回调与恢复快照

stage_service() 在业务安全点内加载 Patch，完整实现如下：

```lua
local function stage_service(patch_source)
    if not patch_source then
        return nil
    end

    -- 执行受信 Patch 构建函数并校验结果；此时尚不写入线上状态。
    local service_update = assert(module_state.registration.service_update, "Service 未提供内部更新入口")
    local chunk = assert(load(hotupgrade_common.normalize_source(patch_source), "=Service Patch", "t", _G))
    local build_patch = chunk()
    assert(type(build_patch) == "function", "Service Patch 必须返回构建函数")
    ---@type FlyWowHotUpgradeServicePatch
    local patch = build_patch(service_update.state)

    assert(type(patch) == "table" and getmetatable(patch) == nil, "Service 构建结果必须是普通表")
    assert(patch.migrate == nil and patch.functions == nil, "Service Patch 使用 update_state / replace_functions")
    assert(patch.update_state == nil or type(patch.update_state) == "function", "update_state 必须是函数")
    assert(patch.replace_functions == nil or (type(patch.replace_functions) == "table"
        and getmetatable(patch.replace_functions) == nil), "replace_functions 必须是普通表")
    assert(patch.update_state or (patch.replace_functions and next(patch.replace_functions)), "Service Patch 没有更新内容")

    -- 保存本次可能替换的旧函数，Activate 失败时逐字段恢复。
    local staged =
    {
        patch         = patch, -- 仅本 State 持有的状态更新回调和替换函数。
        old_functions = {},    -- 本次将替换的现有函数，不处理未列出的字段。
        touched       = false, -- 首次线上写入前置 true，部分提交同样必须恢复。
    }
    for name, replacement_function in pairs(patch.replace_functions or {}) do
        assert(type(name) == "string" and type(replacement_function) == "function"
            and type(rawget(service_update.functions, name)) == "function", "只能直接替换现有业务函数")
        staged.old_functions[name] = rawget(service_update.functions, name)
    end

    -- 只保存恢复快照；更新回调留到提交阶段执行，不创建候选状态或做合并。
    if patch.update_state then
        if service_update.snapshot then
            staged.old_state = service_update.snapshot(service_update.state)
            assert(type(staged.old_state) == "table" and staged.old_state ~= service_update.state,
                "自定义快照必须返回独立状态表")
        else
            staged.old_state = hotupgrade_module_patch.snapshot_state(service_update.state)
        end
    end

    return staged
end
```

构建函数接收真实 state，但只创建闭包，update_state 此时没有执行。old_state 是失败恢复快照，old_functions 是涉及的旧函数；准备阶段不生成 next_state。

#### 第四次状态快照：准备完成

原 state 与 business.load 尚未改变。批次记录拥有 patch、old_state 和 old_functions，touched 为 false。准备失败通过现有 Abort 清理已准备的普通模块和参与目标。

### 7. Activate：在原有对象上正式安装 V2

现有 Update 先提交普通模块，再同步更新 Service：

```lua
        -- Activate 同步提交；失败先报告，再由 Controller 串行 Abort 整批目标。
        local installed = hotupgrade_module_patch.commit(txn.modules)
        local ok, message = pcall(function()
            assert(installed.ok, installed.message)
            local staged = txn.service
            if staged then
                local service_update = module_state.registration.service_update
                staged.touched = true
                if staged.patch.update_state then
                    staged.patch.update_state()
                end

                for name, fn in pairs(staged.patch.replace_functions or {}) do
                    rawset(service_update.functions, name, fn)
                end
            end

            if module_state.registration.after_upgrade then
                assert(module_state.registration.after_upgrade() ~= false, "after_upgrade 拒绝更新")
            end
        end)

        if not ok then
            return hotupgrade_result.failure("HU_ACTIVATE_FAILED", tostring(message))
        end
```

先置 touched=true，再执行 update_state()，确保回调写到一半抛错也会恢复。随后直接安装 replace_functions 中列出的函数；未列出的函数保留。after_upgrade 在提交后运行，拒绝或异常同样触发组合恢复。

普通模块仍由 hotupgrade_module_patch.commit() 完整替换原模块根表的字段，package.loaded 的根表身份不变。Service 状态由 update_state 直接赋值。例如 state.equip="剑" 后 level 保留原值 50；state.nested.count=8 保留 nested 的其余字段与身份，而 state.nested={} 则替换整个嵌套字段。框架不参与业务状态合并。

失败时复用以下恢复实现：

```lua
local function restore_service(txn)
    local staged = txn.service
    if not staged or not staged.touched then
        return
    end

    local service_update = module_state.registration.service_update
    -- 自定义恢复只处理 Service 自己的对象；即使它失败也继续尝试还原函数字段。
    local ok, message = pcall(function()
        if staged.old_state then
            if service_update.restore then
                assert(service_update.restore(service_update.state, staged.old_state) ~= false, "Service 拒绝恢复")
            else
                hotupgrade_module_patch.restore_state(staged.old_state, service_update.state)
            end
        end
    end)

    for name, fn in pairs(staged.old_functions) do
        rawset(service_update.functions, name, fn)
    end

    assert(ok, message)
end
```

默认 restore_state 将旧快照原地恢复到线上根表，移除更新新增字段，并重建旧数据关系。特殊对象采用成对 snapshot / restore，自定义 commit 已删除。恢复失败仍报告错误，但结束本批后释放入口。更新和恢复必须同步，不得执行无法撤销的消息、数据库等外部操作。

#### 第五次状态快照：Activate 完成

state 已修改，business.load 已替换为捕获原 state 的新闭包，普通模块也已安装 V2。旧快照和旧函数仍保留到 Finish，后续失败可由 Abort 恢复；Finish 或 Abort 结束时清理本批数据并开放业务。

### 8. Controller 怎样部署正式 Lua 文件？

现在执行权回到了：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:run_batch()`。

前面的 Prepare 和 Update 都已经成功返回，Controller 可以继续执行后面的文件部署代码。

真实源码：

```lua
-- 仅使用已冻结的完整文件，不能在 Update 后重新读取发布包。
for _, file in ipairs(batch.files) do
    local written, failure = hotupgrade_native.replace_file(self.root_path, file.entry_file, file.source)
    if not written then
        batch.error = hotupgrade_result.failure(native_code(failure), "部署失败: " .. file.entry_file)
        return
    end
    file.touched = true
end
if #batch.files > 0 then
    local cleared, failure = pcall(skynet.cache.clear)
    if not cleared then
        batch.error = hotupgrade_result.failure("HU_CACHE_CLEAR_FAILED", tostring(failure))
    end
end
```

这段代码位于 `M:run_batch()` 的 Update 成功之后。

`batch.files` 是之前由 `M:load_patch()` 冻结的正式 `.lua` 文件集合。

我们的发布包中，它包含：

```text
lualib/player_logic.lua
service/player_service.lua
```

Controller 逐个调用 Native `replace_file()`，将冻结的 V2 源码部署到 `root_path` 对应的正式宿主目录。

具体来说，文件内容从：

`patches/v2/lualib/player_logic.lua`

部署到：

`host/lualib/player_logic.lua`

同时把：

`patches/v2/service/player_service.lua`

部署到：

`host/service/player_service.lua`

这不是简单修改现存 Service 的内存，而是真正把正式宿主文件更新成 V2。

而 `service/player_service.patch` 不在 `batch.files` 中，因此不会复制到正式宿主目录。

它已经完成了对现存 Service 的一次性更新任务。

#### 为什么部署完还要 `skynet.cache.clear()`？

这是因为 Skynet 对 Service 入口源码存在代码缓存。

即使正式磁盘上的 `player_service.lua` 已经变成 V2，如果 Skynet 后续创建新 Service 时继续使用先前缓存的 V1 Service 代码，就无法实现我们想要的效果。

因此，完成正式文件部署后，Controller 调用：

`skynet.cache.clear()`

清理 Skynet 的代码缓存，使后续 Service 创建能够重新读取新版 Service 入口源码。

这里也要区分两种缓存：

**Skynet 代码缓存**影响后续 Service 如何取得入口源码。

**Lua `package.loaded`** 保存的是某个 Lua State 已经加载过的模块。

`skynet.cache.clear()` 不负责把原 PlayerService 中的 `logic` 表变成 V2；那件事早已在 Update 中由 Module Patch Engine 完成。

现在我们终于同时拥有了：

- 原 PlayerService 内存中的 V2 模块、V2 状态和 V2 业务函数。
- 正式磁盘上的 V2 完整 Lua 文件。
- 已经清理的 Skynet 代码缓存。

但这仍然不是最后一步。

#### 第六次状态快照：正式文件部署完成

```text
Controller
    phase = APPLYING
    batch.phase = UPDATE
    batch.files 中两份正式文件已部署
    尚未执行 Finish

原 PlayerService
    hot.patching = true
    txn.phase = ACTIVATED

    state = V2
    logic = V2 导出内容
    business.load = V2 闭包

    旧快照：仍保留

正式磁盘
    player_logic.lua = V2
    player_service.lua = V2

Skynet
    代码缓存已清理
```

现在 Controller 已经具备完成发布的条件。

### 9. Finish：为什么这时才开放玩家业务？

正式文件部署、代码缓存清理和所有目标 Update 均确认成功之后，执行权仍然在 Controller 的 `M:run_batch()`。

接下来执行：

```lua
-- 文件和全部 Update 已确认成功；各目标 Finish 独立报告，不再执行回滚。
batch.phase = "PUBLISH_DECIDED"
for _, target in ipairs(batch.targets) do
    batch.current_service_handle = target.service_handle
    target.result = self:step(batch, target, "finish")
    if not target.result.ok then
        batch.error = hotupgrade_result.failure("HU_RECOVERY_REQUIRED",
            target.result.message or target.result.code, "finish")
        self.recovery_required = true
    end
end
batch.phase = batch.error and "RECOVERY_REQUIRED" or "COMPLETED"
```

这是 `flywow_hotupgrade_controller.lua` 的 `M:run_batch()` 中完整的发布决定和 Finish 循环。

首先把批次阶段设置为：

`PUBLISH_DECIDED`

这表示 Controller 已经确认本批次的所有运行时 Update 和正式文件部署都成功了。

随后，Controller 通过此前学习过的 `M:step()`，向 `first_service_handle` 发送：

`handle_upgrade("finish")`

这又是一条跨 Service RPC。

PlayerService 收到后，仍然进入：

`hotupgrade/lualib/flywow_hotupgrade.lua` 的本地 `handle_upgrade()`。

我们之前已经读过这个函数的 Prepare 和 Update，现在继续读 Finish 分支：

```lua
-- finish 确认提交后才清理旧快照并重新开放业务入口。
if command == "finish" and txn.phase == "ACTIVATED" then
    local finished = hotupgrade_module_patch.finish(txn.modules)
    module_state.completed_sequence = txn.sequence
    module_state.last_batch_id = txn.batch_id
    module_state.active_transaction = nil
    M.patching = false
    return finished
end
```

执行位置是 PlayerService 自己的 Lua State。

之前的 Update 已经完成，所以 `txn.phase` 应当是 `ACTIVATED`。

框架先调用：

`hotupgrade_module_patch.finish(txn.modules)`

它将释放普通模块更新时保存的旧导出快照和候选数据，并清理模块更新引擎的活动记录。

然后：

```lua
module_state.completed_sequence = txn.sequence
module_state.last_batch_id = txn.batch_id
module_state.active_transaction = nil
M.patching = false
```

这几句来自同一个 Finish 分支。

`completed_sequence` 和 `last_batch_id` 用于记录已经结束的批次身份，帮助拒绝迟到命令及处理已完成批次的重复收尾消息。

`active_transaction = nil` 表示当前 PlayerService 不再持有这个活动事务。

最后才把 `M.patching` 设为 `false`。

这时新业务就可以重新进入 PlayerService 自己的 queue，正常使用 V2 状态和函数。

为什么旧快照不能在 Update 成功后立即释放？

因为 Update 成功只说明内存更新成功。如果接下来的正式文件部署失败，Controller 还需要让 PlayerService 恢复 V1。

一旦提前释放旧快照，就失去了正常恢复的依据。

所以当前顺序是：

**Update 保留恢复能力 → 部署正式文件 → 发布决定 → Finish 释放恢复数据并开放业务。**

Finish 成功后，它通过 RPC 返回 Controller。

Controller 收齐结果后，在 `M:run_batch()` 的结尾保存最终批次记录：

```lua
self.last_batch = batch
self.active_batch = nil
self.phase = batch.error and "IDLE" or batch.phase
self:wake_lifecycle()
```

这里的代码来自 `M:run_batch()` 的事务收尾部分。

本次成功，因此：

`batch.phase = "COMPLETED"`

`self.phase = "COMPLETED"`

`self.active_batch = nil`

`self.last_batch` 保存刚才完成的批次记录。

`self:wake_lifecycle()` 则唤醒发布期间等待创建新 Service 或首次加载模块的协程。

#### 第七次状态快照：Finish 完成

```text
Controller
    phase = COMPLETED
    active_batch = nil
    last_batch = 本次 batch
    batch.phase = COMPLETED
    recovery_required = false

原 PlayerService
    hot.patching = false
    module_state.active_transaction = nil
    completed_sequence = 本次 sequence

    state.equip = "剑"
    state.schema_version = 2
    state == state_root

    logic.version() = "v2"
    模块导出根表身份不变

    business.load(100) = 121
    initial_load(100) = 100

    旧模块快照：已释放
    旧 Service 事务：已结束

正式磁盘
    player_logic.lua = V2
    player_service.lua = V2

Skynet
    代码缓存已清理
```

到这里，一次成功的 HotUpgrade 发布已经完成。

不过我们的主 Service 还在等待，因此还需要回到 Sample，看看如何确认结果。

## 五、第四阶段：验收原 Service 和新 Service

Controller 完成批次之后，我们最初编写的 `lesson4_main.lua` 正在通过 `status()` 查询结果。

这一部分调用的仍然是 Controller 的 `"hotupgrade"` 协议。

消息进入 `flywow_hotupgrade_controller.lua` 的 `M:handle_command("status")`。

这个分支读取当前生命周期状态和指定 `batch_id` 的批次记录，并将它们返回给主 Service。

它不会再次执行更新，也不会访问 PlayerService 的私有 Lua table。

我们主 Service 中的等待循环检查：

`status.record.phase`

一旦等于 `"COMPLETED"`，便退出等待。

注意 `status.record.phase` 和 `status.lifecycle.phase` 的区别：

前者表示指定批次的实际结果。

后者表示 Controller 当前的生命周期和发布门禁状态。

本次成功时，两者都是 `COMPLETED`。发生已恢复的失败时，前者可以是 `ABORTED`，而后者已经回到 `IDLE`。

### 检查已经运行的 PlayerService

现在主 Service 向原来的 `first_service_handle` 发送：

`skynet.call(first_service_handle, "lua", "inspect")`

这是我们自己编写的 `lesson4_main.lua` 中的 RPC。

因为 Finish 已经把 `hot.patching` 改为 `false`，所以 PlayerService 的 `"lua"` dispatch 允许查询进入业务 queue。

`business_queue(inspect)` 执行的 `inspect()` 就是最早在 `host_v1/service/player_service.lua` 中定义的那个函数。

注意：原 Service 没有重新执行 V2 `player_service.lua` 文件。

它仍然运行原先已经加载的 Service 入口代码，里面的 `inspect()`、`initialize()` 等局部函数并没有被整体替换。

但我们明确登记并更新的 `state`、`logic` 导出字段和 `business.load`，已经变成 V2。

所以原 PlayerService 返回的数据应当是：

| 检查项目 | 预期结果 |
|---|---|
| `handle` | 等于原 `first_service_handle` |
| `version` | `v2` |
| `equip` | 剑 |
| `schema_version` | `2` |
| `attack` | `121` |
| `initial_attack` | `100` |
| `load_changed` | `true` |
| `state_same` | `true` |
| `module_alias_same` | `true` |
| `patching` | `false` |

另外，主 Service 还比较了更新前后返回的 `module_id`。

这个值是在同一个 PlayerService Lua State 内对 `logic` table 调用 `tostring()` 得到的，用来辅助观察更新前后模块根表是否仍是原对象。

我们没有跨 Lua State 直接比较两张 table。真正的 `logic` table 从未离开 PlayerService。

### 为什么后来创建的 PlayerService 直接使用 V2？

原实例验收完毕后，主 Service 执行：

```lua
local second_service_handle = hot.newservice("player_service")
```

这行来自我们最终版本 `lesson4_main.lua` 的 `skynet.start()` 回调。

调用过程和第一次创建相同：

主 Service → HotUpgrade `M.newservice()` → Controller `M:handle_command()` → `M:newservice()` → Skynet 原生 `newservice()`。

区别在于，这次正式宿主目录已经部署了完整的 V2 `player_service.lua`，并且 Skynet 代码缓存已经清理。

因此新创建的 Service 加载的是 V2 Service 入口源码。

主 Service 随后发送 `"init"`。

这时执行的是我们编写在：

`hotupgrade/lesson4/patches/v2/service/player_service.lua`

中的 `initialize()`，也就是已经部署到正式宿主目录的那份代码。

它直接创建：

```lua
state =
{
    equip = "剑",
    schema_version = 2,
}
```

这段来自我们自己编写的 V2 `player_service.lua` 的 `initialize()`。

接着通过 `hot.require("player_logic")`，从正式宿主目录加载完整的 V2 `player_logic.lua`。

随后调用 V2 `logic.make_load(state)`，创建 V2 业务闭包。

因此第二个 PlayerService 初始化后直接具有：

```text
second_service_handle
    新的 Skynet Service handle
    新的 Lua State

    logic = 新加载的 V2 模块导出表
    state = {equip="剑", schema_version=2}
    business.load = 新创建的 V2 闭包

    business.load(100) = 121
    initial_load(100) = 121
    hot.patching = false
```

它并不需要执行 `service/player_service.patch`。

因为那个 Patch 的工作，是把**已经运行的 V1 对象迁移到 V2**。

第二个 PlayerService 从创建开始就已经是 V2，没有任何 V1 状态需要迁移。

因此，两个 Service 虽然最终计算出相同的攻击力，但得到 V2 的路径完全不同：

```text
原 PlayerService（first_service_handle 不变）
    V1 入口启动 → V1 状态和模块
    → Prepare → Update → Finish
    → 现存对象更新为 V2

新 PlayerService（second_service_handle 是新 handle）
    加载 V2 Service 入口 → 加载 V2 普通模块
    → 初始化 V2 状态
    → 直接运行完整 V2
```

到这里，我们已经验证了这套热更机制的核心目标：

**运行中的对象可以在保留关键身份的情况下更新，而未来创建的对象直接读取正式部署的新版本。**

## 六、如果发布中途失败，会发生什么？

前面我们完整走了一次成功路径。

现在不新增 Sample 故障注入代码，只沿着刚才走过的同一条调用链，看 Controller 如何处理失败。

本课先理解整体恢复模型。各种失败场景的细节和源码处理，放到第 7 课深入研究。

关键分界点是：

`PUBLISH_DECIDED`

在它之前，Controller 仍然可以尝试把整批恢复为发布前的版本。

在它之后，Controller 已经确认运行时更新和正式文件部署成功，开始通过 Finish 释放快照和开放业务，不再采用整批回滚。

### Prepare 或 Update 失败

假设我们的 PlayerService 在 Prepare 阶段无法取得业务安全点。

这时本地 `handle_upgrade("prepare")` 返回失败。

Controller 的 `M:step()` 将失败结果交给 `M:run_batch()`，后者进入恢复分支，对已经参与当前批次的目标发送：

`handle_upgrade("abort")`

PlayerService 收到 Abort 后进入 `flywow_hotupgrade.lua` 的本地 `abort(txn)`。

本地 `abort()` 会尝试恢复被修改的 Service 状态和函数，并通过 Module Patch Engine 恢复普通模块导出。

恢复确认成功之后，才清理本地事务，并将：

`hot.patching = false`

如果失败发生在 Stage，线上对象通常还没有被安装 V2，但依然需要清理已建立的事务和候选记录。

如果失败发生在 Activate，可能已经安装了一部分新内容，因此更需要利用 Stage 保留的旧快照恢复。

本地 Activate 出错时会先尝试一次本地组合恢复，随后 Controller 仍按整批失败路径处理。

恢复成功后，Controller 保存：

```text
batch.phase = ABORTED
Controller.phase = IDLE
```

原本已经完成的发布请求不会变成 `COMPLETED`，但 Controller 可以接受下一次发布。

### 文件部署失败

再假设所有目标 Update 都已经成功，原 PlayerService 现在运行 V2，但在部署正式 Lua 文件时失败了。

此时 Controller 不能直接放开 PlayerService，否则运行时和正式文件可能处于不同版本。

所以 `M:run_batch()` 的恢复分支会先尝试恢复已经改动的正式文件，并在需要时重新清理 Skynet 代码缓存。

然后再对参与过事务的 PlayerService 执行 Abort。

这里的恢复顺序是有实际意义的：

**先处理正式文件和代码缓存，再解除 PlayerService 的业务安全点。**

这样一旦原 PlayerService 恢复并重新接收业务，正式文件也已被恢复到与旧版本一致的状态。

如果文件或运行时无法确认恢复成功，Controller 不能宣称已经恢复，而是进入恢复要求状态。

### 恢复失败与 Finish 失败

这里要区分两种情况。

第一种是**发布决定前恢复失败**。

例如，某个 PlayerService 无法恢复旧状态，或者已经修改的正式文件无法恢复。

Controller 会记录：

`RECOVERY_REQUIRED`

并使生命周期进入：

`RECOVERY_REQUIRED`

这意味着系统无法确认版本已经收敛，后续新的发布及受管理创建会被门禁阻止，需要宿主核实和处理。

第二种是**Finish 阶段失败**。

它发生在 `PUBLISH_DECIDED` 之后。

此前新版正式文件已经部署，运行时 Update 也已成功。部分目标甚至已经 Finish，释放了旧快照并重新开放业务。

这时候再强行整批回滚是不安全的。

所以 Controller 会继续尝试其他目标的 Finish 并报告失败，结束本批后允许继续发布，不撤回新版文件或对已经 Finish 的目标执行整体回滚。

失败不要求人工确认解锁；宿主或运维根据报告决定下一批内容，下一批以当时现场重新保存快照和执行。

这就是本课需要掌握的恢复边界。

## 七、运行完整 Sample，并回顾这条调用链

现在我们的文件已经全部准备好了。

从 FlyWow 根目录再次执行：

```bash
bash hotupgrade/lesson4/run.sh ../skynet
```

运行脚本会先恢复 V1 正式宿主目录，然后由 `lesson4_main.lua` 创建原 PlayerService、发起 V2 发布、等待完成并验收两个实例。

按照当前源码和我们编写的代码，成功路径预期包含以下结果：

```text
发布前: v1 刀 1 105

发布批次: <batch_id>

发布后: v2 剑 2 121
原 Service handle 保持: true
原状态根表保持: true
原模块根表保持: true
模块缓存别名保持: true
业务函数已替换: true
旧闭包的攻击力: 100
原 Service patching: false

新 PlayerService: v2 剑 2 121
两个 Service 的 handle 不同: true
```

以上是源码推导的预期输出。本次已核对 GitHub 源码，但没有实际构建或运行这个新编写的教学 Sample，因此不把这些输出标为已测试通过。

到这里，我们把整个 HotUpgrade 从使用到内部实现，完整走了一遍。

这条调用链可以压缩成下面的执行模型：

```text
主 Service：begin({path="v2"})
    ↓ RPC
Controller：建立 batch / skynet.fork(run_batch)
    ↓
初始排空：继续接纳创建和首次加载，等待在途操作完成
    ↓
加载发布包：冻结源码 / 初次匹配目标 / 保存旧文件
    ↓ RPC
PlayerService Prepare：patching=true / 等待 queue 排空，仍允许完成创建和首次加载
    ↓
Controller：等待新增操作完成 / 用冻结 Patch 重匹配 / 新目标补做 Prepare
    ↓ 无待准备目标、在途计数为零，连续关门
PlayerService Update / Stage：准备候选与旧快照
    ↓
PlayerService Update / Activate：原地更新模块、状态和业务函数
    ↓ RPC 返回
Controller：正式文件部署 / skynet.cache.clear()
    ↓ RPC
PlayerService Finish：释放快照 / patching=false
    ↓ RPC 返回
Controller：batch.phase=COMPLETED
    ↓ status 查询
主 Service：验证原 PlayerService 和新 PlayerService
```

现在回过头再理解 HotUpgrade 的设计，会清楚得多。

Controller 需要保存 Service 登记元数据、确定更新目标、协调控制 RPC、部署正式文件，但它不需要持有任何玩家业务对象。

PlayerService 自己保存状态和函数，所以真正修改 Lua table 的操作必须进入它自己的 Lua State 执行。

Prepare 使用 PlayerService 已有的 queue 建立业务安全点；Update 在这个安全点中完成模块、状态和函数的组合更新；正式文件部署保证未来创建的 Service 能读取新版；Finish 则意味着本地旧快照可以释放，业务可以重新开放。

最后需要明确三个独立事实：

- **Service handle 不变**：因为原 PlayerService 没有被销毁或重新创建。
- **状态根表和普通模块导出根表身份不变**：因为 HotUpgrade 对这些根表执行的是原地更新。
- **函数引用不一定跟着改变**：只有显式更新的函数字段会替换，其他已经缓存的闭包依然保留原来的函数逻辑。

这就是第 4 课的核心。

我们现在已经把一次完整发布的工程调用关系建立起来了。后续第 5 课可以直接从这里的 `hotupgrade_module_patch.stage()`、`commit()`、`abort()` 和 `finish()` 深入普通模块更新算法，不需要再重复整套发布流程。
