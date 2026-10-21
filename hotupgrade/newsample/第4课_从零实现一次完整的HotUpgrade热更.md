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
        handle = skynet.self(),
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
    local hotupgrade_service_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hot = require "flywow_hotupgrade"

    local root = os.getenv("HOTUPGRADE_LESSON_ROOT")

    local result = skynet.call(hotupgrade_service_handle, "lua", "init",
    {
        patch_path = root .. "/patches",
        root_path = root .. "/host",
        service_path = "service",
    })
    if not result.ok then
        error(result.message)
    end

    local first_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_handle, "lua", "init")
    if not initialized.ok then
        error(initialized.message)
    end

    local response = skynet.call(first_handle, "lua", "inspect")
    local player = response.player

    print("handle:", player.handle)
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
local hotupgrade_service_handle = skynet.uniqueservice("flywow_hotupgrade_service")
```

这里使用的是 **Skynet 原生 `uniqueservice()`**，创建或取得进程中的唯一 Controller Service。

Controller 的入口文件是仓库现有的：

`hotupgrade/service/flywow_hotupgrade_service.lua`

Controller 启动后，在自己的 Lua State 中加载 `flywow_hotupgrade_controller.lua`，并注册 `lua` 和 `hotupgrade` 两套协议处理。

随后我们的主 Service 发送：

```lua
skynet.call(hotupgrade_service_handle, "lua", "init", ...)
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
local first_handle = hot.newservice("player_service")
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
    local answer = skynet.call(hotupgrade_service_handle, "hotupgrade", "newservice",
        {service_name = service_name, arguments = table.pack(...)})
    assert(type(answer) == "table" and answer.ok,
        tostring(type(answer) == "table" and answer.code) .. ": " ..
        tostring(type(answer) == "table" and answer.message or answer))
    return answer.handle
end
```

这里的 `hotupgrade_service_handle` 是 HotUpgrade 模块在所在 Lua State 内取得的 Controller handle。

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
local first_handle = hot.newservice("player_service")
```

执行完毕后，`first_handle` 是一个真实的 Skynet Service handle。

但现在有一个容易忽略的区别：

**取得 handle，不代表 PlayerService 已经完成业务初始化和 HotUpgrade 登记。**

Controller 仍然保留刚才的待创建记录。

所以主 Service 接着执行：

```lua
local initialized = skynet.call(first_handle, "lua", "init")
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
    service_patch = service_update ~= nil,
}
local ok, answer = pcall(skynet.call, hotupgrade_service_handle, "hotupgrade", "register", metadata)
```

注意，这个请求里没有 `state`，没有 `business`，也没有 `initial_load`。

Controller 只需要知道：哪个 Service、登记了哪些普通模块、是否支持 Service Patch。

Controller 最终持有的目标记录可以理解为（其中 `service_name` 来自受管理创建记录，不是 `register_service()` 请求字段）：

```lua
{
    service_name = "player_service",
    modules = {"lualib.player_logic"},
    service_patch = true,
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

它使用 Skynet 消息携带的真实 `source` 作为 PlayerService handle，将元数据保存到 `self.targets[source]`，并通过 `finish_creation()` 移除刚才的待创建记录。

登记 RPC 返回成功，PlayerService 的 `initialize()` 才结束；PlayerService 再通过 `skynet.retpack()` 把结果回复给主 Service。

这样主 Service 才能安全地执行后面的 `"inspect"`。

我们至此走完了：

```text
主 Service：lesson4_main.lua
    hot.newservice("player_service")
            ↓ RPC
Controller Service：M:newservice()
    skynet.newservice() → 返回 first_handle
            ↓
主 Service
    skynet.call(first_handle, "lua", "init")
            ↓ RPC
PlayerService：Lua dispatch → initialize()
    hot.require() → hot.register_service()
            ↓ RPC
Controller Service：M:register() → finish_creation()
            ↓ 返回
PlayerService：init 回复 → 主 Service：inspect
```

### 当前状态

第一次创建和登记完成后，我们应该建立这样一份运行时状态：

```text
Controller Service
    phase = IDLE
    active = nil
    sequence = 0
    creation_count = 0
    module_load_count = 0
    targets[first_handle] = 已登记的目标元数据

PlayerService（first_handle）
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

`first_handle` 是 Service 的标识；`state` 是 PlayerService Lua State 内的一张 table；`logic` 是同一个 Lua State 内已经加载的普通模块导出 table。

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

`first_handle` 对应的 PlayerService 已经运行，它内部的 `state` 还是：

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
        migrate = function(old_state)
            return
            {
                equip = "剑",
                schema_version = 2,
            }
        end,

        functions =
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

`migrate` 接收旧状态的独立快照，生成 V2 候选状态。

`functions.load` 是准备替换到现有 `business` 表中的新函数。它直接捕获构建函数收到的 `state` 根表。

这里的 `old_state` 参数目前只作为迁移输入；这个最小业务例子不需要保留旧装备或其他字段。实际游戏中的 `migrate` 通常会从旧快照取出需要延续的数据。

注意 `migrate()` 返回的新 table 并不会取代原 PlayerService 的 `state` 根表。

