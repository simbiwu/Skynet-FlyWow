# 第 6 课：Skynet 协程、业务 Queue 与热更安全点

**源码基线**：`simbiwu/SKYNET-FLYWOW`，`bbef522d03654248cbbc73c17d5f80a6335a7a77`（2026-10-23）。Skynet 的 `lualib/skynet/queue.lua`、`lualib/skynet.lua` 按官方源码核对。本文所有 `hotupgrade/lesson6/` 文件都是**本课新建的教学文件**，不是声称仓库已经存在的源码；标注 `hotupgrade/lualib/...` 的部分才是 FlyWow 真实实现。

**本课目标**：已经运行的 PlayerService 正处理一个会 yield 的请求，Controller 此时开始热更。我们要亲手看到：正在处理的业务为什么可以继续完成，已经进入 queue 的请求为什么会被排空，之后的新请求在哪里被拒绝，Prepare 为什么等待，以及 fork 出去的协程为什么不会自动被业务 queue 管住。完成后，你应该能独立审核一个业务 Service 是否真正达到了安全更新点。

## 学习方法：从第 4、5 课继承什么

第 4 课有效的方式是**从零建立同一个 PlayerService，沿真正的运行顺序走**：启动 V1 → Controller 初始化 → `newservice` → `init` / `register_service` → `begin` → Prepare → Update → 正式文件部署 → Finish → 验收。每次跨文件，都先说明谁调用、运行在哪个 Service、是否发生 RPC/yield，再进入源码；不把一串零散的函数片段当作教程。

第 5 课有效的方式是**一次只深入一个内部机制**：用独立的最小实验观察 `stage/commit/abort/finish`，持续跟踪 `live` 模块表、候选表、旧函数字段和闭包引用；先给出能验证的现象，再对应源码解释，最后回到第 4 课的大调用链。这样可以做到深入而不重复上一课。

第 6 课沿用两者的长处：**只有一条主线、一个 PlayerService、一份 V1/V2 模块**。先搭好能实际运行的完整实验，再按事件发生顺序进入真实 `skynet.queue`、业务入口、`handle_upgrade(prepare)` 和 Controller 的 `run_batch`，每个阶段使用相同的状态指标。成功流程讲透以后，只解释本课直接相关的边界。Guard 已从当前项目删除，因此不介绍不存在的 Guard API，也不设计替代封装；复杂回滚、故障注入留给第 7、8 课。

## 一、先明确我们要复现的现场

玩家初始金币为 **100**，普通模块 `player_logic.lua` 是 V1，`version()` 返回 `"v1"`。我们让 PlayerService 按时间顺序收到三个请求：

- 请求 A：`hold`，取得业务 queue 后挂起（`skynet.wait()`），稍后释放时扣 **10** 金币。
- 请求 B：`spend(20)`，在热更开始之前已经通过业务入口检查，但因 A 占着 queue，只能排队。
- 请求 C：热更 Prepare 已经设置 `hot.patching=true` 后才到达的 `spend(30)`，应立即返回 `HU_UPGRADING`，不能加入业务 queue。

同时，我们启动一个 **`skynet.fork()` 的只读演示任务**，使它在 Prepare 期间仍在运行。它不修改玩家状态，目的只是证明它不会自动成为 queue 的一部分。

预期时间线：

```text
A: hold          进入 queue → wait，继续占有 queue ────────┐
B: spend(20)                已通过入口检查 → 排队 ───────┤
Controller: begin                               ↓         │
Controller: prepare → PlayerService: hot.patching=true    │
PlayerService: before_upgrade() → 在 queue 后面排队 ─────┤
C: spend(30) → HU_UPGRADING，没进入 queue                 │
Main: release A → A 扣10 → B 扣20 → before_upgrade 得到 queue
Controller: Update V2 → 部署 player_logic.lua → Finish
PlayerService: hot.patching=false；下一笔业务看到 V2
```

请记住两种不同的“新”：**C 是 Prepare 设置 `patching` 之后才进入业务入口的新请求；B 是 Prepare 之前就已经被业务入口接纳、但尚未获得 queue 的在途请求**。本课最重要的安全点，正是让 B 也结束以后才更新。

## 二、第一阶段：准备一个最小、可重复运行的教学工程

本课沿用第 4 课的目录与构建习惯，但采用**当前源码的正式配置名称** `patch_path / root_path / service_path`，不沿用第 4 课旧文档中的 `patch_root / service_dir`。每次运行都把 V1 复制到独立运行目录，避免上次发布过的文件污染实验。

新建以下完整目录：

```text
hotupgrade/lesson6/
├── lesson6_main.lua
├── skynet_config.lua
├── run.sh
├── host_v1/
│   ├── service/
│   │   └── player_service.lua
│   └── lualib/
│       └── player_logic.lua
└── patches/
    └── v2/
        └── lualib/
            └── player_logic.lua
```

V2 发布包只包含一个完整普通模块。**我们不添加 Service `.patch`**，因为这一课要理解的不是状态迁移算法，而是怎样安全地等待正在运行的业务结束。金币数据不会因普通模块发布而被重置。

### 先建立 V1 和 V2 的完整模块

**新建文件** `hotupgrade/lesson6/host_v1/lualib/player_logic.lua`：

```lua
local M = {}

function M.version()
    return "v1"
end

return M
```

**新建文件** `hotupgrade/lesson6/patches/v2/lualib/player_logic.lua`：

