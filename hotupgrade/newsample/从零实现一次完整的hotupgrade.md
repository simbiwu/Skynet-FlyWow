# HotUpgrade 独立源码实战特别课程

> **从零构建一个 MMO PlayerService，沿真实 Skynet 调用链学透热更、模块引擎、业务安全点、失败恢复与前向修复**
>
> 课程性质：一门独立的终结性实战课程；**学习者亲手编写 Sample**，不是阅读成品 Demo。  
> 源码基线：[`simbiwu/Skynet-FlyWow`](https://github.com/simbiwu/Skynet-FlyWow) 的 `main`，已提交基线 `b4cccb8e69cdedac40f536a1df3f159cc1c850e3`，并包含本次工作区尚未提交的 HotUpgrade 简化修改（2026-10-27）。内部摘录以本次同步时的实际源码为准。  
> 核对范围：`AGENTS.md`、工程编码 Skill、HotUpgrade README、Controller、Service 入口、Module Patch Engine、Native 接口、现有真实 Sample 与测试。  
> 验证标记：**已核对源码；本教学新 Sample 未在此环境实际执行 Skynet 测试**。文中输出属于依据源码推导的验收预期，必须由你亲手运行确认。  
> 编写日期：2026-10-27。

---

## 导学：学完这门课，应该会什么

想象一台运行中的 MMO 游戏服务器：玩家已经登录，`PlayerService` 正持有玩家等级、金币和装备。现在要修复技能伤害公式、增加一份战斗规则表，同时升级玩家的状态结构。我们不能把所有在线玩家踢掉重启，也不能仅仅把 Lua 文件复制上去就宣称更新完成。

这门课要解决的，就是**怎样在原 Service handle、现存状态根表和原模块导出根表保持身份不变的前提下，安全更新业务行为；失败时怎样认识真实现场，再通过新的正常发布继续修复**。

课程从一个空的教学目录开始。你亲手敲出 V1、运行它、制造并发、发布 V2、观察对象引用，再有意制造恢复失败，最终发布 V3。每走到一个框架函数，先交代调用者、文件、执行 Service/Lua State、参数和触发原因，再按真正的运行顺序阅读源码；遇到大函数，分段进入，最后回到原来的调用链。


### 当前源码的返回合同（以此节覆盖旧摘录中的返回形式）

当前 HotUpgrade 内部可失败操作使用 FlyWowResult<T>：成功载荷读取 value，失败读取稳定 code、message 和可选 details。公开适配入口 hotupgrade.require、newservice、uniqueservice 保留原生返回值和抛错行为；首次受控加载、许可等待或 Service 创建可能 yield，调用方按原生习惯使用 pcall。

状态合同：snapshot_state 返回 FlyWowResult<any>，restore_state 返回 FlyWowResult<nil>；模块 import_state 和 Service 自定义 restore 返回 FlyWowResult<nil>，自定义 snapshot 返回 FlyWowResult<any>。export_state 返回自然状态值。before_upgrade 与 after_upgrade 固定返回 boolean，只有 true 表示通过，false 表示业务拒绝。回调抛错由明确的候选代码或业务回调边界捕获，再转换为所属操作的结果；不要把 pcall 的布尔值泄漏为内部错误合同。

下面部分早期源码摘录保留其教学背景；若摘录展示 {ok=true}、裸快照或裸 import_state 返回值，应以本节及当前 docs/hotupgrade/README.md 所列合同为准，实际运行以当前源码为准。

### 结果表读取方式

FlyWow 内部可失败的操作统一使用公共 FlyWowResult<T>。先检查 ok，再读取成功载荷 value；失败时读取稳定 code、诊断 message，需要模块专属结构化诊断时读取 details。HotUpgrade 的 require、newservice、uniqueservice 是面向 Lua/Skynet 的适配入口，仍直接返回模块表或 Service handle，失败时抛出异常。

### 六个学习阶段

| 阶段   | 自己完成的事情                                 | 关键源码                              | 验收点                           |
| ------ | ---------------------------------------------- | ------------------------------------- | -------------------------------- |
| ① V1   | 创建 PlayerService、状态、业务 queue、启动脚本 | Service 初始化与 `hotupgrade.require` | V1 可运行，数据可观察            |
| ② V2   | 编写完整 Lua 文件、新模块和 `.patch`，发起批次 | Controller `begin/run_batch/step`     | V1→V2，旧实例不换 handle         |
| ③ 引擎 | 用本案例深挖 Stage、Commit、Abort、Finish      | `flywow_hotupgrade_module_patch.lua`  | 能画出 live/candidate/old 引用图 |
| ④ 并发 | 构造业务 A/B/C 及 Prepare 安全点               | `skynet.queue`、Controller 门禁       | B 完成后才更新，C 被拒绝         |
| ⑤ 故障 | 制造 Update 错误和恢复失败，实施 V3 修复       | Controller 恢复、Service Abort        | `RECOVERY_REQUIRED` 后下一批成功 |
| ⑥ 维护 | 定位错误码、独立做新场景推演                   | 真实测试与 Native 文件接口            | 独立诊断和维护                   |

### 阅读约定：三种代码身份，绝不混淆

- **【你要编写：完整文件】**：课程新设计的教学代码。你需要亲手在指定路径创建；它原本不在仓库中。
- **【真实源码摘录】**：从上述工作区源码基线摘出的连续逻辑，均明确给出路径、函数、调用场景；为了聚焦只展示所讨论的逻辑块时，不声称这是整个函数。
- **【原理示意】**：时间线、对象图及状态表，不是框架代码，不能复制运行。

**我们不会修改 HotUpgrade 框架。** 如果课堂代码运行结果与当前检出的源码不一致，先查版本、真实日志和文件路径，不通过修改框架来强行迎合教程。

---

# 第一部分：从零启动 MMO PlayerService V1

## 第 1 章：先明确我们到底要热更什么

假设玩家角色刚进入游戏，服务端记录：

```text
等级 level = 50
金币 gold = 100
装备 weapon = "刀"
状态版本 schema_version = 1
玩家攻击：输入基础攻击 100；装备是“刀”则 +5，所以攻击=105
```

实现这些行为至少涉及两类对象：

1. **普通 Lua 业务模块** `player_logic.lua`：定义攻击计算规则，是 `require` 得到的模块表。热更时要保留调用方持有的模块表身份。
2. **PlayerService 自己的私有状态与业务函数**：`state.gold`、`state.weapon`、`operations.attack` 属于某个 Service 的 Lua State。它们不能靠修改磁盘 Lua 文件自动改变。

这两类更新对应 FlyWow 的两条机制：普通模块由 **Module Patch Engine** 原地更新导出字段；Service 私有状态和业务函数由一次性 **Service Patch** 负责。

在传统 C++ MMO 中，可以把 `PlayerService` 理解为持有某个玩家运行状态的业务执行单元，把 `state` 理解为它维护的角色对象数据；但这里一个 Skynet Service 拥有独立 Lua State、通过消息调用，不是一个共享内存 C++ `Player*`。不同 Service 之间传递的是消息和可序列化值，不是玩家状态 table 指针。

### 第 1.1 节：本课程的目录约定

在 FlyWow 仓库根目录下创建教学目录：

```bash
mkdir -p hotupgrade/newsample/master_course/host_v1/lualib
mkdir -p hotupgrade/newsample/master_course/host_v1/service
```

最终目录会逐步生长为：

```text
hotupgrade/newsample/master_course/
├── main.lua                          # 教学管理端：由你写；运行多个场景
├── skynet_config.lua                 # 真实 Skynet 配置
├── run.sh                            # 生成独立运行目录并启动 Skynet
├── host_v1/
│   ├── lualib/player_logic.lua       # 最初的 V1 完整模块
│   └── service/player_service.lua    # V1 Service 入口
└── patches/
    ├── v2/                           # 正常热更
    │   ├── lualib/player_logic.lua
    │   ├── lualib/combat_rules.lua
    │   ├── service/player_service.lua
    │   └── service/player_service.patch
    ├── faulty/                       # 故意触发状态更新失败
    │   └── service/player_service.patch
    └── v3/                           # 对实际受损状态作前向修复
        ├── lualib/player_logic.lua
        ├── service/player_service.lua
        └── service/player_service.patch
```

这里有三层不同目录，务必从开始就分清：

- `host_v1/`：**教学初始版本**。每次运行时被复制到临时 `host/`，不会直接变成热更后的文件。
- `patches/`：**等待发布的完整源码包**。Controller 从这里按批次冻结源码，不把 `.patch` 当成未来 Service 入口文件。
- `build/hotupgrade-master-course/host/`：**运行期间的正式宿主目录**。热更真正修改的是这里的文件；我们用它观察部署与恢复结果。

## 第 2 章：亲手编写 V1 普通模块

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/host_v1/lualib/player_logic.lua`。由 PlayerService 在 `init` 时调用 `hotupgrade.require("player_logic")`，最终加载并在本 Lua State 保存这张表。

```lua
-- player_logic.lua：V1 完整业务模块。
local M = {} -- 候选模块的导出根表，return 后用于本次候选提交。

function M.version()
    return "v1"
end

function M.make_attack(state)
    return function(base_attack)
        return base_attack + (state.weapon == "刀" and 5 or 0)
    end
end

return M
```

先别急着想热更。这里的 `M` 是普通 Lua table；`M.make_attack(state)` 返回一个闭包，闭包持有 `state` 引用。假设你保存：

```lua
local old_attack = player_logic.make_attack(state) -- 预先缓存的 V1 闭包；替换模块字段不会自动更新这个局部引用。
```

未来 `player_logic.make_attack` 字段被替换，也不会自动把 `old_attack` 变量改成新函数。这是后面最重要的实验观察之一。

## 第 3 章：亲手编写 V1 PlayerService

**执行上下文**：`player_service.lua` 由 Skynet 的 `snlua` 启动，在自己的 Lua State 中运行。业务管理端通过 `skynet.call(handle, "lua", "init")` 触发初始化；初始化期间使用 `hotupgrade.require` 声明模块并通过 `register_service` 注册本 Service。之后 `inspect/spend/hold` 等消息由同一 `skynet.dispatch("lua", ...)` 接收。

这里先给你完整可运行文件。代码中的 `hold`、`spend` 是后面 Queue 实验的真实业务入口；暂时只需知道它们共享同一条业务 queue，等运行到并发章节再深入解释等待过程。

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/host_v1/service/player_service.lua`：

```lua
-- V1 PlayerService：业务状态留在本 Service，所有受控业务共用一条 queue。
local skynet = require "skynet" -- 当前 Service 使用的 Skynet API。
local business_queue = require "skynet.queue"() -- 业务串行队列；业务处理和热更安全点都经过它。
local hotupgrade = require "flywow_hotupgrade" -- 当前 Service 的受控模块加载、登记和生命周期 API。

local logic                 -- 首次 init 后的普通模块根表；热更保持表身份。
local state                 -- 玩家私有数据根表；由 Service Patch 原地修改。
local operations            -- 现有业务函数表；Patch 只替换指定函数。
local state_identity        -- 保存最初状态根表，用于观察身份是否稳定。
local old_attack            -- 缓存 V1 闭包，用于观察旧函数引用。
local registered = false    -- register_service 真正成功后才允许业务请求。
local holding_thread        -- hold 占用 queue 时正在 wait 的业务协程。
local waiting_spends = 0    -- 已通过入口但尚未拿到 queue 的 spend 请求数量。
local fail_restore = false  -- 只用于故障实验，正常运行恒为 false。

--- 返回 PlayerService 当前版本、私有状态和函数引用的观测快照。
local function inspect_state()
    return
    {
        ok = true,
        handle = skynet.self(),
        version = logic.version(),
        weapon = state.weapon,
        level = state.level,
        gold = state.gold,
        schema_version = state.schema_version,
        attack = operations.attack(100),
        old_attack = old_attack(100),
        state_same = state == state_identity,
        module_alias_same = package.loaded["lualib.player_logic"] == logic,
        combat_loaded = package.loaded["lualib.combat_rules"] ~= nil,
        patching = hotupgrade.patching,
    }
end

--- 声明业务模块和私有状态，最后登记当前 PlayerService。
local function initialize_player()
    if registered then
        return {ok = false, code = "ALREADY_INITIALIZED"}
    end

    logic = hotupgrade.require("player_logic")
    state =
    {
        weapon = "刀",
        level = 50,
        gold = 100,
        schema_version = 1,
    }
    operations = {attack = logic.make_attack(state)}
    state_identity = state
    old_attack = operations.attack

    local answer = hotupgrade.register_service( -- 管理命令的调用结果。
    {
        service_update =
        {
            state = state,
            functions = operations,
            -- 课堂故障需要显式控制恢复失败，所以这里使用成对自定义快照。
            snapshot = function(source)
                return require("flywow_result").success(
                {
                    weapon = source.weapon,
                    level = source.level,
                    gold = source.gold,
                    schema_version = source.schema_version,
                })
            end,
            restore = function(destination, snapshot)
                if fail_restore then
                    error("injected restore failure")
                end
                for key in pairs(destination) do
                    destination[key] = nil
                end
                for key, value in pairs(snapshot) do
                    destination[key] = value
                end
                return require("flywow_result").success()
            end,
        },
        before_upgrade = function()
            -- 必须排在所有已接纳业务之后取得同一条 queue。
            return business_queue(function() return true end)
        end,
        after_upgrade = function()
            -- 同步状态检查；故障实验把 schema 改成 99，以触发 Update 失败。
            return state.schema_version ~= 99
        end,
    })
    registered = answer.ok
    return answer
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer -- 管理命令的调用结果。

        if command == "init" then
            answer = initialize_player()
        elseif not registered then
            answer = {ok = false, code = "NOT_INITIALIZED"}
        elseif command == "inspect" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(inspect_state)
            end
        elseif command == "peek" then
            -- 教学观测口：只读、不进入业务 queue，避免观察者自身被 queue 挡住。
            answer =
            {
                ok = true,
                holding = holding_thread ~= nil,
                waiting_spends = waiting_spends,
                patching = hotupgrade.patching,
                gold = state.gold,
                schema_version = state.schema_version,
            }
        elseif command == "hold" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function()
                    holding_thread = coroutine.running()
                    skynet.wait(holding_thread)
                    holding_thread = nil
                    state.gold = state.gold - 10
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "release" then
            -- 教学控制消息必须独立于业务 queue，否则无法唤醒被占用的 queue。
            if holding_thread then
                local thread = holding_thread -- 从 holding_thread 取出的协程句柄，交给 skynet.wakeup 唤醒。
                holding_thread = nil
                skynet.wakeup(thread)
                answer = {ok = true}
            else
                answer = {ok = false, code = "NOT_HOLDING"}
            end
        elseif command == "spend" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                assert(type(request.amount) == "number" and request.amount > 0)
                waiting_spends = waiting_spends + 1
                answer = business_queue(function()
                    waiting_spends = waiting_spends - 1
                    state.gold = state.gold - request.amount
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "inject_restore_failure" then
            -- 课堂故障开关；不作为框架或实际业务管理 API。
            fail_restore = request.enabled == true
            answer = {ok = true}
        else
            answer = {ok = false, code = "UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
```

### 第 3.1 节：理解初始化，先不展开热更底层

从 `initialize_player()` 的执行位置看：

1. `hotupgrade.require("player_logic")`：在本 Lua State 搜索完整 Lua 文件，加载模块并记录原始加载名与实际文件身份。
2. `state`：该 Service 的普通数据根表；调用方只通过消息观察，不拿到此 table 指针。
3. `operations`：真正供业务调用的函数表；`operations.attack` 起初就是 V1 闭包。
4. `register_service({...})`：把**模块名清单**与是否有 Service Patch 入口等元数据送给 Controller；`state`、`operations`、快照及回调仍保存在本 Lua State。
5. `before_upgrade()`：HotUpgrade 在 Prepare 时调用。它不是简单“返回 true”；必须等业务 queue 前面所有已进入的任务执行完。
6. `after_upgrade()`：HotUpgrade 在 Update 的提交之后同步调用；返回 false 会使本批 Update 失败。这个实验用它注入确定的故障。

`restore` 故意加入了课堂开关，是为了演示“回滚失败，后续继续修复”的真实代码路径。它不意味着生产项目应该提供这种开关；在正常业务中，没有特殊对象时可以使用框架的默认普通数据图快照和恢复。

注意 `inspect` 与 `peek` 的区别：`inspect` 是受保护的正常业务读取；`peek` 是教学期的只读观测口，不能作为生产业务绕过 `hot.patching` 的范例。

## 第 4 章：让 V1 真正在 Skynet 中运行

我们现在只有业务模块和 Service 入口，还没有管理端、Skynet 配置和运行脚本。接下来按“先理解谁启动谁”的顺序补齐。

### 第 4.1 节：编写 Skynet 配置

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/skynet_config.lua`：

```lua
-- 配置只引用运行脚本导出的绝对路径，不依赖某个固定的 Server 目录布局。
-- Skynet 配置加载器先展开字符串中的 $变量名；配置运行环境没有 os，因此这里不能调用 os.getenv。
local skynet_root = "$FLYWOW_MASTER_SKYNET_ROOT" -- Skynet 安装目录，配置文件据此定位 loader 与原生服务。
local framework_root = "$FLYWOW_MASTER_FRAMEWORK_ROOT" -- 命令行环境提供的 FlyWow 根目录。
local course_root = "$FLYWOW_MASTER_COURSE_ROOT" -- 本课程源码目录的绝对路径。
local runtime_root = "$FLYWOW_MASTER_RUNTIME_ROOT" -- 当前启动环境中由 run.sh 传入的宿主运行目录。

thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
start = "main"
lualoader = skynet_root .. "/lualib/loader.lua"

luaservice = framework_root .. "/hotupgrade/service/?.lua;"
    .. course_root .. "/?.lua;"
    .. runtime_root .. "/host/service/?.lua;"
    .. skynet_root .. "/service/?.lua"

lua_path = runtime_root .. "/host/?.lua;"
    .. runtime_root .. "/host/lualib/?.lua;"
    .. runtime_root .. "/host/lualib/?/init.lua;"
    .. skynet_root .. "/lualib/?.lua;"
    .. skynet_root .. "/lualib/?/init.lua;"
    .. framework_root .. "/common/lualib/?.lua;"
    .. framework_root .. "/hotupgrade/lualib/?.lua"

lua_cpath = skynet_root .. "/luaclib/?.so;"
    .. framework_root .. "/build/native/?.so"

cpath = skynet_root .. "/cservice/?.so"
```

**为什么配置里不能直接写 `os.getenv`？** Skynet 启动器在受限环境中执行配置文件；`skynet_main.c` 会先把配置源码里的 `$变量名` 替换成进程环境变量，再执行 Lua 配置。这个环境提供 `include`，不提供 `os`，所以配置用字符串 `"$FLYWOW_MASTER_SKYNET_ROOT"` 取值。稍后由 Skynet 启动的 `main.lua` 运行在 Service Lua State 中，那里可以像普通 Lua 代码一样调用 `os.getenv`。

**当前调用背景**：Skynet 进程首先读取这个配置，`bootstrap` 负责启动启动流程，`start="main"` 让 Skynet 从 `luaservice` 路径中找到我们的 `main.lua`。`lua_path` 是业务 `require` 搜索路径，`lua_cpath` 用于找到 Native 模块 `flywow_hotupgrade_native.so`。这些都是启动阶段的文件定位，不是热更发布包内部路径。

### 第 4.2 节：编写最小 V1 管理端

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/main.lua`。这是第一版；第二部分你将**完整替换**为带正常发布与故障实验的管理端。

```lua
-- V1 入口：只初始化控制面、创建业务 Service，暂不发布 Patch。
local skynet = require "skynet" -- 当前 Service 使用的 Skynet API。

skynet.start(function()
    local ok, failure = xpcall(function() -- xpcall 的执行成功标志，用于最终决定进程退出码。
        local hot = require "flywow_hotupgrade" -- 管理端持有的 HotUpgrade API。
        local controller = skynet.uniqueservice("flywow_hotupgrade_service") -- 当前管理端要发送命令的控制 Service handle。
        local runtime_root = assert(os.getenv("FLYWOW_MASTER_RUNTIME_ROOT")) -- 当前启动环境中由 run.sh 传入的宿主运行目录。
        local initialized = skynet.call(controller, "lua", "init", -- Controller init 的结果；成功后才允许创建业务目标。
        {
            root_path = runtime_root .. "/host",
            patch_path = runtime_root .. "/patches",
            service_path = "service",
        })
        assert(initialized.ok, initialized.message)

        local player = hot.newservice("player_service") -- 本轮受管理创建的 PlayerService handle。
        local started = skynet.call(player, "lua", "init") -- PlayerService init/register_service 的结果。
        assert(started.ok, started.message)
        local snapshot = skynet.call(player, "lua", "inspect") -- Service 返回的观测快照，用于断言热更前后版本、状态和身份。
        assert(snapshot.ok, snapshot.code)
        assert(snapshot.version == "v1" and snapshot.attack == 105)
        assert(snapshot.gold == 100 and snapshot.state_same and snapshot.module_alias_same)
        print(string.format("V1 handle=%d version=%s gold=%d attack=%d",
            player, snapshot.version, snapshot.gold, snapshot.attack))
        print("MASTER_V1_OK")
    end, debug.traceback)

    if not ok then
        skynet.error("MASTER_FAILED: " .. tostring(failure))
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)
```

执行链先看清楚：`main.lua/skynet.start` → `skynet.uniqueservice("flywow_hotupgrade_service")` 得到 Controller Service handle → `lua/init` 初始化 Controller → `hot.newservice("player_service")` 通过受管理入口创建目标 → `lua/init` 让目标加载模块并登记自身 → `lua/inspect` 返回玩家信息。

### Controller 初始化：先构造候选，再一次性发布模块状态

`main.lua` 调用 Controller 的 `lua/init` 后，Service 入口进入 `M.initialize()`。该函数先验证配置并解析目录；只有全部成功，才构造下面这张短期的 `controller_initial_state` 表。它只是等待提交的字段集合，`M` 上的长期状态此时仍为 `nil`。

**【真实源码摘录】** `hotupgrade/lualib/flywow_hotupgrade_controller.lua` → `M.initialize()`：

```lua
    local controller_initial_state = -- 所有配置已校验后的候选状态字段；全部准备好后一次性赋给 Controller。
    {
        root_path                     = root_path,                                      -- 已解析的宿主根目录；Controller 的正式文件读取、部署和恢复共用此根。
        patch_root                    = patch_root,                                     -- 已解析的受信 Patch 根目录；每批从此处读取并冻结发布源码。
        service_path                  = controller_config.service_path,                 -- 宿主根目录下的相对 Service 目录；据此区分 Service 文件与普通模块。
        service_registrations         = {},                                             -- 按真实 Service handle 保存登记信息；用于加载许可、Patch 匹配和控制 RPC。
        pending_creations             = {},                                             -- 保存已受理但尚未登记或取消的创建记录；完成后从集合移除。
        service_creations             = {},                                             -- 按 Service handle 索引创建记录；用于匹配早到的 register。
        early_exit_handles            = {},                                             -- 记录原生创建返回前收到的退出 handle；对应创建结果收敛后清除。
        service_registration_waiters  = {},                                             -- 保存等待 register 来源与原生 handle 匹配的协程；映射变化时唤醒重查。
        module_load_permits           = {},                                             -- 按许可 ID 保存 Service handle 与模块名；登记、取消或 Service 退出时消费。
        module_permit_sequence        = 0,                                              -- 本 Controller 内递增的许可序号；生成不复用的首次加载许可 ID。
        batch_sequence                = 0,                                              -- 本 Controller 内递增的批次序号；生成批次身份并拒绝迟到控制消息。
        lifecycle_gate_waiters        = {},                                             -- 保存因 Update 门禁暂停的创建/首次加载协程；批次终态后统一唤醒。
        unique_service_entries        = {},                                             -- 按逻辑 Service 名保存唯一创建记录、等待者及已创建 handle。
        active_batch                  = nil,                                            -- 当前唯一活动批次；终态后原记录移入 last_batch。
        last_batch                    = nil,                                            -- 最近结束批次及其报告；下一批结束后替换，不保留更早历史。
    }

    for name, value in pairs(controller_initial_state) do
        M[name] = value
    end
    M.initialized = true
```

这里不是把 controller_initial_state 交给另一个协程：初始化循环把字段和值写入模块表 M，之后各 Controller 方法通过 self 中的同名字段访问它们。service_creations 是 Service handle 到创建记录的索引，用于匹配早到的 register；pending_creations 保存尚未完成的创建记录；module_load_permits 保存尚未完成的首次加载许可。后两张表是批次等待直接检查的事实来源，不再另存同步计数。status 对外仍返回 pending_service_count 和 pending_module_count，但每次查询时分别统计这两张表。batch_sequence 是 Controller 内部序号，具体批次记录再保存本批的 sequence，控制 RPC 继续沿用 sequence 字段。

为什么不能直接 `skynet.newservice("player_service")`？因为 HotUpgrade 需要在受管理创建时建立 Service 身份记录、创建屏障和后续登记关系。否则 Controller 没有充分依据把这个 Service 纳入目标集合。

### 第 4.3 节：编写独立运行脚本

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/run.sh`：

```bash
#!/usr/bin/env bash
# 运行本课程的一个独立实验；每次从 host_v1 重建运行目录。
set -euo pipefail

COURSE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FRAMEWORK_DIR="$(cd -- "$COURSE_DIR/../../.." && pwd)"
SKYNET_ROOT="$(realpath -- "${1:?用法: run.sh SKYNET_ROOT [v1|normal|queue|forward]}")"
SCENARIO="${2:-v1}"
RUNTIME_ROOT="$FRAMEWORK_DIR/build/hotupgrade-master-course"
LOG_FILE="$RUNTIME_ROOT/course.log"

case "$SCENARIO" in
    v1|normal|queue|forward) ;;
    *) echo "未知实验: $SCENARIO" >&2; exit 2 ;;