后面框架会把候选字段应用到原来的根表中，保证原有引用不失效。

而 `functions.load` 捕获的，正是这张原来的根表。

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
        handle = skynet.self(),
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
    local hotupgrade_service_handle = skynet.uniqueservice("flywow_hotupgrade_service")
    local hot = require "flywow_hotupgrade"
    local root = os.getenv("HOTUPGRADE_LESSON_ROOT")

    -- 初始化 Controller。
    local result = skynet.call(hotupgrade_service_handle, "lua", "init",
    {
        patch_path = root .. "/patches",
        root_path = root .. "/host",
        service_path = "service",
    })
    if not result.ok then
        error(result.message)
    end

    -- 创建第一个 PlayerService，执行 V1。
    local first_handle = hot.newservice("player_service")
    local initialized = skynet.call(first_handle, "lua", "init")
    if not initialized.ok then
        error(initialized.message)
    end

    local before = skynet.call(first_handle, "lua", "inspect")
    print("发布前:", before.player.version, before.player.equip,
        before.player.schema_version, before.player.attack)

    -- 开始发布 V2。
    local begun = skynet.call(hotupgrade_service_handle, "hotupgrade", "begin",
    {
        path = "v2",
    })
    if not begun.ok then
        error(begun.message)
    end

    print("发布批次:", begun.batch_id)

    -- 等待该批次执行完毕。
    while true do
        local status = skynet.call(hotupgrade_service_handle, "hotupgrade", "status",
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
    local after = skynet.call(first_handle, "lua", "inspect")

    print("发布后:", after.player.version, after.player.equip,
        after.player.schema_version, after.player.attack)

    print("原 handle 保持:", first_handle == after.player.handle)
    print("原状态根表保持:", after.player.state_same)
    print("原模块根表保持:",
        before.player.module_id == after.player.module_id)
    print("模块缓存别名保持:", after.player.module_alias_same)
    print("业务函数已替换:", after.player.load_changed)
    print("旧闭包的攻击力:", after.player.initial_attack)
    print("原 Service patching:", after.player_service.patching)

    -- 创建第二个 PlayerService，直接运行 V2。
    local second_handle = hot.newservice("player_service")
    local second_initialized = skynet.call(second_handle, "lua", "init")
    if not second_initialized.ok then
        error(second_initialized.message)
    end

    local second = skynet.call(second_handle, "lua", "inspect")

    print("新 PlayerService:", second.player.version, second.player.equip,
        second.player.schema_version, second.player.attack)
    print("两个 Service 的 handle 不同:", second_handle ~= first_handle)

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
local begun = skynet.call(hotupgrade_service_handle, "hotupgrade", "begin",
{
    path = "v2",
})
```

代码来源是 `hotupgrade/lesson4/lesson4_main.lua` 的 `skynet.start()` 回调。

`hotupgrade_service_handle` 来自之前的 `skynet.uniqueservice()`，`path="v2"` 则表示选择 Controller 配置的 `patch_path` 下的 `v2` 目录。

这是一条跨 Service 的 RPC。主 Service 发送请求后 yield，等待 Controller 回复。

消息到达的真实入口是：

`hotupgrade/service/flywow_hotupgrade_service.lua`

其 `skynet.dispatch("hotupgrade", ...)` 调用：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 中的 `M:handle_command()`。

`handle_command()` 根据 `"begin"` 命令进入同文件的 `M:begin()`。

我们来看这个完整函数：

```lua
function M:begin(request)
    if self.phase == "FAILED_LOCKED" then
        return hotupgrade_result.failure("HU_DEPLOYMENT_BLOCKED", "上次发布尚未恢复")
    end
    if self.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "已有发布屏障")
    end
    if request.dry_run ~= nil and type(request.dry_run) ~= "boolean" then
        return hotupgrade_result.failure("HU_INVALID_REQUEST", "dry_run 必须为布尔值")
    end
    local path = request.path
    local dry_run = request.dry_run
    self.sequence = self.sequence + 1
    self.active =
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
    local batch = self.active
    skynet.fork(function()
        self:run(batch, {path = path, dry_run = dry_run})
    end)
    return hotupgrade_result.success({batch_id = batch.batch_id})