```lua
local M = {}

function M.version()
    return "v2"
end

return M
```

这两个模块刻意只差一个返回值。第 5 课已经学过引擎怎样保持旧导出表身份并替换 `version` 字段；本课只需把 `logic.version()` 当作当前版本的观察点。

### 编写完整 PlayerService：所有请求和安全点都在同一个文件

**新建文件** `hotupgrade/lesson6/host_v1/service/player_service.lua`。下面是完整代码，后文将按真实执行顺序逐个进入其中的函数；请先整体读一遍，暂时不要跳着理解。

```lua
local skynet = require "skynet"
local business_queue = require "skynet.queue"()
local hot = require "flywow_hotupgrade"
local logic = hot.require("player_logic")

local state =
{
    gold = 100,
}

local hold_thread
local holding = false
local waiting_spends = 0
local background_running = false

-- 业务 A：取得 queue 后主动 yield，等待主 Service 发 release。
local function hold()
    if hot.patching then
        return {ok = false, code = "HU_UPGRADING"}
    end

    return business_queue(function()
        holding = true
        hold_thread = coroutine.running()
        skynet.wait()

        hold_thread = nil
        holding = false
        state.gold = state.gold - 10
        return {ok = true, gold = state.gold, version = logic.version()}
    end)
end

-- 业务 B/C：先在入口检查更新标志，再进入相同的业务 queue。
local function spend(amount)
    if hot.patching then
        return {ok = false, code = "HU_UPGRADING"}
    end

    waiting_spends = waiting_spends + 1
    local ok, answer = pcall(business_queue, function()
        state.gold = state.gold - amount
        return {ok = true, gold = state.gold, version = logic.version()}
    end)
    waiting_spends = waiting_spends - 1

    if not ok then
        error(answer)
    end
    return answer
end

-- 演示用：仅唤醒等待中的协程，不能在业务 queue 内执行。
local function release_hold()
    if not hold_thread then
        return {ok = false, code = "NOT_HOLDING"}
    end
    return {ok = skynet.wakeup(hold_thread) == true}
end

-- 演示用：不进入业务 queue 的 fork 协程，不修改业务状态。
local function fork_probe()
    skynet.fork(function()
        background_running = true
        skynet.sleep(500)
        background_running = false
    end)
    return {ok = true}
end

-- 只读诊断入口：故意不经过业务 queue，以便观察 hold 期间的状态。
-- 正式业务读写仍须遵循同一套入口与 queue 规则。
local function peek()
    return
    {
        ok = true,
        gold = state.gold,
        version = logic.version(),
        patching = hot.patching,
        holding = holding,
        waiting_spends = waiting_spends,
        background_running = background_running,
    }
end

local function initialize()
    return hot.register_service(
    {
        before_upgrade = function()
            return business_queue(function()
                return true
            end)
        end,
    })
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, argument)
        local answer

        if command == "init" then
            answer = initialize()
        elseif command == "hold" then
            answer = hold()
        elseif command == "spend" then
            answer = spend(argument)
        elseif command == "release" then
            answer = release_hold()
        elseif command == "fork_probe" then
            answer = fork_probe()
        elseif command == "peek" then
            answer = peek()
        else
            answer = {ok = false, code = "UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
```

这是教学示例而不是通用业务框架：`hold` / `release` 是为了稳定控制 yield 的发生顺序，`peek` 是为了能够在业务 queue 被占用时查看局部状态；真实业务不会需要这些演示命令。`waiting_spends` 只是本课观察“请求已通过入口但还在等待 queue”的指标，不参与热更控制。

注意顶部这四行调用发生在 **PlayerService 入口文件加载阶段**。这符合已经确认的新启动合同：**主 Service 必须先完成 Controller 初始化，再创建这个受管理的 PlayerService**。现在 `require "flywow_hotupgrade"` 不在文件顶部执行 Controller RPC，而 `hot.require("player_logic")` 在尚未 `register_service` 时也不会申请模块加载许可，只会完成初始模块加载和声明。

### 编写主 Service：以确定顺序驱动现场

**新建文件** `hotupgrade/lesson6/lesson6_main.lua`。这里是本课真正的执行起点，后面的源码阅读都从它发出的请求继续追踪。