esac

[[ -x "$SKYNET_ROOT/skynet" ]] || { echo "找不到 Skynet 可执行文件" >&2; exit 1; }

if [[ ! -s "$FRAMEWORK_DIR/build/native/flywow_hotupgrade_native.so" ]]; then
    bash "$FRAMEWORK_DIR/scripts/build_flywow.sh" "$SKYNET_ROOT" hotupgrade
fi

# 只清理专用 build 目录；不会删除课程源码或其它工程文件。
rm -rf -- "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/host" "$RUNTIME_ROOT/patches"
cp -a "$COURSE_DIR/host_v1/." "$RUNTIME_ROOT/host/"
if [[ -d "$COURSE_DIR/patches" ]]; then
    cp -a "$COURSE_DIR/patches/." "$RUNTIME_ROOT/patches/"
fi

export FLYWOW_MASTER_SKYNET_ROOT="$SKYNET_ROOT"
export FLYWOW_MASTER_FRAMEWORK_ROOT="$FRAMEWORK_DIR"
export FLYWOW_MASTER_COURSE_ROOT="$COURSE_DIR"
export FLYWOW_MASTER_RUNTIME_ROOT="$RUNTIME_ROOT"
export FLYWOW_MASTER_SCENARIO="$SCENARIO"

# 绝对搜索路径由 skynet_config.lua 提供；工作目录无需特定 Server 布局。
cd "$SKYNET_ROOT"
set +e
timeout --signal=TERM 90s "$SKYNET_ROOT/skynet" "$COURSE_DIR/skynet_config.lua" 2>&1 | tee "$LOG_FILE"
result=${PIPESTATUS[0]}
set -e

expected="MASTER_${SCENARIO^^}_OK"
if [[ "$result" -ne 0 ]] || ! grep -qx "$expected" "$LOG_FILE"; then
    echo "实验失败：$SCENARIO，检查 $LOG_FILE" >&2
    exit 1
fi
```

**运行前提**：Linux / Bash、`realpath`、`timeout`、`tee`，并且已取得**与当前 FlyWow 配套的 Skynet 源码、Lua 5.4 运行环境和可执行文件**。`SKYNET_ROOT` 参数必须指向有 `skynet` 可执行文件、`lualib/`、`service/` 等目录的 Skynet 根目录。FlyWow 的 Native 构建需要 CMake、C++ 编译器和对应 Lua 头文件。

从 **FlyWow 仓库根目录**执行：

```bash
# 若尚未构建 Skynet，先在自己的 Skynet 目录按其构建说明构建。
# 以下 ../skynet 只是示例参数，按实际目录替换。
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/newsample/master_course/run.sh ../skynet v1
```

如果成功，应看到类似（handle 每次运行可能不同）：

```text
V1 handle=... version=v1 gold=100 attack=105
MASTER_V1_OK
```

**第一个验收点**：`gold=100`、`attack=105`、`module_alias_same=true`、`state_same=true`。若启动失败，按顺序检查：`skynet` 与 Lua 版本、`flywow_hotupgrade_native.so`、配置搜索路径、`lua/init` 是否成功、`register_service()` 返回的错误码。不要跳过 V1 验收直接做 V2。

### 第 4.4 节：把 V1 执行链复述一遍

此刻你应该能准确区分三个调用：

| 调用                                          | 调用者      | 接收方                                     | 是否跨 Service / 可能 yield | 作用                                             |
| --------------------------------------------- | ----------- | ------------------------------------------ | --------------------------- | ------------------------------------------------ |
| `skynet.call(controller,"lua","init",config)` | 教学 `main` | HotUpgrade Service                         | 是                          | 初始化发布根路径、Controller 等                  |
| `hot.newservice("player_service")`            | 教学 `main` | Controller，再由 Skynet 创建 PlayerService | 是                          | 建立受管理创建记录，取得真实 handle              |
| `skynet.call(player,"lua","init")`            | 教学 `main` | PlayerService                              | 是                          | `hotupgrade.require`、建状态和业务函数、登记目标 |

调用是从**管理端**进入**Controller**，再进入**PlayerService**；结果返回管理端。这是第一条完整的、已经可运行的 Skynet 调用链。

---

# 第二部分：亲手发布 V2，再沿完整批次记录进入 Controller

## 第 5 章：为什么复制一个 `player_logic.lua` 还不够

现在 V1 正在运行：内存里已有一张 `logic` 表、一份玩家 `state`，`operations.attack` 缓存了 V1 闭包。我们的新需求是：

- 玩家装备从“刀”升级为“剑”，`schema_version` 从 1 升为 2，**金币和等级保持不变**。
- 攻击改为读取新增模块 `combat_rules.lua` 的规则：剑加 20，基础攻击 100 时得到 120。
- 已经运行的 PlayerService 不重建；新创建的 PlayerService 要直接初始化为 V2。

仅替换现存 `player_logic.lua` 的文件，不会主动修改现有 Lua State 的 `logic` 表，也不会让 `state.weapon` 从“刀”自动变为“剑”。因此我们的 V2 发布包必须同时包含：

1. **完整的新版普通 Lua 模块** `lualib/player_logic.lua`，供 Module Patch Engine 更新现存模块，并供未来 Service 加载。
2. **新增完整模块** `lualib/combat_rules.lua`，用于候选模块的依赖。
3. **完整新版 Service 入口** `service/player_service.lua`，供未来新实例启动。
4. **一次性 Service Patch** `service/player_service.patch`，用于修改已经运行的实例；这个文件不会部署到正式宿主目录。

### 第 5.1 节：创建 V2 目录

```bash
mkdir -p hotupgrade/newsample/master_course/patches/v2/lualib
mkdir -p hotupgrade/newsample/master_course/patches/v2/service
```

### 第 5.2 节：新增规则模块

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v2/lualib/combat_rules.lua`。在 V1 中它尚不存在；未来由目标 PlayerService 的更新流程第一次加载。

```lua
-- 新增战斗规则：V1 运行时尚未存在。
local M = {} -- 候选模块的导出根表，return 后用于本次候选提交。

function M.weapon_bonus(weapon)
    return weapon == "剑" and 20 or 0
end

return M
```

`combat_rules` 的 `M` 是一张新创建的模块表。它的首次加载与普通模块“原地替换现存表”的过程不同：本批没有对应的旧 `live`，所以它不是本批要执行 Stage/Commit 的已有模块。

### 第 5.3 节：完整的 V2 普通模块

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v2/lualib/player_logic.lua`。

```lua
-- V2 普通模块：新的攻击闭包通过首次声明的战斗规则模块计算加成。
local hotupgrade = require "flywow_hotupgrade" -- 当前 Service 的受控模块加载、登记和生命周期 API。
local combat_rules = hotupgrade.require("combat_rules") -- 通过 hotupgrade.require 声明的新增依赖；普通候选执行时从该模块读取规则。
local M = {} -- 候选模块的导出根表，return 后用于本次候选提交。

function M.version()
    return "v2"
end

function M.make_attack(state)
    return function(base_attack)
        return base_attack + combat_rules.weapon_bonus(state.weapon)
    end
end

return M
```

注意代码执行时机：这份文件既是未来新 Service 的完整 Lua 文件，又会作为**冻结的源代码字符串**交给已经运行的 PlayerService 中的 `Module Patch Engine.stage()`。后者使用 `load(source)` 编译候选，再执行 chunk；执行到文件顶部 `hotupgrade.require("combat_rules")` 时，新模块必须已经可以被找到并完成本批登记。

### 第 5.4 节：为新实例准备完整 V2 Service 入口

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v2/service/player_service.lua`。

为什么还要有这个文件？因为 `.patch` 只作用于**现存实例**，不会变成未来创建 Service 时的入口源码。如果只提供一次性 `.patch`，新建 PlayerService 仍按正式目录里的 V1 入口初始化。

下面文件保留与 V1 相同的消息协议、queue、故障教学观测与注册方式；唯一有意改变的业务初始化值是 `weapon="剑"` 和 `schema_version=2`。为保证可独立复现，这里提供完整文件，而不是要求“复制 V1 并自行修改”。

```lua
-- V2 PlayerService：新实例通过正式部署的 V2 入口初始化。
local skynet = require "skynet" -- 当前 Service 使用的 Skynet API。
local business_queue = require "skynet.queue"() -- 业务串行队列；业务处理和热更安全点都经过它。
local hotupgrade = require "flywow_hotupgrade" -- 当前 Service 的受控模块加载、登记和生命周期 API。

local logic                 -- 首次 init 后的普通模块根表；热更保持表身份。
local state                 -- 玩家私有数据根表；由 Service Patch 原地修改。
local operations            -- 现有业务函数表；Patch 只替换指定函数。
local state_identity        -- 保存最初状态根表，用于观察身份是否稳定。
local old_attack            -- 缓存这个 Service 创建时的初始闭包，用于观察旧函数引用。
local registered = false    -- register_service 真正成功后才允许业务请求。
local holding_thread        -- hold 占用 queue 时正在 wait 的业务协程。
local waiting_spends = 0    -- 已通过入口但尚未拿到 queue 的 spend 请求数量。
local fail_restore = false  -- 只用于故障实验，正常运行恒为 false。

--- 返回 PlayerService 当前版本、私有状态和函数引用的观测快照。
local function inspect_state()
    return
    {
        ok = true,
        handle = skynet.self(),
        version = logic.version(),
        weapon = state.weapon,
        level = state.level,
        gold = state.gold,
        schema_version = state.schema_version,
        attack = operations.attack(100),
        old_attack = old_attack(100),
        state_same = state == state_identity,
        module_alias_same = package.loaded["lualib.player_logic"] == logic,
        combat_loaded = package.loaded["lualib.combat_rules"] ~= nil,
        patching = hotupgrade.patching,
    }
end

--- 声明业务模块和私有状态，最后登记当前 PlayerService。
local function initialize_player()
    if registered then
        return {ok = false, code = "ALREADY_INITIALIZED"}
    end

    logic = hotupgrade.require("player_logic")
    state =
    {
        weapon = "剑",
        level = 50,
        gold = 100,
        schema_version = 2,
    }
    operations = {attack = logic.make_attack(state)}
    state_identity = state
    old_attack = operations.attack

    local answer = hotupgrade.register_service( -- 管理命令的调用结果。
    {
        service_update =
        {
            state = state,
            functions = operations,
            -- 课堂故障需要显式控制恢复失败，所以这里使用成对自定义快照。
            snapshot = function(source)
                return require("flywow_result").success(
                {
                    weapon = source.weapon,
                    level = source.level,
                    gold = source.gold,
                    schema_version = source.schema_version,
                })
            end,
            restore = function(destination, snapshot)
                if fail_restore then
                    error("injected restore failure")
                end
                for key in pairs(destination) do
                    destination[key] = nil
                end
                for key, value in pairs(snapshot) do
                    destination[key] = value
                end
                return require("flywow_result").success()
            end,
        },
        before_upgrade = function()
            -- 必须排在所有已接纳业务之后取得同一条 queue。
            return business_queue(function() return true end)
        end,
        after_upgrade = function()
            -- 同步状态检查；故障实验把 schema 改成 99，以触发 Update 失败。
            return state.schema_version ~= 99
        end,
    })
    registered = answer.ok
    return answer
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer -- 管理命令的调用结果。

        if command == "init" then
            answer = initialize_player()
        elseif not registered then
            answer = {ok = false, code = "NOT_INITIALIZED"}
        elseif command == "inspect" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(inspect_state)
            end
        elseif command == "peek" then
            -- 教学观测口：只读、不进入业务 queue，避免观察者自身被 queue 挡住。
            answer =
            {
                ok = true,
                holding = holding_thread ~= nil,
                waiting_spends = waiting_spends,
                patching = hotupgrade.patching,
                gold = state.gold,
                schema_version = state.schema_version,
            }
        elseif command == "hold" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function()
                    holding_thread = coroutine.running()
                    skynet.wait(holding_thread)
                    holding_thread = nil
                    state.gold = state.gold - 10
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "release" then
            -- 教学控制消息必须独立于业务 queue，否则无法唤醒被占用的 queue。
            if holding_thread then
                local thread = holding_thread -- 从 holding_thread 取出的协程句柄，交给 skynet.wakeup 唤醒。
                holding_thread = nil
                skynet.wakeup(thread)
                answer = {ok = true}
            else
                answer = {ok = false, code = "NOT_HOLDING"}
            end
        elseif command == "spend" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                assert(type(request.amount) == "number" and request.amount > 0)
                waiting_spends = waiting_spends + 1
                answer = business_queue(function()
                    waiting_spends = waiting_spends - 1
                    state.gold = state.gold - request.amount
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "inject_restore_failure" then
            -- 课堂故障开关；不作为框架或实际业务管理 API。
            fail_restore = request.enabled == true
            answer = {ok = true}
        else
            answer = {ok = false, code = "UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
```

这里的完整重复代码不是要求你记住两份 Service 文件每一行，而是为了让**独立发布包真实具备新实例入口**。V1 和 V2 的相同协议只是教学案例的一部分；后续源码阅读仍以真实 FlyWow 的调用链为重点。

### 第 5.5 节：编写只作用于现存实例的 Service Patch

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v2/service/player_service.patch`。

这个文件并不是由 Skynet 当作新的 Service 入口来 `require`。它被 Controller 读取并冻结成字符串，在对应目标的 `handle_upgrade("update")` 内通过 `stage_service_patch()` 执行。`build_patch(state)` 接收到的是**现存 PlayerService 的 `state` 根表**，因此它能够为后续 Activate 准备修改原状态的闭包。

```lua
-- 一次性 Patch：仅更新已经运行的 PlayerService。
return function(state)
    return
    {
        -- 先声明本批 Update 中需要首次加载的新模块。
        new_modules = {"combat_rules"},
        -- 在 Activate 阶段执行，不在构建 Patch 时提前改线上数据。
        update_state = function()
            state.weapon = "剑"
            state.schema_version = 2
            -- gold、level 不修改，保持原来的玩家运行数据。
        end,
        -- 只替换已有的业务函数字段；不新建业务函数表。
        replace_functions =
        {
            attack = function(base_attack)
                return base_attack + (state.weapon == "剑" and 20 or 0)
            end,
        },
    }
end
```

有四个重要细节：

1. `new_modules` 是声明清单，**不是**让你在构建函数里先执行 `hotupgrade.require("combat_rules")`。Controller 必须先知道清单，目标再按照本批新模块协议加载它。
2. `update_state` 在这个文件执行并返回 Patch 结果时**还没有运行**；它只是一个捕获原 `state` 的函数，留待 Activate。
3. `replace_functions.attack` 同样捕获原 `state`。新函数写入 `operations.attack`，而不是把整个 `operations` table 换掉。
4. V2 新实例通过完整 `player_service.lua` 初始化；V1 旧实例通过当前这个 `.patch` 迁移。这是两条不同但应收敛到相同业务结果的路径。

## 第 6 章：让教学管理端正式发布、观察结果

现在有了完整的 V2 发布包。下一步由管理端调用 Controller 的 `begin`，再通过 `status` 获取异步批次终态。为了在后面继续做 Queue 和失败实验，我们这次将 `main.lua` **完整替换**成最终教学管理端；先只运行 `normal`，其余两个场景在对应章节再解释和执行。

**【你要修改：完整替换文件】** `hotupgrade/newsample/master_course/main.lua`：

```lua
-- 本课程管理端：v1 / normal / queue / forward 四个相互独立的场景。
local skynet = require "skynet" -- 当前 Service 使用的 Skynet API。
local SCENARIO = os.getenv("FLYWOW_MASTER_SCENARIO") or "v1" -- 环境变量选择的教学运行模式；未设置时使用 v1。

--- 断言 Skynet RPC 成功，并把统一结果表返回给调用方。
local function expect(answer)
    assert(type(answer) == "table" and answer.ok,
        type(answer) == "table" and (answer.message or answer.code) or tostring(answer))
    return answer
end

--- 向 PlayerService 查询当前业务快照，RPC 失败时直接报错。
local function get_player_snapshot(player)
    return expect(skynet.call(player, "lua", "inspect"))
end

--- 输出一个快照中的版本、状态和函数观察值。
local function print_player(label, snapshot)
    print(string.format("%s handle=%d version=%s weapon=%s gold=%d schema=%d attack=%d old_attack=%d",
        label, snapshot.handle, snapshot.version, snapshot.weapon,
        snapshot.gold, snapshot.schema_version, snapshot.attack, snapshot.old_attack))
end

--- 每个 Skynet tick 重新检查条件，超过上限后报告等待超时。
local function wait_for(check, description)
    for _ = 1, 3000 do
        local answer = check() -- 管理命令的调用结果。
        if answer then return answer end
        skynet.sleep(1)
    end
    error("等待超时: " .. description)
end