end
```

这就是 Controller 接受一次发布的完整过程。

此处有两个不同的状态对象：

`self` 是 Controller 模块表本身，保存唯一控制面的运行状态。现有实现没有创建额外的 Controller 实例。

`batch` 是刚刚创建的一次发布批次对象。

`self.active = batch` 代表 Controller 当前正在管理这个批次。

`self.sequence` 则是 Controller 生命周期内不断递增的批次序号。它与 Controller 自己的 handle 一起组成 `batch_id`，用于区分不同事务。

创建完批次后：

```lua
skynet.fork(function()
    self:run(batch, {path = path, dry_run = dry_run})
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

后续真正的文件加载、Prepare、Update、Finish，都由新协程中的 `M:run()` 负责执行。

这也是为什么我们的 Sample 必须通过 `status({batch_id=...})` 等待最终结果。

#### 第一次状态快照：begin 被接受

```text
Controller
    phase = WAITING_CREATIONS
    active = batch
    sequence = 1
    batch.batch_id = "<Controller handle>:1"
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

### 2. 为什么 `run()` 不直接加载 Patch，而要先等待生命周期屏障？

接下来执行权来到 Controller 新协程。

当前函数：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:run(batch, request)`。

调用者是刚才 `M:begin()` 创建的 `skynet.fork()` 协程。

先看 `run()` 的开头，这是一段连续真实源码：

```lua
function M:run(batch, request)
    -- 登记 waiter 到 wait 之间不 yield；完成回调会唤醒同一批次，恢复后重验身份和计数。
    while self.active == batch and (self.creation_count > 0 or self.module_load_count > 0) do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end
    if self.active ~= batch then
        return
    end
    self:advance_deployment()
    local dry_run = request.dry_run == true
    local ok, message = pcall(function()
        local loaded = self:load(request)
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

只要任一计数不为零，`run()` 就通过 `skynet.wait()` 等待。

当这些操作完成时，相应的登记或取消函数会更新计数，并调用 `advance_deployment()`。当两个计数都归零时，它会设置阶段并唤醒等待中的发布协程。

`skynet.wakeup()` 只是让协程有机会恢复，`run()` 恢复后仍然重新检查计数以及当前 `batch` 的身份。

在我们这次 Sample 中，第一次 PlayerService 的 `init` RPC 已经成功返回，创建和模块登记都已完成，因此两个计数都是零，不需要实际等待。

不过这里必须理解清楚：

**生命周期屏障保护的是 Service 和模块登记过程，不是玩家正在执行的业务。**

玩家业务的安全点，要等到稍后的 Prepare 才建立。

这是两种不同的等待机制，不能混为一谈。

### 3. Controller 怎样读取发布包并确定目标？

生命周期屏障通过后，`run()` 进入：

```lua
local loaded = self:load(request)
```

这是对同一个 Controller 模块表的方法调用，仍然运行在 Controller Service 的 Lua State 内，没有跨 Service。

现在进入：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:load()`。

这里的 `request.path` 就是我们从 Sample 传入的 `"v2"`。

`M:load()` 先检查生命周期和请求，再调用同文件的 `build_patch()`。

`build_patch()` 经由 `load_files()` 和 Native `list_lua()` 扫描发布目录，使用 Native `read_file()` 读取文件内容。

对每份源码，`load_files()` 用：

```lua
local chunk, syntax_error = load(source, "@" .. relative, "t", {})
if not chunk then
    return hotupgrade_result.failure("HU_MODULE_SYNTAX", syntax_error)
end
```

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

分类之后，`M:load()` 再根据 Controller 已保存的 `targets` 登记表确定真正需要发送控制 RPC 的目标。

真实源码的目标匹配部分位于 `M:load()`：

```lua
local targets = {} -- 本批需要执行原有更新协议的真实 Service。
local matched = {} -- 当前登记快照已覆盖的 Service .patch 文件。
for _, record in pairs(self.targets) do
    local modules = {}
    for _, entry in ipairs(loaded.patch.modules) do
        if record.modules[entry.name] then
            modules[#modules + 1] = entry
        end
    end

    local service = loaded.patch.services[record.service_name]
    if service and not record.service_patch then
        return hotupgrade_result.failure("HU_SERVICE_PATCH_UNSUPPORTED", request.path .. "/" .. service.entry_file
            .. ": 目标 " .. record.handle .. " 未提供 Service 内部更新入口")
    end

    if service then
        matched[service.entry_file] = true
    end

    if #modules > 0 or service then
        targets[#targets + 1] =
        {
            handle = record.handle,
            modules = modules,
            service_source = service and service.source,
            service_entry_file = service and service.entry_file,
        }
    end
end
```

这是 `M:load()` 中的连续代码，没有重新编写算法。

Controller 从 `self.targets` 取出此前登记的 `first_handle`。

它发现这个 Service 已声明：

`lualib.player_logic`

而本次发布包恰好包含同名的完整模块 Patch。

同时，该 Service 的 `service_name` 是 `player_service`，与发布包中的 `service/player_service.patch` 匹配，而且登记时声明支持 Service 内部更新。

所以本次将 `first_handle` 加入更新目标。

得到的目标记录可以理解为：

```lua
{
    handle = first_handle,
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

`M:load()` 也会检查发布包中的 Service Patch 是否至少匹配一个目标。如果找不到对应的已登记 Service，就不会继续本次发布。

### 4. Prepare 之前，Controller 还做了什么？

现在返回 `M:run()`。

`M:load()` 已经成功返回，里面包含两样东西：

`loaded.patch`：本次完整发布包的冻结内容。

`loaded.targets`：本次要执行运行时更新的目标列表。

接下来，`run()` 先读取正式宿主目录中每份将被部署的 `.lua` 文件的旧内容，保存为 `file.old_source`，供发布决定前失败时恢复。

然后固定：

```lua
batch.files = loaded.patch.files
batch.targets = loaded.targets
batch.target_count = #loaded.targets
```

这些语句位于 `flywow_hotupgrade_controller.lua` 的 `M:run()`，在 `self:load(request)` 返回之后执行。

本次 `batch.files` 包含两份完整 `.lua` 文件：

```text
lualib/player_logic.lua
service/player_service.lua
```

`batch.targets` 则只有一个目标，即 `first_handle`。

到这里，Controller 终于可以开始联系 PlayerService。

#### 第二次状态快照：目标和文件已经固定

```text
Controller
    phase = DEPLOYING → 即将进入 APPLYING
    active = batch
    batch.targets = {first_handle}
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

现在回到 Controller 的 `M:run()`。

接下来执行的是这个函数中的一段连续源码：

```lua
batch.targets = loaded.targets
batch.target_count = #loaded.targets
self.phase = "APPLYING"
for _, command in ipairs({"prepare", "update"}) do
    batch.phase = command:upper()
    for _, target in ipairs(batch.targets) do
        if batch.cancelled then
            batch.error = hotupgrade_result.failure("HU_ABORT_REQUESTED", "管理端终止发布")
            return
        end
        batch.current_handle = target.handle
        target.participated = true
        local answer = self:step(batch, target, command)
        if not answer.ok then
            target.result = answer
            batch.error = answer
            return
        end
    end
end
```

这段代码来自：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:run()`。

这里最重要的一点，是外层循环：

```lua
for _, command in ipairs({"prepare", "update"}) do
```

假设将来有多个 PlayerService 需要更新，那么执行顺序是：

先让**所有目标完成 Prepare**，再开始逐个 Update。

而不是更新完第一个 Service，再去准备第二个。

我们这里只有一个 `first_handle`，因此当前执行的是：

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
    local ok, answer = pcall(skynet.call, target.handle, "hotupgrade", command, request)
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

`target.handle` 是 `first_handle`，也就是我们创建的原 PlayerService。

`command` 当前是 `"prepare"`。

`batch_id` 和 `sequence` 来自刚才 Controller 创建的发布批次。

Prepare 不传送模块源码，只传批次身份。

`skynet.call()` 使 Controller 的当前发布协程 yield，等待 PlayerService 的回复。

这里发生了真正的跨 Service 跳转：

```text
Controller Service                             PlayerService
 M:run()
   └── M:step(batch,target,"prepare")
         │
         └── skynet.call(first_handle, "hotupgrade", "prepare", request)
                                                │
                                                └── skynet.dispatch("hotupgrade")
                                                      └── handle_upgrade("prepare")
                                                            └── before_upgrade()
                                                │
                 <────────── RPC 回复 ────────────┘
         │
         └── 继续 M:run()
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
        -- 未预期异常可能发生在写入后；保留本地事务与 patching，不能伪称恢复成功。
        if module_state.active_transaction then
            module_state.active_transaction.phase = "RECOVERY_REQUIRED"
        end
        answer = hotupgrade_result.failure("HU_RECOVERY_REQUIRED", tostring(answer))
    end

    if session ~= 0 then
        skynet.retpack(answer)
    end
end)
```

这个 `handle_upgrade()` 是 PlayerService 所加载的 HotUpgrade 模块中的**本地函数**，与 Controller 的 `M:handle_command()` 不是同一个函数。

前者执行在 PlayerService 的 Lua State，能够访问玩家状态和本地模块表。

后者执行在 Controller Service 的 Lua State，只负责管理命令及协调。

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
    local txn = {batch_id = request.batch_id, sequence = request.sequence, phase = "QUIESCING"}
    module_state.active_transaction = txn
    M.patching = true
    if not module_state.registration.before_upgrade then
        return hotupgrade_result.failure("HU_SAFEPOINT_REQUIRED", "未提供 before_upgrade，不能确认业务已排空")
    end
    local ok, answer = pcall(module_state.registration.before_upgrade)
    if module_state.active_transaction ~= txn or not M.patching then
        return hotupgrade_result.failure("HU_STALE_TRANSACTION", "等待时批次已结束")
    end
    if not ok then
        return hotupgrade_result.failure("HU_PREPARE_FAILED", tostring(answer))
    end
    if answer ~= true and not (type(answer) == "table" and answer.ok == true) then
        return hotupgrade_result.failure("HU_SAFEPOINT_REQUIRED",
            type(answer) == "table" and (answer.message or answer.code) or "before_upgrade 未确认业务安全点")
    end
    txn.phase = "QUIESCED"
    return hotupgrade_result.success()
end
```