```lua
local skynet = require "skynet"

local function wait_until(predicate, description)
    for _ = 1, 1000 do
        if predicate() then
            return
        end
        skynet.sleep(1)
    end
    error("等待失败：" .. description)
end

skynet.start(function()
    -- 先初始化 Controller，再创建业务 Service；这是本工程明确的启动合同。
    local controller = skynet.uniqueservice("flywow_hotupgrade_service")
    local root = assert(os.getenv("HOTUPGRADE_LESSON6_ROOT"))
    local initialized = skynet.call(controller, "lua", "init",
    {
        patch_path = root .. "/patches",
        root_path = root .. "/host",
        service_path = "service",
    })
    assert(initialized.ok, tostring(initialized.message))

    local hot = require "flywow_hotupgrade"
    local player = hot.newservice("player_service")
    local registered = skynet.call(player, "lua", "init")
    assert(registered.ok, tostring(registered.message))

    -- A：先持有业务 queue，然后在 queue 内 skynet.wait()。
    local hold_answer
    skynet.fork(function()
        hold_answer = skynet.call(player, "lua", "hold")
    end)
    wait_until(function()
        return skynet.call(player, "lua", "peek").holding
    end, "A 已经进入 queue 并挂起")

    -- B：在 Prepare 之前通过业务入口，但排在 A 后面。
    local queued_answer
    skynet.fork(function()
        queued_answer = skynet.call(player, "lua", "spend", 20)
    end)
    wait_until(function()
        return skynet.call(player, "lua", "peek").waiting_spends == 1
    end, "B 已经排队")

    -- 与业务 queue 无关的 fork 任务，只做观察，不更改金币。
    assert(skynet.call(player, "lua", "fork_probe").ok)
    wait_until(function()
        return skynet.call(player, "lua", "peek").background_running
    end, "fork 任务正在运行")

    -- 第 4 课的 begin：这里只为真正触发 Prepare。
    local begun = skynet.call(controller, "hotupgrade", "begin", {path = "v2"})
    assert(begun.ok, tostring(begun.message))

    -- 等到 PlayerService 已进入 Prepare 并设置 patching。
    wait_until(function()
        return skynet.call(player, "lua", "peek").patching
    end, "Prepare 已设置 hot.patching")

    local during = skynet.call(player, "lua", "peek")
    assert(during.holding and during.waiting_spends == 1)
    print("PREPARE:", during.gold, during.version, during.patching,
        during.holding, during.waiting_spends, during.background_running)

    -- C：到达时间晚于 Prepare，必须在入口被拒绝。
    local rejected = skynet.call(player, "lua", "spend", 30)
    assert(not rejected.ok and rejected.code == "HU_UPGRADING")

    -- 唤醒 A。之后队列依次执行 B，最后 before_upgrade 才取得 queue。
    assert(skynet.call(player, "lua", "release").ok)
    wait_until(function()
        return hold_answer ~= nil and queued_answer ~= nil
    end, "A 和 B 均完成")
    assert(hold_answer.ok and hold_answer.gold == 90)
    assert(queued_answer.ok and queued_answer.gold == 70 and queued_answer.version == "v1")

    -- Controller 最终发布完成；期间会执行 Update、文件部署、Finish。
    local final_record
    wait_until(function()
        local status = skynet.call(controller, "hotupgrade", "status", {batch_id = begun.batch_id})
        assert(status.ok)
        local record = status.record
        if record and (record.phase == "COMPLETED" or record.phase == "ABORTED"
            or record.phase == "RECOVERY_REQUIRED") then
            final_record = record
            return true
        end
        return false
    end, "热更批次结束")
    assert(final_record.phase == "COMPLETED", tostring(final_record.error and final_record.error.message))

    local after = skynet.call(player, "lua", "peek")
    assert(after.gold == 70 and after.version == "v2" and not after.patching)

    local resumed = skynet.call(player, "lua", "spend", 5)
    assert(resumed.ok and resumed.gold == 65 and resumed.version == "v2")

    print("FINISH:", after.gold, after.version, after.patching)
    print("AFTER_BUSINESS:", resumed.gold, resumed.version)
    print("LESSON6_OK")
    io.stdout:flush()
    os.exit(0)
end)
```

这里有两个会产生不同等待的 `skynet.fork`：主 Service 先 fork 一个协程调用 `hold`，主协程可以继续通过 `peek` 观察；之后又 fork 一个协程调用 `spend(20)`，它会等待 PlayerService 内部的 queue。两次 `skynet.call` 都等待自己的 RPC 结果，**并不是主 Service 的 `skynet.start` 在等待这两个函数完成**。

### Skynet 启动配置和运行脚本

**新建文件** `hotupgrade/lesson6/skynet_config.lua`：

```lua
local framework_root = "./third_party/skynet-flywow"
local runtime_root = framework_root .. "/build/hotupgrade-lesson6"

thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "lesson6_main"
lualoader = "./third_party/skynet/lualib/loader.lua"

luaservice = framework_root .. "/hotupgrade/service/?.lua;"
    .. framework_root .. "/hotupgrade/lesson6/?.lua;"
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

**新建文件** `hotupgrade/lesson6/run.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
SERVER_ROOT="$(cd -- "$FRAMEWORK_DIR/../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?请传入 Skynet 根目录}")"

RUNTIME_ROOT="$FRAMEWORK_DIR/build/hotupgrade-lesson6"
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/host" "$RUNTIME_ROOT/patches"
cp -a "$SCRIPT_DIR/host_v1/." "$RUNTIME_ROOT/host/"
cp -a "$SCRIPT_DIR/patches/." "$RUNTIME_ROOT/patches/"