--- 提交发布请求并轮询直到该批进入终态。
local function publish(controller, patch_name)
    local begun = expect(skynet.call(controller, "hotupgrade", "begin", {path = patch_name})) -- 当前发布 begin 的受理结果，提供后续轮询身份。
    print("BEGIN " .. patch_name .. " batch=" .. begun.value.batch_id)
    return wait_for(function()
        local status = expect(skynet.call(controller, "hotupgrade", "status", -- 指定批次的当前状态查询结果。
            {batch_id = begun.value.batch_id}))
        local record = status.value.record -- 当前轮询读取的批次状态记录。
        if record.phase == "COMPLETED" or record.phase == "ABORTED"
            or record.phase == "RECOVERY_REQUIRED" then
            print("END " .. patch_name .. " phase=" .. record.phase
                .. " error=" .. tostring(record.error and record.error.code))
            return record
        end
    end, "发布 " .. patch_name)
end

--- 创建或复用控制 Service，并完成一次性目录配置。
local function initialize_controller()
    local controller = skynet.uniqueservice("flywow_hotupgrade_service") -- 当前管理端要发送命令的控制 Service handle。
    local runtime_root = assert(os.getenv("FLYWOW_MASTER_RUNTIME_ROOT")) -- 当前启动环境中由 run.sh 传入的宿主运行目录。
    expect(skynet.call(controller, "lua", "init",
    {
        root_path = runtime_root .. "/host",
        patch_path = runtime_root .. "/patches",
        service_path = "service",
    }))
    return controller
end

--- 创建受管理 PlayerService 并等待它完成初始化登记。
local function create_player(hot)
    local handle = hot.newservice("player_service") -- 新建业务 Service 的 Skynet handle。
    expect(skynet.call(handle, "lua", "init"))
    return handle
end

--- 检查初始 V1 Service 的版本、状态和对象身份。
local function run_v1(_controller, hot, player)
    local before = get_player_snapshot(player) -- 热更前从玩家 Service 读取的状态快照。
    print_player("V1", before)
    assert(before.version == "v1" and before.gold == 100 and before.attack == 105)
    assert(before.state_same and before.module_alias_same)
    print("MASTER_V1_OK")
end

--- 发布 V2，检查现存实例和新建实例都使用新代码。
local function run_normal(controller, hot, player)
    local before = get_player_snapshot(player) -- 热更前从玩家 Service 读取的状态快照。
    print_player("BEFORE", before)
    local first = publish(controller, "v2") -- 第一次发布 v2 的终态记录。
    assert(first.phase == "COMPLETED")

    local after = get_player_snapshot(player) -- 热更后从现存 PlayerService 读取的状态快照。
    print_player("EXISTING", after)
    assert(after.handle == player and after.version == "v2")
    assert(after.weapon == "剑" and after.schema_version == 2 and after.gold == 100)
    assert(after.attack == 120 and after.old_attack == 100)
    assert(after.state_same and after.module_alias_same and after.combat_loaded)

    local another = create_player(hot) -- 热更后新创建的 PlayerService handle，用来验证正式入口也是 V2。
    local second = get_player_snapshot(another) -- 新 Service 返回的状态快照。
    print_player("NEW", second)
    assert(another ~= player and second.version == "v2" and second.attack == 120)
    print("MASTER_NORMAL_OK")
end

--- 保持业务请求排队时发布，检查 Prepare 等待同一业务队列。
local function run_queue(controller, _hot, player)
    local first_done = false -- hold 请求是否已经完成。
    local second_done = false -- 排队的 spend 请求是否已经完成。
    local a_result -- 第一个 hold 请求的业务结果。
    local b_result -- 第二个 spend 请求的业务结果。

    skynet.fork(function()
        a_result = expect(skynet.call(player, "lua", "hold"))
        first_done = true
    end)
    wait_for(function()
        local peek = expect(skynet.call(player, "lua", "peek")) -- PlayerService 的只读观测结果，不进入业务 queue。
        return peek.holding
    end, "请求 A 占有业务 queue")

    skynet.fork(function()
        b_result = expect(skynet.call(player, "lua", "spend", {amount = 20}))
        second_done = true
    end)
    wait_for(function()
        local peek = expect(skynet.call(player, "lua", "peek")) -- PlayerService 的只读观测结果，不进入业务 queue。
        return peek.waiting_spends == 1
    end, "请求 B 已排入业务 queue")

    -- A 占着 queue，B 排队；现在开始发布，Prepare 也排在 B 后面。
    local begun = expect(skynet.call(controller, "hotupgrade", "begin", {path = "v2"})) -- 当前发布 begin 的受理结果，提供后续轮询身份。
    wait_for(function()
        local peek = expect(skynet.call(player, "lua", "peek")) -- PlayerService 的只读观测结果，不进入业务 queue。
        return peek.patching
    end, "Prepare 已关闭新业务入口")

    local c_result = skynet.call(player, "lua", "spend", {amount = 30}) -- 当前 spend 请求的业务响应；后续与 hold 响应一起验证 queue 顺序。
    assert(not c_result.ok and c_result.code == "HU_UPGRADING")
    expect(skynet.call(player, "lua", "release"))
    wait_for(function() return first_done and second_done end, "A/B 完成")
    assert(a_result.version == "v1" and a_result.gold == 90)
    assert(b_result.version == "v1" and b_result.gold == 70)

    local finished = wait_for(function() -- 等待本批排队业务和热更完成的终态记录。
        local status = expect(skynet.call(controller, "hotupgrade", "status", {batch_id = begun.value.batch_id})) -- 指定批次的当前状态查询结果。
        local phase = status.value.record.phase -- 轮询得到的批次阶段，用于判断是否已进入 UPDATE。
        if phase == "COMPLETED" or phase == "ABORTED" or phase == "RECOVERY_REQUIRED" then
            return status.value.record
        end
    end, "并发热更批次")
    assert(finished.phase == "COMPLETED")
    local after = get_player_snapshot(player) -- 热更后从现存 PlayerService 读取的状态快照。
    print_player("QUEUE_AFTER", after)
    assert(after.version == "v2" and after.gold == 70 and after.attack == 120)
    print("A V1 gold=90, B V1 gold=70, C HU_UPGRADING")
    print("MASTER_QUEUE_OK")
end

--- 演示失败报告后继续发布修复版本。
local function run_forward(controller, hot, player)
    assert(publish(controller, "v2").phase == "COMPLETED")
    local healthy = get_player_snapshot(player) -- 故障发布前的健康状态快照，修复后要与它对照。
    assert(healthy.version == "v2" and healthy.gold == 100)

    -- 教学故障：只让本次 Abort 的自定义 Service 状态恢复失败。
    expect(skynet.call(player, "lua", "inject_restore_failure", {enabled = true}))
    local faulty = publish(controller, "faulty") -- 故障 Patch 的终态记录，验证 Update 失败会报告错误。
    assert(faulty.phase == "RECOVERY_REQUIRED")
    assert(faulty.error and faulty.error.details.original_error and faulty.error.details.recovery_error)

    local damaged = get_player_snapshot(player) -- 故障批次后现存 Service 的实际状态快照。
    print_player("DAMAGED", damaged)
    assert(damaged.schema_version == 99 and damaged.gold == 0)
    assert(damaged.version == "v2" and damaged.state_same)

    -- 不需要管理端解锁 Controller；解除课堂注入，下一次普通发布直接修复。
    expect(skynet.call(player, "lua", "inject_restore_failure", {enabled = false}))
    local repaired = publish(controller, "v3") -- 后续修复批次的终态记录；上一批错误不阻止它开始。
    assert(repaired.phase == "COMPLETED")
    local fixed = get_player_snapshot(player) -- 修复完成后现存 Service 返回的状态。
    print_player("REPAIRED", fixed)
    assert(fixed.version == "v3" and fixed.weapon == "霜剑")
    assert(fixed.schema_version == 3 and fixed.gold == 88 and fixed.attack == 125)
    assert(fixed.state_same and fixed.module_alias_same)

    local another = create_player(hot) -- 热更后新创建的 PlayerService handle，用来验证正式入口也是 V2。
    local newcomer = get_player_snapshot(another) -- 修复后新建 Service 的状态，用于验证正式文件入口也已更新。
    print_player("NEW_V3", newcomer)
    assert(newcomer.version == "v3" and newcomer.schema_version == 3)
    assert(newcomer.attack == 125)
    print("MASTER_FORWARD_OK")
end

skynet.start(function()
    local ok, failure = xpcall(function() -- xpcall 的执行成功标志，用于最终决定进程退出码。
        local hot = require "flywow_hotupgrade" -- 管理端持有的 HotUpgrade API。
        local controller = initialize_controller() -- 当前管理端要发送命令的控制 Service handle。
        local player = create_player(hot) -- 本轮受管理创建的 PlayerService handle。
        if SCENARIO == "v1" then
            run_v1(controller, hot, player)
        elseif SCENARIO == "normal" then
            run_normal(controller, hot, player)
        elseif SCENARIO == "queue" then
            run_queue(controller, hot, player)
        elseif SCENARIO == "forward" then
            run_forward(controller, hot, player)
        else
            error("未知实验: " .. tostring(SCENARIO))
        end
    end, debug.traceback)
    if not ok then
        skynet.error("MASTER_FAILED: " .. tostring(failure))
    end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)
```

**不要现在就运行 `queue` 或 `forward`**：`queue` 要先理解等待的实际交错，`forward` 的故障和修复包还没有编写。`normal` 已具备全部依赖，可以运行。

```bash
# 在 FlyWow 根目录执行；每次运行脚本会复制一份干净 V1 和发布包。
bash hotupgrade/newsample/master_course/run.sh ../skynet normal
```

预期重要现象（handle 和批次 ID 不固定）：

```text
BEFORE handle=... version=v1 weapon=刀 gold=100 schema=1 attack=105 old_attack=105
BEGIN v2 batch=...
END v2 phase=COMPLETED error=nil
EXISTING handle=... version=v2 weapon=剑 gold=100 schema=2 attack=120 old_attack=100
NEW handle=... version=v2 weapon=剑 gold=100 schema=2 attack=120 old_attack=120
MASTER_NORMAL_OK
```

**为什么旧实例的 `old_attack=100`，新实例的 `old_attack=120`？** 旧实例保存的是 V1 攻击函数：它仍看着同一份 `state`，但是其代码仍然判断“刀加 5”。装备改成“剑”后它只返回基础攻击 100。旧实例当前 `operations.attack` 已被 Service Patch 替换为新闭包，返回 120。新实例第一次初始化时直接缓存了 V2 闭包，因此它的 `old_attack` 其实是“创建时的函数”而非历史 V1 函数，值为 120。

**第二个验收点**：同一个旧 handle、`state_same=true`、`module_alias_same=true`、`combat_loaded=true`；新版完整文件能被新的 Service 加载。若 `normal` 失败，优先检查 `patches/v2/` 是否完整、`.patch` 文件是否匹配 `service_name=player_service`、`hotupgrade.require` 的模块路径以及 Controller 批次错误。

## 第 7 章：沿着刚才真实执行过的批次，逐段进入 Controller

此刻不再创建新文件。我们刚刚通过管理端实际发出过 `begin({path="v2"})`，所以从**这条已发生的 RPC**开始阅读真实源码，而不是随机抽一段 Controller 函数来介绍。

### 第 7.1 节：第一跳——管理端到控制 Service

**调用现场**：教学 `main.lua/publish(controller,"v2")` 调用 `skynet.call(controller,"hotupgrade","begin",{path="v2"})`。管理端所在协程等待结果；接收者是独立 HotUpgrade Service。

**【真实源码摘录】** `hotupgrade/service/flywow_hotupgrade_service.lua`，`skynet.start` 内注册的 `skynet.dispatch("hotupgrade",...)`，业务协议消息到此入口：

```lua
skynet.dispatch("hotupgrade", function(session, source, command, request)
    local answer -- 管理命令的调用结果。
    if not controller_initialized then
        answer = flywow_result.failure("HU_NOT_INITIALIZED", "宿主尚未完成 init")
    else
        local ok -- xpcall 的执行成功标志，用于最终决定进程退出码。
        ok, answer = pcall(hotupgrade_controller.handle_command,
            hotupgrade_controller, command, request, source)
        if not ok then
            answer = flywow_result.failure("HU_CONTROL_FAILED", tostring(answer))
        end
    end
    if session ~= 0 then
        skynet.retpack(answer)
    end
end)
```

`hotupgrade_controller` 是 `require "flywow_hotupgrade_controller"` 得到的 Controller 模块表。它在**控制 Service 的 Lua State** 中保存唯一控制面的状态。`request.path="v2"` 就是从管理端 RPC 传来的相对发布包目录，**不是**可任意访问的宿主绝对路径。

`handle_command()` 根据 `command=="begin"` 转入 `M:begin(request)`。这是一条普通 Lua 函数调用，不再跨新的 Service。

### 第 7.2 节：`begin()` 为什么先返回，而真正更新尚未开始？

**【真实源码摘录】** `hotupgrade/lualib/flywow_hotupgrade_controller.lua`，`M:begin(request)` 中创建批次和启动后台发布协程的连续逻辑块：

```lua
function M:begin(request)
    if self.active_batch then
        return flywow_result.failure("HU_UPGRADE_BUSY", "已有发布屏障")
    end
    self.batch_sequence = self.batch_sequence + 1
    ---@type FlyWowHotUpgradeBatch
    local batch = -- Controller 当前协调的发布批次，携带冻结文件、目标和终态信息。
    {
        batch_id             = tostring(skynet.self()) .. ":" .. self.batch_sequence, -- 管理端用它查询这次发布；迟到命令也用它确认批次身份。
        sequence             = self.batch_sequence,                                   -- 本 Controller 内递增；控制 RPC 用它拒绝迟到的旧批消息。
        patch_dir            = request.path,                                          -- 相对 patch_root 的发布目录；begin 接受时固定并从此冻结源码。
        phase                = "WAITING_CREATIONS",                                   -- run_batch 推进；生命周期门禁和 status 视图据此生成。
        service_results      = {},                                                    -- 保存每个目标 Service 的最终结果，供 status 返回成功/失败明细。
        service_targets      = {},                                                    -- 保存本批实际需要执行控制命令的 Service；Update 前确定，终态后释放。
    }
    self.active_batch = batch
    skynet.fork(function()
        self:run_batch(batch)
    end)
    return flywow_result.success({batch_id = batch.batch_id})
end
```

注意两个不同的“先后”：

- `begin()` 启动发布协程后，返回 `{ok=true,value={batch_id=...}}`；**这只代表接受请求，不代表发布完成**。
- `run_batch()` 在另外一条 Skynet 协程中继续执行；期间可能在 `skynet.wait`、Prepare RPC、目标 Update RPC 等地方 yield。管理端通过 `status(batch_id)` 查询，而不是把一次 `begin` RPC 一直挂到整个发布完成。

从 begin 开始直到终态，Controller 始终使用这一张 `batch` 表，`batch.patch_dir` 固定记录本批相对于 `patch_root` 的发布目录。`self.active_batch` 只是 Controller 对当前批次的引用；`batch.phase` 是唯一保存的发布进度。门禁直接读取它，`status.value.lifecycle.phase` 则在查询时生成：例如批次处于 PREPARE 或 UPDATE 时，查询视图仍报告 APPLYING。Controller 不再同时维护另一份 `self.phase`，也不再在 fork 时另建一份 path 请求表。

### 第 7.3 节：`run_batch()` 第一段——为什么先等旧创建和首次加载？

**调用现场**：刚才 `M:begin()` fork 的协程开始执行 `self:run_batch(batch)`。在它运行之前，游戏里可能已经有其他受管理 Service 正在创建，或者某个 Service 取得了首次模块加载许可但尚未完成登记。

**【真实源码摘录】** `flywow_hotupgrade_controller.lua` → `wait_for_batch_work()`：

```lua
--- 等待目标创建和首次模块加载都结束，确保批次目标集合稳定。
local function wait_for_batch_work(controller, batch)
    -- 两张事实表分别记录尚未登记的创建与尚未消费的模块许可；batch.waiter 只保存本批等待协程。
    while next(controller.pending_creations) ~= nil or next(controller.module_load_permits) ~= nil do
        batch.waiter = coroutine.running()
        skynet.wait(batch.waiter)
        batch.waiter = nil
    end
end
```

`next(map) ~= nil` 表示表中至少还有一条未完成记录。批次开始和每轮 Prepare 后都会调用这个函数；只要创建记录或模块许可仍存在，当前发布协程就记录自己的 waiter 并让出执行权。创建登记/取消或模块许可登记/取消时，Controller 删除对应记录并调用 `wake_batch()`。协程恢复后重新检查两张表；两张表都为空才从等待函数返回。这里没有定时轮询，也没有单独维护在途计数。

`status` 仍对外报告 `pending_service_count` 和 `pending_module_count`，但它们是查询时根据 `pending_creations` 和 `module_load_permits` 统计出来的值，不是 Controller 内部状态字段。

**返回调用主线**：在 `M:run_batch()` 中，这次等待返回后先把批次标为 `DEPLOYING`，再把 Patch 源码和正式文件旧内容读入本批记录：

```lua
wait_for_batch_work(self, batch)
batch.phase = "DEPLOYING"
local control_succeeded, control_failure = pcall(prepare_and_update_batch, self, batch) -- Prepare/Update 协调函数是否正常返回。
```

`prepare_and_update_batch()` 完成每轮 Prepare 后也会复用同一个等待函数；因此等待结束后继续重新匹配目标，全部目标准备好后才部署正式文件并执行 Update。

这里不再检查活动批次是否被取消或替换：`begin` 会拒绝并行批次，管理端主动 `abort` 已被取消，运行期间没有另一条路径替换 `active_batch`。完成回调改变的是两张在途事实表，所以被唤醒后只重查这两个实际可变的条件。

这段结束后，进入同一个 `run_batch` 的“冻结发布包和旧文件快照”段，Controller 读取发布包 `v2/` 下的 `.lua` 与 `.patch`，检查路径和源码，并完成初次目标匹配。

### 第 7.4 节：冻结源码、保存旧文件，再进入 Prepare

**【真实源码摘录】** `M:run_batch()` 通过 `pcall` 调用 `prepare_and_update_batch()`。下面先展示四阶段编排，再进入第一个阶段 `load_and_snapshot_batch_files()`：

```lua
--- 依次准备所有目标并执行 Update，任一步失败交给批次恢复。
local function prepare_and_update_batch(controller, batch)
    -- 各阶段共用 batch.error 传递首个失败；这里据此停止推进，恢复由外层 run_batch 统一执行。
    load_and_snapshot_batch_files(controller, batch)
    if batch.error then
        return
    end

    prepare_batch_targets(controller, batch)
    if batch.error then
        return
    end

    deploy_batch_files(controller, batch)
    if batch.error then
        return
    end

    update_batch_targets(controller, batch)
end

--- 读取本批源码并保存正式文件旧内容，供部署失败时恢复。
local function load_and_snapshot_batch_files(controller, batch)
    -- load_patch 填充的 files 只含正式 .lua；此处补齐 old_source，false 表示部署前没有该文件。
    -- DEPLOYING 阶段只读取一次发布包，并保存所有正式文件的旧内容。
    local load_result = controller:load_patch(batch)
    if not load_result.ok then
        batch.error = load_result
        return
    end

    for _, file in ipairs(batch.files) do
        local old_source, read_failure = hotupgrade_native.read_file(controller.root_path, file.host_relative_path) -- 正式目录中替换前的文件内容；失败时写回它恢复旧版本。
        if old_source == nil then
            batch.error = flywow_result.failure(native_code(read_failure), "文件准备失败: " .. file.host_relative_path)
            return
        end
        file.old_source = old_source
    end