这段才真正开始改变 PlayerService 的运行状态。

它先创建 `txn`，保存本次批次身份，并将阶段设置成 `QUIESCING`。

然后：

```lua
module_state.active_transaction = txn
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

`handle_upgrade()` 将：

`txn.phase = "QUIESCED"`

随后返回 `{ok=true}`，通过 PlayerService 的 `skynet.retpack()` 回复 Controller。

Controller 中先前 yield 的 `M:step()` 恢复，接着返回 `M:run()`。

**到这里，Prepare 才真正完成。**

我们这次没有模拟耗时业务，因此在实际运行中，这个等待通常会很快完成。不过它所建立的安全条件，是后面原地修改 Lua 对象的前提。

#### 第三次状态快照：Prepare 完成

```text
Controller
    phase = APPLYING
    batch.phase = PREPARE
    batch.targets = {first_handle}
    batch.control_started = true

原 PlayerService
    hot.patching = true
    module_state.active_transaction = txn
    txn.phase = QUIESCED

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

现在 `M:run()` 已经完成所有目标的 Prepare。

外层循环进入第二轮：

`command = "update"`

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

Controller 通过 `skynet.call()` 把更新请求发送给 `first_handle`，当前协程再次 yield。

PlayerService 收到消息后，经本地 `skynet.dispatch("hotupgrade", ...)` 进入：