export HOTUPGRADE_LESSON6_ROOT="$RUNTIME_ROOT"
cd "$SERVER_ROOT"
"$SKYNET_ROOT/skynet" "$SCRIPT_DIR/skynet_config.lua"
```

这份脚本假定本工程仍按第 4 课的宿主布局：`server/third_party/skynet-flywow`，Skynet 源码位于可传入的外部目录。先在 FlyWow 根目录构建 HotUpgrade Native，再运行：

```bash
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/lesson6/run.sh ../skynet
```

以上文件完整列出，便于你照着新建并复现实验。**本文已核对源码与调用合同，没有在当前环境中编译、运行这套新建的教学文件**；实际输出须以你本地执行为准。

## 三、第二阶段：A 为什么 yield 了，B 却仍不能执行？

现在按 `lesson6_main.lua` 的真实执行顺序开始读。

主 Service 的 `skynet.start` 回调先同步调用 Controller `init`，得到成功答复后，执行 `hot.newservice("player_service")`；Controller 负责受管理创建，原生启动成功后返回 PlayerService handle。主 Service 随即通过 `"lua"` 协议发送 `"init"`。PlayerService 的 `skynet.dispatch("lua", ...)` 接到这条消息，直接调用同文件的 `initialize()`，后者通过 `hot.register_service()` 保存 `before_upgrade` 回调并向 Controller 登记。

到这里，PlayerService 的模块 `logic` 和金币表 `state` 已经保存在其**自己的 Lua State** 内。Controller 只知道这个 Service 的真实 handle 和可更新模块名单，不持有玩家金币 table。

随后主 Service fork 一个协程，调用 `skynet.call(player, "lua", "hold")`。这一调用在**主 Service 的子协程**中等待 RPC；PlayerService 的 Lua dispatch 则启动自己的请求协程，进入本文件的 `hold()`：

```lua
local function hold()
    if hot.patching then
        return {ok = false, code = "HU_UPGRADING"}
    end

    return business_queue(function()
        holding = true
        hold_thread = coroutine.running()
        skynet.wait()

        hold_thread = nil
        holding = false
        state.gold = state.gold - 10
        return {ok = true, gold = state.gold, version = logic.version()}
    end)
end
```

**以上为本课教学文件 `host_v1/service/player_service.lua` 的完整 `hold()`，不是 FlyWow 框架函数。** 此时 `hot.patching=false`，因此通过入口检查。`business_queue` 初始没有持有者，这个请求立即成为 queue 的拥有者，把 `holding` 设为 `true`，记录当前协程到 `hold_thread`，然后调用 `skynet.wait()`。

`skynet.wait()` **只挂起当前协程**；并不会释放这个业务 queue。我们可以把队列视为“持有者仍是 A，A 暂停了执行”。这与 C++ 线程 mutex 的直觉很接近：线程阻塞并不意味着它自动 unlock；这里只不过持有者是 Lua 协程，而不是操作系统线程。

要确认这一点，必须进入 **Skynet 原生源码**：`lualib/skynet/queue.lua` 中的 `skynet.queue()`。下面是本课需要理解的完整实现（官方源码，保留逻辑）：

```lua
local skynet = require "skynet"
local coroutine = coroutine
local xpcall = xpcall
local traceback = debug.traceback
local table = table

function skynet.queue()
    local current_thread
    local ref = 0
    local thread_queue = {}

    local function xpcall_ret(ok, ...)
        ref = ref - 1
        if ref == 0 then
            current_thread = table.remove(thread_queue,1)
            if current_thread then
                skynet.wakeup(current_thread)
            end
        end
        assert(ok, (...))
        return ...
    end

    return function(f, ...)
        local thread = coroutine.running()
        if current_thread and current_thread ~= thread then
            table.insert(thread_queue, thread)
            skynet.wait()
            assert(ref == 0)
        end
        current_thread = thread

        ref = ref + 1
        return xpcall_ret(xpcall(f, traceback, ...))
    end
end

return skynet.queue
```

从 `hold` 的执行路径看，`business_queue(f)` 进入闭包后，A 对应 `current_thread=A`，`ref=1`，然后调用 `xpcall(f, ...)` 执行业务函数。业务函数内部 `skynet.wait()` 时，`xpcall` **尚未返回**，因此 `xpcall_ret` 还没有机会执行；`ref` 仍然是 1，`current_thread` 仍然是 A。

紧接着主 Service 发起 B：`skynet.call(player,"lua","spend",20)`。PlayerService 在**另一个请求协程**中调用 `spend()`。此时 `hot.patching=false`，B 通过入口检查，`waiting_spends=1`，随后调用同一张 `business_queue`。队列发现 `current_thread=A`，当前协程却是 B，于是把 B 加入 `thread_queue`，调用 `skynet.wait()`。**B 暂时不能扣金币，金币仍是 100。**

现在固定同一组观察量，第一次做状态快照：

| 观察项 | 此刻的值 | 含义 |
|---|---|---|
| `state.gold` | 100 | A 和 B 都尚未执行扣款 |
| `hot.patching` | `false` | 热更尚未进入 PlayerService 的 Prepare |
| `holding` | `true` | A 已进入 queue，且等待外部唤醒 |
| `waiting_spends` | 1 | B 已通过入口检查，正在等 queue |
| queue `current_thread` | A | queue 的拥有者是 A |
| queue `ref` | 1 | A 的 queue 包裹函数还没返回 |
| `logic.version()` | `"v1"` | 正式业务仍使用 V1 |

这一步是整课的地基：**“Service 能同时存在多个挂起的协程”与“同一时刻只有一个协程实际运行在该 State 内”并不冲突。业务 queue 要解决的是这些协程在 yield 之后可能交错访问同一份玩家状态。**

## 四、第三阶段：Controller 发起 Prepare，业务安全点怎样形成？

主 Service 已通过 `peek` 确认 B 在队列中，随后执行本课 `lesson6_main.lua` 里的：

```lua
local begun = skynet.call(controller, "hotupgrade", "begin", {path = "v2"})
```

这是一条从主 Service 到 Controller 的跨 Service RPC。Controller `flywow_hotupgrade_controller.lua` 的 `M:begin(request)` 创建批次，调用 `skynet.fork(function() self:run_batch(...) end)` 启动发布协程，然后把 `batch_id` 返回。**`begin` 返回不等于发布完成**。

Controller 的 `M:run_batch()` 首先等待已接纳的 Service 创建和首次模块加载收敛，然后在 `DEPLOYING` 冻结 Patch 和旧文件，识别出登记了 `player_logic.lua` 的 PlayerService。随后进入 `APPLYING / PREPARE`，调用同文件 `M:step(batch,target,"prepare")`，由它执行真实 RPC：

```lua
local ok, answer = pcall(skynet.call, target.service_handle,
    "hotupgrade", command, request)