end
```

四阶段共用同一个 batch。第一个阶段失败会写入 batch.error 并返回；编排函数立即停止后续阶段，回到 run_batch() 后进入恢复，不会跳过批次收尾。

`load_patch(batch)` 先调用 `freeze_patch_files(controller,batch)` 扫描、读取、检查语法并分类源码，将结果写入 `batch.files`、`batch.modules`、`batch.service_patches`，再完成初次匹配，写入 `batch.service_targets`；活动目标数由该列表长度计算，终态释放列表前才保存 `batch.target_service_count`。`service_targets` 的每一项是一个目标 Service 的本批记录，包含真实 handle、匹配到的模块及 Prepare/Abort 所需参与状态；它不是另一种批次或发布包。返回的 `frozen` 仅是冻结操作结果；它不再携带另一层 patch/targets 包装。普通模块源码记录与文件恢复记录分别用于目标 RPC 和正式文件恢复，旧文件快照不发送给目标 Service。本批的三个发布集合各有用途：batch.files 保存所有正式 Lua 文件路径和新源码，供部署及失败恢复；batch.modules 只保存普通 Lua 模块候选，供目标按已登记模块名筛选；batch.service_patches 按 Service 入口名保存对应更新脚本。模块名按路径把斜杠改成点，所以 a/b.lua 和 a.b.lua 都会得到 a.b，不能在同一批重复发布。

这里的 `read_file` 能区分“旧文件本来不存在”与“读取操作失败”：新增 `combat_rules.lua` 在 V1 宿主里不存在，其 `old_source` 表示不存在，而不是因为没有旧文件就拒绝新模块发布。回滚时对本批新创建的文件执行删除。

**这时只把 Patch 源码和旧文件快照读入内存，还没有复制正式 V2 文件。** 随后 `batch.phase` 进入 `PREPARE`，Controller 用初次匹配结果逐个向目标发送 Prepare。我们的 `player_service` 因为已经通过受管理入口创建、登记了 `lualib.player_logic`，且提供 Service 更新入口，因此是本批参与目标。

### 第 7.5 节：第二跳——Controller 发送 Prepare 到目标 Service

**谁调用谁**：`M:run_batch()` → `prepare_and_update_batch()` → `prepare_batch_targets()` → 同文件 `M:step(batch,service_target,"prepare")` → `skynet.call(service_target.service_handle,"hotupgrade",...)` → PlayerService 的 `hotupgrade` dispatch → 本地 `handle_upgrade("prepare",...)`。

**【真实源码摘录】** `flywow_hotupgrade_controller.lua` → `M:step()` 中构造并发送 RPC 的连续逻辑块：

```lua
function M:step(batch, service_target, command)
    -- service_target 是本批复用的目标记录；modules 是筛选后的候选，service_patch 保存匹配到的 .patch 源码。
    ---@type FlyWowHotUpgradeControlRequest
    local request = -- 本批固定的管理请求，后续执行始终使用同一发布目录。
    {
        batch_id = batch.batch_id,
        sequence = batch.sequence,
    }

    if command == "update" then
        request.modules = service_target.modules
        request.service_patch_source = service_target.service_patch and service_target.service_patch.service_patch_source
    end

    if service_target.exited then
        return service_target.hotupgrade_result
    end

    -- 调用前置位，RPC 抛错时不能判断远端是否已经执行。
    local call_succeeded, service_result = pcall(skynet.call, -- 向目标 Service 发送控制 RPC 是否正常返回。
        service_target.service_handle, "hotupgrade", command, request)
    if service_target.exited then
        return service_target.hotupgrade_result
    end
    if not call_succeeded or type(service_result) ~= "table" or type(service_result.ok) ~= "boolean" then
        return flywow_result.failure("HU_RPC_FAILED", tostring(service_result), {step = command})
    end

    if not service_result.ok and service_target.service_patch then
        service_result.message = service_target.service_patch.patch_relative_path .. ": " .. (service_result.message or service_result.code)
    end
    return service_result
end
```

Prepare 只需要 `batch_id`、`sequence` 等批次身份，不发送完整模块源码。Update 才另外携带本目标的冻结模块源码及可选 Service Patch 源码。目标 handle 来自已登记的真实 Service 身份，不是凭文件名猜测出来的。

**接收方在哪里？** `hotupgrade/lualib/flywow_hotupgrade.lua` → `register_service()` 安装的 `dispatch_upgrade_command()` → `handle_upgrade(command,request,source)` → `prepare_batch(request)`。当收到 Prepare 时：

**【真实源码摘录】** `flywow_hotupgrade.lua` → `prepare_batch(request)`：

```lua
--- 向匹配到的 Service 发送 Prepare，并等待业务安全点。
local function prepare_batch(request)
    -- active_batch 是当前 Service 的本地记录；request 的身份来自 Controller，回调与业务对象仍只留在此 Lua State。
    if module_state.active_batch then
        return flywow_result.failure("HU_UPGRADE_BUSY", "当前批次已在处理中")
    end

    module_state.active_batch =
    {
        batch_id = request.batch_id,
        sequence = request.sequence,
        new_module_context = nil, -- Update 临时上下文覆盖 Patch 构建、新模块加载和候选 Stage，owner 限定当前控制协程。
    }
    M.patching = true

    local prepare_succeeded, prepare_result = pcall(module_state.registration_config.before_upgrade) -- 业务 before_upgrade 是否正常返回。

    if not prepare_succeeded then
        return flywow_result.failure("HU_PREPARE_FAILED", tostring(prepare_result))
    end
    if prepare_result ~= true and not (type(prepare_result) == "table" and prepare_result.ok == true) then
        return flywow_result.failure("HU_SAFEPOINT_REQUIRED",
            type(prepare_result) == "table" and (prepare_result.message or prepare_result.code) or "before_upgrade 未确认业务安全点")
    end
    return flywow_result.success()
end
```

这里发生了两个不同的动作：

- **先**设 `hotupgrade.patching=true`，后来的普通业务请求在入口处拒绝加入 queue。
- **再**调用宿主注册的 `before_upgrade`。我们的 V1 实现是 `business_queue(function() return true end)`，它需要真的拿到业务 queue 的执行权，才能确认先前已进入的业务完成。它允许 yield，Controller 的 Prepare RPC 会等待目标回复。

这就是第 4 部分并发实验要真实观察的安全点。这里先沿正常 V2 的流程继续：无在途业务时 Prepare 很快完成，目标把成功结果返给 Controller。

### 第 7.6 节：Prepare 返回后，为什么还要重匹配？

回到 `prepare_batch_targets()` 的 Prepare 循环，而不是直接跳到 Update。`before_upgrade()` 允许 yield，之前已经进入业务 queue 的代码也可能在这段时间创建新的受管理 Service、首次加载模块。因此 Controller 必须：

1. 等在途创建和首次加载完成。
2. 用**同一份冻结的 Patch** 重新匹配当前已登记的目标。
3. 新增目标补做 Prepare；已有目标如新声明了受影响模块，则补充模块清单，但不重新执行它的 Prepare。
4. 确认没有未 Prepare 的新目标，且在途计数为零，才向 Update 收口。

**【真实源码摘录】** `prepare_batch_targets()` 循环尾部，展示当前逻辑块的关键连续段：

```lua
local matched = match_service_targets(batch, controller.service_registrations) -- 本批按 Service 入口名匹配后的目标列表和是否需要 Prepare 的结果。
if not matched.ok then
    batch.error = matched
    return
end

if not matched.value.needs_prepare then
    break
end
```

`match_service_targets(batch, controller.service_registrations)` 在同一 HotUpgrade Service 的 Lua State 内执行。匹配失败时的 return 退出 prepare_batch_targets()；编排函数看到 batch.error 后返回，由 run_batch() 进入统一恢复；末尾的 break 则只退出 Prepare 重匹配循环。它先按 handle 索引上轮目标，匹配到旧目标时复用原记录并更新模块清单，只为新增目标创建记录；这样已经 Prepare 的目标保留 participated、退出通知和恢复结果。完整匹配成功后更新 batch.service_targets；匹配时已经根据 participated 计算是否有新目标仍需 Prepare，并放在 matched.value.needs_prepare 中，调用处直接据此决定是否再循环，不再二次遍历目标列表。最终匹配与下一阶段赋值之间没有 yield；随后 prepare_batch_targets() 返回，prepare_and_update_batch() 继续进入部署阶段。

### 第 7.7 节：真正的顺序——先关闭门禁、部署文件、清缓存，再 Update

现在回到同一个 `M:run_batch()` 调用的阶段函数。这里是整门课程最容易被旧材料误导的地方：**不能先 Update 再复制正式文件**。

**【真实源码摘录】** `flywow_hotupgrade_controller.lua` → `deploy_batch_files()` 和紧接着调用的 `update_batch_targets()`，分别关闭门禁并部署、清缓存，再串行 Update：

```lua
--- 把本批固定读取的文件写入正式目录并清理 Lua 缓存。
local function deploy_batch_files(controller, batch)
    -- files 保存本批源码和旧文件快照；只有替换成功才设 touched，失败恢复据此选择实际写过的文件。
    -- PREPARE 收口后无 yield 地关闭入口；先部署本批完整 Lua 文件并清缓存。
    batch.phase = "UPDATE"
    for _, file in ipairs(batch.files) do
        local file_written, write_failure = hotupgrade_native.replace_file( -- 当前正式文件替换是否成功。
            controller.root_path, file.host_relative_path, file.source)
        if not file_written then
            batch.error = flywow_result.failure(native_code(write_failure), "部署失败: " .. file.host_relative_path)
            return
        end
        file.touched = true
    end
    if #batch.files > 0 then
        local cache_cleared, cache_failure = pcall(skynet.cache.clear) -- 正式文件全部替换后缓存清理是否成功。
        if not cache_cleared then
            batch.error = flywow_result.failure("HU_CACHE_CLEAR_FAILED", tostring(cache_failure))
            return
        end
    end
end

--- 按目标顺序执行 Update，首个失败交由恢复流程处理。
local function update_batch_targets(controller, batch)
    -- service_targets 已在 Prepare 收口时固定；current_service_handle 还用于允许当前目标登记 new_modules。
    -- 全部文件就绪后才向目标发送 Update；新生命周期请求继续等待批次终态。
    for _, service_target in ipairs(batch.service_targets) do
        batch.current_service_handle = service_target.service_handle
        local service_result = controller:step(batch, service_target, "update") -- 目标 Service 对本次 Prepare 或 Update 的结构化答复。
        if batch.error then
            return
        end
        if not service_result.ok then
            service_target.hotupgrade_result = service_result
            batch.error = service_result
            return
        end
    end
end
```


在 `prepare_and_update_batch()` 把 `batch.phase` 设为 `UPDATE` 后，`lifecycle_closed()` 直接检查活动批次，使后来到达的受管理创建、普通首次加载**等待至批次终态**。WAITING_CREATIONS 和 PREPARE 继续接纳依赖；冻结文件和保存旧快照的 DEPLOYING、正式部署及 Update、发布决定后的 Finish 期间关闭入口。对外查询仍将 PREPARE、UPDATE、PUBLISH_DECIDED 显示为 APPLYING，但这个值只在查询时推导。此前计数已归零，关闭门禁时不会遗漏“已经获准进入的半成品”。

源码的门禁判断就在同文件顶层：

**【真实源码摘录】** `flywow_hotupgrade_controller.lua` → `lifecycle_closed(controller)`：

```lua
--- 从活动批次阶段判断创建和模块首次加载入口是否关闭。
local function lifecycle_closed(controller)
    local batch = controller.active_batch -- Controller 当前协调的发布批次，携带冻结文件、目标和终态信息。
    return batch ~= nil and batch.phase ~= "WAITING_CREATIONS" and batch.phase ~= "PREPARE"
end
```

紧接着的正式文件部署是**同步 Native 操作**。Controller 将已经冻结的 V2 完整 `.lua` 替换进本次运行的正式 `host/`，包括 V1 时不存在的 `combat_rules.lua`；随后在存在部署文件时调用 `skynet.cache.clear()`，使后续 Service 加载入口源码时不会继续使用旧代码缓存。它**不意味着清空所有 Service 的 `package.loaded`**。现存普通模块表的更新，是目标 Lua State 之后收到 Update 才执行的。

此刻的状态快照：

| 观察项                               | Prepare 完成之后、第一条 Update RPC 之前      |
| ------------------------------------ | --------------------------------------------- |
| 旧 PlayerService handle              | 仍是原来的 handle                             |
| 旧 PlayerService `state`             | 仍是 V1：刀、100 金币、schema 1               |
| 旧 PlayerService `operations.attack` | 仍是 V1 函数                                  |
| 旧 PlayerService `hot.patching`      | `true`                                        |
| 正式宿主文件                         | **已经是 V2**，新增 `combat_rules.lua` 已部署 |
| 受管理普通首次加载门禁               | 关闭；新请求等待本批终态                      |
| 本批普通模块 Stage                   | 尚未开始                                      |

这里必须接受一个短暂的、受控的版本窗口：磁盘文件已更新，而旧 Service 内存尚未更新。但是已经 Prepare 的目标业务入口仍关闭；新 Service 创建和普通首次加载也被 Controller 门禁阻挡。失败时才有条件按当前批次记录的恢复顺序回滚文件和目标。

### 第 7.8 节：第三跳——目标 Update RPC 到达 PlayerService

现在 Controller 在 update_batch_targets() 循环调用 `controller:step(batch,service_target,"update")`。`M:step()` 将 `service_target.modules` 和 `service_target.service_patch.service_patch_source` 放进请求，通过 `skynet.call` 发送给 PlayerService。这里的 `service_patch_source` 是 `.patch` 文件内容，不是文件路径。Controller 协程等待这个 RPC 结果；目标所在 Lua State 由 dispatch_upgrade_command() 进入 handle_upgrade("update")，完成公共校验后分派到 update_batch(batch,request)。

**【真实源码摘录】** `hotupgrade/lualib/flywow_hotupgrade.lua` → `update_batch()`，从准备到提交的连续逻辑：

```lua
--- 在目标 Lua State 加载本批新增模块并 Stage、Commit 普通模块。
local function update_batch(batch, request)
    -- request.modules 和 service_patch_source 是 Controller 为本批固定读取的候选输入。
    -- Controller 在 Prepare 收口时已固定普通候选；new_modules 在这里才首次加载并登记，从下一批 Stage 起才会匹配。
    -- Service Patch 构建和 new_modules 登记结果；成功后才能执行普通候选 Stage。
    local service_patch_result = stage_service_patch_and_new_modules(batch, request.service_patch_source)
    if not service_patch_result.ok then
        return service_patch_result
    end
    -- 当前 Service 的提交定义和恢复材料；本批没有匹配的 Service Patch 时为 nil。
    local service_patch = service_patch_result.value

    -- 保留同一声明上下文直到候选模块执行结束，漏列的新依赖须立即失败，不能在 UPDATE 等许可。
    -- 普通模块候选 Stage 的执行状态和结果；失败时需清除临时新模块加载权限。
    local stage_succeeded, module_result = pcall(hotupgrade_module_patch.stage,
        request.modules, module_state.declared_modules)
    batch.new_module_context = nil
    if not stage_succeeded then
        -- 内部若已返回 FlyWowResult 则保留其错误码，普通 Lua 异常由本阶段错误码包装。
        local cause = type(module_result) == "table" and module_result.ok == false and module_result or nil
        return flywow_result.failure("HU_MODULE_STAGE_FAILED",
            cause and cause.message or tostring(module_result), cause and {cause_code = cause.code} or nil)
    end
    if not module_result.ok then
        return module_result
    end

    batch.module_stage = module_result.value.stage
    batch.service_patch = service_patch

    -- Activate 同步提交；失败先报告，再由 Controller 串行 Abort 整批目标。
    -- 原地安装候选模块导出的结果；失败后由 Controller 调用 Abort 恢复。
    local commit_result = hotupgrade_module_patch.commit(batch.module_stage)
    if not commit_result.ok then
        return flywow_result.failure("HU_ACTIVATE_FAILED", commit_result.message)
    end
    -- 捕获 Service 状态、函数及 after_upgrade 提交异常，交由 Controller 统一 Abort。
    local activation_succeeded, activation_failure = pcall(function()
        if service_patch then
            local service_update = module_state.registration_config.service_update -- register_service 提供的私有状态/函数更新合同。
            service_patch.touched = true
            if service_patch.update_state then
                service_patch.update_state()
            end

            for name, fn in pairs(service_patch.replace_functions or {}) do
                rawset(service_update.functions, name, fn)
            end
        end

        if module_state.registration_config.after_upgrade then
            assert(module_state.registration_config.after_upgrade() ~= false, "after_upgrade 拒绝更新")
        end
    end)

    if not activation_succeeded then
        -- Controller 串行发出一次 Abort，报告更新错误与独立恢复结果。
        return flywow_result.failure("HU_ACTIVATE_FAILED", tostring(activation_failure))
    end

    return flywow_result.success()
end
```

这段看起来很长，但不能拆成毫无关系的 API 介绍。它属于**同一次目标 Update RPC**，严格按下面的发生顺序继续：

Controller 在 `update_batch_targets()` 中按去重后的 Service handle 顺序只派发一次 Update，并在所有目标成功后才发送 Finish。Service 本地批次只保留提交和恢复所需的记录；不重复保存 Controller 已保证的阶段状态。新模块登记 RPC 即使 yield，也不会使当前 Controller 调用链重发 Update。

1. `stage_service_patch_and_new_modules()`：构建 Service Patch，解析 `new_modules`，加载并登记同批新增的依赖。
2. `hotupgrade_module_patch.stage()`：加载本批**已有**受影响模块的候选源码，为原地更新准备旧导出和候选状态。
3. `hotupgrade_module_patch.commit()`：把候选字段安装到原模块导出表上。
4. 执行 `update_state()`、替换 `operations.attack` 等函数字段。
5. 同步执行 `after_upgrade()` 检查；成功则返回 `{ok=true}`。

这里沿调用链固定两个名字：`batch` 是当前 PlayerService 从 Prepare 保留到 Finish/Abort 的本地批次记录；`service_patch` 是本次准备好的 Service 提交内容及恢复快照，返回后存入 `batch.service_patch`。执行 .patch 构建函数得到的 `patch_definition` 属于首次接收的业务输入，stage_service_patch() 检查它后，提取 update_state、replace_functions、new_modules，并保存 old_state、old_functions、touched。准备结果直接持有这些字段，提交时使用 service_patch.update_state 访问同一份提交回调。普通模块 Stage 的返回操作结果叫 `module_result`，其中真正的暂存记录存入 `batch.module_stage`；这两者分别是操作结果和恢复数据，不是同一对象的改名。

本课程 V2 的第 1 步成功登记 `combat_rules`，第 2 步才执行 `player_logic` 候选；候选文件顶部依赖 `combat_rules`，这时已经可以从本 State 加载结果中复用。**第 2 步不会对刚刚首次登记的 `combat_rules` 再 Stage 一次**，因为本批普通模块目标集合早已在 Controller 中冻结。

这份 Update 分支之后，我们先暂时停在目标 `Module Patch Engine.stage()` 的调用入口。第三部分会在**这个实际发生的位置**深入模块更新引擎，再原路返回这里继续看 Controller 如何收尾。

---

# 第三部分：在目标 Update 内深入 Module Patch Engine

## 第 8 章：先冻结当前执行位置

我们现在仍在 **旧 PlayerService 的 Lua State**。Controller 的发布协程正在等待 `skynet.call(player,"hotupgrade","update",...)` 返回，而 PlayerService 的 `handle_upgrade("update")` 刚刚做完 Service Patch 构建、`new_modules` 登记，即将调用：

```lua
-- 真实调用位置：flywow_hotupgrade.lua / update_batch(batch, request)。
local stage_succeeded, module_result = pcall(hotupgrade_module_patch.stage,
    request.modules, module_state.declared_modules)