`flywow_hotupgrade.lua` 的 `handle_upgrade("update")`。

现在先看真实代码的 Stage 部分：

```lua
if command == "update" then
    if txn.phase ~= "QUIESCED" then
        return hotupgrade_result.failure("HU_SAFEPOINT_REQUIRED", "Prepare 尚未确认业务安全点")
    end
    -- Stage 只准备候选和快照，不写线上导出或状态。
    for _, entry in ipairs(request.modules or {}) do
        if not module_state.declared_modules[entry.name] then
            return hotupgrade_result.failure("HU_MODULE_NOT_REGISTERED", tostring(entry.name))
        end
    end

    local staged = hotupgrade_module_patch.stage(request.modules or {})
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
for _, name in ipairs(module_stage.order) do
    local entry = module_stage.entries[name]
    local candidate = entry.chunk()
    check_exports(candidate, name)
    assert(candidate ~= entry.live, "候选须返回新的导出表")
    for key, value in pairs(candidate) do
        assert(entry.live[key] == nil or type(entry.live[key]) == type(value), "导出字段类型变化")
    end

    assert((entry.live.export_state == nil) == (candidate.import_state == nil),
        "新旧模块缺少配对状态钩子")
    if entry.live.export_state then
        -- 新版只能接触独立数据；旧闭包仍持有自己的状态，Abort 恢复旧导出即可。
        local snapshot = M.copy_state(entry.live.export_state())
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

#### 接着 Stage Service 状态和函数

普通模块 Stage 成功后，`handle_upgrade("update")` 执行：

```lua
local ok, service = pcall(stage_service, request.service_source)
```

这里的 `stage_service()` 不是 Skynet Service，而是 `flywow_hotupgrade.lua` 内的普通本地函数。

它的参数就是 Controller 发来的 `service/player_service.patch` 源码字符串。

我们进入这个函数。

文件：`hotupgrade/lualib/flywow_hotupgrade.lua`

函数：`local function stage_service(source)`

完整实现：

```lua
local function stage_service(source)
    if not source then
        return nil
    end

    local service_update = assert(module_state.registration.service_update, "Service 未提供内部更新入口")
    local chunk = assert(load(source, "=Service Patch", "t", _G))
    local build = chunk()
    assert(type(build) == "function", "Service Patch 必须返回构建函数")
    local patch = build(service_update.state)
    assert(type(patch) == "table" and getmetatable(patch) == nil, "Service 构建结果必须是普通表")
    assert(patch.migrate == nil or type(patch.migrate) == "function", "migrate 必须是函数")
    assert(patch.functions == nil or (type(patch.functions) == "table"
        and getmetatable(patch.functions) == nil), "functions 必须是普通表")
    assert(patch.migrate or (patch.functions and next(patch.functions)), "Service Patch 没有更新内容")
    local staged =
    {
        patch = patch,       -- 仅本 State 持有的新函数和迁移函数。
        old_functions = {}, -- 本次将替换的现有函数，不处理未列出的字段。
        touched = false,    -- 首次线上写入前置 true，部分提交同样必须恢复。
    }
    for name, fn in pairs(patch.functions or {}) do
        assert(type(name) == "string" and type(fn) == "function"
            and type(rawget(service_update.functions, name)) == "function", "只能直接替换现有业务函数")
        staged.old_functions[name] = rawget(service_update.functions, name)
    end

    if patch.migrate then
        if service_update.snapshot then
            staged.old_state = service_update.snapshot(service_update.state)
            local isolated = service_update.snapshot(service_update.state)
            assert(type(staged.old_state) == "table" and type(isolated) == "table"
                and staged.old_state ~= service_update.state and isolated ~= staged.old_state
                and isolated ~= service_update.state, "自定义快照必须独立")
            staged.next_state = patch.migrate(isolated)
        else
            staged.old_state = hotupgrade_module_patch.copy_state(service_update.state)
            staged.next_state = patch.migrate(hotupgrade_module_patch.copy_state(staged.old_state))
            staged.next_state = hotupgrade_module_patch.copy_state(staged.next_state)
        end

        assert(type(staged.next_state) == "table" and staged.next_state ~= service_update.state,
            "迁移须返回完整独立候选状态")
    end

    return staged