```

这里 Controller 协程会 yield 等待 **PlayerService 的 `hotupgrade` 协议回复**。它不是直接执行玩家队列，也无法访问玩家私有的 `state.gold`。PlayerService 之前 `register_service()` 时，框架已通过 `skynet.dispatch("hotupgrade", ...)` 注册控制入口；因此消息进入 `flywow_hotupgrade.lua` 中的局部函数 `handle_upgrade(command, request, source)`。

现在看这个**真正控制业务停止接纳的关键实现**。以下代码为 `hotupgrade/lualib/flywow_hotupgrade.lua` → `handle_upgrade()` 中完整的 Prepare 分支，保持当前源码顺序：

```lua
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

先按顺序理解三件事。

**首先：设置 `M.patching=true`。** `M` 就是业务侧 `require "flywow_hotupgrade"` 得到的模块表；所以 `hot.patching` 立刻变为 `true`。这不是 Controller 修改另一张 table，而是 **PlayerService 收到 prepare 消息后，在自己的 Lua State 内修改自己的本地字段**。

**随后：调用 `before_upgrade()`。** 这是 `PlayerService.initialize()` 注册的业务回调，不是 Controller 提供的统一 Guard。它的完整实现仍在本课 `player_service.lua`：

```lua
before_upgrade = function()
    return business_queue(function()
        return true
    end)
end,
```

调用这个回调的仍是 **PlayerService 内处理 `hotupgrade` 协议的协程**。它试图进入 `business_queue`，但队列此刻还有 A 正在持有、B 正在等待，所以这个回调也被加入 `thread_queue`，排在 B 之后并 yield。此时 Controller 正等待 Prepare 的 RPC 回复；业务 A、B 却可以在各自唤醒后继续执行，不会因为 Controller 在等待而停止。

**最后：返回 `true` 的含义。** 当 `before_upgrade` 终于拿到 queue 并执行其空回调，表明先前已获业务入口许可并等待该 queue 的操作已完成；这时它才返回 `true`。`handle_upgrade()` 只有看到回调确认成功才向 Controller 返回 Prepare 成功。

**这是“安全点”的真正形成条件：先关新入口，再在同一业务 queue 后面插入一道排空栅栏。** 如果把顺序反过来，先排空后设置 `patching`，新请求可能趁空隙进入；如果把 `before_upgrade` 仅写成 `return true`，则 A 仍持有 queue，更新就可能在旧业务完成前发生。

在 A 尚未被释放时，第二次状态快照：

| 观察项 | 此刻的值 | 含义 |
|---|---|---|
| `state.gold` | 100 | A、B 还未真正扣金币 |
| `hot.patching` | `true` | C 这类新请求应在入口被拒绝 |
| `holding` | `true` | A 仍占有业务 queue |
| `waiting_spends` | 1 | B 仍在排队，不能被丢弃 |
| `background_running` | `true` | 非业务 queue 的 fork 任务依旧运行 |
| `before_upgrade()` | 等待 queue | 尚未向 Controller 确认安全点 |
| Controller `step(prepare)` | 等待 RPC | Controller 自己的发布协程已 yield |
| `logic.version()` | `"v1"` | Update 尚未开始 |

这里最容易误解的是：**`hot.patching=true` 不会自动取消 A，也不会撤销 B 已获得的业务入口许可**。它只供业务入口主动判断“接下来新到的业务是否还应该被接纳”。已有队列任务正是需要正常完成的那部分旧业务。

## 五、第四阶段：拒绝 C，释放 A，让 B 和安全点按顺序执行

主 Service 通过 `peek` 看到 `patching=true`，接着发送 C：

```lua
local rejected = skynet.call(player, "lua", "spend", 30)
```

PlayerService 收到 `"spend"` 后，调用本课 `spend(amount)`。第一行判断 `hot.patching`，立即返回 `{ok=false, code="HU_UPGRADING"}`；**不会递增 `waiting_spends`，也不会进入 `business_queue`，金币不会被扣掉 30**。

然后主 Service 发出 `"release"`；这个演示命令故意不经过 queue，而是 `skynet.wakeup(hold_thread)`。被唤醒的 A 从 `skynet.wait()` 后一行继续，扣 10 金币并返回。`business_queue` 的 `xpcall_ret()` 才会使 `ref` 归零，并按 FIFO 唤醒 B。

B 恢复执行，从 `business_queue` 的 `skynet.wait()` 后继续成为 queue 拥有者，扣 20 金币，完成后才轮到等待队列的 `before_upgrade` 协程。它执行 `return true`，释放 queue，`handle_upgrade(prepare)` 得到 `true`，再向 Controller 返回成功。

完整顺序如下。左侧是 **同一个 PlayerService 的不同协程**，右侧是 Controller 的发布协程：