```

`request.modules` 不是“所有发布文件”，而是 **Controller 对这个 Service 匹配出来的已有模块更新清单**。在我们的实验里主要是 `lualib.player_logic`；新增 `lualib.combat_rules` 此前不存在，因此不参加本批普通模块的 Stage。

`module_state.declared_modules` 保存原始加载名和来源路径；例如 `player_logic` 对应实际 `host/lualib/player_logic.lua`。引擎不是直接去磁盘读取候选源文件，而是执行 Controller 已冻结并通过 RPC 送来的源码字符串，这避免 Prepare 后重新读取源包时被无意替换成另一份内容。

以下的 `M.stage/M.commit/M.abort/M.finish` 都来自：

`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`

这里的 `M` 是该模块导出的 Lua table，**不是 C++ class**，也不是 Controller 的 `M`。同名变量位于不同 Lua 模块文件，实际职责不同。

## 第 9 章：Stage 第一轮为什么只编译和保存旧引用？

为了避免被实际源码的多个变量淹没，先给它们具体名字和对象关系。

| 名称                                    | 当前例子                               | 所属 Lua State   | 实际含义                          |
| --------------------------------------- | -------------------------------------- | ---------------- | --------------------------------- |
| `live`                                  | 最初 `player_logic` 的 `M` 表          | 旧 PlayerService | 已经被线上业务持有的根导出表      |
| `old`                                   | `{version=V1函数, make_attack=V1函数}` | 旧 PlayerService | Stage 记录的旧字段**引用**快照    |
| `candidate`                             | 执行 V2 源码返回的新 `M` 表            | 旧 PlayerService | 尚未安装到 live 上的 V2 导出表    |
| `module_stage.entries`                  | 本次受影响模块条目数组                 | 旧 PlayerService | 在 Finish 或 Abort 前持有上述对象 |
| `package.loaded["lualib.player_logic"]` | 指向 `live`                            | 旧 PlayerService | 框架使用的规范模块名缓存别名      |

**【真实源码摘录】** `flywow_hotupgrade_module_patch.lua` → `M.stage(module_patches,module_loaders)` 中的第一轮循环（局部连续片段）：

```lua
for _, module_patch in ipairs(module_patches) do
    local live = package.loaded[module_patch.name] -- package.loaded 中当前线上模块的导出表，Commit 原地写它。
    check_exports(live, module_patch.name)
    local fields = {} -- 候选导出表的完整字段集合，Stage 后由 Commit 安装到 live。
    for key, value in pairs(live) do
        fields[key] = value
    end

    local chunk = assert(load( -- 编译后的候选模块代码；编译阶段不执行模块顶层代码。
        hotupgrade_common.normalize_source(module_patch.source),
        "@" .. module_patch.name, "t"))
    local loader = module_loaders and module_loaders[module_patch.name] -- 普通 require 返回的加载器；Skynet loader 会另行确认其来源。
    module_stage.entries[#module_stage.entries + 1] =
    {
        name = module_patch.name,
        live = live,
        old = fields,
        chunk = chunk,
        loader_name = loader and loader.name or module_patch.name,
        loader_path = loader and loader.path,
        candidate = nil,
    }
end
```

第一轮最重要的三件事：

**一，先找到线上根表 `live`。** 比如 `package.loaded["lualib.player_logic"]` 指向旧 `logic` 表。`M.stage` 必须验证这张表确实是受支持的无元表导出，而不是随便用 `package.loaded[name]` 覆盖一个来源不明的对象。

**二，保存旧导出字段，而不是复制整个 Lua 函数。** `fields.version` 与 V1 的 `live.version` 是同一个函数引用；Lua 函数和它的 upvalue 不是因为 `fields[key]=value` 就自动深拷贝。若旧代码事先保存 `local old_version=logic.version`，这个变量后面仍指向旧函数。

**三，编译所有候选源码，但此时不执行候选 chunk。** `load(...,"t")` 生成函数对象；真正执行 `player_logic.lua` 顶层代码——包括 `hotupgrade.require("combat_rules")`——是在第二轮。之所以拆成两轮，是要在任何候选执行之前，先为所有受影响模块固定线上根表、旧字段及可编译的完整源码。这样可以避免已经执行了一部分候选后才发现另一份源代码连语法都不能编译。

`normalize_source` 处理 Lua BOM/shebang 一类源码头；候选使用默认当前 Lua State 的全局环境，**不使用隔离的自定义 `_ENV`**。所以候选顶层的业务副作用并不是自动可回滚的；项目合同要求受信源码、同步执行且不产生不可撤销副作用。

## 第 10 章：Stage 第二轮怎样得到 candidate？

现在第一轮已经完成。我们仍在 `M.stage()` 内，没有返回 `handle_upgrade()`；继续进入同函数的第二轮。

**【真实源码摘录】** `flywow_hotupgrade_module_patch.lua` → `M.stage()` 中紧接着的第二轮循环：

```lua
for _, entry in ipairs(module_stage.entries) do
    local candidate = entry.chunk(entry.loader_name, entry.loader_path) -- 执行候选 chunk 得到的新模块根表。
    check_exports(candidate, entry.name)
    assert(candidate ~= entry.live, "候选须返回新的导出表")
    -- 只有旧版提供快照且新版提供导入钩子时才迁移；缺少任一方就使用新版初始化状态。
    if entry.live.export_state and candidate.import_state then
        local snapshot = M.snapshot_state(entry.live.export_state()) -- Service 返回的观测快照，用于断言热更前后版本、状态和身份。
        assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
        -- 导入钩子可能改变候选导出；只在执行过该钩子后重新检查。
        check_exports(candidate, entry.name)
    end
    entry.candidate = candidate
    entry.chunk = nil
end
```

拿我们的 `player_logic.lua` 逐句理解：

1. `entry.chunk(...)` 开始执行此前编译好的完整 V2 源码。Lua 文件执行到顶部，通过 `hotupgrade.require("combat_rules")` 取得已经声明的新模块，再创建**一张新的**候选 `M` 表。
2. `check_exports(candidate,...)` 检查候选导出是否合法。它要求根导出为无元表 table，顶层键为字符串；还约束可支持的嵌套结构以及状态钩子必须成对出现。
3. `candidate ~= entry.live`：这张新表绝不能就是线上根表。如果候选直接修改并返回旧根表，Stage 就已经改变线上数据了，无法保持“暂存而不提交”的合同。
4. 若旧模块提供 `export_state`，且新模块提供 `import_state`，则通过快照迁移模块自己的**闭包私有状态**。我们实际 V1/V2 模块没有私有计数器，所以此分支自然跳过。 import_state 可能改变候选导出，所以执行过它才再次运行 check_exports；未执行导入钩子时，第一次检查后的候选图没有改变，不再无条件完整检查第二遍。
5. 把候选保存到 `entry.candidate`，释放对已执行 chunk 的当前条目引用。到此 Stage 才能成功返回。

### 第 10.1 节：为什么要有 `export_state/import_state`？

这是一个**补充的原理实例，不需要你额外创建文件**。假设玩家逻辑模块有私有命中计数：

```lua
-- 【原理示意：旧版模块的局部状态，不是我们 V1 Sample 的实际文件】
local hit_count = 7
local M = {} -- 候选模块的导出根表，return 后用于本次候选提交。
function M.hit() hit_count = hit_count + 1 end
function M.export_state() return {hit_count = hit_count} end
function M.import_state(snapshot)
    hit_count = snapshot.hit_count
    return true
end
return M
```

候选 V2 重新执行时，会创建自己的局部 `hit_count` 和自己的函数闭包。**替换导出表里的 `hit` 字段，并不会把旧闭包的 upvalue 自动搬到新闭包**。引擎通过旧版 `export_state()` 取得 `{hit_count=7}`，使用 `snapshot_state` 制作与旧状态隔离的普通数据快照，再调用候选 `import_state(snapshot)` 把计数写进新闭包。

为什么快照需要隔离？如果候选导入时就对旧状态 table 原地修改，Stage 失败便可能污染旧业务。项目默认快照支持普通数据图、共享引用及循环结构，拒绝不支持的特殊对象；特殊对象需要由 Service 显式提供成对 snapshot/restore。

**重要边界**：旧函数引用依旧指向旧闭包及旧 upvalue；新函数引用指向新闭包及迁移后的新 upvalue。它们并不是同一个计数变量。Stage 不使用 `debug.upvaluejoin` 偷偷合并闭包状态。

### 第 10.2 节：Stage 成功时的对象快照

```text
旧 PlayerService 的 Lua State

logic ──────────────────────┐
package.loaded["player_logic"] ──┤
package.loaded["lualib.player_logic"] ─┤
                           ▼
                       [live / V1 根表]
                       version ───────► V1 version 函数
                       make_attack ───► V1 make_attack 函数

module_stage.entries[1]
  ├─ live ───────────────► 同一个 live 根表
  ├─ old.version ────────► V1 version 函数
  ├─ old.make_attack ────► V1 make_attack 函数
  └─ candidate ──────────► [V2 新根表]
                            version ───► V2 version 函数
                            make_attack ► V2 make_attack 函数

线上表此时仍是 V1；candidate 尚未被安装。
```

## 第 11 章：Commit 为什么不把 `package.loaded` 指到 candidate？

**调用者**：Stage 返回 `{ok=true,stage=...}` 到 PlayerService 的 `handle_upgrade("update")`，该函数把记录保存到 `batch.module_stage`，然后调用 `hotupgrade_module_patch.commit(batch.module_stage)`。我们在这里再次进入模块引擎。

**【真实源码摘录】** `flywow_hotupgrade_module_patch.lua` → `M.commit()` 中验证与安装逻辑：

```lua
for _, entry in ipairs(module_stage.entries) do
    assert(package.loaded[entry.name] == entry.live
        and getmetatable(entry.live) == nil,
        "模块身份在 Stage 后改变")
end
module_stage.committed = true
for _, entry in ipairs(module_stage.entries) do
    replace_exports(entry.live, entry.candidate)
end
```

它先统一确认所有目标根表仍是 Stage 保存的 `live`，才把 `committed=true`，然后在**旧根表对象上**安装候选字段。这里 `committed` 必须在修改前标记：如果替换了一半发生错误，后续 Abort 仍知道需要尝试恢复。

**【真实源码摘录】** 同文件中的局部函数 `replace_exports(module_exports,export_fields)`：

```lua
local function replace_exports(module_exports, export_fields)
    for key in pairs(module_exports) do
        rawset(module_exports, key, nil)
    end
    for key, value in pairs(export_fields) do
        rawset(module_exports, key, value)
    end
end
```

这段看起来简单，却决定了重要的语义：

- **根表身份保留**：`logic`、规范名缓存和原始名缓存继续指向同一张 `live`。
- **完整字段替换**：V2 新增的字段会出现，V2 删除的旧字段会消失；这不是增量递归合并。
- **嵌套 table 身份不保证**：如果 V1 导出 `logic.settings` 为表 A、V2 导出新 `settings` 表 B，Commit 会令 `logic.settings=B`；但早已缓存 `local old_settings=A` 的代码仍持有 A。
- **缓存的旧函数不会自动更换**：已有 `old_attack` 变量保留旧函数；是否继续引用旧状态由闭包自己决定。

**【原理示意：Commit 前后】**

| 持有者                                   | Commit 前   | Commit 后                                                |
| ---------------------------------------- | ----------- | -------------------------------------------------------- |
| `logic` 变量                             | live 根表   | **同一个 live 根表**                                     |
| `package.loaded["lualib.player_logic"]`  | live        | **同一个 live**                                          |
| `logic.version`                          | V1 函数     | **V2 函数**                                              |
| `old_version = 曾经缓存的 logic.version` | V1 函数     | **仍是 V1 函数**                                         |
| `candidate`                              | V2 独立根表 | 仍独立，字段已被引用安装到 live                          |
| `state.weapon`                           | 刀          | **此时还没变**，需要随后 Service Patch 的 `update_state` |

这里最容易混淆的是最后一项。**Module Patch Engine 的 Commit 与 Service 状态更新是两个连续步骤**。不能在 Commit 后立即说“整次热更完成”。

## 第 12 章：从引擎返回 PlayerService，继续完成 Activate

我们已从 `commit()` 返回到 `flywow_hotupgrade.lua/handle_upgrade("update")`，Controller 仍在等这次 RPC。现在执行先前读过的代码剩余部分：

```lua
if service_patch then
    local service_update = module_state.registration_config.service_update -- register_service 提供的私有状态/函数更新合同。
    service_patch.touched = true
    if service_patch.update_state then
        service_patch.update_state()
    end

    for name, fn in pairs(service_patch.replace_functions or {}) do
        rawset(service_update.functions, name, fn)
    end
end

if module_state.registration_config.after_upgrade then
    assert(module_state.registration_config.after_upgrade() ~= false, "after_upgrade 拒绝更新")
end
```

现在 V2 Service Patch 的 `update_state()` 才真正运行，把旧 `state.weapon` 从刀改成剑，`schema_version` 从 1 改成 2；`state.gold=100`、`state.level=50` 自然保留。随后业务函数表中的 `attack` 字段被替换为 Patch 提供的新闭包。

本次旧 PlayerService 的状态变化可以完整列出来：

| 时点                                | `logic.version()` | `state.weapon` | `operations.attack(100)` | `old_attack(100)` | `hot.patching` |
| ----------------------------------- | ----------------- | -------------- | ------------------------ | ----------------- | -------------- |
| V1 正常运行                         | v1                | 刀             | 105                      | 105               | false          |
| Prepare 完成                        | v1                | 刀             | 105                      | 105               | true           |
| 正式文件部署完、尚未 Update         | v1                | 刀             | 105                      | 105               | true           |
| 普通模块 Stage 完成                 | v1                | 刀             | 105                      | 105               | true           |
| 模块 Commit 后、Service 更新前      | v2                | 刀             | 105                      | 105               | true           |
| `update_state/replace_functions` 后 | v2                | 剑             | 120                      | 100               | true           |
| Finish 完成                         | v2                | 剑             | 120                      | 100               | false          |

这张表是**依据代码推导的阶段快照**，不是声称这些中间状态都能通过普通业务 RPC 直接读取。恰恰因为 `hot.patching=true`，此时业务入口不应该能随意观察和修改中间状态。

`after_upgrade()` 返回 true 后，目标 Update RPC 成功返回 Controller。**Update 的成功不等于 Finish**，因为如果后面其他目标 Update 失败，Controller 仍需要使用旧快照向已经更新成功的目标发送 Abort。

## 第 13 章：回到 Controller，了解 PUBLISH_DECIDED 与 Finish

**恢复执行位置**：`flywow_hotupgrade_controller.lua/update_batch_targets()` 的 Update 循环。当前旧 PlayerService 已经返回成功；如果还有其他匹配目标，Controller 继续串行等待它们的 Update。全部成功后，`run_batch()` 调用 `finish_batch()` 作出发布决定。

**【真实源码摘录】** `finish_batch()` 的成功收尾逻辑：

```lua
local function finish_batch(controller, batch)
    -- 目标的 hotupgrade_result 在此记录 Finish 或退出结果；发布决定已作出，错误只影响收尾报告。
    batch.phase = "PUBLISH_DECIDED"
    for _, service_target in ipairs(batch.service_targets) do
        batch.current_service_handle = service_target.service_handle
        if not service_target.exited then
            service_target.hotupgrade_result = controller:step(batch, service_target, "finish")
        end
        if not service_target.hotupgrade_result.ok then
            batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED",
                service_target.hotupgrade_result.message or service_target.hotupgrade_result.code, {step = "finish"})
        end
    end
    batch.phase = batch.error and "RECOVERY_REQUIRED" or "COMPLETED"
end
```

`PUBLISH_DECIDED` 的含义：正式文件和全部目标 Update 已经确认成功，Controller 作出发布决定。随后逐个 Finish，不再采取整批回滚，因为此前成功 Finish 的目标可能已释放旧快照并开放业务。

全部目标 Update 均成功后，Controller 才进入 Finish；再跟踪接收方：`M:step` 通过 `skynet.call` 通知目标 → PlayerService `dispatch_upgrade_command()` → `handle_upgrade("finish")` → `finish_batch(batch)`：

**【真实源码摘录】** `flywow_hotupgrade.lua/finish_batch()`：

```lua
local function finish_batch(batch)
    -- Controller 仅在全部目标 Update 成功后发送 Finish；这里释放旧/新导出引用并开放业务入口。
    local finished = hotupgrade_module_patch.finish(batch.module_stage)
    close_batch(batch)
    return finished
end
```

Finish 中调用的 `close_batch(batch)` 定义在同一个 `flywow_hotupgrade.lua`，仍运行在 PlayerService 的 Lua State。进入它时，模块引擎已经完成本次 Finish；它负责结束本地批次记录和开放业务，返回后 finish_batch() 将结果交回 handle_upgrade()，再由 dispatch_upgrade_command() 回复 Controller。

**【真实源码摘录】** 同文件 `close_batch()` 的完整实现：

```lua
local function close_batch(batch)
    -- 本地完成序号和批次身份用于识别迟到或重复控制消息；释放 active_batch 后才重新接纳业务。
    module_state.completed_sequence = batch.sequence
    module_state.last_batch_id = batch.batch_id
    module_state.active_batch = nil
    M.patching = false
end
```

Abort 和控制异常也调用同一函数清理本地批次记录，避免不同出口分别维护序号、活动批次记录和 patching。

`module_patch.finish()` 释放记录中保留的旧导出与候选引用；然后清理 Service 本地批次记录，将 `patching=false`，新业务可以进入 queue。Controller 收到 Finish 回复，保存 `last_batch`、释放 `active_batch` 并唤醒生命周期门禁等待者。管理端的 `status(batch_id)` 最终读到 `COMPLETED`，我们 `run_normal()` 才继续创建第二个 PlayerService。

**这就闭合了第一条完整发布链路**：

```text
main/publish (管理 Service)
  └─ RPC begin → hotupgrade_service/dispatch → Controller/begin
       └─ fork run_batch
            ├─ 等在途创建与加载
            ├─ 读取并固定本批 Patch 内容、保存旧文件、匹配目标
            ├─ RPC prepare → dispatch_upgrade_command → handle_upgrade → prepare_batch → before_upgrade → queue 安全点
            ├─ 等在途依赖、最终重匹配
            ├─ batch.phase=UPDATE（关闭普通生命周期门禁）
            ├─ 部署完整 .lua → skynet.cache.clear
            ├─ RPC update → dispatch_upgrade_command → handle_upgrade → update_batch
            │    ├─ stage_service_patch_and_new_modules → require_module → load_and_register_module → register_new_module RPC
            │    ├─ module_patch.stage → live/old/candidate
            │    ├─ module_patch.commit → 原地覆盖普通模块根表字段
            │    ├─ update_state → 原地修改 Service 私有 state
            │    ├─ replace_functions → 更新业务函数表字段
            │    └─ after_upgrade → 结果返回 Controller
            ├─ PUBLISH_DECIDED
            └─ RPC finish → dispatch_upgrade_command → handle_upgrade → finish_batch → module_patch.finish → patching=false