end
```

这段函数比较长，但实际只做一件事：**根据本 Service 的登记配置和 Patch 源码，准备状态及函数更新所需的全部候选与旧快照。**

我们沿执行顺序看。

最初：

```lua
local service_update = assert(module_state.registration.service_update, ...)
```

它取得的就是此前 `initialize()` 中登记的：

```lua
service_update = {state = state, functions = business}
```

这两行分别来自框架的 `stage_service()` 和我们 V1 `player_service.lua` 的 `initialize()` 登记配置。它们表达的是同一份对象引用关系。

接着：

```lua
local chunk = assert(load(source, ...))
local build = chunk()
local patch = build(service_update.state)
```

这三句位于框架 `stage_service()` 内。

调用 `load()` 编译 `.patch` 源码。

执行 `chunk()` 得到我们在 `player_service.patch` 最外层返回的 `function(state)`。

随后执行 `build(service_update.state)`，把原 PlayerService 的真实状态根表传进去。

因此，`player_service.patch` 里面新定义的 `functions.load` 所捕获的 `state`，就是现存 Service 的原表，而不是迁移后另外创建的一张表。

后面函数检查新函数是否可以替换已存在的 `business.load`，并把旧函数保存到：

`staged.old_functions.load`

然后开始迁移状态。

我们没有提供自定义的 `snapshot()`、`commit()`、`restore()`，因此使用默认的普通 table 复制与恢复逻辑。

框架先保存一份独立的旧状态快照：

```text
staged.old_state
    equip = "刀"
    schema_version = 1
```

再复制一份独立数据交给 `patch.migrate()`。

而我们的 `migrate()` 返回：

```text
staged.next_state
    equip = "剑"
    schema_version = 2
```

现在需要特别区分三份东西：

```text
PlayerService 线上 state
    equip = "刀"
    schema_version = 1
         │
         ├── old_state：独立旧快照，供恢复使用
         │
         └── next_state：独立 V2 候选状态
```

此时真正的 `state` 还是 V1。

框架只创建了候选状态，没有把 `state` 替换成 `next_state`。

这样，即使 Stage 失败，正常线上对象也不需要先经历一次修改再恢复。

`stage_service()` 返回 `staged` 后，执行权回到本地 `handle_upgrade("update")`，把它保存到 `txn.service`，并设置：

`txn.phase = "STAGED"`

#### 第四次状态快照：Stage 完成

```text
Controller
    phase = APPLYING
    batch.phase = UPDATE
    正在等待 first_handle 的 Update RPC

原 PlayerService
    hot.patching = true
    txn.phase = STAGED

    logic.version() = "v1"
    state.equip = "刀"
    state.schema_version = 1

    business.load(100) = 105
    initial_load(100) = 105

    txn.modules
        已保存旧模块字段
        已生成 V2 候选模块

    txn.service
        old_state = V1 快照
        next_state = V2 候选状态
        old_functions.load = V1 闭包
        patch.functions.load = V2 闭包

正式磁盘
    player_logic.lua = V1
    player_service.lua = V1
```

到这个时间点，我们已经有了所有将要安装的新版本内容，但线上仍然是旧版本。

接下来才是最关键的一步：Activate。

### 7. Activate：在原有对象上正式安装 V2

现在继续执行：

`hotupgrade/lualib/flywow_hotupgrade.lua` 的 `handle_upgrade("update")`。

前面已经运行到：

`txn.phase = "STAGED"`

紧接着执行下面这段真实源码：

```lua
-- Activate 同步提交；任一步失败先组合恢复，再由 Controller 整批 Abort。
local installed = hotupgrade_module_patch.commit(txn.modules)
local ok, message = pcall(function()
    assert(installed.ok, installed.message)
    local staged = txn.service
    if staged then
        local service_update = module_state.registration.service_update
        staged.touched = true
        if staged.next_state then
            if service_update.commit then
                assert(service_update.commit(service_update.state, staged.next_state) ~= false, "Service 拒绝提交")
            else
                hotupgrade_module_patch.restore_state(service_update.state, staged.next_state)
            end
        end

        for name, fn in pairs(staged.patch.functions or {}) do
            rawset(service_update.functions, name, fn)
        end
    end

    if module_state.registration.after_upgrade then
        assert(module_state.registration.after_upgrade() ~= false, "after_upgrade 拒绝更新")
    end
end)
if not ok then
    local restored = abort(txn)
    return restored.ok and hotupgrade_result.failure("HU_ACTIVATE_FAILED", tostring(message)) or restored
end

txn.phase = "ACTIVATED"
return hotupgrade_result.success()
```

这是同一个 Update RPC 内部的后半段，没有增加新的控制 RPC。

这段代码首先调用：

`hotupgrade_module_patch.commit(txn.modules)`

进入 `flywow_hotupgrade_module_patch.lua` 的 `M.commit()`。

它在通过模块身份检查后，对每个模块调用本文件的 `replace_exports()`。

`replace_exports()` 的完整实现是：

```lua
local function replace_exports(live, fields)
    assert(type(live) == "table" and getmetatable(live) == nil, "线上表身份或元表发生变化")
    for key in pairs(live) do
        rawset(live, key, nil)
    end

    for key, value in pairs(fields) do
        rawset(live, key, value)
    end