```text
PlayerService                                     Controller
-------------                                     ----------
A 持有 queue，wait()                             step(prepare) → RPC 等待
B 排队于 A 后
prepare 控制协程：patching=true
before_upgrade 排队于 B 后
C 入口检查：patching=true → 拒绝
release → wakeup(A)
A 恢复：gold 100→90，退出 queue
B 获得 queue：gold 90→70，退出 queue
before_upgrade 获得 queue：return true
handle_upgrade(prepare) 回复成功  ──────────────→ RPC 恢复
                                                  进入 Update
```

为什么 `before_upgrade()` 没有直接检查队列“当前是否为空”？因为 Skynet queue 没有向业务暴露一套可靠的“所有权 + 等待者状态”接口。**排空栅栏本身就是一次进入 queue 的操作**：它排在既有请求之后，轮到它执行时就意味着之前进入这个 queue 的请求已经执行完毕。

此时可以有第三次状态快照：`state.gold=70`、`holding=false`、`waiting_spends=0`、`hot.patching=true`。**Prepare 已安全，业务入口仍关闭**；安全点不是一闪而过，而是一直保持到这次热更 Finish 或成功 Abort。

## 六、第五阶段：安全点之后发生什么，什么时候重新接纳业务？

Controller 收到 Prepare 成功后，继续执行 `flywow_hotupgrade_controller.lua` 的 `M:run_batch()`。它还要检查这段 Prepare 窗口中新发生的受管理 Service 创建、首次模块声明是否完成，并对新增目标补做 Prepare；这个门禁是**Controller 的跨 Service 生命周期门禁**，不同于 PlayerService 的业务 queue。全部收敛后，Controller 进入 Update。

PlayerService 的 `handle_upgrade("update", ...)` 在当前同一个 Lua State 中调用模块更新引擎：`stage()` 准备 V2，`commit()` 原地替换模块导出字段。随后 Controller 把发布包中的完整 `lualib/player_logic.lua` 部署到宿主目录，清理 Skynet Lua 加载缓存，最后向目标发送 `finish`。这些算法在第 4、5 课已经讲过，本课只跟踪入口开关：

```text
Prepare 开始       hot.patching = true
Prepare 排空完成   hot.patching = true
Update 完成       hot.patching = true
文件部署完成       hot.patching = true
Finish 成功       hot.patching = false
```

这五个节点都属于**PlayerService 自己的 `hot` 模块表字段**，不是 Controller `phase` 的别名。

最后一个节点在真实源码 `hotupgrade/lualib/flywow_hotupgrade.lua` → `handle_upgrade()` 的 Finish 分支：

```lua
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

到这里，主 Service 查询到批次 `COMPLETED`。`peek` 应返回 `gold=70`、`version="v2"`、`patching=false`。主 Service 再发送一笔 `spend(5)`，这次新请求可以通过入口检查、进入 queue、扣到 **65**，它调用的 `logic.version()` 已是 V2。

第四次状态快照：

| 观察项 | 结果 |
|---|---|
| A 的 RPC 回复 | `{ok=true, gold=90, version="v1"}` |
| B 的 RPC 回复 | `{ok=true, gold=70, version="v1"}` |
| C 的 RPC 回复 | `{ok=false, code="HU_UPGRADING"}` |
| 批次结果 | `COMPLETED` |
| 旧 PlayerService 的金币 | 70；没有重建或重置 |
| `logic.version()` | `"v2"` |
| `hot.patching` | `false` |
| Finish 后新 `spend(5)` | `{ok=true, gold=65, version="v2"}` |

这证实本课真正要学的不是“怎样替换一个函数”，而是**在不取消旧业务的前提下，把运行时推进到允许替换函数的时刻**。

## 七、第六阶段：为什么 `skynet.fork()` 不自动受 queue 保护？

前面我们还执行了本课 `player_service.lua` 里的 `fork_probe()`：

```lua
local function fork_probe()
    skynet.fork(function()
        background_running = true
        skynet.sleep(500)
        background_running = false
    end)
    return {ok = true}