main/status → COMPLETED → 验证旧 Service → 创建新 Service 并验证 V2
```

## 第 14 章：`new_modules` 为什么不能简单交给普通首次加载？

回想 Controller 在 Update 之前已经关闭普通首次加载门禁，而候选 V2 文件顶部需要加载 `combat_rules`。如果候选在 Update 中直接发起普通首次加载许可：

```text
Controller 正在等待 PlayerService 的 Update RPC 返回
PlayerService 的候选执行又等待 Controller 放开普通首次加载门禁
Controller 只有发布终态才放开门禁，而发布终态又依赖这个 Update 成功
=> 互相等待
```

这不是依赖文件尚未部署的唯一问题，也是**生命周期协议的并发问题**。当前设计有两个必要步骤：

1. Controller 先把本批完整 `.lua` 放入正式宿主目录并清理缓存，使 `combat_rules.lua` 确实能被搜索和加载。
2. PlayerService 在 Update 期间通过 Service Patch 的 `new_modules` 声明获得受控的新模块登记通道；这条通道不申请普通首次加载许可。

**实际调用者**：`flywow_hotupgrade.lua/handle_upgrade("update")` 分派到 `update_batch()`，再调用 `stage_service_patch_and_new_modules(batch,request.service_patch_source)`。后者先调用 stage_service_patch() 执行 Service Patch 构建函数，取得 `new_modules={"combat_rules"}`。清单中的每项在准备时解析身份，统一模块名直接填入 new_module_context.names，例如 a/b.lua 对应 a.b，解析结果按声明顺序保存到 new_module_identities；随后调用私有 `require_module(identity.name, identity)` 复用这些已确认的身份。公共 `M.require(name)` 仍负责检查新调用的模块名、解析身份，再进入同一个加载流程。

**【真实源码摘录】** `flywow_hotupgrade.lua` → `stage_service_patch_and_new_modules()` 中新模块清单处理逻辑：

```lua
local function stage_service_patch_and_new_modules(batch, service_patch_source)
    -- 清单保留到普通候选 Stage 结束；未声明的新依赖立即失败，不能申请普通许可后与本批 Update 互等。
    local new_module_context =
    {
        owner = coroutine.running(), -- 允许本批声明新模块加载的 Update 协程。
        batch_id = batch.batch_id,   -- Controller 当前发布批次身份，新模块登记时原样带回。
        names = {},                  -- 本批允许首次加载的模块统一名称集合。
    }
    batch.new_module_context = new_module_context
    local failure_code = "HU_SERVICE_STAGE_FAILED"
    local stage_succeeded, service_patch_or_error = pcall(function()
        if not service_patch_source then
            return nil
        end

        -- 先构建并核验完整声明清单，再加载模块，避免边加载边发现重复路径。
        -- 当前 Service 的更新定义；其中 new_modules 指定本批首次加载的模块。
        local service_patch = stage_service_patch(service_patch_source)
        -- 解析完成的模块文件身份；校验重复路径后直接用于加载，不再重新查找文件。
        local new_module_identities = {}
        for _, name in ipairs(service_patch.new_modules or {}) do
            -- 清单名称对应的真实文件身份；例如 a/b.lua 与 a.b.lua 都转换成 a.b，重复声明会被拒绝。
            local identity = resolve_module_identity(name)
            assert(not new_module_context.names[identity.canonical_name],
                "HU_DUPLICATE_MODULE: new_modules 重复指向同一文件: " .. identity.canonical_name)
            new_module_context.names[identity.canonical_name] = true
            new_module_identities[#new_module_identities + 1] = identity
        end

        -- 只有声明内的模块允许在 Update 期间首次加载；每次 require 仍完成正式登记。
        failure_code = "HU_NEW_MODULE_FAILED"
        for _, identity in ipairs(new_module_identities) do
            require_module(identity.name, identity)
        end
        return service_patch
    end)
    if not stage_succeeded then
        local cause = type(service_patch_or_error) == "table" and service_patch_or_error.ok == false and service_patch_or_error or nil
        batch.new_module_context = nil
        return flywow_result.failure(failure_code,
            cause and cause.message or tostring(service_patch_or_error), cause and {cause_code = cause.code} or nil)
    end
    return flywow_result.success(service_patch_or_error)
end
```

私有 `require_module` 检查当前 Update 协程的声明权限，再取得同模块加载锁，调用 `load_and_register_module()`。后者在许可 RPC 返回后用 `module_load_attempt.cache_snapshot` 保存原名与规范别名两个缓存槽，再调用 `load_module_exports()` 校验缓存、加载器路径和模块来源；随后建立别名与本地声明，完成 Controller 登记；失败先回退并抛出原错误。外层无论成功失败都先释放锁、唤醒等待者，再返回模块表或继续抛错。

**【真实源码摘录】** 同文件 `load_and_register_module()` 完成本地模块加载与声明后，发送本批新模块登记的逻辑：

```lua
elseif register_new_module and module_load_attempt.module_declaration_added then
    local answer = skynet.call(get_hotupgrade_handle(), "hotupgrade", "register_new_module", -- 管理命令的调用结果。
        {batch_id = new_module_context.batch_id, name = canonical_name})
    assert(answer.ok, "新模块登记失败: " .. tostring(answer.message))
end
```

**接收方**：`flywow_hotupgrade_controller.lua/M:register_new_module(request,source)`。它只允许当前活跃批次处于 UPDATE、`batch_id` 匹配，而且**消息来源是正在 Update 的目标 Service**；它把统一模块名（例如 a/b.lua 对应的 a.b）记录到该 Service 的注册元数据中。由于普通 Stage 目标集合在 Update 前已经确定，新增模块不会在当前批次被二次 Stage；下一批重新匹配后才能作为已有模块更新。

**真实限制**：若新增模块在本 State 同时被另一个普通首次加载协程占用，Update 不等待它走完可能被门禁阻断的路径，而是快速失败 `HU_MODULE_LOADING`。若候选尝试 `hotupgrade.require` 一个未声明、未登记的新依赖，则快速报 `HU_NEW_MODULE_NOT_DECLARED`，阶段错误保留在 `code`，根因码位于 `details.cause_code`。

### 第 14.1 节：原生 `require` 与 `hotupgrade.require` 的职责不同

Module Patch Engine 的候选 chunk 使用 Lua State 的默认全局环境，因此**原生 `require`** 可以按 Lua 原生规则查找依赖，并把新加载的模块留在 `package.loaded`。但它不会替 FlyWow 完成受控模块的路径登记或本批 `new_modules` 声明。凡是要作为 FlyWow 受管理的新模块参与后续更新的依赖，应遵守 `hotupgrade.require` 和清单合同。

同样，**Abort 不负责卸载已成功加载的新依赖或撤销初始化副作用**。如果本批后续失败，当前 Lua State 可能仍保留新模块登记，磁盘文件却已被恢复或删除。后续发布以这一真实现场继续，而不是假装新模块从未出现。

如果新模块自身的登记 RPC 失败，`load_and_register_module()` 会在把错误交回 Update 前恢复本次修改的 `package.loaded` 两个键、撤销本次新增的来源映射和本地声明；外层再释放该模块的本地加载锁。Controller 随后按失败流程 Abort 并恢复正式文件。若该 Lua 文件是本批新增，恢复后文件会被删除，重试前须由后续批次重新部署。Foundation 测试夹具保留文件，只验证 Lua State 的缓存回退和普通首次加载重试；真实 Skynet `new_modules_failure` 场景验证新增文件被删除且后续批次可继续。

## 第 15 章：引擎的 Abort 与 Finish，先建立准确边界

正常流程只调用 Stage→Commit→Finish；错误流程才会调用 Abort。为了理解下一部分的真实故障，先把两个函数看完整。

**【真实源码摘录】** `flywow_hotupgrade_module_patch.lua` → `M.abort(module_stage)` 的关键连续恢复逻辑：

```lua
local errors = {}
for _, entry in ipairs(module_stage.entries) do
    local ok, message = pcall(function() -- xpcall 的执行成功标志，用于最终决定进程退出码。
        assert(package.loaded[entry.name] == entry.live
            and getmetatable(entry.live) == nil,
            "模块缓存身份或元表变化: " .. entry.name)
        if module_stage.committed then
            replace_exports(entry.live, entry.old)
        end
    end)
    if not ok then
        errors[#errors + 1] = tostring(message)
    end
end
local finished = M.finish(module_stage) -- 等待本批排队业务和热更完成的终态记录。
if #errors > 0 then
    return flywow_result.failure(
        "HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
end
return finished
```

Abort 试图恢复**旧根表上的旧字段引用**，不是把整个 `package.loaded` 指针替换回“另一张旧表”。就算某个条目恢复失败，仍继续尝试其他条目，然后释放本轮引擎记录；不会永久占住 `active_module_stage`。

**【真实源码摘录】** 同文件 `M.finish(module_stage)`：

```lua
function M.finish(module_stage)
    -- active_module_stage 是本 State 的唯一在途暂存；清空 entries 释放旧导出与候选引用，不修改线上模块。
    if module_state.active_module_stage ~= module_stage then
        return flywow_result.failure(
            "HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end
    module_stage.entries = {}
    module_state.active_module_stage = nil
    return flywow_result.success()
end
```

Finish 只释放暂存记录，不重装旧字段。即使 Abort 已确认部分恢复失败，当前设计仍释放本批的引擎临时批次记录，使后续批次能够从当前状态重新开始。

**这一章结束时请记住四个不同层次的对象：**

- `package.loaded` 中的**模块根表**：原地更新，不换身份。
- `module_stage` 的**暂存记录**：仅在 Stage 到 Finish/Abort 期间持有旧字段、候选及状态迁移关联。
- PlayerService 的**私有 `state`**：由 Service Patch 更新，框架通过 Service 恢复数据尝试回退，不由 Module Patch Engine 直接管理。
- 已成功加载的**新依赖**：其加载和初始化不是普通模块 Abort 的全部回滚对象。

完成这条深入分支以后，我们返回完整的 Controller 发布链；接下来要回答一个尚未通过实验解释的问题：**业务正在运行和 yield 时，Prepare 凭什么说安全？**

---

# 第四部分：用真实并发实验看懂协程、Queue 和安全点

## 第 16 章：同一个 PlayerService，三个并发玩家请求

前面 V2 发布成功是最简单的情况：旧 PlayerService 没有正在处理的业务。现在我们不改框架，也不创建第二套 Sample，而是重新启动**同一套教学代码**，运行 `queue` 场景。

目标是制造三个具体的业务请求：

- **A：`hold`**，先取得业务 queue，记录自身协程，`skynet.wait()` 挂起，占着 queue 不释放；恢复后扣 10 金币。
- **B：`spend(20)`**，在发布开始前已经被业务入口接纳，却因为 A 占着 queue 而排队；获得执行权后扣 20 金币。
- **C：`spend(30)`**，Controller 开始 Prepare、`hot.patching` 已设为 true 后才到达，应直接返回 `HU_UPGRADING`，不进入 queue。

我们期待：A 返回 V1、金币 90；B 返回 V1、金币 70；C 被拒绝；Prepare 确认队列排空后才进行 V2；最终金币仍为 70，攻击变 120。

### 第 16.1 节：先认清 Skynet 中的两个独立协程执行位置

管理端 `main.lua/run_queue()` 先用 `skynet.fork` 创建协程 A 的**RPC 发起方**，然后在该协程中 `skynet.call(player,"lua","hold")`。PlayerService 收到这条 RPC 后，Skynet 在**PlayerService 的 Lua State** 中调度处理该消息的协程。管理端发起协程与目标处理协程并不是同一条。

目标中的 `business_queue` 来自 `require "skynet.queue"()`，属于**该 PlayerService 的 Lua State 内部**，不自动跨 Service 共享。A 在 queue 内调用 `skynet.wait()`，业务队列仍由 A 持有；B 只能等待 A 退出 queue。

`skynet.wait` 的语义是挂起当前协程等待相应唤醒，**不是**把业务 queue 的所有权释放给下一个请求。这与传统 C++ MMO 服务端中“异步任务等待 I/O”和“按玩家顺序串行执行业务命令”的关系相似：协程可以挂起，但业务上的排他执行权是否转移，取决于业务 queue 的实现，而不是协程 yield 本身。

### 第 16.1.1 节：直接看 `skynet.queue` 的真正排他机制

为了避免把“协程会 yield”误当成“业务锁自动释放”，我们进一步看 Skynet 官方实现。**执行上下文**：PlayerService 文件顶层 `require "skynet.queue"()` 创建一个 queue 实例；后续 `hold/spend/before_upgrade` 都调用这个实例返回的函数。

**【官方 Skynet 源码摘录】** [`lualib/skynet/queue.lua`](https://github.com/cloudwu/skynet/blob/1df1a6bbf57288743926a64b4e90bd1c64c301ca/lualib/skynet/queue.lua) 的核心逻辑；这是上游代码，实际运行仍以你本机配套 Skynet 的同名文件为准：

```lua
function skynet.queue()
    local current_thread
    local ref = 0
    local thread_queue = {}

    local function xpcall_ret(ok, ...)
        ref = ref - 1
        if ref == 0 then
            current_thread = table.remove(thread_queue, 1)
            if current_thread then
                skynet.wakeup(current_thread)
            end
        end
        assert(ok, (...))
        return ...
    end

    return function(f, ...)
        local thread = coroutine.running() -- 从 holding_thread 取出的协程句柄，交给 skynet.wakeup 唤醒。
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
```

注意三个变量的 owner 都是**这一条 queue 的闭包**，不是全局锁。`current_thread` 保存当前拥有 queue 的协程，`thread_queue` 是等待者集合，`ref` 支持同一协程在嵌套情形下重入 queue。

当 A 正在 `f` 内部 `skynet.wait()` 时，`xpcall(f, ...)` 尚未返回，`xpcall_ret` 根本还没有执行，`ref` 因而没有递减到 0。B 的 `current_thread ~= thread` 成立，于是把自身排入 `thread_queue` 再 wait。直到 A 最终从回调退出，`xpcall_ret` 才取出并唤醒下一个等待者。

所以业务安全点使用**同一个 queue 执行一个空操作**是有意义的：它轮到执行时，前面的 A/B 已经退出 queue。这不是凭借“目前看上去没有在运行的业务协程”来猜测安全。

### 第 16.2 节：业务代码从哪里被调用？

**【你之前已编写的 Sample；不新增文件】** `host_v1/service/player_service.lua` → `skynet.dispatch("lua",...)` → `command=="hold"` 分支：

```lua
elseif command == "hold" then
    if hotupgrade.patching then
        answer = {ok = false, code = "HU_UPGRADING"}
    else
        answer = business_queue(function()
            holding_thread = coroutine.running()
            skynet.wait(holding_thread)
            holding_thread = nil
            state.gold = state.gold - 10
            return {ok = true, gold = state.gold, version = logic.version()}
        end)
    end
```

`hold` 入口先检查 `hotupgrade.patching`，然后进入 queue；**两个操作之间没有主动 yield**。这保证了“是否接纳新业务”与“加入同一条受保护的 queue”之间没有由业务代码制造的明显等待窗口。

B 走同文件 `command=="spend"`，在通过入口检查后将 `waiting_spends` 加一，然后排队：

```lua
elseif command == "spend" then
    if hotupgrade.patching then
        answer = {ok = false, code = "HU_UPGRADING"}
    else
        assert(type(request.amount) == "number" and request.amount > 0)
        waiting_spends = waiting_spends + 1
        answer = business_queue(function()
            waiting_spends = waiting_spends - 1
            state.gold = state.gold - request.amount
            return {ok = true, gold = state.gold, version = logic.version()}
        end)
    end
```

这里 `waiting_spends` 是**课程专用观测计数**。它在业务已经通过入口、等待 queue 期间为 1；一旦 B 获得执行权就减少。它不是框架给业务自动维护的“所有请求数”。

### 第 16.3 节：时间线逐步推进，不能凭想象跳到 Finish

**【原理示意，按真实 Sample 的事件安排】**

```text
时间 →

管理端 fork A ──RPC hold──────────────┐
PlayerService A：进入业务 queue ──────┴─ wait，占有 queue ─────────────┐
                                                                       │
管理端 fork B ──RPC spend(20) ──────────────── 等待业务 queue ──────────┤
                                                                       │
管理端 begin(v2) → Controller：冻结 Patch → Prepare RPC ───────┐        │
目标 handle_upgrade(prepare)：patching=true                 │        │
目标 before_upgrade()：在同一个业务 queue 后面排队             │        │
管理端 C spend(30) → HU_UPGRADING，C 从未进入 queue             │        │
管理端 release RPC → skynet.wakeup(A)                          │        │
                                                                │        ▼
PlayerService A 继续：gold 100→90，退出 queue                  │   A 已完成
PlayerService B 取得 queue：gold 90→70，退出 queue              │   B 已完成
before_upgrade 获得 queue：return true ──Prepare RPC 返回──────┘
Controller：最终重匹配、关普通生命周期门禁、部署 V2 文件、清缓存
Controller：Update → 新模块登记 → Stage → Commit → Service 状态更新
Controller：Finish → patching=false → 业务恢复接纳
```

这里存在**三套不同的等待体系**，绝对不能混为一谈：

| 机制                    | 所有者             | 阻挡什么                              | 谁解除                       |
| ----------------------- | ------------------ | ------------------------------------- | ---------------------------- |
| 业务 `business_queue`   | PlayerService      | 先前已经被接纳的串行业务              | 当前持有 queue 的任务退出    |
| `hot.patching`          | PlayerService      | 后续新的业务入口                      | 本地 Finish/Abort 结束批次记录   |
| Controller 生命周期门禁 | HotUpgrade Service | 受管理 Service 创建、普通首次模块加载 | 当前发布批次结束后唤醒等待者 |

`hot.patching` 不会自动暂停已进入 queue 的 B；Controller 门禁也不等同于业务 queue。只有准确区分这三者，才能判断一个 Service 到底有没有到达安全点。

### 第 16.4 节：亲手执行并发实验

我们已经在最终版 `main.lua/run_queue()` 中写了完整的操作：fork A → 用教学 `peek` 确认 A 持有 queue → fork B → 确认 B 等待 → begin → 等待 `patching=true` → 发 C → release A → 等 A/B 结束 → 等待批次 `COMPLETED`。

运行：

```bash
bash hotupgrade/newsample/master_course/run.sh ../skynet queue
```

由于每次 `run.sh` 都从 V1 重建正式运行目录，不会继承上一次 `normal` 场景的已部署 V2 文件或已经更新的 Lua State。

预期关键输出：

```text
QUEUE_AFTER handle=... version=v2 weapon=剑 gold=70 schema=2 attack=120 old_attack=100
A V1 gold=90, B V1 gold=70, C HU_UPGRADING
MASTER_QUEUE_OK
```

如果卡在发布阶段，应该先问三个问题：A 是否实际进入了 `skynet.wait`？管理端是否发送了 `release`？`before_upgrade()` 是否确实使用业务请求共享的同一条 queue？若拿另一条 queue 或简单返回 `true` 来“凑过”安全点，虽然可能不再等待，但已经破坏了 HotUpgrade 的安全前提。

## 第 17 章：为什么 `skynet.fork()` 不自动受 queue 保护？

现在实验完成，回到实际 API 的执行边界。`skynet.fork(fn)` 在**当前 Service 的 Lua State** 新建可调度协程；但这个协程是否经过业务 queue，完全取决于 `fn` 中是否调用了同一 `business_queue(...)`。

如果原 PlayerService 在 `skynet.fork` 里直接修改 `state.gold`，同时 `before_upgrade` 只等待 queue，则这个独立 fork 不会天然被 Prepare 排空。它可能在模块或状态已经更新时继续用旧闭包写状态。

因此实际 MMO Service 接入需要统一的业务边界：所有需要和热更序列化的玩家状态操作，都应在业务入口检查 `hot.patching` 并经过同一个约定的 queue。确有长期独立任务时，应由业务显式安排其停止、排空或与安全点协调；不能假定 Skynet 自动替框架跟踪所有业务协程。

此时你应能独立回答：为什么已经排队的 B 可以在 Prepare 后继续完成，却不会被 `HU_UPGRADING` 拒绝？答案是：B 在 Prepare 设 `patching=true` 之前已经通过入口并加入 queue；Prepare 的安全栅栏排在 B 后面。C 在 Prepare 后才通过入口检查，因此直接被拒绝。

---

# 第五部分：主动制造故障，再通过后续正常热更修复

## 第 18 章：先明确我们选择的恢复合同

我们明确采用的设计不是永久锁定，也不是承诺所有对象一定回到某个旧版本：

1. 发布失败时，Controller 尽力恢复本批已经触及的正式文件，必要时清理缓存。
2. Controller 尽力向已经参加 Prepare 的目标发送内部 Abort。
3. 目标尽力恢复 Service 私有状态和函数，以及普通模块导出字段；新依赖成功加载及登记后不保证被撤销。
4. 恢复成功，批次报告 `ABORTED`；恢复失败或 Finish 收尾故障，报告 `RECOVERY_REQUIRED`。
5. **不因为这次恢复失败永久锁定 Controller**。当前批次释放临时批次记录与门禁，后续正常热更可以按实际状态再次实施修复。

这里的“允许继续”并非宣称所有历史问题已经解决：下一批成功只能证明下一批自己成功；修复包必须真正覆盖前次遗留问题。课程下一节就要把这点写成能运行的代码，而不止讲概念。

### 第 18.1 节：失败发生在哪里，恢复顺序如何？

先回到框架调用链：`update_batch_targets()` 中 Update RPC 失败后设置 `batch.error` 并返回，编排函数停止推进；`run_batch()` 随后调用 `recover_batch()`。

**【真实源码摘录】** `flywow_hotupgrade_controller.lua` → `recover_batch()` 的恢复核心逻辑：

```lua
local function recover_batch(controller, batch)
    -- batch.files 的 touched/old_source 决定文件恢复；目标列表的 participated/exited 决定哪些实例仍需 Abort。
    local recovery_errors = {}    -- 汇总所有恢复失败；单项失败不停止其余文件或目标恢复。
    local recovery_failure        -- 保留第一份结构化恢复错误，供最终结果携带诊断。
    local files_touched   = false -- 只有正式文件被替换后才需要清理文件缓存。

    -- 恢复后的文件供后续创建和首次加载使用；文件恢复失败也必须继续尝试目标 Abort。
    for index = #(batch.files or {}), 1, -1 do
        local file = batch.files[index]
        if file.touched then
            files_touched = true
            local restore_called, file_restored, restore_failure = pcall(hotupgrade_native.replace_file,
                controller.root_path, file.host_relative_path, file.old_source or nil)
            if not restore_called or not file_restored then
                recovery_failure = recovery_failure or flywow_result.failure(
                    restore_called and native_code(restore_failure) or "HU_CONTROL_FAILED", file.host_relative_path)
                recovery_errors[#recovery_errors + 1] = file.host_relative_path .. ": "
                    .. tostring(restore_called and native_code(restore_failure) or file_restored)
            end
        end
    end
    if files_touched then
        local cache_cleared, cache_failure = pcall(skynet.cache.clear) -- 正式文件全部替换后缓存清理是否成功。
        if not cache_cleared then
            recovery_failure = recovery_failure or flywow_result.failure("HU_CACHE_CLEAR_FAILED", tostring(cache_failure))
            recovery_errors[#recovery_errors + 1] = tostring(cache_failure)
        end
    end

    -- 再逆序撤销已参与且仍存活的目标；失败目标也不能跳过其余 Abort。
    for index = #batch.service_targets, 1, -1 do
        local service_target = batch.service_targets[index] -- 当前正在执行 Update 的目标 Service 记录。
        if service_target.participated and not service_target.exited then
            local restored = controller:step(batch, service_target, "abort")
            if not restored.ok and not service_target.exited then
                recovery_failure = recovery_failure or restored
                recovery_errors[#recovery_errors + 1] = service_target.service_handle .. ": "
                    .. tostring(restored.message or restored.code)
                service_target.hotupgrade_result = restored
            end
        end
    end

    if #recovery_errors > 0 then
        batch.error = flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(recovery_errors, "; "),
            {original_error = batch.error or recovery_failure, recovery_error = recovery_failure})
    end
    batch.phase = (#recovery_errors > 0 or batch.error.code == "HU_RECOVERY_REQUIRED")
        and "RECOVERY_REQUIRED" or "ABORTED"
end
```

先恢复文件，再清缓存，再 Abort 目标，是有具体原因的：在目标通过 Abort 解除 `patching` 之前，要尽量让正式宿主文件恢复到适当版本，避免重新开放业务时读取到已撤销批次的残留文件。本批新增的文件可以在恢复阶段被删除，目录本身可能留下空目录。

对比正常顺序：

```text
正常： Prepare → 关门 → 正式 .lua 部署 → 缓存清理 → Update → Finish
失败： 已出错 → 恢复 touched 文件 → 必要时清缓存 → 各目标 Abort → 报告终态
```

注意管理端**不存在**用于主动取消批次的 `abort` 命令；它返回 `HU_UNKNOWN_COMMAND`。此处 `abort` 是 Controller 发给参与目标的**内部恢复命令**，不是要求管理员人工解锁。

### 第 18.2 节：PlayerService 的 Abort 实际恢复什么？

**调用链**：Controller `M:step(...,"abort")` → PlayerService 的 `hotupgrade` dispatch → `handle_upgrade("abort")` → 同文件局部 `abort(batch)` → `restore_service(batch)` 与 `module_patch.abort(batch.module_stage)`。

**【真实源码摘录】** `flywow_hotupgrade.lua` → 局部 `abort(batch)` 的关键逻辑：

```lua
local function abort(batch)
    -- 先尝试恢复 Service 私有状态，再恢复模块导出；一个失败也继续另一项。
    local errors = {}
    local ok, message = pcall(restore_service, batch) -- xpcall 的执行成功标志，用于最终决定进程退出码。
    if not ok then
        errors[#errors + 1] = tostring(message)
    end

    if batch.module_stage then
        local restored = hotupgrade_module_patch.abort(batch.module_stage)
        if not restored.ok then
            errors[#errors + 1] = restored.message
        end
    end

    -- 本批尽力恢复后释放批次记录与临时门禁；错误只通过结果报告。
    close_batch(batch)
    if #errors > 0 then
        return flywow_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end
    return flywow_result.success()
end
```

它会先尝试恢复 Service 状态，再尝试恢复模块导出；**即使 Service 的恢复失败，也会继续尝试模块恢复**。最后释放批次记录、`patching=false`，将恢复失败通过结果报告出去。这正是我们选择“失败可继续修复，而不永久锁定”的实现。

其中 close_batch() 就是第 13 章已经沿 Finish 调用点进入过的同一个结束函数。此时返回到 handle_upgrade(`abort`)，结果再经目标 dispatch 回复 Controller；Controller 继续下一目标的 Abort，随后形成整批终态。

`restore_service(batch)` 中会分别处理状态与函数字段；即使自定义状态恢复抛错，它仍会在状态恢复的 `pcall` 之后尝试把已保存的旧业务函数字段重新安装，随后报告状态恢复错误。不要把“恢复失败”误解为“一个东西也没恢复”。

## 第 19 章：准备确定会失败的 `faulty` 批次

我们的正常 V1→V2 已完成，当前旧 PlayerService 是 V2：

```text
state.weapon = "剑"
state.schema_version = 2
state.gold = 100
logic.version() = "v2"
operations.attack(100) = 120
```

故障设计是这样：先通过教学 `inject_restore_failure` 使这一次的自定义 Service 状态恢复函数主动抛错；随后发布一个有意错误的 Service Patch，**Update 阶段把 schema 改为 99 并让 `after_upgrade` 拒绝提交**。Controller 会进行内部 Abort，但状态恢复失败，留下可观察的不一致状态。这样我们能够可靠地观察 `RECOVERY_REQUIRED`，再用 V3 批次继续修复。

这个故障只用于课堂，不模拟真实线上修改数据库或不可撤销外部副作用；我们只改 Service 自有的普通 Lua table。

创建目录：

```bash
mkdir -p hotupgrade/newsample/master_course/patches/faulty/service
```

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/faulty/service/player_service.patch`：

```lua
-- 课堂故障：故意提交不合法 schema，使 after_upgrade 返回 false。
return function(state)
    return
    {
        update_state = function()
            state.gold = 0
            state.schema_version = 99
        end,
        replace_functions =
        {
            attack = function(base_attack)
                return base_attack
            end,
        },
    }
end
```

为什么这个目录没有完整 `.lua` 文件？因为当前 HotUpgrade 合同允许**只有 Service Patch 的发布包**，前提是 `.patch` 能匹配已登记且支持 Service 更新的目标。此次只想修改旧实例的 Service 状态与业务函数，不需要部署新 Service 文件。

接下来是真实执行路径：

```text
Controller begin("faulty")
 → 识别只含 .patch 的发布包，匹配现存 player_service
 → Prepare，取得安全点
 → UPDATE；batch.files 为空，因此没有正式 .lua 替换
 → PlayerService stage_service_patch：构造更新回调并保存状态快照
 → module_patch.stage([]) / commit([])：本次没有旧普通模块需要更新
 → update_state：gold=0、schema_version=99
 → replace_functions：临时将 attack 换成直接返回 base_attack 的函数
 → after_upgrade：返回 false，Update 失败
 → Controller 发内部 Abort
 → 自定义 restore 因教学开关而报错；旧函数字段仍尽力恢复
 → 模块 Abort 尽力结束，Controller 汇总错误并报告 RECOVERY_REQUIRED
 → 本地 patching=false，Controller 回到 IDLE，后续发布可以继续
```

**故障后的实际现场预期**：`gold=0`、`schema_version=99` 尚未恢复，`logic.version()` 仍是 V2（本批没有普通模块更新），业务函数字段已经尝试恢复，Controller 不保持永久锁定。这里的关键不是“回滚做得不够”，而是**我们确实知道哪些数据没恢复，并允许下一次具有明确内容的更新去修它**。

## 第 20 章：V3 前向修复必须从实际状态出发

不能直接把正常 V2 Patch 再执行一次就宣称修好了，因为它明确要求 `schema_version==1`，而我们上一批之后的真实状态是 99。**前向修复必须按受损现状设计新的 Patch**。

我们要把当前状态推进到一个明确的 V3：

```text
weapon = "霜剑"
schema_version = 3
gold = 88
attack(100) = 125
```

这里的金币 88 是教学中的**明确修复目标值**，不是自动从失败之前的金币推算出来的。如果实际商业 MMO 的金币属于权威持久化数据，恢复目标应由业务的可靠数据来源确定，不能凭空写 88。课堂只为验证“后续更新可覆盖受损状态”。

创建目录：

```bash
mkdir -p hotupgrade/newsample/master_course/patches/v3/lualib
mkdir -p hotupgrade/newsample/master_course/patches/v3/service
```

### 第 20.1 节：完整 V3 普通模块

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v3/lualib/player_logic.lua`：

```lua
-- V3：完整普通模块；本版“霜剑”给予 25 点加成。
local M = {} -- 候选模块的导出根表，return 后用于本次候选提交。

function M.version()
    return "v3"
end

function M.make_attack(state)
    return function(base_attack)
        return base_attack + (state.weapon == "霜剑" and 25 or 0)
    end
end

return M
```

注意这是一份完整的新导出，不是只提供 `version()` 的增量片段。Commit 会清除线上根表旧字段，再安装 V3 完整字段集合。如果你省掉以后仍需要的 `make_attack`，即使它曾在 V2 中存在，Commit 后也会消失。

### 第 20.2 节：给未来新实例准备完整 V3 Service 文件

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v3/service/player_service.lua`：

```lua
-- V3 PlayerService：新实例通过正式部署的 V3 入口初始化。
local skynet = require "skynet" -- 当前 Service 使用的 Skynet API。
local business_queue = require "skynet.queue"() -- 业务串行队列；业务处理和热更安全点都经过它。
local hotupgrade = require "flywow_hotupgrade" -- 当前 Service 的受控模块加载、登记和生命周期 API。

local logic                 -- 首次 init 后的普通模块根表；热更保持表身份。
local state                 -- 玩家私有数据根表；由 Service Patch 原地修改。
local operations            -- 现有业务函数表；Patch 只替换指定函数。
local state_identity        -- 保存最初状态根表，用于观察身份是否稳定。
local old_attack            -- 缓存这个 Service 创建时的初始闭包，用于观察旧函数引用。
local registered = false    -- register_service 真正成功后才允许业务请求。
local holding_thread        -- hold 占用 queue 时正在 wait 的业务协程。
local waiting_spends = 0    -- 已通过入口但尚未拿到 queue 的 spend 请求数量。
local fail_restore = false  -- 只用于故障实验，正常运行恒为 false。

--- 返回 PlayerService 当前版本、私有状态和函数引用的观测快照。
local function inspect_state()
    return
    {
        ok = true,
        handle = skynet.self(),
        version = logic.version(),
        weapon = state.weapon,
        level = state.level,
        gold = state.gold,
        schema_version = state.schema_version,
        attack = operations.attack(100),
        old_attack = old_attack(100),
        state_same = state == state_identity,
        module_alias_same = package.loaded["lualib.player_logic"] == logic,
        combat_loaded = package.loaded["lualib.combat_rules"] ~= nil,
        patching = hotupgrade.patching,
    }
end

--- 声明业务模块和私有状态，最后登记当前 PlayerService。
local function initialize_player()
    if registered then
        return {ok = false, code = "ALREADY_INITIALIZED"}
    end

    logic = hotupgrade.require("player_logic")
    state =
    {
        weapon = "霜剑",
        level = 50,
        gold = 100,
        schema_version = 3,
    }
    operations = {attack = logic.make_attack(state)}
    state_identity = state
    old_attack = operations.attack

    local answer = hotupgrade.register_service( -- 管理命令的调用结果。
    {
        service_update =
        {
            state = state,
            functions = operations,
            -- 课堂故障需要显式控制恢复失败，所以这里使用成对自定义快照。
            snapshot = function(source)
                return require("flywow_result").success(
                {
                    weapon = source.weapon,
                    level = source.level,
                    gold = source.gold,
                    schema_version = source.schema_version,
                })
            end,
            restore = function(destination, snapshot)
                if fail_restore then
                    error("injected restore failure")
                end
                for key in pairs(destination) do
                    destination[key] = nil
                end
                for key, value in pairs(snapshot) do
                    destination[key] = value
                end
                return require("flywow_result").success()
            end,
        },
        before_upgrade = function()
            -- 必须排在所有已接纳业务之后取得同一条 queue。
            return business_queue(function() return true end)
        end,
        after_upgrade = function()
            -- 同步状态检查；故障实验把 schema 改成 99，以触发 Update 失败。
            return state.schema_version ~= 99
        end,
    })
    registered = answer.ok
    return answer
end

skynet.start(function()
    skynet.dispatch("lua", function(session, _source, command, request)
        request = request or {}
        local answer -- 管理命令的调用结果。

        if command == "init" then
            answer = initialize_player()
        elseif not registered then
            answer = {ok = false, code = "NOT_INITIALIZED"}
        elseif command == "inspect" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(inspect_state)
            end
        elseif command == "peek" then
            -- 教学观测口：只读、不进入业务 queue，避免观察者自身被 queue 挡住。
            answer =
            {
                ok = true,
                holding = holding_thread ~= nil,
                waiting_spends = waiting_spends,
                patching = hotupgrade.patching,
                gold = state.gold,
                schema_version = state.schema_version,
            }
        elseif command == "hold" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                answer = business_queue(function()
                    holding_thread = coroutine.running()
                    skynet.wait(holding_thread)
                    holding_thread = nil
                    state.gold = state.gold - 10
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "release" then
            -- 教学控制消息必须独立于业务 queue，否则无法唤醒被占用的 queue。
            if holding_thread then
                local thread = holding_thread -- 从 holding_thread 取出的协程句柄，交给 skynet.wakeup 唤醒。
                holding_thread = nil
                skynet.wakeup(thread)
                answer = {ok = true}
            else
                answer = {ok = false, code = "NOT_HOLDING"}
            end
        elseif command == "spend" then
            if hotupgrade.patching then
                answer = {ok = false, code = "HU_UPGRADING"}
            else
                assert(type(request.amount) == "number" and request.amount > 0)
                waiting_spends = waiting_spends + 1
                answer = business_queue(function()
                    waiting_spends = waiting_spends - 1
                    state.gold = state.gold - request.amount
                    return {ok = true, gold = state.gold, version = logic.version()}
                end)
            end
        elseif command == "inject_restore_failure" then
            -- 课堂故障开关；不作为框架或实际业务管理 API。
            fail_restore = request.enabled == true
            answer = {ok = true}
        else
            answer = {ok = false, code = "UNKNOWN_COMMAND"}
        end

        if session ~= 0 then
            skynet.retpack(answer)
        end
    end)
end)
```

这里新 Service 的初始金币仍是 100，而修复后的旧实例金币是 88。它们是**两个不同的 PlayerService 实例**，演示中创建了两个独立玩家状态，金币不必相同；共同需要一致的是业务结构版本、攻击规则和模块代码版本。不要把“多 Service 都使用 V3”误读成“所有玩家必须拥有相同金币”。

### 第 20.3 节：一次性 V3 修复 Patch

**【你要编写：完整文件】** `hotupgrade/newsample/master_course/patches/v3/service/player_service.patch`：

```lua
-- V3 前向修复：显式接纳已损坏的当前状态，推进到健康版本。
return function(state)
    return
    {
        update_state = function()
            -- 不假设上一批已完整回滚到 schema 1 或 schema 2。
            assert(type(state.schema_version) == "number",
                "当前玩家状态缺少可识别的 schema_version")
            state.weapon = "霜剑"
            state.schema_version = 3
            state.gold = 88
        end,
        replace_functions =
        {
            attack = function(base_attack)
                return base_attack + (state.weapon == "霜剑" and 25 or 0)
            end,
        },
    }
end
```

这份 Patch 是一个明确的**向前修复版本**，而不是反向执行旧 V2 的假回滚。当前正式 `player_logic.lua` 将从 V2 更新为 V3，现存 Service 的状态和攻击函数也被推到 V3；未来创建的新实例从完整 V3 `player_service.lua` 启动。

## 第 21 章：亲手运行故障→诊断→后续修复的完整链

现在你已经写完 `faulty` 和 `v3`，不需要再改 `main.lua`；最终版管理端的 `run_forward()` 已按真实场景顺序实现了所有操作。

```bash
bash hotupgrade/newsample/master_course/run.sh ../skynet forward
```

预期关键输出（批次 ID 与 handle 不固定）：

```text
BEGIN v2 batch=...
END v2 phase=COMPLETED error=nil
BEGIN faulty batch=...
END faulty phase=RECOVERY_REQUIRED error=HU_RECOVERY_REQUIRED
DAMAGED handle=... version=v2 weapon=剑 gold=0 schema=99 attack=120 old_attack=100
BEGIN v3 batch=...
END v3 phase=COMPLETED error=nil
REPAIRED handle=... version=v3 weapon=霜剑 gold=88 schema=3 attack=125 old_attack=100
NEW_V3 handle=... version=v3 weapon=霜剑 gold=100 schema=3 attack=125 old_attack=125
MASTER_FORWARD_OK
```

这段实验的每个验收点都有明确来源：

| 时刻             | 关键状态                               | 由哪个代码路径导致                              |
| ---------------- | -------------------------------------- | ----------------------------------------------- |
| 正常 V2 完成     | `version=v2`、`schema=2`、`gold=100`   | Controller 正常发布、Service Update/Finish      |
| faulty Update 后 | `schema=99`、`gold=0`                  | `faulty` Patch 的 `update_state`                |
| faulty Abort 后  | `RECOVERY_REQUIRED`、状态仍坏          | `restore` 人为报错，但释放批次记录与门禁            |
| 进入下一批 `v3`  | 不需管理端 `resolve_deployment`        | Controller 没有永久失败锁定                     |
| V3 完成          | `version=v3`、`schema=3`、`gold=88`    | 新的完整 Lua + Service Patch 从真实状态继续修复 |
| 新建 V3 Service  | `version=v3`、`schema=3`、`attack=125` | 使用已正式部署的 V3 Service 入口与模块          |

注意“修复成功”的范围：**我们确认的是这次被明确修改并验证的玩家状态和逻辑**。如果此前失败还破坏了其他未被本次 Patch 涉及的对象，下一批成功不会自动修复它们。这恰好是前向修复策略的真实工程边界。

### 第 21.1 节：为什么 `recovery_required` 可以在下一批后变为 false？

**【真实源码摘录】** `flywow_hotupgrade_controller.lua` → `complete_batch()` 的终态保存逻辑：

```lua
batch.target_service_count = #batch.service_targets
batch.service_targets = nil
batch.files = nil
batch.modules = nil
batch.service_patches = nil
controller.last_batch = batch
controller.active_batch = nil
controller:wake_lifecycle()
```

complete_batch() 在这里释放冻结源码和恢复快照，将同一个 batch 保留为 last_batch，然后唤醒门禁等待者。 成功/失败计数在 status 查询时由 service_results 统计，不再额外保存在 batch；活动期间目标数量从 service_targets 的长度计算，complete_batch() 释放列表前才保存 target_service_count 终态快照。管理端下次发送 status 时，消息重新进入 Controller 的 handle_command(`status`)，该路由调用 handle_status_request(controller, request)，由查询函数从 last_batch 和活动批次生成恢复诊断：

查询函数入口的 lifecycle_batch 取值为 controller.active_batch or controller.last_batch，表示当前活动批次；没有活动批次时指向最近终态。下面的代码读取它以及 controller.last_batch，生成返回给管理端的布尔值。

**【真实源码摘录】** `handle_status_request()` 中恢复诊断的生成逻辑；`M:handle_command()` 的 status 分支只分派到此函数：

```lua
local recovery_required = controller.last_batch ~= nil and controller.last_batch.phase == "RECOVERY_REQUIRED"
if controller.active_batch and lifecycle_batch.phase == "PUBLISH_DECIDED" and lifecycle_batch.error then
    recovery_required = lifecycle_batch.error.code == "HU_RECOVERY_REQUIRED"
end
```

faulty 结束后 last_batch.phase 为 RECOVERY_REQUIRED；V3 进行中仍能看到该最近终态的诊断，若当前批次 Finish 又出错也会报告。V3 成功结束后，同一个 last_batch 引用改为 V3 批次，其 phase 为 COMPLETED，下一次查询自然得到 false。Controller 不再保存需要同步更新的 recovery_required 字段。

它只保留最近一批的结果，不持久化历史；字段表达的是**最近一批是否报告恢复问题**，而不是系统全部历史故障都已消失。我们的教学管理端把 `faulty` 的错误先观察、打印，才进行 V3。实际生产环境要将关键错误可靠留存、结合业务数据判断修复范围；这不意味着必须给框架增加解锁协议或永久锁定。

---

# 第六部分：失败边界、源码排查、验收与独立维护

## 第 22 章：其它典型失败发生时，程序到底走到哪一步？

我们的 `forward` 实验实际运行了 Update 失败与 Abort 失败的链路。要形成完整的模块维护能力，还需要清楚其他故障分支的**发生顺序与状态边界**。这一章仍使用同一套 `master_course` 概念模型，不引入第二套 Sample；其中没有亲手注入的场景会明确标注为**源码推演**，不冒充实际运行结果。

### 22.1 发布包本身不合法

**调用位置**：Controller `load_and_snapshot_batch_files()` → `M:load_patch()` → `freeze_patch_files()` → Patch 文件扫描、路径匹配、语法检查。比如 `.patch` 语法不合法、源路径含非法结构、`.patch` 放错目录、Service Patch 找不到匹配的受管理目标。

**结果**：错误发生在目标 Prepare 之前；Controller 尚未向目标发控制命令，也尚未部署正式 `.lua`。批次按具体错误结束；如果业务尚未被触及，就没有“需要恢复运行中玩家状态”的理由。

排查这类失败时结合稳定错误码、失败消息和批次目标/结果字段确认故障阶段；不要仅凭终态 phase 推断目标是否已处理，因为 phase 只保存当前或最终阶段。

### 22.2 某个目标 Prepare 失败

**调用位置**：`prepare_batch_targets()` 的 Prepare 循环 → `M:step(batch,service_target,"prepare")` → PlayerService `before_upgrade()`。例如业务 queue 中某个任务一直不结束、回调抛错、拒绝安全点。

这里要严格区分“等待很久”与“失败返回”：框架没有根据固定等待秒数自动把未完成的业务强制认为已排空。单纯无法取得 queue，可能使 Prepare 持续等待，而非马上报告错误；如果回调实际返回失败，则进入 Abort。

**源码推演**：已参与目标需要执行内部 Abort 来释放其 `patching`；尚未开始正式文件部署，因此没有本批已部署文件需要撤回。对于旧业务仍占用 queue 的情况，不应靠强行跳过安全点解决。

### 22.3 正式文件部署在中途失败

**调用位置**：`deploy_batch_files()` 的文件循环，调用 `hotupgrade_native.replace_file(root,host_relative_path,source)`。假设本批需要部署 `player_logic.lua`、`combat_rules.lua` 和 `player_service.lua`，前两个写入成功，第三个失败。

此时**一个目标 Update RPC 都还没有发送**。但是宿主磁盘已经局部改变，需要按 `file.touched` 逆序恢复，新增的 `combat_rules.lua` 若原来不存在就应该删除，恢复已触及文件后清缓存，再 Abort 已 Prepare 的业务 Service。

为什么不是简单清空 `package.loaded`？因为不同 Service 有独立 Lua State，而且已存在的对象持有模块表、函数和闭包引用；任意清缓存并不能恢复这些旧引用，还可能制造第二套不受控模块表。

这一路径已有仓库内真实测试覆盖，可在源码中找到：

- `hotupgrade/tests/test_controller.lua` 的 `resources` 场景：模拟某个文件部署失败，检查旧文件恢复、新增文件删除、已 Prepare 目标收到 Abort。
- `hotupgrade/tests/skynet_hotupgrade.lua` 的 `deploy_failure` 场景：在真实 Skynet 进程中制造一个目标文件路径不可正常替换的现场，验证文件及 Service 恢复。

这些是**框架已有的测试**，不是我们的 `master_course` 私有脚本；本课程介绍它们用于源码证据和扩展验证，不要求你阅读其它旧课程。

### 22.4 缓存清理失败

**调用位置**：正式文件已经部署之后、任何目标 Update 之前，Controller 调用 `pcall(skynet.cache.clear)`。

如果这里失败，当前发布批次停止继续发送 Update，进入文件恢复与缓存恢复流程，再 Abort 已 Prepare 目标。若恢复阶段再次清缓存也失败，则同时报告恢复故障。不能把“第一次清缓存失败”直接当成“已经更新了一半内存模块”；此时目标 Update 尚未开始。

### 22.5 第二个 Service 的 Update 失败

**源码推演**：假设有两个受管理 `PlayerService` 实例，A 和 B 都受 `lualib.player_logic` Patch 影响：

```text
A: Prepare 成功
B: Prepare 成功
Controller: 正式文件全部部署并清缓存
A: Update 成功，已提交 V2，但保留旧快照，patching=true
B: Update 失败，可能已经局部修改自身状态
Controller: 恢复文件并清缓存
Controller: 对所有已参与目标逆序 Abort（先 B 后 A）
A/B: 尽可能恢复各自的旧对象，释放本地批次记录
Controller: 报告 ABORTED 或 RECOVERY_REQUIRED
```

“Update 成功”只是目标 A 在自己的 Lua State 中完成本地更新，并不意味着整批作出了 `PUBLISH_DECIDED`。它仍需等待其它目标确认，才轮到 Finish 释放旧快照。

不同 Service 的 Lua State 中 `logic` 是不同的 Lua table：**保留的是各自 State 内的根表身份**，并不是所有 Service 共享同一个 Lua table 指针。

### 22.6 Finish 失败、RPC 结果不明

**调用位置**：Controller 已进入 `PUBLISH_DECIDED`，向某目标发送 Finish。目标可能返回失败，也可能发生 RPC 异常，Controller 无法明确知道目标是否已成功释放旧快照。

为什么不再全批回滚？因为其它目标可能已经成功 Finish、开放业务、清理本地旧快照。此时强行假定所有目标都可回到 V1，将违反当前设计的真实时序。Controller 尝试剩余目标 Finish，记录 `RECOVERY_REQUIRED`，结束批次；后续修复发布以实际现场为基础。

### 22.7 `new_modules` 登记后的候选 Stage 失败

**源码推演**：我们的 V2 Service Patch 已将 `combat_rules` 成功加载并登记，然后普通模块 `player_logic` 的候选顶部抛错。

失败后框架可以恢复受控的旧 `player_logic` 导出、Service 状态、正式文件，但成功加载的新模块及初始化副作用**可能仍在旧 PlayerService 的 `package.loaded` 与登记元数据中**。后续批次把这种现状当成真实起点，不承诺卸载它。

这就是你已经接受的恢复边界，也解释了为什么故障排查不能只比较磁盘两份 `.lua` 文件是否相同。

### 22.8 目标 Service 在 Prepare/Update/Finish 期间退出

这是一个重要但不应改造为通用超时/重试系统的边界。HotUpgrade Service 的入口 `hotupgrade/service/flywow_hotupgrade_service.lua` 在 Controller 初始化成功后使用 Skynet 原生 `MONITOR` 接收 Service 退出通知。退出消息来源 `source` 是真实退出的 Service handle；接收方调用 Controller `on_service_exit(source)` 清理登记和在途记录，并调用原生 `skynet.term(source)` 解除控制面对此已退出目标的挂起 RPC。

该逻辑与业务 `skynet.queue` 完全不同：它处理的是**Service 生命周期终止**，不是已有业务请求的正常排空。目标在 Prepare、Update 或 Finish 期间退出，Controller 按实际已知的 RPC 结果推进并报告相应失败/收尾诊断；它不假定退出通知与 RPC 异常的到达顺序固定。

如果宿主进程里别的模块已经占用了 Skynet 的进程级 `MONITOR`，Controller 初始化会报告 `HU_MONITOR_OCCUPIED`，不能偷偷覆盖其它模块的监视器。这个限制需要在真实服务器 composition root 组装时处理，但不需要为教学 Sample 再造监控服务。

## 第 23 章：Native、缓存和源码身份——最后三个容易混淆的边界

### 23.1 Native 模块究竟负责什么？

路径 `hotupgrade/native/hotupgrade_native.cpp` 是 Native 实现；它编译为 `build/native/flywow_hotupgrade_native.so`，通过 `require "flywow_hotupgrade_native"` 供 Controller 和业务入口调用。

它主要提供可信路径解析、发布文件扫描与同步文件读写/替换等能力。跨多个 Service 协调 Prepare/Update/Finish 的策略在 Lua Controller 内，不应把 Native 文件接口误认为“热更批次协调器”。

例如 `deploy_batch_files()` 把冻结好的 `file.source` 交给 `hotupgrade_native.replace_file()`；Native 只负责按接口合同处理该文件，**是否继续更新、失败如何 Abort、是否标记 RECOVERY_REQUIRED** 属于 Controller 的职责。

不要把 `replace_file` 误当作对所有已加载 Lua 模块即时替换：磁盘字节变化、Skynet Service 源码缓存变化、目标 Lua State 中的模块根表变化，是三种不同的事情。

### 23.2 `skynet.cache.clear()` 为什么不等于热更所有 Lua State？

Controller 在部署正式 Lua 文件后清理 Skynet 的相关源码缓存，使后续 Service 创建能够读取新入口文件；目标当前 Lua State 的 `package.loaded`、`logic` 变量以及已有业务闭包并不会因为这一调用而自动统一变化。

因此：

- **新 Service**：由正式部署的完整 V2/V3 Service 入口启动，按自己的 Lua State 正常 require 模块。
- **旧 Service**：通过 Controller 的 Update RPC 在自己的 Lua State 内执行 Module Stage/Commit 与 Service Patch，保持已有业务对象身份。

我们的 `run_normal()` 同时验证了这两种路径。二者结果可以相同，但机制绝不相同。

### 23.3 模块名身份如何从路径产生？

**【真实源码位置】** `flywow_hotupgrade.lua` → `resolve_module_identity(name)`，公共 `M.require(name)` 检查模块名后调用；new_modules 的准备阶段也调用它，后续直接复用身份记录。

当前接口并非直接给普通 require 名称加一个固定前缀，而是先用 `package.searchpath(name,package.path)` 找到源码，再用 Native `resolve` 得到规范化路径，并验证它位于 Controller 配置的 `root_path` 内。最后对路径去掉 `.lua` 并把 `/` 转为 `.`，生成规范登记名。

在我们的 Sample 中：

```text
普通 require 名：player_logic
实际文件：.../build/hotupgrade-master-course/host/lualib/player_logic.lua
root_path：.../build/hotupgrade-master-course/host
相对路径：lualib/player_logic.lua
规范登记名：lualib.player_logic
```

入口已经确认且未改变的模块名、路径和返回合同，内部链路直接复用。检查仍保留在新事实产生的位置：Service Patch 返回表、自定义快照、候选导出必须在执行代码后检查；申请许可、等待其他协程或执行 require 之后，缓存来源、别名和模块身份可能改变，需要在使用处重新核对。目标控制消息还必须检查真实来源、当前批次和序号。这些检查与重复验证一份未变化的输入具有不同用途。

因此 `package.loaded["player_logic"]` 与 `package.loaded["lualib.player_logic"]` 应指向**同一张被 HotUpgrade 确认来源的模块表**。单纯先用普通 `require` 占据缓存、以后再让 `hotupgrade.require` 认领一个来源不明的对象，不在当前合同支持范围内。

## 第 24 章：以后自己排查热更，先沿着这张检查地图走

不要一看见错误码就随机打开十几个文件。先判断失败停在哪个控制阶段，再顺着当时的调用链定位。

| 现场                           | 首先检查的真实文件/函数                                                        | 核心判断                                                        |
| ------------------------------ | ------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| Controller 无法初始化          | `hotupgrade/service/flywow_hotupgrade_service.lua` 的 `lua/init`               | Native 搜索路径、配置及 MONITOR 是否允许初始化                  |
| Service 没被热更匹配           | `flywow_hotupgrade_controller.lua` 的 `load_patch/match_service_targets`               | 是否受管理创建、已登记、模块名和 `.patch` 路径是否匹配          |
| 首次 `hotupgrade.require` 失败 | `flywow_hotupgrade.lua/M.require`、`resolve_module_identity`                   | 原名/规范名/真实路径/许可/缓存占用                              |
| 一直停在 `WAITING_CREATIONS`   | Controller `run_batch/wake_batch`                                              | 在途 Service 创建或首次模块登记是否正常结束                     |
| 一直停在 Prepare               | 目标 `prepare_batch()`、业务 `before_upgrade`                        | 是否已有请求永久占有 queue；是否正确使用同一条 queue            |
| 创建/首次加载在 Update 等待    | Controller `lifecycle_closed/wait_lifecycle`                                   | 是否处于预期的关门阶段，还是业务绕开了显式新模块清单            |
| 新模块首次加载失败             | `stage_service_patch_and_new_modules`、`require_module`、Controller `register_new_module` | 是否在 `new_modules` 声明，是否当前目标、是否有并发首次加载冲突 |
| Stage 失败                     | `flywow_hotupgrade_module_patch.lua/M.stage`                                   | 候选语法、导出根表、依赖、私有状态钩子                          |
| Commit 或 Activate 失败        | `M.commit` 和目标 `update_batch()`                                   | 模块身份是否稳定、Service 状态更新/回调是否抛错                 |
| 文件部署/清缓存失败            | Controller `M:run_batch` 和 Native `replace_file`                              | 哪些文件 touched，恢复是否成功                                  |
| Abort 失败                     | 目标 `abort/restore_service`、`module_patch.abort`                             | 具体哪份状态或模块字段没恢复                                    |
| Finish 失败                    | Controller 的 `PUBLISH_DECIDED` 以后、目标 `finish_batch()`          | 已有目标是否释放快照，是否进入 RECOVERY_REQUIRED                |

注意结果对象中的 `code` 和 `details.cause_code` 语义：前者通常表示当前阶段的错误类型；后者在有明确传播原因时表达内层异常根因。**不能依赖解析日志中文字符串来判断业务错误类型**。如果异常由候选代码用 `pcall` 捕获，后续另一种失败不能沿用先前已经被捕获的 `details.cause_code`。

### 日志和验证顺序

1. 先看 `build/hotupgrade-master-course/course.log`，确认哪个阶段最后出现了有意义的日志。
2. 看 `status(batch_id).value.record.phase/error`；如果 `record.error.details` 中有 `original_error` / `recovery_error`，要分别看首次故障和恢复故障。
3. 检查 file.touched 对应的文件恢复结果；它是 Controller 用来定位本批已成功替换文件的内部标记。
4. 进入相应的真实函数，沿调用者和返回路径复现，而不是孤立阅读错误语句。
5. 判断原 Service、正式文件、新 Service、`package.loaded` 和业务状态**分别**是否已经更新或恢复。
6. 对后续修复包，明确它要覆盖的真实状态和验证项，不能默认历史问题都已消失。

## 第 25 章：完整实验清单与自己应该得到的答案

我们没有给你一个不可拆分的巨大脚本，而是按阶段完成了一套独立工程。现在从 FlyWow 仓库根目录执行以下四次，每次脚本会重置独立的运行目录：

```bash
bash hotupgrade/newsample/master_course/run.sh ../skynet v1
bash hotupgrade/newsample/master_course/run.sh ../skynet normal
bash hotupgrade/newsample/master_course/run.sh ../skynet queue
bash hotupgrade/newsample/master_course/run.sh ../skynet forward
```

| 实验      | 成功标记            | 必须亲自确认的现象                                                   |
| --------- | ------------------- | -------------------------------------------------------------------- |
| `v1`      | `MASTER_V1_OK`      | V1 真实运行；模块别名、状态根表有效                                  |
| `normal`  | `MASTER_NORMAL_OK`  | V2 更新，旧 handle 不变，模块和状态符合合同，新实例直接 V2           |
| `queue`   | `MASTER_QUEUE_OK`   | A/B 先以 V1 完成，C 被拒绝，Prepare 后才升级                         |
| `forward` | `MASTER_FORWARD_OK` | faulty 报 RECOVERY_REQUIRED 后无需解锁，V3 修复旧实例且新实例使用 V3 |

### 25.0 进一步验证现有框架测试（可选，不依赖旧教程）

如果你的仓库已经按当前项目标准布局接入 `Server/third_party/skynet-flywow`，还可以在 **FlyWow 根目录**额外运行框架自带的完整测试套件：

```bash
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/scripts/run_hotupgrade_tests.sh ../skynet
```

此脚本位于当前仓库 `hotupgrade/scripts/run_hotupgrade_tests.sh`，会执行模块引擎/Controller/Service 状态单元测试及多个真实 Skynet 集成场景，包括文件恢复、模块登记、并发门禁、退出通知、失败继续发布等。**它的真实 Skynet 集成部分按原工程固定的 Server 目录布局运行**，不同于本课程使用绝对路径的独立 `master_course/run.sh`；如果你单独检出 FlyWow 而没有该宿主布局，应先使用本课程的四个独立实验，不要把原测试脚本的路径失败误认为 HotUpgrade 功能失败。

运行后按实际终端输出判断；本课程没有替你运行上述命令。

**验证边界**：教程中需要创建的 Lua/.patch 文件已通过独立 Lua 解释器的语法编译检查，Shell 启动脚本已通过 `bash -n` 语法检查；但这里无法启动与你仓库配套的真实 Skynet，也没有实际构建 Native 或执行发布实验。上述运行输出与中间状态仍属于依据真实源码和已有测试合同推导的预期。若运行中有差异，应以真实日志和当前检出源码为准，记录问题后核对，不得为让标记变绿而删断言。

### 25.1 不看答案先做十个源码推演题

1. 为什么管理端 `begin()` 返回成功，批次还可能失败？
2. 为什么 `register_service()` 不能把 `state` table 当作消息参数直接传给 Controller 保存？
3. 为什么 Controller 在 Prepare 后仍可能发现新目标？
4. 为什么正式 `.lua` 必须在第一个目标 Update 之前部署？
5. 为什么 `new_modules` 不能直接改走普通首次加载许可？
6. Stage 后线上 `logic.version()` 为什么仍然可能是 V1？
7. Commit 后已经保存的 `old_attack` 为什么不自动变成 V2？
8. 为什么 A 调用 `skynet.wait()` 以后 B 还没有获得业务 queue？
9. 为什么 Update 成功不能立即丢弃 `old`，而 Finish 可以？
10. 为什么 faulty 的 RECOVERY_REQUIRED 不阻止下一批，但 V3 成功也不能证明所有历史问题自动消失？

### 25.2 对照答案和对应源码入口

1. `Controller/M:begin()` 只接受任务并 fork `run_batch`；真正完成是另一个协程的终态，由 `status` 查询。
2. 每个 Service 有自己的 Lua State；Controller 保存的是跨 Service 可用的元数据，目标私有 table/函数只留在原 State 中。
3. Prepare 允许 yield；已在业务 queue 中的操作仍可受管理创建 Service、首次加载模块，所以 Controller 要排空并重匹配。
4. Update 中的候选/Service Patch 可能首次加载本批新依赖；如果正式文件尚未部署，其 `package.searchpath/load` 找不到本批内容。
5. 普通许可关门至批次终态，当前 Update 又要等待该许可，会形成互等；`register_new_module` 是当前目标的特例登记通道。
6. `stage()` 只准备新的 `candidate`、旧字段和隔离状态；直到 `commit()` 才原地覆盖 `live`。
7. 原 Lua 函数引用不因 module table 的字段被重写而自动重绑定；旧闭包引用仍持有自己的函数代码与 upvalue。
8. yield 只挂起协程，不自动退出 `business_queue` 的作用域；A 必须从 queue 包裹的函数真正返回，B 才能获得执行权。
9. A 先 Update 成功，B 仍可能 Update 失败；直到整个批次决定成功之前，A 需要保留旧字段供 Abort。
10. Controller 释放临时批次记录，允许下一次从实际状态前向修复；但下一批只保证自己修改和验证的范围，未涉及问题不会神奇消失。

## 第 26 章：最后一次完整状态盘点

这不是另外一套架构总结，而是把我们**亲手完成的三个场景**放在同一张实际对象变化表里。以后你调试时可以用它检查自己是否还分得清磁盘、Lua State 与批次状态。

| 状态/对象                 | V1 初始 | V2 正常完成 | faulty 恢复失败后   | V3 修复完成        |
| ------------------------- | ------- | ----------- | ------------------- | ------------------ |
| 旧 PlayerService handle   | H       | H           | H                   | H                  |
| `state` 根表身份          | S       | S           | S                   | S                  |
| 旧模块 `logic` 根表身份   | L       | L           | L                   | L                  |
| `logic.version()`         | v1      | v2          | v2                  | v3                 |
| `state.weapon`            | 刀      | 剑          | 剑                  | 霜剑               |
| `state.schema_version`    | 1       | 2           | 99                  | 3                  |
| `state.gold`              | 100     | 100         | 0                   | 88                 |
| `operations.attack(100)`  | 105     | 120         | 120（函数尽力恢复） | 125                |
| 旧 `old_attack(100)`      | 105     | 100         | 100                 | 100                |
| 正式 `player_logic.lua`   | V1      | V2          | V2                  | V3                 |
| 正式 `player_service.lua` | V1      | V2          | V2                  | V3                 |
| `combat_rules`            | 不存在  | 已加载登记  | 保留                | 已登记，未要求卸载 |
| 批次结果                  | 无发布  | COMPLETED   | RECOVERY_REQUIRED   | COMPLETED          |
| 是否永久锁定 Controller   | 否      | 否          | **否**              | 否                 |

`H/S/L` 只在**同一个旧 PlayerService 的连续发布**中表示相同对象身份；每次重新运行 `run.sh` 都会启动全新的独立 Skynet 进程和新的实例，不应把不同实验之间的 H、S、L 当作同一地址。新创建的 Service 也有自己的 Lua State，不能共享旧实例的根表指针。

### 最终能独立完成的事情

学完后，你应该能够：

- 不看旧课程，从空教学目录实现并跑通 V1、V2、Queue 与 V3 修复案例。
- 从 `main.lua/skynet.call` 出发，沿 `hotupgrade_service.lua → controller.lua → player_service.lua → flywow_hotupgrade.lua → module_patch.lua` 的实际 RPC 与本地调用返回路径，解释整个发布。
- 指出每个关键阶段**哪个 Service 在运行、哪个协程可能 yield、哪些状态已更新、哪些尚未更新**。
- 解释 `live/candidate/old`、根表身份、缓存别名、闭包与 upvalue，以及 Stage/Commit/Abort/Finish 对应的对象变化。
- 判断玩家业务能否进入安全点，识别那些绕开业务 queue 的并发写状态行为。
- 根据 `status` 错误和实际现场构造下一批前向修复，而不是机械要求永久锁定或假定完全回滚。
- 独立定位真实框架中的 Controller、业务入口、模块引擎、Native 和测试文件。

到这里，HotUpgrade 的系统性学习可以结束。后续如果你要给新的 MMO Service 接入热更，主要是**把这里理解的状态所有权、安全点、Patch 声明与恢复边界应用到真实业务**，不需要再围绕同一条链路重新开数门课程。

---

## 附录 A：本课程使用的真实源码索引

以下是实际工程文件，并非课程新建代码。链接固定到本次课程的 GitHub 代码基线；如果后来升级了 `main`，请先核对差异，再判断课程片段是否仍适用。

| 角色                                                                       | 真实文件与定位                                                                                                                                                                                                                                                                                                                                                   |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 控制 Service、协议 dispatch、初始化                                        | [`hotupgrade/service/flywow_hotupgrade_service.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/service/flywow_hotupgrade_service.lua)                                                                                                                                                                    |
| Controller 生命周期、批次、门禁、目标 RPC、部署、恢复                      | [`hotupgrade/lualib/flywow_hotupgrade_controller.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/lualib/flywow_hotupgrade_controller.lua)                                                                                                                                                                |
| 业务入口、`hotupgrade.require`、Service Patch、Prepare/Update/Abort/Finish | [`hotupgrade/lualib/flywow_hotupgrade.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/lualib/flywow_hotupgrade.lua)                                                                                                                                                                                      |
| 模块 Stage、Commit、Abort、Finish、快照与根表覆盖                          | [`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/lualib/flywow_hotupgrade_module_patch.lua)                                                                                                                                                            |
| 路径、扫描、同步文件部署/恢复 Native                                       | [`hotupgrade/native/hotupgrade_native.cpp`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/native/hotupgrade_native.cpp)                                                                                                                                                                                      |
| 公共结果表和源码头处理                                                     | [`common/lualib/flywow_result.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/common/lualib/flywow_result.lua)、[`flywow_hotupgrade_common.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/lualib/flywow_hotupgrade_common.lua) |
| Controller 顺序、恢复和门禁单元测试                                        | [`hotupgrade/tests/test_controller.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/tests/test_controller.lua)                                                                                                                                                                                            |
| 真实 Skynet 集成测试                                                       | [`hotupgrade/tests/skynet_hotupgrade.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/tests/skynet_hotupgrade.lua)                                                                                                                                                                                        |
| 不锁定、后续发布继续的测试                                                 | [`hotupgrade/tests/test_failure_continuation.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/hotupgrade/tests/test_failure_continuation.lua)                                                                                                                                                                        |
| 当前完整模块合同                                                           | [`docs/hotupgrade/README.md`](https://github.com/simbiwu/Skynet-FlyWow/blob/5c5c930626d0e59ca785a7da2711cbfc899301ec/docs/hotupgrade/README.md)                                                                                                                                                                                                                  |

**附录用途**：它是当前课程内部阅读真实框架源码的索引，不是让你另找一门课程来补前置知识。所有完成这套 Sample 所需的教学文件、步骤、调用背景和核心机制已在正文给出。

## 附录 B：运行失败时的最短排查顺序

如果 `v1` 启动失败，先看 `run.sh` 导出的四个绝对路径、Skynet 可执行文件和 Lua/Native 模块搜索路径。排查范围在 `skynet_config.lua`、`flywow_hotupgrade_service.lua/lua init` 及 `player_service.lua/init`。

如果 `normal` 失败，先核对 `patches/v2` 的四个完整文件、`player_service.patch` 的目标匹配、`hotupgrade.require` 的规范名以及 `status` 的错误码，再看 Controller `run_batch` 的阶段。

如果 `queue` 卡住，先用 `peek` 的教学观察值判断 A 是否占 queue、B 是否已排队、Prepare 是否设置 `patching`、release 是否成功唤醒 A；不要直接删掉 `before_upgrade()` 的 queue 栅栏来绕过问题。

如果 `forward` 没出现 RECOVERY_REQUIRED，首先确认 `faulty` 之前成功发布 V2、`inject_restore_failure` 确实在旧 PlayerService 生效、`after_upgrade` 在 schema 99 时确实返回 false，以及目标恢复是否走到自定义 `restore`。

如果日志、接口或路径与本文不符，先比较真实提交与本文 `5c5c930` 基线，不要猜测旧课程中曾经存在的 `FAILED_LOCKED`、`resolve_deployment` 或管理端 `abort` 是否还有效：**当前基线不使用这些旧协议**。

---

**课程结束。**