end
```

这里的 `live` 是已经加载的模块导出根表，也就是 PlayerService 中 `logic` 指向的对象。

`fields` 是 Stage 得到的 V2 候选导出字段。

代码先删除原导出字段，再安装新字段。

**它没有把 `package.loaded["lualib.player_logic"]` 改为另一张 table。**

因此原来的：

`logic`

仍指向同一张模块导出表，但 `logic.version()` 已经执行 V2 函数，返回 `"v2"`。

需要特别注意，此时 `business.load` 还没有改变。

它是之前 `logic.make_load(state)` 返回并保存下来的旧闭包，而不是每次调用时都重新从 `logic` 中获取函数。

所以普通模块更新结束后，短暂出现这样的内部状态：

```text
logic.version() = "v2"
business.load = V1 闭包
state.equip = "刀"
```

这是一次尚未结束的 Activate 内部状态，不是已经开放给业务使用的最终状态。Prepare 阶段建立的安全点仍然有效。

接下来 `handle_upgrade("update")` 开始应用 Service Patch。

它取得：

`module_state.registration.service_update`

也就是原来的 `{state=state, functions=business}`。

先设置：

`staged.touched = true`

这个标记非常重要。一旦开始提交 Service 状态，即使提交过程部分失败，Abort 也需要知道必须尝试恢复。

随后，因为本例没有自定义 `commit()`，框架调用：

`hotupgrade_module_patch.restore_state(service_update.state, staged.next_state)`

虽然这里使用的函数名叫 `restore_state`，但它负责的是把一份普通数据图的字段**原地应用到指定根表**。

对应源码：

```lua
function M.restore_state(live, fields)
    assert(type(live) == "table" and type(fields) == "table", "状态必须为表")
    M.copy_state(fields, live)
end
```

来源是 `hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`。这次由 `handle_upgrade("update")` 的 Activate 分支调用。

调用时：

`live` 是原 PlayerService 的 `state`。

`fields` 是 Stage 生成的 `next_state`。

执行结束后，原 `state` 的字段已经成为：

```lua
{
    equip = "剑",
    schema_version = 2,
}
```

但它的 table 身份没有变化。

原来的 `state_root` 和 Patch 中新函数捕获的 `state`，仍然指向这张表。

接下来更新业务函数：

```lua
for name, fn in pairs(staged.patch.functions or {}) do
    rawset(service_update.functions, name, fn)
end
```

这段是框架 `handle_upgrade("update")` 的 Activate 代码。

我们的 `staged.patch.functions` 只有一个 `load` 字段。

所以最终执行的效果相当于：

```lua
business.load = 新的 V2 闭包
```

这行是帮助理解的等价表达，不是框架源码。

这次更新保留 `business` 表本身，只替换了其中的 `load` 函数字段。

于是：

`business.load(100)` 现在得到 `121`。

而 `initial_load` 是此前独立保存的旧闭包引用，没有任何代码重新给它赋值。

因此它仍然执行 V1 的 `"刀"` 判断。

但它捕获的 `state` 已经被原地迁移成 `"剑"`，所以：

`initial_load(100)` 现在返回 `100`，而不再是 V1 初始状态下的 `105`。

这正好说明：

**旧闭包保留的是旧函数逻辑，不代表它捕获的状态也被冻结在旧版本。**

最后，Activate 调用我们登记的 `after_upgrade()`，检查模块版本、装备、状态版本和攻击计算。检查成功，便把：

`txn.phase = "ACTIVATED"`

并返回 `{ok=true}`。

如果 Activate 中出现错误，当前 Service 会先尝试本地组合恢复；Controller 得知失败后，还会进入整批 Abort。

当前成功路径中，PlayerService 的 Update RPC 到这里已经结束。

#### 第五次状态快照：Activate 完成

```text
Controller
    phase = APPLYING
    batch.phase = UPDATE
    已收到 first_handle 的 Update 成功

原 PlayerService
    hot.patching = true
    txn.phase = ACTIVATED

    state == state_root
    state.equip = "剑"
    state.schema_version = 2

    logic = 原来的模块导出根表
    logic.version() = "v2"

    business = 原来的业务函数表
    business.load = V2 闭包
    business.load(100) = 121

    initial_load = 原 V1 闭包
    initial_load(100) = 100

    package.loaded["player_logic"] == logic
    package.loaded["lualib.player_logic"] == logic

    旧模块导出快照：仍保留
    旧 Service 状态和函数快照：仍保留

正式磁盘
    player_logic.lua = V1
    player_service.lua = V1
```

这里有一个很重要的现象：

**原 PlayerService 已经运行 V2 业务，但正式磁盘文件仍然是 V1。**

这是有意安排的。

如果这时候马上开放业务，后来创建的新 PlayerService 仍会读到旧文件，造成新旧实例版本不一致。

因此，Update 成功后还不能释放旧快照，也不能让 `hot.patching` 变回 `false`。

接下来执行权回到 Controller，继续完成正式文件部署。

### 8. Controller 怎样部署正式 Lua 文件？

现在执行权回到了：

`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:run()`。

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

这段代码位于 `M:run()` 的 Update 成功之后。

`batch.files` 是之前由 `M:load()` 冻结的正式 `.lua` 文件集合。

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

正式文件部署、代码缓存清理和所有目标 Update 均确认成功之后，执行权仍然在 Controller 的 `M:run()`。

接下来执行：

```lua
-- 文件和全部 Update 已确认成功；各目标 Finish 独立报告，不再执行回滚。
batch.phase = "PUBLISH_DECIDED"
batch.decided = true
for _, target in ipairs(batch.targets) do
    batch.current_handle = target.handle
    target.result = self:step(batch, target, "finish")
    if not target.result.ok then
        batch.error = hotupgrade_result.failure("HU_RECOVERY_REQUIRED",
            target.result.message or target.result.code, "finish")
        self.recovery_required = true
    end