end
```

这段代码的关键不在 500 tick，而在**fork 创建的是新协程**。它没有调用 `business_queue()`，因此不会出现在 `skynet.queue` 的 `thread_queue` 中。`before_upgrade()` 取得 queue 并返回 `true` 时，不能由此推断 `background_running` 已是 `false`。

我们的演示 fork 任务只修改自己的观察标记，没有修改金币，所以不会破坏此次更新安全性。实际业务如果在 fork 中还会异步修改 `state.gold`，就不能因为 `before_upgrade()` 进入 queue 成功而认为所有写入已停止。比如下面这种**反例**：

```lua
-- 反例示意：不是本课 player_service.lua 的一部分，不要复制进业务。
skynet.fork(function()
    skynet.sleep(20)
    state.gold = state.gold + 100
end)
```

这个写入既没有经过相同的 queue，也不在安全点等待范围内。更接近真实项目的例子是一次玩家购买：主协程进入 queue，fork 子协程去异步取得支付结果、随后直接修改玩家内存。即使主协程已经退出 queue，也不代表子协程已完成。**正确边界是“所有会修改这份业务状态的执行路径都必须纳入同一套业务串行约束”**；不能只保护几个收到的 Lua 命令，却遗漏定时器、fork 和异步回调。

这里不要误解成“不准 fork”。Skynet 的 fork 非常正常，后台只读工作、独立统计、非当前对象所有权内的工作可以不进入玩家业务 queue。只有涉及同一份玩家私有状态、且会与热更发生并发交错的路径，才需要由业务明确协调。**框架不替你追踪所有 fork 协程，也没有保留旧 Guard 的 owner/active 机制**。

## 八、同一个 Service 的协程、Controller 生命周期门禁、业务 queue：三种不同的等待

现在回顾这一次实验中的三个容易混淆的“等待”。

**第一种：Skynet `skynet.call()` / `skynet.wait()` 挂起某个协程。** 调用者让出执行权，所在 Service 仍可调度其他消息。我们例子中 Controller 的 `step(prepare)` 在等 PlayerService 回复，PlayerService 的 A 在等 `release`，B 在等 queue。它们可以同时处于等待状态。Skynet 不会因为某一个协程 yield 就自动把其访问的 Lua 私有表锁起来。

**第二种：业务 `skynet.queue()` 在一个 Service 内提供协程级串行。** A 进入 queue 后 yield，queue 所有权还在 A；B 和 `before_upgrade` 排队。只有 A 的 queue 包裹函数返回，B 才能继续，最后才轮到 `before_upgrade`。业务 queue 不会替你检测 `hot.patching`，所以**必须先在入口判断，再进入 queue**。

**第三种：Controller `wait_lifecycle()` 约束跨 Service 创建与新的模块首次声明。** 真实源码 `flywow_hotupgrade_controller.lua` 的 `lifecycle_closed()` 按 Controller 阶段判断是否暂时关闭：`DEPLOYING` 期间关闭，`APPLYING / PREPARE` 期间重新允许创建和首次加载，进入 `UPDATE` 后再次关闭；等待到发布终态才恢复。这里保护的是“新服务和新模块加入本次发布”的生命周期边界，**并不是玩家业务 queue**。

把它们放在一张图里：

```text
                  Controller Service                         PlayerService
           ┌─────────────────────────┐                ┌──────────────────────────┐
           │ wait_lifecycle          │                │ 玩家命令入口             │
           │ newservice / 首次加载   │                │ if hot.patching 拒绝新业务│
           └───────────┬─────────────┘                └────────────┬─────────────┘
                       │                                           │
               发布批次的准入门禁                          已接纳的业务
                       │                                           ▼
                       │                                 ┌───────────────────┐
                       └─ step(prepare) ─── RPC ───────→ │ skynet.queue      │
                                                         │ A → B → before... │
                                                         └───────────────────┘
```

**Controller 不负责也无法直接排空每个业务 queue；业务 Service 不负责冻结发布文件或决定本批目标集合。** 这就是当前设计有意保留的职责划分。

### 为什么 Prepare 期间 Controller 还允许创建和首次模块加载？

这是最近重构特别重要的地方。假设玩家的一笔**已进入业务 queue** 的请求尚未结束，期间需要调用 `hot.newservice("child")` 或在已登记 Service 中首次 `hot.require("extra")`，并同步等待结果。如果 Controller 在 Prepare 之前就把这些操作全部挡住，那么：

```text
父 Service 已接纳的业务请求
   → 在 queue 中等待新建子 Service / 首次模块加载
   → Controller 关门，操作不能完成
   → Controller 同时等待父 Service 的 before_upgrade 排空 queue
   → 双方互相等待
```

所以 Controller 现在允许 `PREPARE` 窗口中的生命周期操作完成，并把新登记目标补入同一份冻结发布包的 Prepare 匹配；只有确认在途创建和首次加载全部归零，且最终重匹配到的目标都已安全后，才在无 yield 的收口点进入 `UPDATE`。这解决的是**跨 Service 生命周期等待环**。它不能替代 PlayerService 对新业务入口设置 `hot.patching` 检查，也不意味着 Prepare 期间允许新的玩家写操作继续进入 queue。

## 九、业务侧真正需要遵守的合同

经过本课实验，可以把业务接入要求压缩为几个实质条件，而不需要重新发明 Guard。

**其一，业务入口先检查 `hot.patching`。** 检查放在排队前，而不是 queue 回调内。这样在 Prepare 之前已经进入队列的 B 可以排空，Prepare 之后新到的 C 不再插队。Controller 不是自动拦截所有 `lua` 消息，业务必须在自己的写入入口实现此判断。

**其二，同一份会被热更修改的业务状态，写入必须受到一致的串行管理。** 例子里 A 与 B 都走同一个 queue；如果另一个命令直接写 `state.gold`，即使当前 queue 排空成功，安全点也不成立。这也包括 fork、定时器、异步结果处理等会写同一份状态的代码路径。

**其三，`before_upgrade()` 应真正确认安全点。** 对于本课的单业务 queue，直接 `return business_queue(function() return true end)` 足够。它不取消正在执行的业务，也不需要实现队列内部 owner/ref 状态。如果业务使用多套完全独立的状态所有者，就应由该业务自己确认它所承诺的安全点；当前框架不会替业务做全局协程扫描。

**其四，控制事务仍要正确区分 Prepare 与 Update。** Prepare 回调允许 yield；Update、Abort、Finish 必须按当前框架的同步提交/恢复合同执行，业务的 `update_state`、`after_upgrade` 不应该再主动 yield。本课不深入恢复失败的每个分支，那是第 7 课的内容。

**其五，宿主先初始化 Controller。** 这是已经确认的最新接入合同。`hot.require` 可以在业务 Service 文件顶部调用，因为初次加载时 `root_path` 已由 Controller 发布；`register_service()` 仍在可 yield 的协程里完成，业务只有收到成功登记后才宣布 READY。业务是否使用外部 `init` 命令还是自主启动协程，不改变本课的安全点原理。

## 十、四个容易误判的场景，直接用本课代码回答

**场景 A：A 在 queue 内 `skynet.sleep(100)`，是不是 100 tick 内没人能处理 PlayerService 消息？** 不是。A 这条协程 yield 之后，PlayerService 仍可处理其他消息，所以主 Service 才能发送 `peek` 和 `release`；只是其他想取得同一个 `business_queue` 的业务协程必须等待 A 完成。**单 Service 同时只有一个协程实际运行，不等于同时只有一个存在的协程。**

**场景 B：Controller 发送 Prepare 后，能不能直接进入 Update？** 不能。Prepare 的 RPC 等待 `handle_upgrade()` 返回，而它又等待业务 `before_upgrade()`。`before_upgrade` 已排在 A、B 后面，只有它真的执行到，才能确认业务安全点。

**场景 C：B 已通过入口检查，但 B 进入 queue 之前刚好设置了 `patching=true`，B 会不会被重新拒绝？** 例子中不会。B 已完成入口判断，之后走到排队函数；同一协程在进入 `business_queue` 前没有 yield 的情况下，`patching` 无法在这两个普通 Lua 操作之间被另一条消息协程插入修改。进入 queue 后即使 yield，B 也是 Prepare 前接纳的旧业务，应该排空而不是强制取消。

**场景 D：Controller `begin` 已返回 `batch_id`，但 A 还没释放，调用 `status` 会不会显示完成？** 不会；发布在 Controller `skynet.fork` 的协程内继续进行，等 Prepare RPC 成功才可能推进到 Update。主 Service 可以持续查询状态，也可以继续发出只读演示命令。

## 十一、运行验收与排错位置

在 FlyWow 根目录把上述六个文件放好后，构建并执行 `hotupgrade/lesson6/run.sh`。成功时应观察到：

```text
PREPARE: 100 v1 true true 1 true
FINISH: 70 v2 false
AFTER_BUSINESS: 65 v2
LESSON6_OK
```

`PREPARE` 行中最后一个 `true` 是 fork 探针运行状态；它用于说明该协程没有加入 queue。只要探针在 Prepare 现场还在运行即可，它何时自然退出与热更结果无关。批次 `COMPLETED`、金币和版本这几项由完整教学代码中的断言检查。

若运行失败，按时间线定位即可，不必引入额外框架：

| 现象 | 优先检查的位置 |
|---|---|
| Service 顶部 `HU_NOT_INITIALIZED` | 主 Service 是否先收到 Controller `lua/init` 成功，再执行 `hot.newservice` |
| `register_service` 失败 | `player_service.lua` 的 `initialize()` 是否在合法协程内，Service 是否由受管理入口创建 |
| `PREPARE` 阶段始终不结束 | A 是否仍持有 queue；主 Service 是否真的发送 `release` |
| C 没有被拒绝 | `spend` 的 `if hot.patching` 是否在 `business_queue()` 之前 |
| B 观察到 V2 而非 V1 | 是否误把 B 的请求放在 Prepare 之后，或替换了本课约定的执行顺序 |
| 最终 version 没变 V2 | `patches/v2/lualib/player_logic.lua` 是否在正确位置；当前模块是否经 `hot.require` 登记 |
| `FAILED_LOCKED` / 恢复失败 | 留给第 7 课沿真实错误和目标阶段分析，不要在本课添加任意等待来“解决” |

前四课学习成果应使你能解释 Controller、业务 Service 和内存对象分别由谁持有；第 5 课应使你能解释 V2 模块字段如何原地安装；**本课则补上关键条件：为什么安装 V2 之前，旧版本中那些已经开始执行、又可能 yield 的业务必须先走完。**

## 十二、你应该能够独立回答的六个问题

1. 为什么 `skynet.wait()` 让 A 挂起后，A 仍持有业务 queue？从原生 `queue.lua` 的 `ref/current_thread/xpcall_ret` 逐行解释。
2. 为什么 B 在 Prepare 前排队，会被允许执行；C 在 Prepare 后才到达，却必须被拒绝？入口检查和 queue 栅栏的先后次序是什么？
3. Controller 调用 `step(prepare)` 时，是哪个 Service 的协程在等待？`before_upgrade()` 又运行在哪个 Lua State？
4. 为什么 `before_upgrade()` 拿到 queue 并返回 `true`，比只检查 `hot.patching` 更有证明力？
5. 为什么 fork 一个会改玩家状态的协程，不能由这个 queue 安全点自动覆盖？怎样保持单一状态所有权而不增加 Guard？
6. Controller 的 `wait_lifecycle()` 与业务 `skynet.queue()` 分别挡的是什么？为什么 Prepare 期间还需要允许子 Service 创建和模块首次加载？

能沿**同一份 PlayerService 的 A → B → Prepare → C → release → Finish** 重述这六个问题，才是真正掌握了当前 FlyWow 的“安全热更”机制，而不是记住 `hot.patching` 这个布尔值。

**下一课：第 7 课《失败处理、恢复与回滚边界》**。届时仍使用真实事务，但深入 Prepare / Update / 文件部署失败、RPC 不确定结果、多 Service 恢复与 `FAILED_LOCKED` 等分支，不在本课提前扩张这些逻辑。