end
batch.phase = batch.error and "RECOVERY_REQUIRED" or "COMPLETED"
```

这是 `flywow_hotupgrade_controller.lua` 的 `M:run()` 中完整的发布决定和 Finish 循环。

首先把批次阶段设置为：

`PUBLISH_DECIDED`

并设置：

`batch.decided = true`

这表示 Controller 已经确认本批次的所有运行时 Update 和正式文件部署都成功了。

随后，Controller 通过此前学习过的 `M:step()`，向 `first_handle` 发送：

`handle_upgrade("finish")`

这又是一条跨 Service RPC。

PlayerService 收到后，仍然进入：

`hotupgrade/lualib/flywow_hotupgrade.lua` 的本地 `handle_upgrade()`。

我们之前已经读过这个函数的 Prepare 和 Update，现在继续读 Finish 分支：

```lua
-- finish 确认提交后才清理旧快照并重新开放业务入口。
if command == "finish" and txn.phase == "ACTIVATED" then
    local finished = hotupgrade_module_patch.finish(txn.modules)
    if not finished.ok then
        txn.phase = "RECOVERY_REQUIRED"
        return finished
    end

    module_state.completed_sequence = txn.sequence
    module_state.last_batch_id = txn.batch_id
    module_state.active_transaction = nil
    M.patching = false
    return hotupgrade_result.success()
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

Controller 收齐结果后，在 `M:run()` 的结尾保存最终批次记录：

```lua
self.last = batch
self.active = nil
self.phase = self.recovery_required and "FAILED_LOCKED"
    or (batch.error and "IDLE" or batch.phase)
self:wake_lifecycle()
```

这里的代码来自 `M:run()` 的事务收尾部分。

本次成功，因此：

`batch.phase = "COMPLETED"`

`self.phase = "COMPLETED"`

`self.active = nil`

`self.last` 保存刚才完成的批次记录。

`self:wake_lifecycle()` 则唤醒发布期间等待创建新 Service 或首次加载模块的协程。

#### 第七次状态快照：Finish 完成

```text
Controller
    phase = COMPLETED
    active = nil
    last = 本次 batch
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

现在主 Service 向原来的 `first_handle` 发送：

`skynet.call(first_handle, "lua", "inspect")`

这是我们自己编写的 `lesson4_main.lua` 中的 RPC。

因为 Finish 已经把 `hot.patching` 改为 `false`，所以 PlayerService 的 `"lua"` dispatch 允许查询进入业务 queue。

`business_queue(inspect)` 执行的 `inspect()` 就是最早在 `host_v1/service/player_service.lua` 中定义的那个函数。

注意：原 Service 没有重新执行 V2 `player_service.lua` 文件。

它仍然运行原先已经加载的 Service 入口代码，里面的 `inspect()`、`initialize()` 等局部函数并没有被整体替换。

但我们明确登记并更新的 `state`、`logic` 导出字段和 `business.load`，已经变成 V2。

所以原 PlayerService 返回的数据应当是：

| 检查项目 | 预期结果 |
|---|---|
| `handle` | 等于原 `first_handle` |
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
local second_handle = hot.newservice("player_service")
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
second_handle
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
原 PlayerService（first_handle 不变）
    V1 入口启动 → V1 状态和模块
    → Prepare → Update → Finish
    → 现存对象更新为 V2

新 PlayerService（second_handle 是新 handle）
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

Controller 的 `M:step()` 将失败结果交给 `M:run()`，后者进入恢复分支，对已经参与当前批次的目标发送：

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

所以 `M:run()` 的恢复分支会先尝试恢复已经改动的正式文件，并在需要时重新清理 Skynet 代码缓存。

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

`FAILED_LOCKED`

这意味着系统无法确认版本已经收敛，后续新的发布及受管理创建会被门禁阻止，需要宿主核实和处理。

第二种是**Finish 阶段失败**。

它发生在 `PUBLISH_DECIDED` 之后。

此前新版正式文件已经部署，运行时 Update 也已成功。部分目标甚至已经 Finish，释放了旧快照并重新开放业务。

这时候再强行整批回滚是不安全的。

所以 Controller 会继续尝试其他目标的 Finish，并报告失败，将生命周期锁定，而不会撤回新版文件或对已经 Finish 的目标执行整体回滚。

`resolve_deployment()` 也不是一键恢复函数。它只是让宿主在核实并完成必要的人工恢复或版本收敛后，显式确认可以解除 Controller 的发布锁定。

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
原 handle 保持: true
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
Controller：建立 batch / skynet.fork(run)
    ↓
生命周期屏障：等待创建和首次加载完成
    ↓
加载发布包：冻结源码 / 确定目标 / 保存旧文件
    ↓ RPC
PlayerService Prepare：patching=true / 等待 queue 排空
    ↓ RPC
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
