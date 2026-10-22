# 第 5 课：从零实验普通 Lua 模块热更，读懂 Module Patch Engine

源码仓库：`https://github.com/simbiwu/Skynet-FlyWow`

本课核对的 `main` 提交：`7fa806e64448930f82fce02abc3f5c65dc1cc56a`

主要源码：[`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/7fa806e64448930f82fce02abc3f5c65dc1cc56a/hotupgrade/lualib/flywow_hotupgrade_module_patch.lua)

配合阅读：[`hotupgrade/lualib/flywow_hotupgrade.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/7fa806e64448930f82fce02abc3f5c65dc1cc56a/hotupgrade/lualib/flywow_hotupgrade.lua)、[`hotupgrade/lualib/flywow_hotupgrade_controller.lua`](https://github.com/simbiwu/Skynet-FlyWow/blob/7fa806e64448930f82fce02abc3f5c65dc1cc56a/hotupgrade/lualib/flywow_hotupgrade_controller.lua)

> **阅读约定**：本课新写的教学实验放在 `hotupgrade/lesson5/`，代码是我们为学习编写的，不是仓库已有 Sample；带有仓库源码路径、函数名和对应调用关系的代码才是实际框架源码。所有函数名与字段名均按上述最新提交核对。该版本 Controller 使用 `run_batch()`、`load_patch()`，业务 Lua State 使用 `handle_upgrade()`。不要沿用第 4 课旧提交里的 `run()`、`load()` 和 `control()` 来定位这些内部函数。
>
> **前置条件**：已经完成第 4 课，知道 `hotupgrade.require()`、Prepare、Update、Finish 与 Service Patch 的作用。本课不重新讲 Controller 如何启动或怎样发布完整 Service 文件，而是接着第 4 课进入 **Update 内部的普通模块更新引擎**。示例仍沿用“刀 → 剑”，但本课会专门观察模块导出表、函数引用、闭包私有状态和旧快照。

## 一、这次究竟要弄懂什么？

第 4 课我们看到了这样的更新结果：原来的 `PlayerService` 没有销毁，`logic` 仍然引用原来的普通模块导出表，`logic.version()` 却从 `v1` 变为 `v2`；之前保存的旧业务闭包并没有自动变成新函数。

这不是 Lua 自动完成的，而是 `flywow_hotupgrade_module_patch.lua` 里的更新引擎有意实现的。它要解决四件事：

1. **Stage**：读取已经冻结的 V2 源码，在当前 Lua State 内创建候选模块，并保存旧导出字段；不立即修改正在使用的模块表。
2. **Commit**：把候选模块的完整导出字段安装到旧模块根表上，根表身份保持不变。
3. **Abort**：如果整次事务在发布决定前失败，尝试恢复旧导出字段，并在恢复成功后释放阶段数据。
4. **Finish**：正式文件已经成功部署、发布决定已经作出后，释放旧字段快照，不再提供本批次的普通模块撤销能力。

除此之外，我们还必须弄清一个容易误解的问题：**模块导出表与模块闭包的 upvalue 不是同一层状态**。原地更新 `logic.version`，并不意味着旧闭包的 upvalue 自动迁移。需要迁移的模块私有状态，要靠 `export_state()` 和 `import_state()` 显式传递。

为了让这次学习不再被 Controller、Service 初始化、业务 queue 和大量 `assert()` 分散注意力，我们先写一个**单 Lua State 的最小实验**，直接调用真实的 Module Patch Engine。这里调用的是框架内部模块，不是生产环境推荐的公开发布接口。实验结束后，再把每一步放回真正的 `PlayerService` Update 调用链中。

本课准备观察以下对象，不再在中途改名称：

```text
logic                 V1 加载后获得的模块导出根表
logic_root            仅用于验证 logic 根表身份
old_version           提前缓存的 V1 version 函数
old_load              提前创建、捕获 state 的 V1 攻击闭包
old_settings          提前缓存的 V1 嵌套配置表
state                 实验模拟的 PlayerService 玩家状态根表
module_stage          stage() 创建的本次候选及旧快照记录
module_state.active   更新引擎在当前 Lua State 的活动记录
```

我们会先实际观察 `stage → commit → abort`，再重新 `stage → commit → finish`。这样同一套 V1/V2 文件同时展示成功提交与恢复的区别。

## 二、第一阶段：创建一个最小的 V1/V2 模块实验

在 FlyWow 仓库根目录下，新建：

```text
hotupgrade/lesson5/
├── v1/
│   └── player_logic.lua
├── v2/
│   └── player_logic.lua
└── run_module_patch.lua
```

这里没有新增 `PlayerService`、Controller 或 Skynet 配置，因为这次要直接观察普通模块引擎在**同一个 Lua State 内**怎样修改 `package.loaded` 中已有的模块表。第 4 课已经完成过真实多 Service 发布；本课是拆开其中一个内部步骤进行源码实验。

### 先编写 V1 模块

文件：`hotupgrade/lesson5/v1/player_logic.lua`。下面是我们新编写的**完整文件**。

```lua
local count = 0
local M =
{
    legacy_tag = "only-v1",
    settings = {bonus = 5},
}

function M.version()
    return "v1"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "刀" and 5 or 0)
    end
end

function M.next_count()
    count = count + 1
    return count
end

function M.export_state()
    return {count = count}
end

function M.import_state(snapshot)
    count = snapshot.count
    return true
end

return M
```

这与上一课的玩家业务逻辑基本一致：装备是“刀”时加 5 点攻击力。这次额外增加了两种很小的状态，专门用于研究模块热更：

- `M.settings` 是模块导出的嵌套 table，方便观察旧嵌套引用是否还有效。
- `local count` 是模块文件内的局部变量，`next_count()`、`export_state()` 和 `import_state()` 闭包可以访问它。它**不是** `M.count` 字段，也不在 `package.loaded` 导出表中。

从 C++ 的角度理解，`M` 类似一个由外部保存的对象接口表；`count` 更像函数闭包私有持有的状态。Lua 不能依靠把新方法写入 `M` 来自动替换旧闭包所捕获的这个局部变量。

### 再编写 V2 完整模块

文件：`hotupgrade/lesson5/v2/player_logic.lua`。下面也是**完整文件**：

```lua
local count = 0
local M =
{
    new_tag = "only-v2",
    settings = {bonus = 21},
}

function M.version()
    return "v2"
end

function M.make_load(state)
    return function(base_attack)
        return base_attack + (state.equip == "剑" and 21 or 0)
    end
end

function M.next_count()
    count = count + 1
    return count
end

function M.export_state()
    return {count = count}
end

function M.import_state(snapshot)
    count = snapshot.count
    return true
end

return M
```

这份文件与 V1 有四处有意义的差异：业务版本变成 `v2`；装备改为“剑”且加成变为 21；`legacy_tag` 删除、`new_tag` 新增；新的模块文件重新创建了自己的局部变量 `count = 0`。

请注意最后一项。**如果只执行新的模块源码，V2 的 `count` 初始值就是 0，并不知道旧模块已经累积了多少次调用。** 我们同时保留 `export_state/import_state`，就是为了让 Stage 把旧模块私有状态交给 V2 候选闭包。

这两个文件都是完整的模块文件，不是“只改动的代码片段”。现在还没有创建或加载 V2 的模块表。

### 编写实验入口

文件：`hotupgrade/lesson5/run_module_patch.lua`。这是本课自己编写的**完整执行入口**，不包含 Skynet、Controller，也没有把输出封装成测试框架：

```lua
-- 从 FlyWow 仓库根目录执行；直接使用仓库的 Module Patch Engine。
package.path = "./hotupgrade/lualib/?.lua;"
    .. "./hotupgrade/lesson5/v1/?.lua;"
    .. package.path

local module_patch = require "flywow_hotupgrade_module_patch"
local logic = require "player_logic"

-- 教学实验只模拟 hotupgrade.require 已建立的规范名称别名。
-- 真实 Service 中由 hotupgrade.require 创建，不需要业务这样写。
package.loaded["lualib.player_logic"] = logic

local logic_root = logic
local old_version = logic.version
local old_settings = logic.settings
local state = {equip = "刀"}
local old_load = logic.make_load(state)

-- 更新前，调用两次 V1 私有计数函数。
logic.next_count()
logic.next_count()
print("V1:", logic.version(), old_load(100), logic.export_state().count)

-- 从文件读取完整 V2 源码，作为引擎 stage() 的输入。
local file = assert(io.open("hotupgrade/lesson5/v2/player_logic.lua", "rb"))
local v2_source = file:read("*a")
file:close()

local modules =
{
    {name = "lualib.player_logic", source = v2_source},
}

-- 第一次更新：Stage → Commit → Abort，观察恢复。
local prepared = module_patch.stage(modules)
if not prepared.ok then
    error(prepared.message)
end
local module_stage = prepared.stage
print("Stage:", logic.version(), logic.export_state().count)

local committed = module_patch.commit(module_stage)
if not committed.ok then
    error(committed.message)
end
state.equip = "剑" -- 仅模拟 Service 状态迁移；不是模块引擎的职责。
print("Commit:", logic.version(), logic.make_load(state)(100), old_load(100))
print("字段:", logic.legacy_tag, logic.new_tag, logic.settings.bonus)
print("表身份:", logic == logic_root, logic.settings == old_settings)
print("候选私有计数:", logic.next_count())

local aborted = module_patch.abort(module_stage)
if not aborted.ok then
    error(aborted.message)
end
print("Abort:", logic.version(), state.equip, old_load(100), logic.export_state().count)
print("旧字段恢复:", logic.legacy_tag, logic.new_tag, logic.settings == old_settings)

-- Module Patch Engine 不会恢复业务 state，实验手工回到 V1。
state.equip = "刀"

-- 第二次更新：Stage → Commit → Finish，正式保留 V2。
local prepared_again = module_patch.stage(modules)
if not prepared_again.ok then
    error(prepared_again.message)
end
local committed_again = module_patch.commit(prepared_again.stage)
if not committed_again.ok then
    error(committed_again.message)
end
state.equip = "剑" -- 同样只模拟 Service Patch 对状态的更新。

local finished = module_patch.finish(prepared_again.stage)
if not finished.ok then
    error(finished.message)
end
print("Finish:", logic.version(), logic.make_load(state)(100), old_load(100))
print("旧引用:", old_version(), old_settings.bonus)
print("最终根表:", logic == logic_root, package.loaded["lualib.player_logic"] == logic)
print("最终私有计数:", logic.export_state().count)
```

这是一个小型内部算法实验，所以主动模拟了两件生产框架平时自动完成的准备工作。

第一，`require "player_logic"` 加载 V1，随后给 `package.loaded["lualib.player_logic"]` 设置同一张表别名。真实的 PlayerService 不会手工设置这个别名；第 4 课已经看到，它是在 `hotupgrade.require("player_logic")` 中根据文件实际路径确定并维护的。

第二，`state.equip = "剑"` 只是为了观察旧攻击闭包和新攻击闭包在同一张玩家状态表下的表现。在完整热更事务中，状态迁移属于 Service Patch，并不是 `flywow_hotupgrade_module_patch.lua` 的工作。这个区别在 Abort 以后尤为明显：**只调用模块引擎 Abort，不会把业务 `state.equip` 自动变回“刀”。**

现在先不急着运行后理解输出。先拿着这个入口，从第一次 `module_patch.stage(modules)` 开始，进入真实源码。

## 三、第二阶段：Stage 如何编译候选、保存旧字段、迁移私有状态？

我们当前执行在 `run_module_patch.lua` 的顶层脚本中，已加载 V1 并保存四个重要引用：`logic_root`、`old_version`、`old_settings`、`old_load`。`logic.next_count()` 已执行两次，所以 V1 闭包内的 `count=2`。

此时：

```text
package.loaded["player_logic"] ─────┐
                                    ▼
package.loaded["lualib.player_logic"] ──→ logic（V1 导出根表）
                                          ├── version → V1 函数
                                          ├── make_load → V1 函数
                                          ├── settings → V1 嵌套表（bonus=5）
                                          ├── legacy_tag → "only-v1"
                                          └── export_state → 捕获 V1 count 的函数

old_version  → V1 version 函数
old_settings → V1 settings 嵌套表
old_load     → V1 make_load(state) 创建的旧闭包
state        → {equip="刀"}
V1 私有 count = 2
```

`module_patch.stage(modules)` 的调用者在完整工程中不是我们这个实验脚本，而是业务 Service Lua State 内的 `flywow_hotupgrade.lua`，函数名为 `handle_upgrade()`。现在只为方便观察内部引擎，直接调用它。

源码文件：`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`。

### 先看 Stage 保存哪些东西

进入源码时，文件顶部定义了：

```lua
local M = {}
local module_state =
{
    active = nil, -- 本 State 唯一候选和旧快照，保留至 finish/abort。
}
```

这是该源码文件顶部的真实声明。不要把这里的 `module_state` 与 `flywow_hotupgrade.lua` 中的同名私有状态表混淆：**它们属于两个不同的 Lua 模块，只是都运行在当前 PlayerService 的 Lua State 内。**

`module_state.active` 保存的是普通模块更新引擎尚未结束的 Stage。它不是 Controller 的发布批次，也不是 PlayerService 本地的 `active_transaction`。

我们先读完整 `M.stage()`，然后按其两个循环解释对象的创建和变化。这是当前工作区的真实函数：

```lua
function M.stage(entries)
    if module_state.active then
        return hotupgrade_result.failure("HU_UPGRADE_BUSY", "模块 Stage 尚未结束")
    end

    -- 本 State 从 Stage 持有到 Finish/Abort；每条记录集中保存候选及恢复所需的旧字段。
    local module_stage =
    {
        entries   = {},    -- 按输入顺序保存模块记录；Commit 安装候选，Abort 恢复各记录的旧字段。
        committed = false, -- 开始写线上字段前置为 true；即使部分提交失败，Abort 也会执行恢复。
    }
    local ok, message = pcall(function()
        -- 数组结构、模块名、源码及唯一性已由 Controller 建立；这里只检查本 State 的实际对象。
        -- 先编译全部 Patch 并保存每个线上模块的旧字段。
        for _, item in ipairs(entries) do
            local live = package.loaded[item.name]
            check_exports(live, item.name)
            local fields = {}
            for key, value in pairs(live) do
                fields[key] = value
            end

            -- 只引用已加载依赖；不执行新的依赖加载链，不代表提供安全沙箱。
            local env = setmetatable({require = function(name)
                local dependency = package.loaded[name]
                assert(type(dependency) == "table", "依赖尚未加载: " .. tostring(name))
                return dependency
            end}, {__index = _G})
            local chunk = assert(load(item.source, "@" .. item.name, "t", env))
            module_stage.entries[#module_stage.entries + 1] =
            {
                name      = item.name, -- package.loaded 的规范名；提交与恢复时核对线上根表身份。
                live      = live,      -- 原模块根表；提交与恢复始终原地修改它的字段。
                old       = fields,    -- 旧导出字段及原引用；保留至 Finish 或恢复成功。
                chunk     = chunk,     -- 第一轮编译的源码；第二轮执行后释放。
                candidate = nil,       -- 第二轮准备的新导出；Commit 时整体安装其字段。
            }
        end

        -- 再执行候选模块，检查导出并迁移隔离的私有状态。
        for _, entry in ipairs(module_stage.entries) do
            local candidate = entry.chunk()
            check_exports(candidate, entry.name)
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
    end)
    if not ok then
        return hotupgrade_result.failure("HU_MODULE_STAGE_FAILED", tostring(message))
    end

    module_state.active = module_stage
    return hotupgrade_result.success({stage = module_stage})
end
```

看起来较长，但它的流程很明确：**第一个循环先处理全部模块的旧导出字段与源码编译，第二个循环再执行候选模块并完成验证和私有状态迁移。** 我们只有一个 `lualib.player_logic`，所以每个循环仅迭代一次。以后一个批次有多个模块时，这个执行顺序仍然成立。

生产调用中，Controller 的 `build_patch()` 负责路径映射、源码类型、语法及去重，并构造连续的模块数组；目标筛选保留这份顺序。引擎依赖这个输入合同，不再重复检查数组空洞、模块名、源码类型和重复名称。本课直接调用内部引擎，也要按这个合同构造输入。Stage 中的 `load()` 仍必须执行，因为它要把冻结源码绑定到当前 State 的候选环境。

第一句先检查 `module_state.active`。如果上一次 Stage 尚未结束，就不能再开启新的 Stage。这不是 Controller 的排他锁，而是此 Lua State 内更新引擎自己的活动记录。

接着创建：

```lua
-- 本 State 从 Stage 持有到 Finish/Abort；每条记录集中保存候选及恢复所需的旧字段。
local module_stage =
{
    entries   = {},    -- 按输入顺序保存模块记录；Commit 安装候选，Abort 恢复各记录的旧字段。
    committed = false, -- 开始写线上字段前置为 true；即使部分提交失败，Abort 也会执行恢复。
}
```

这句属于 `M.stage()` 开头，内部两个字段分别有明确用途：

- `entries` 是按输入顺序排列的模块记录数组；每条记录集中保存 `name`、旧根表 `live`、旧导出字段 `old`、编译函数 `chunk` 和候选 `candidate`。后续 Commit 和 Abort 直接遍历这些记录。
- `committed=false` 表示还没有开始对线上模块表写入新导出字段。

#### 第一轮循环：找到线上表并编译候选

`item.name` 在本例中是 `lualib.player_logic`，`item.source` 就是从 V2 文件读取的完整 Lua 源码。

```lua
local live = package.loaded[item.name]
check_exports(live, item.name)
local fields = {}
for key, value in pairs(live) do
    fields[key] = value
end
```

这是 `M.stage()` 第一轮循环里的连续代码。

`live` 是**当前已经在使用的 V1 导出根表**，不是另一个新表。`check_exports()` 先验证 V1 导出结构，再遍历顶层字段，把旧值存进 `fields`。

这份快照有一个精确边界：**它是顶层字段的浅拷贝，而不是把闭包或嵌套 table 全部复制一遍。**

例如：

```text
module_stage.entries[1].old.version  ──→ 原 V1 函数
module_stage.entries[1].old.settings ──→ 原 V1 settings 表
module_stage.entries[1].old.next_count ──→ 原 V1 闭包
```

它保存的是这些旧值的引用。这样以后 `abort()` 可以把旧字段重新挂回同一张 `live` 根表。它不会克隆函数的 Lua upvalue，也不会保护违反合同而被 Patch 顶层代码直接修改的外部对象。

再往下，源码为这个候选模块创建 `env`，并用 Lua 的 `load()` 编译：

```lua
local env = setmetatable({require = function(name)
    local dependency = package.loaded[name]
    assert(type(dependency) == "table", "依赖尚未加载: " .. tostring(name))
    return dependency
end}, {__index = _G})
local chunk = assert(load(item.source, "@" .. item.name, "t", env))
module_stage.entries[#module_stage.entries + 1] =
{
    name      = item.name, -- package.loaded 的规范名；提交与恢复时核对线上根表身份。
    live      = live,      -- 原模块根表；提交与恢复始终原地修改它的字段。
    old       = fields,    -- 旧导出字段及原引用；保留至 Finish 或恢复成功。
    chunk     = chunk,     -- 第一轮编译的源码；第二轮执行后释放。
    candidate = nil,       -- 第二轮准备的新导出；Commit 时整体安装其字段。
}
```

这是 `M.stage()` 中同一循环的下一段。`load(source, chunkname, "t", env)` 将字符串源码编译为一个可执行 Lua 函数，但**此时还没有执行这个候选函数**。

`"t"` 要求文本源码。`"@" .. item.name` 设置错误信息中的 chunk 名称，便于定位。

候选环境对 `require()` 做了限制：只能取得当前 Lua State 中 `package.loaded` 已存在的 table 依赖，不能趁热更偷偷加载一条全新模块依赖链。

然而 `env` 通过 `__index = _G` 仍可访问其他原有全局函数，因此**这不是安全沙箱**。模块顶层和状态钩子应当是受信、同步、无外部副作用的代码，不能在里面启动任务、执行 I/O、写线上业务状态或 yield。框架通过 `pcall` 捕获 Lua 错误，并不能撤销 Patch 代码擅自产生的副作用。

第一轮执行完后，我们的状态是：

```text
live                  → V1 线上模块导出根表
fields                → V1 旧导出字段快照
chunk                 → 已编译但尚未执行的 V2 源码函数
module_stage.entries[1] → 集中保存 name、live、chunk 和 old=fields
module_stage.committed = false

logic.version() = "v1"
V1 count = 2
```

Stage 在这里尚未结束，所以现在不会返回给实验脚本。

#### 第二轮循环：执行候选、校验导出、迁移私有状态

第二个循环通过 `for _, entry in ipairs(module_stage.entries) do` 取得每个模块记录，再执行：

```lua
local candidate = entry.chunk()
check_exports(candidate, entry.name)
assert(candidate ~= entry.live, "候选须返回新的导出表")
for key, value in pairs(candidate) do
    assert(entry.live[key] == nil or type(entry.live[key]) == type(value), "导出字段类型变化")
end
```

这段是 `M.stage()` 第二轮循环的开头。这里才真正调用 `chunk()`，执行我们的 V2 `player_logic.lua`。

执行时，V2 文件里：

```lua
local count = 0
local M =
{
    new_tag = "only-v2",
    settings = {bonus = 21},
}
```

这段代码来自我们自己编写的 `hotupgrade/lesson5/v2/player_logic.lua` 的文件顶部。它会创建**新的候选导出表**以及**新的 V2 私有 count**，与旧模块不是同一张表，也不是同一份 upvalue。

随后 `check_exports(candidate, entry.name)` 验证候选导出；`candidate ~= entry.live` 明确禁止候选返回正在使用的旧导出根表。另一个循环禁止新版与旧版**同名顶层字段改变类型**。例如 V1 `version` 是函数，V2 也应当是函数；新版新增 `new_tag`、删除 `legacy_tag` 则允许。

再往下 Stage 处理私有状态：

```lua
assert((entry.live.export_state == nil) == (candidate.import_state == nil),
    "新旧模块缺少配对状态钩子")
if entry.live.export_state then
    -- 新版只能接触独立数据；旧闭包仍持有自己的状态，Abort 恢复旧导出即可。
    local snapshot = M.copy_state(entry.live.export_state())
    assert(candidate.import_state(snapshot) ~= false, "模块拒绝状态导入")
end
entry.candidate = candidate
entry.chunk = nil
```

这段仍是 `M.stage()` 第二轮循环中后续连续代码。因为我们给 V1 与 V2 都提供了状态钩子，所以会执行这个分支。

`entry.live.export_state()` 调用的是 **V1 模块导出表中的旧函数**。它访问旧闭包捕获的 `count=2`，返回 `{count=2}`。

`M.copy_state()` 把结果复制成独立普通数据图，避免新模块直接持有旧模块返回的可变状态对象。然后，Stage 调用 **V2 候选导出表** 中的 `candidate.import_state(snapshot)`。

V2 `import_state()` 将自己刚刚创建的 `count=0` 改为 `count=2`。

注意：这整个过程并没有用 `debug.upvaluejoin()` 把 V1 与 V2 的 upvalue 强行绑定在一起。它们仍然属于不同的闭包，只是通过明确的数据快照传递了数值。

最后，`entry.candidate = candidate` 保存新的候选根表，`entry.chunk = nil` 释放已经不再需要的编译函数引用。

Stage 退出 `pcall()` 后才设置：

```lua
module_state.active = module_stage
return hotupgrade_result.success({stage = module_stage})
```

它把本次 Stage 记为当前 Lua State 中唯一的活动模块更新，然后把记录交回调用者。实验脚本接收到 `prepared.stage`，保存为 `module_stage`。

如果这个过程中出现编译错误、导出检查失败或私有状态导入失败，`M.stage()` 返回 `HU_MODULE_STAGE_FAILED`，并且不会把这个失败的 `module_stage` 设置为 `module_state.active`。正常合同下线上旧导出字段仍未被改写。`pcall` 并不提供执行副作用的事务回滚。

### Stage 完成后的第一次状态快照

回到我们自己的 `run_module_patch.lua`，这一句：

```lua
print("Stage:", logic.version(), logic.export_state().count)
```

来源是教学实验入口，在 `module_patch.stage(modules)` 成功之后。预期打印：

```text
Stage: v1 2
```

原因现在应当非常清楚：Stage 已经执行 V2 候选代码，还把旧的 `count=2` 导入了候选 V2 闭包，但它**没有替换 `logic` 根表中的任何导出字段**。

```text
线上：logic（原 V1 根表）
    version() = "v1"
    settings.bonus = 5
    legacy_tag = "only-v1"
    export_state().count = 2

Stage 记录：module_stage
    entries["lualib.player_logic"].live      → 原 V1 根表
    entries["lualib.player_logic"].candidate → 新 V2 候选根表
    old["lualib.player_logic"]               → 旧字段快照
    committed = false

V2 候选私有 count = 2
module_state.active = module_stage
```

**Stage 已经准备好未来要安装的 V2，但业务当前访问的仍是 V1。**

## 四、Stage 为什么还需要 `check_exports()` 与 `copy_state()`？

刚才为了保持调用链连续，我们先跟完了整个 Stage。现在两个辅助函数已经实际出现，而且它们分别影响候选是否可接受、模块私有状态是否与旧对象隔离。这里直接把它们理解清楚，不另起一套例子。

### `check_exports()` 检查的究竟是什么？

调用位置：`M.stage()` 在保存旧字段前检查 `live`，在候选 `chunk()` 执行后检查 `candidate`。

定义文件：`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`。

当前完整实现如下：

```lua
local function check_exports(exports, name)
    -- 先校验顶层导出并收集嵌套表，seen 允许数据图共享引用和循环引用。
    assert(type(exports) == "table" and getmetatable(exports) == nil, name .. " 必须导出普通表")
    local pending = {} -- 待检查的嵌套表；迭代遍历避免深层数据造成递归栈溢出。
    local seen = {}    -- 每张嵌套表只检查一次，允许共享引用与嵌套表之间的循环。
    local function check_value(value)
        local kind = type(value)
        if kind == "table" then
            assert(value ~= exports, name .. " 嵌套导出不得引用模块根导出表")
            assert(getmetatable(value) == nil, name .. " 嵌套导出必须是无元表普通表")
            if not seen[value] then
                seen[value] = true
                pending[#pending + 1] = value
            end
        else
            assert(kind == "function" or kind == "number" or kind == "string" or kind == "boolean",
                name .. " 导出包含不支持的类型: " .. kind)
        end
    end

    for key, value in pairs(exports) do
        assert(type(key) == "string", name .. " 顶层导出字段名必须是字符串")
        check_value(value)
    end

    -- 遍历嵌套数据图，校验键和值类型并拒绝元表和根表回指。
    while #pending > 0 do
        local nested = table.remove(pending)
        for key, value in pairs(nested) do
            local kind = type(key)
            assert(kind == "string" or kind == "number" or kind == "boolean",
                name .. " 嵌套导出键必须是字符串、数字或布尔值")
            check_value(value)
        end
    end

    -- 模块私有状态钩子是额外合同，必须成对提供且都为函数。
    assert((exports.export_state == nil) == (exports.import_state == nil), name .. " 状态钩子须成对")
    if exports.export_state ~= nil then
        assert(type(exports.export_state) == "function" and type(exports.import_state) == "function",
            name .. " 状态钩子必须是函数")
    end
end
```

这段函数不是为了限制正常 Lua 所有可能的写法，而是为**当前这套原地更新算法**限定可处理的导出结构。

它要求模块根表是没有元表的普通 table，顶层键只能是字符串；非 table 的导出值只能是函数、数字、字符串或布尔值，不能把 userdata、thread 等对象直接作为普通模块导出。嵌套 table 也不能带元表，嵌套表之间允许共享或循环，但禁止直接或间接引用模块根表本身。

`pending` 和 `seen` 的配合用于遍历嵌套 table，而不是递归遍历所有 Lua 对象。`seen` 可以避免一个嵌套表被重复检查，也不会因为嵌套表之间有环而无限循环。

本例的 `settings = {bonus=5}` 和 V2 `{bonus=21}` 都符合这个合同。`version`、`make_load`、`next_count` 等都是函数，也符合。

这里要区分两项检查：

- `check_exports()` 检查单个模块自身的导出结构是否合法。
- `M.stage()` 中随后的 `type(entry.live[key]) == type(value)` 检查旧、新版本**同名顶层字段**的类型兼容性。

所以 V2 能够新增 `new_tag`、删除 `legacy_tag`，但不能把原来的 `version()` 从函数改成字符串。普通模块的“完整版本”指整个导出字段集合由新版决定，不代表新版必须保留旧版的所有字段。

### `copy_state()` 复制的不是模块导出表

`M.stage()` 调用 `M.copy_state()` 时，传入的是：

```lua
entry.live.export_state()
```

这句来自 `M.stage()` 的私有状态迁移分支。它返回的是我们 V1 模块自己导出的 `{count=2}` 数据，而不是 `logic` 模块导出根表。

源码文件仍是 `hotupgrade/lualib/flywow_hotupgrade_module_patch.lua`。下面是实际 `M.copy_state()`：

```lua
function M.copy_state(value, destination)
    local seen = {} -- 当前复制过程的旧表到新表映射，不保留在线上状态中。
    local count = 0 -- 限制一次快照的节点/字段数，避免错误状态图耗尽控制阶段资源。
    local function copy(item, depth)
        local kind = type(item)
        if kind ~= "table" then
            assert(kind == "nil" or kind == "string" or kind == "boolean" or kind == "number",
                "状态快照只接受普通数据")
            return item
        end

        assert(getmetatable(item) == nil, "状态对象需要显式快照和恢复处理")
        if seen[item] then
            return seen[item]
        end

        assert(depth <= 64, "状态快照嵌套超过 64 层")
        local target = {}
        if depth == 1 and destination then
            target = destination
            assert(target ~= item and getmetatable(target) == nil, "快照必须与线上根表隔离")
            for key in pairs(target) do
                rawset(target, key, nil)
            end
        end
        seen[item] = target
        for key, child in pairs(item) do
            count = count + 1
            assert(count <= 10000, "状态快照超过 10000 个字段")
            assert(type(key) == "string" or type(key) == "number" or type(key) == "boolean",
                "状态字段必须使用标量键")
            target[key] = copy(child, depth + 1)
        end

        return target
    end

    return copy(value, 1)
end
```

这份实现有两个用途。Stage 私有状态迁移时不提供 `destination`，得到一份独立的数据图；Service 状态原地提交或恢复时，另一个函数 `restore_state(live, fields)` 会指定旧的 `live` 根表为 `destination`，只更新其内容。

但是这两个调用场景的对象不同，不能因为它们都用 `copy_state()`，就误以为普通模块的 `logic` 根表也是靠 `copy_state()` 更新的。**普通模块根表由后面讲到的 `replace_exports()` 更新。**

对于图结构，`seen` 保存源 table 到目标 table 的对应关系，能够保留嵌套表之间的共享和循环。`depth` 限制嵌套深度为 64，`count` 限制本次复制遍历的字段数量为 10000。键只允许字符串、数字或布尔值，值只允许普通数据及符合合同的嵌套表。

本例只有 `{count=2}`，因此 `copy_state()` 新建一张普通表，把数字 2 复制过去。V2 `import_state(snapshot)` 拿到独立的 table，而不是对 V1 私有 upvalue 的直接引用。

## 五、第三阶段：Commit 怎样保留模块表身份，又换掉所有导出字段？

Stage 成功后，执行权返回到 `run_module_patch.lua`，它调用：

```lua
local committed = module_patch.commit(module_stage)
```

这句来自我们自己写的实验入口。现在进入真实 `hotupgrade/lualib/flywow_hotupgrade_module_patch.lua` 的 `M.commit()`。

完整实现如下：

```lua
function M.commit(module_stage)
    if module_state.active ~= module_stage or module_stage.committed then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 无效或已提交")
    end

    local ok, message = pcall(function()
        -- 先确认所有根表身份仍有效；全部通过后才开始修改线上导出。
        for _, entry in ipairs(module_stage.entries) do
            assert(package.loaded[entry.name] == entry.live and getmetatable(entry.live) == nil,
                "模块身份在 Stage 后改变")
        end

        -- 所有候选已在 Stage 完成检查，现在原地替换每个模块的完整导出字段。
        module_stage.committed = true
        for _, entry in ipairs(module_stage.entries) do
            replace_exports(entry.live, entry.candidate)
        end
    end)
    return ok and hotupgrade_result.success() or hotupgrade_result.failure("HU_MODULE_COMMIT_FAILED", tostring(message))
end
```

这段函数从 `module_state.active` 中确认我们传入的是刚刚成功 Stage 的同一个 `module_stage`，并且尚未提交过。随后先检查所有模块的 `package.loaded[entry.name]` 仍指向 Stage 时登记的 `entry.live` 根表。

注意 `entry.name` 是规范名 `lualib.player_logic`。先前保存的 `logic_root` 和 `entry.live` 都是同一张表。`Commit` **不会清空 `package.loaded`，也不会把模块别名改指向候选根表**。

身份检查通过后，`module_stage.committed = true` 表示开始执行线上写入。如果后续写入出现错误，Abort 便知道需要从各模块记录的 `entry.old` 恢复。然后对每个模块调用本文件的 `replace_exports()`。该辅助函数依赖 Commit 或 Abort 刚完成的根表检查，不再重复验证相同的表类型和元表。

完整 `replace_exports()` 源码是：

```lua
local function replace_exports(live, fields)
    for key in pairs(live) do
        rawset(live, key, nil)
    end

    for key, value in pairs(fields) do
        rawset(live, key, value)
    end
end
```

这就是模块根表原地更新算法的核心，实际上很直接。

`live` 是 `logic` 原来持有的 V1 导出表；`fields` 是 V2 `candidate` 的完整字段集合。

先遍历旧 `live`，删除原来的所有顶层导出字段。然后将 V2 候选中的每个顶层字段写入**同一张 `live` 表**。

它没有执行：

```lua
package.loaded["lualib.player_logic"] = candidate
```

这行是本课用于对比的**没有采用的写法**，不是实际源码。若直接换掉模块根表，业务早已保存的 `logic` 变量仍指向旧表；当前算法保留根表身份，正是为了让这些已有的根表引用读到新版字段。

本例 Commit 之后：

```text
logic（仍是原来的根表）
    version          → V2 version 函数
    make_load        → V2 make_load 函数
    next_count       → V2 next_count 函数
    export_state     → V2 export_state 函数
    import_state     → V2 import_state 函数
    settings         → 新的 V2 settings 表（bonus=21）
    new_tag          → "only-v2"
    legacy_tag       → nil（旧字段已被删除）
```

这也解释了为什么 `old_settings` 不会自动变成 V2 的 `{bonus=21}`。它是我们提前保存的 V1 **嵌套表引用**。`replace_exports()` 只保留模块根表身份，不对旧嵌套表递归修改。新版嵌套表作为新的字段值直接装到 `logic.settings` 上。

所以：

```text
logic == logic_root          true
logic.settings.bonus         21
old_settings.bonus          5
logic.settings == old_settings  false
```

`old_version` 也同样保留着缓存的 V1 函数。虽然现在 `logic.version()` 是 `v2`，直接调用 `old_version()` 仍然返回 `v1`。

### 旧业务闭包为什么还是旧函数？

Commit 完毕，实验入口紧接着执行：

```lua
state.equip = "剑"
print("Commit:", logic.version(), logic.make_load(state)(100), old_load(100))
```

来源：我们编写的 `hotupgrade/lesson5/run_module_patch.lua`。这不是框架替我们修改 Service 状态；这里的 `state.equip` 只是单 Lua State 实验对 Service 状态迁移的模拟。

`logic.make_load(state)` 当前是 V2 的导出函数，返回一个捕获 `state` 的 V2 闭包，所以攻击力是 `100+21=121`。

`old_load` 则是实验开始时从 V1 `logic.make_load(state)` 创建的旧闭包。它的代码始终是“装备为刀时加 5”，不会随着 `logic.make_load` 字段替换而变成新的代码。现在状态表已改成“剑”，旧闭包的条件不再满足，所以它返回 100。

因此预期：

```text
Commit: v2 121 100
```

这里有两层不同的引用关系：

```text
logic ──→ 原模块根表 ──make_load──→ V2 工厂函数

old_load ──→ V1 已创建的旧闭包 ──upvalue──→ state（原玩家状态表）

logic.make_load(state) ──→ 新 V2 闭包 ──upvalue──→ 同一个 state
```

**模块根表的字段可以更新；某个地方已经缓存的函数值不会自动更新；闭包捕获的 table 内容又可以独立变化。**

这三个事实必须分开理解。它们共同解释了第 4 课“原 Service 持有旧闭包却读取到新装备状态”的现象。

### Commit 完成后的第二次状态快照

我们此时已经在模块根表上安装 V2，但没有结束本次 Stage：

```text
module_state.active = module_stage
module_stage.committed = true

logic == logic_root                    true
logic.version()                       "v2"
logic.settings.bonus                  21
logic.legacy_tag                      nil
logic.new_tag                         "only-v2"
logic.settings == old_settings         false
old_version()                         "v1"

state.equip                           "剑"（仅实验手动修改）
logic.make_load(state)(100)           121
old_load(100)                         100

module_stage.entries 中各记录的 old 仍保存旧导出字段
V1 私有 count = 2
V2 候选私有 count = 2
```

回到实验入口，它还会执行 `logic.next_count()`。因为 `logic.next_count` 已换成 V2 候选函数，所以这次把**V2 私有 count 从 2 增加到 3**，并不会修改原 V1 闭包内部的 count。

注意，这一处更新发生在实验模拟的 Commit 后，而真正的业务 Service 在 `hot.patching=true`、业务排空之后进行 Activate，不能在安全点未解除时让业务任意进入调用。我们这里直接调用只是为了看清楚两套闭包的状态确实独立。

## 六、第四阶段：Abort 怎样把旧导出恢复到原来的模块根表？

现在实验入口执行：

```lua
local aborted = module_patch.abort(module_stage)
```

这段来自我们编写的 `run_module_patch.lua`。这一次不经过 Controller，只模拟真实事务在发布决定前失败后对普通模块部分执行的撤销。当前 `module_stage.committed=true`，因为上一阶段已经把 V2 导出字段装入了线上模块根表。

我们进入真实源码：`hotupgrade/lualib/flywow_hotupgrade_module_patch.lua` 的 `M.abort()`。完整实现如下：

```lua
function M.abort(module_stage)
    if module_state.active ~= module_stage then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    -- 尝试恢复每个模块并收集全部故障；单个模块失败不跳过其他模块。
    local errors = {}
    for _, entry in ipairs(module_stage.entries) do
        local ok, message = pcall(function()
            assert(package.loaded[entry.name] == entry.live and getmetatable(entry.live) == nil,
                "模块缓存身份或元表变化: " .. entry.name)
            if module_stage.committed then
                replace_exports(entry.live, entry.old)
            end
        end)
        if not ok then
            errors[#errors + 1] = tostring(message)
        end
    end

    -- 只有所有旧导出都确认恢复后才释放 Stage 和旧快照。
    if #errors > 0 then
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end

    return M.finish(module_stage)
end
```

函数一开始先确认当前 `module_state.active` 就是传入的 `module_stage`，拒绝撤销其他更新留下的记录。

随后按 `module_stage.entries` 的数组顺序遍历每个模块记录。我们的案例只有 `lualib.player_logic`。它先检查 `package.loaded[entry.name]` 仍然是 Stage 时保存的那张旧 `live` 根表，随后根据 `module_stage.committed` 决定是否恢复导出字段。

如果 Stage 已成功但尚未 Commit，线上模块表不需要反向替换，因此直接完成清理即可。如果 Commit 已经开始或完成，`abort()` 则调用：

```lua
replace_exports(entry.live, entry.old)
```

这是 `M.abort()` 中对旧导出字段的恢复操作。注意这里再次调用的是**同一个** `replace_exports()`：先清理当前 `live` 根表上的 V2 字段，再把 Stage 之前保存的 V1 旧导出字段写回来。

因此恢复后：

```text
logic == logic_root                    true
logic.version()                       "v1"
logic.settings                         → 原 V1 settings 表
logic.settings == old_settings         true
logic.legacy_tag                      "only-v1"
logic.new_tag                         nil
```

整个过程没有创建替代的模块根表，也没有让 `package.loaded` 指向另一个对象。**Commit 是在原根表上安装 V2 字段；Abort 是在同一根表上重新安装 V1 字段。**

`abort()` 把每个模块的恢复操作放在独立 `pcall()` 中，是为了一个模块出现恢复错误后，仍继续尝试恢复其他模块，并收集全部失败信息。只要存在任意失败，它就返回 `HU_RECOVERY_REQUIRED`，保留 `module_state.active` 及旧快照，不能声称整个模块更新已经撤销成功。

当前实验只有一个普通模块，没有外部干扰，所以应当成功。`M.abort()` 随后调用 `M.finish(module_stage)` 释放本次 Stage 的记录。它并不是“撤销失败后仍强行释放”，而是**确认所有模块的导出字段都恢复成功后**才释放。

### Abort 会恢复闭包私有 upvalue 吗？

它并没有逐个调用“把 V2 count 改回 2”的代码，也没有对 upvalue 执行特殊操作。这里反而更容易观察到当前设计的思路：

- V1 旧 `next_count` 闭包一直活着，只是 Commit 后它不再挂在 `logic.next_count` 字段上。
- Stage 调用 `V1.export_state()` 取出的是独立快照；`V2.import_state()` 修改的是**新候选闭包**的 count，而不是 V1 原有 count。
- Commit 后，我们调用了一次 V2 的 `next_count()`，让 V2 count 从 2 变为 3；这次调用没有碰到 V1 count。
- Abort 恢复的是旧导出字段引用，包括原 V1 `next_count`、`export_state` 等闭包；因此恢复后的 `logic.export_state().count` 仍然是 V1 保留的 2。

也就是说，这里旧状态恢复成功，不是因为引擎神奇地回滚了任意 Lua upvalue，而是因为**在正常合同下，旧闭包的私有状态从来没有被改写过**。

当然，如果旧模块的 `export_state()` 自己修改了旧 count，或者候选脚本越权修改了外部对象，就不能根据上述机制断言私有状态会完整恢复。因此源码明确要求模块顶层和状态钩子受信、同步、无不可撤销副作用。

### 为什么实验中的玩家装备仍然是“剑”？

回到我们自己的 `run_module_patch.lua`，Abort 后紧接着输出：

```lua
print("Abort:", logic.version(), state.equip, old_load(100), logic.export_state().count)
```

这句来自教学实验入口。预期打印：

```text
Abort: v1 剑 100 2
```

这不是恢复失败，而是在准确体现 **Module Patch Engine 的职责边界**。

`M.abort()` 已经恢复模块导出表，`logic.version()` 确实变回 V1；`old_load` 也仍然执行 V1 函数。

但前面我们直接修改过：

```lua
state.equip = "剑"
```

这个 `state` 是我们创建的外部业务表，并不是普通模块引擎的旧导出字段。单独调用 `module_patch.abort()` 根本不知道它之前是“刀”，自然不会替我们修改它。

因此在我们这个脱离完整 Service 事务的实验里，状态仍是“剑”，旧 V1 攻击函数于是返回 100。

实验下一句手工执行：

```lua
state.equip = "刀"
```

这是为了给第二次更新恢复 V1 初始业务环境。真正的 HotUpgrade 不会让开发者在管理端手工这样补偿；第 4 课学过的 Service Patch 已经在同一个事务中保存了旧业务状态，并在本地恢复时处理。

**本课要记住的边界：模块 Abort 负责模块导出；Service Abort 负责玩家业务状态和登记的业务函数；Controller 负责协调目标与正式文件恢复。** 这三层恢复属于不同对象，不能混成一个 `module_patch.abort()`。

## 七、第五阶段：Finish 为什么只清理记录，却不再改模块表？

现在我们已经通过第一次 Abort 回到了 V1 模块导出内容，并手工恢复了实验的 `state.equip="刀"`。

实验入口再次调用 `module_patch.stage(modules)`。因为之前 `M.abort()` 已成功清理 `module_state.active`，这次 Stage 被允许。它重新读取**我们已经保存在 `modules` 里的同一份 V2 源码字符串**、检查当前 V1 的导出、建立新的 Stage，并把 V1 私有 `count=2` 导入新的 V2 候选闭包。

然后第二次 `module_patch.commit(prepared_again.stage)` 再次把 V2 导出字段装入原来的 `logic` 根表。为了模拟整批 Service 更新成功，我们再次把实验的 `state.equip` 改为“剑”。

这一次没有 Abort，而是执行：

```lua
local finished = module_patch.finish(prepared_again.stage)
```

调用者是教学实验入口；完整工程里则是 `flywow_hotupgrade.lua` 的 `handle_upgrade("finish")` 在 Controller 已做出发布决定后调用。

我们进入真实 `hotupgrade/lualib/flywow_hotupgrade_module_patch.lua` 的 `M.finish()`：

```lua
function M.finish(module_stage)
    if module_state.active ~= module_stage then
        return hotupgrade_result.failure("HU_PHASE_INVALID", "模块 Stage 不属于当前更新")
    end

    module_stage.entries = {}
    module_state.active = nil
    return hotupgrade_result.success()
end
```

整个函数就这些代码。它确认传入的是当前正在活动的 Stage，然后清空 `entries`，解除其中候选和旧字段的引用，最后让引擎的 `module_state.active=nil`。

**它没有再次执行 V2 文件，没有再次修改 `logic`，也没有把模块表替换成 `candidate`。** 因为 Commit 已经完成了线上字段更新，Finish 只负责丢弃本批次以后不再需要的候选和旧快照引用。

特别注意“释放”的实际含义：这里只是解除 Module Patch Engine 对这些对象的引用，让没有其他引用的对象有机会被 Lua GC 回收，并不是调用析构函数强制删除所有旧闭包。

例如我们的脚本始终保存着 `old_version`、`old_load` 和 `old_settings`。即使 `finish()` 已经清空 `module_stage.entries`，这些旧对象仍然被我们的变量引用，所以仍然可以使用：

```text
old_version() = "v1"
old_load(100) = 100      （此时 state.equip 是“剑”）
old_settings.bonus = 5
```

而 `logic` 根表已保留 V2 字段：

```text
logic.version() = "v2"
logic.make_load(state)(100) = 121
logic.settings.bonus = 21
logic == logic_root = true
```

Finish 的一个重要意义是：它**终结本次模块引擎的恢复记录**。后续再以同一个 Stage 记录调用 `M.abort()`，由于 `module_state.active` 已经清空，将返回 `HU_PHASE_INVALID`。如果将来再次发布新版，要重新 Stage，构建新的快照和候选。

### Finish 完成后的最终状态快照

```text
module_state.active = nil

logic                         → 原根表，现装载 V2 导出字段
logic_root                    → 同一根表
package.loaded["player_logic"]          → 同一根表
package.loaded["lualib.player_logic"]   → 同一根表

old_version                   → 独立保存的 V1 函数
old_load                      → 独立保存的 V1 攻击闭包
old_settings                  → 独立保存的 V1 嵌套表

V1 count                      → 若无其他业务缓存其旧函数，已不再被引擎持有，可回收
V2 count                      → 由已安装的 V2 闭包持有，当前为 2

本次 module_stage.entries   → 空表
```

这时，再调用 `logic.next_count()` 会执行 V2 版本，从 V2 自己的 count=2 增加到 3。虽然两个版本在初始化迁移时数值一致，**两者不是同一个 upvalue**。

## 八、把刚才的实验重新放回真实 PlayerService Update 调用链

到这里，我们已经独立走通了引擎的四个函数，接下来必须确认：生产环境到底是谁调用它们？各自在哪个 Service、哪个 Lua State 中执行？何时可以修改线上表？

沿第 4 课的调用链，管理端 `begin({path="v2"})` 之后，Controller Service 的 `flywow_hotupgrade_controller.lua` 使用 `M:run_batch()` 调度发布批次。它通过 `M:step()` 给目标 `PlayerService` 发送 `"hotupgrade"` 协议的 `"update"` 请求。

最新源码中，`M:step()` 构造 Update 请求时使用的真实片段是：

```lua
if command == "update" then
    request.modules = target.modules
    request.service_source = target.service_source
end

batch.control_started = true
local ok, answer = pcall(skynet.call, target.service_handle, "hotupgrade", command, request)
```

来源：`hotupgrade/lualib/flywow_hotupgrade_controller.lua` 的 `M:step()`，调用者是同文件的 `M:run_batch()`。此时执行在 **Controller Service** 中，`target.service_handle` 来自本次已登记目标快照。这个 RPC 发送之后，Controller 协程 yield，直到目标回复。

目标 `PlayerService` 此前已经执行 `hotupgrade.register_service()`，因此本地注册了 `"hotupgrade"` 协议的 dispatch。接收到 Update 以后，进入它自己 Lua State 中：

`hotupgrade/lualib/flywow_hotupgrade.lua` 的 `handle_upgrade("update", request, source)`。

此时 Prepare 必须已完成，本地 `txn.phase` 为 `QUIESCED`，`hot.patching=true`，业务 queue 已通过安全点。下面是最新源码中 Update 的**完整分支**。我们之前讲的引擎 Stage 和 Commit，就在这里调用：

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
end
```

这段代码的来源是 `flywow_hotupgrade.lua` 的 `handle_upgrade()`，不是 Module Patch Engine 自己的代码；调用者是当前 `PlayerService` 的 HotUpgrade 协议 dispatch。它把两种更新放在同一个本地 Update RPC 中：

第一步 `hotupgrade_module_patch.stage()`：把普通 Lua 模块的候选和旧字段准备好。

第二步 `stage_service()`：把一次性 Service Patch 的状态迁移候选和函数替换内容准备好。

第三步 `hotupgrade_module_patch.commit()`：把普通模块的 V2 完整导出字段安装到原模块根表。

第四步：原地更新 Service `state`，再替换 Service `functions` 中指定的业务函数，最后执行 `after_upgrade()` 验证。

如果在 Activate 中失败，就先尝试本地 `abort(txn)`；之后 Controller 得知失败，还会按整批恢复流程处理。这里不再逐个重讲 Service Patch 的状态恢复算法，那属于第 3、4 和第 7 课。当前只需要认清：**普通模块引擎的 `stage/commit/abort/finish` 是嵌在整个 PlayerService 事务之内的内部步骤。**

### 为什么普通模块 Stage 之后不能直接 Finish？

从真实调用顺序现在可以准确回答这个问题。

Stage 只准备候选，线上表仍是 V1。Commit 才真正修改线上表。但 Commit 完成，也不意味着整个发布成功：Service 内状态更新、业务 `after_upgrade()`、其他目标的 Update、正式 `.lua` 文件部署和 Skynet 代码缓存清理都需要成功。

因此，Module Patch Engine 必须让旧导出字段保留在各模块记录的 `entry.old` 中，直到 Controller 通知当前目标 Finish。若在发布决定前失败，则用 Abort 安装旧字段。若发布决定已经作出，才由 Finish 释放旧快照。

这解释了为什么引擎在 `commit()` 后仍保留 `module_state.active`，不在成功返回后自动释放。

### 真实 Service 中 Abort 到底多做了什么？

最新 `flywow_hotupgrade.lua` 的本地 `abort(txn)` 不是简单转发 `hotupgrade_module_patch.abort()`。我们看其完整实现：

```lua
local function abort(txn)
    -- 先尝试恢复 Service 私有状态，再恢复模块导出；一个失败也继续另一项。
    local errors = {}
    local ok, message = pcall(restore_service, txn)
    if not ok then
        errors[#errors + 1] = tostring(message)
    end

    if txn.modules then
        local restored = hotupgrade_module_patch.abort(txn.modules)
        if not restored.ok then
            errors[#errors + 1] = restored.message
        else
            txn.modules = nil
        end
    end

    -- 任何恢复项失败都保留关闭状态；只有全部恢复成功才释放事务。
    if #errors > 0 then
        txn.phase = "RECOVERY_REQUIRED"
        return hotupgrade_result.failure("HU_RECOVERY_REQUIRED", table.concat(errors, "; "))
    end

    module_state.completed_sequence = txn.sequence
    module_state.last_batch_id = txn.batch_id
    module_state.active_transaction = nil
    M.patching = false
    return hotupgrade_result.success()
end
```

它来自 `hotupgrade/lualib/flywow_hotupgrade.lua`，由本地 `handle_upgrade("abort")` 调用，也会被 Activate 失败路径调用。

`restore_service(txn)` 先负责恢复登记的 Service 私有状态和被改写的业务函数字段；`hotupgrade_module_patch.abort(txn.modules)` 再恢复普通模块导出。任一项失败都保留恢复信息和 `patching=true`，只有确认全部成功才清理本地活动事务并重新开放业务。

这正好对应我们在独立实验里看到的区别：单独的 `module_patch.abort()` 不知道外部的 `state.equip`，而完整的 `abort(txn)` 才持有并恢复 Service 部分的旧状态。

### 真实 Service 中 Finish 什么时候调用引擎 Finish？

与之对应，Controller 在文件部署成功并做出发布决定后，向 PlayerService 发送 `"finish"`。当前 Service 的 `handle_upgrade()` 执行以下真实分支：

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

这段属于 `flywow_hotupgrade.lua` 的 `handle_upgrade()`，在目标 Service 内执行。它先释放本地普通模块旧快照，再清理本地事务并把 `hot.patching` 改回 `false`。

你现在可以把三个名字相近、但生命周期和职责不同的对象分开：

```text
Controller Service
    active_batch          整批发布的状态和结果

PlayerService / flywow_hotupgrade.lua
    active_transaction    当前 Service 的完整本地事务，包含模块和 Service 更新记录

PlayerService / flywow_hotupgrade_module_patch.lua
    module_state.active   当前 Lua State 中 Module Patch Engine 的候选和旧导出快照
```

一个 Controller 批次可以协调多个 PlayerService；每个 PlayerService 都有自己的 Lua State、自己的本地完整事务，以及在该 State 内独立加载的 Module Patch Engine 状态。Controller 不会跨 Lua State 直接拿到 `logic` 或 `module_stage` 这些 Lua table。

## 九、私有状态的真正边界：`export_state/import_state` 不能替代万能 upvalue 更新

经过前面真实源码和实验，现在可以准确说明 `export_state/import_state` 的使用范围。

正常更新中，`entry.live.export_state()` 从旧模块闭包中导出一份普通数据；`copy_state()` 将它隔离；`candidate.import_state(snapshot)` 再将它导入新的候选模块闭包。导入成功后，新的 `count` 值就由 V2 函数自己的 upvalue 维护。

这不是在修改 `old_load` 或其他旧闭包，也不是让所有旧函数引用自动转向新函数。

我们的实验里有两种不同的旧引用：

- `old_version` 指向 V1 版本函数，Commit/Finish 后仍然返回 `v1`。
- `old_load` 指向 V1 创建的攻击闭包，继续执行“刀 +5”的判断，同时读取它捕获的**同一张可变 `state` 表**。

而 `M.next_count` 是普通模块的导出函数字段。热更后，通过 `logic.next_count()` 调用的是 V2 闭包；若其他业务提前保存了 `local cached_next = logic.next_count`，则那个引用继续调用 V1 闭包，访问 V1 自己的 `count`。

因此 `export_state/import_state` 解决的是**候选模块需要从旧模块继承哪些私有数据**的问题，而不是“所有旧闭包都会切换到新代码”的问题。

以下两种设计在业务上不能混淆：

```lua
-- 每次经模块表取函数，会看到当前已安装的导出字段。
logic.next_count()

-- 提前缓存旧函数，热更不负责自动替换这个局部变量。
local cached_next = logic.next_count
cached_next()
```

这段是根据我们 `player_logic.lua` 给出的**调用方式示意**，不是框架的源码。它只用于说明为何缓存的旧函数引用仍具有旧版行为。

`export_state()` 返回值还必须满足 `copy_state()` 的普通数据图合同。它不能直接把 Lua 函数、userdata、线程或带元表对象作为需要拷贝的状态值交给引擎。状态钩子必须成对定义在模块导出表上；既不能只留一边，也不能返回 `false` 来假装迁移成功。

在设计普通模块时，如果没有需要跨版本继承的私有状态，**不用为了符合形式而增加这两个钩子**。我们本课放入 `count`，只是为了亲眼验证当前引擎的迁移流程。

## 十、运行与逐项验收

前面我们创建了三个完整文件，都是普通 Lua 文件。本实验不启动 Skynet，也不调用 Native。需要使用项目固定兼容的 Lua 5.4，原因包括源码中使用了 `math.type()` 等 Lua 5.4 API。

在 FlyWow 仓库根目录执行：

```bash
lua5.4 hotupgrade/lesson5/run_module_patch.lua
```

如果本机 Lua 5.4 可执行程序名是 `lua`，则用：

```bash
lua hotupgrade/lesson5/run_module_patch.lua
```

本课代码依赖的 `flywow_hotupgrade_module_patch.lua`、`flywow_hotupgrade_error.lua` 和 `flywow_hotupgrade_common.lua` 都通过脚本设置的 `package.path` 从仓库现有目录加载，不需要复制核心源码文件。

按照目前真实源码和这三个教学文件，完整实验预期输出的关键数据是：

```text
V1:                 v1   105   2
Stage:              v1   2
Commit:             v2   121   100
字段:               nil  only-v2   21
表身份:             true false
候选私有计数:       3
Abort:              v1   剑   100   2
旧字段恢复:         only-v1   nil   true
Finish:             v2   121   100
旧引用:             v1   5
最终根表:           true true
最终私有计数:       2
```

上面省略了 Lua `print()` 使用 Tab 分隔输出时的精确空白，只表示各行的预期字段值。`Abort` 行里仍是“剑”，正是为了证明模块更新引擎**不负责恢复业务状态**。前面已经解释为什么旧 V1 攻击闭包在这个状态下返回 100。

验收时不要只看是否打印出 V2。按同一条执行时间线，依次观察下面这些事实：

| 执行位置 | 线上导出版本 | V1 私有 count | V2 私有 count | 旧字段快照 | `module_state.active` |
|---|---|---:|---:|---|---|
| 首次 Stage 前 | V1 | 2 | 尚未创建 | 无 | nil |
| 首次 Stage 后 | V1 | 2 | 2 | 已保存 | 当前 Stage |
| 首次 Commit 后、调用 V2 `next_count` 后 | V2 | 2 | 3 | 仍保存 | 当前 Stage |
| Abort 成功后 | V1 | 2 | 不再由引擎持有 | 已释放 | nil |
| 第二次 Stage 后 | V1 | 2 | 2 | 已保存 | 新 Stage |
| 第二次 Commit 后 | V2 | 2 | 2 | 仍保存 | 新 Stage |
| Finish 成功后 | V2 | 不再由引擎保留 | 2 | 已释放 | nil |

这份表只是把刚才已经看到的对象变化压缩到一起，方便验收；它不是替代前面源码讲解的另一套流程。

本课已使用本地 Lua 5.4 动态库，运行由上文摘录的引擎函数和完整教学脚本组成的隔离实验，以上各项输出与实际执行一致。**这不等于已经在 GitHub 仓库的原生构建、Skynet Service 或完整发布事务中执行测试。** 在实际仓库中操作时，应以自己的 checkout 版本和执行结果为准；本课阅读的源码提交已经在开头固定。

## 十一、读完第 5 课，应该建立怎样的执行模型？

到这里，我们没有再重新讲一遍 Controller 的完整发布事务，而是把第 4 课内部的 Module Patch Engine 拆开，亲手执行并阅读了它的真实实现。

整个普通模块引擎可以简化成：

```text
已有 V1 模块表位于 package.loaded
               │
               ▼
   stage(entries)
   · 取得 live（原线上根表）
   · check_exports(live)
   · 保存 old（旧顶层导出字段）
   · load(source) 编译完整 V2
   · chunk() 执行得到 candidate
   · check_exports(candidate) / 检查同名字段类型
   · export_state → copy_state → import_state
   · module_state.active = module_stage
               │
               ▼
   commit(module_stage)
   · 验证 package.loaded 身份仍是 live
   · committed = true
   · replace_exports(live, candidate)
   · 原根表身份不变，导出字段换为 V2
               │
               ├───────────────┐
               ▼               ▼
   abort(module_stage)    finish(module_stage)
   · 恢复 old 旧字段       · 不再修改 live
   · 成功后调用 finish    · 清理旧快照与候选记录
   · 回到旧导出内容       · 保留已经提交的 V2
               │               │
               └───────┬───────┘
                       ▼
              module_state.active = nil
```

最终应该能不查笔记、直接解释以下问题：

1. **为什么 Stage 要分成两个循环？** 先为所有模块固定旧字段并编译候选，再执行候选和迁移私有状态；在安装前完成验证。
2. **为什么 Commit 不是 `package.loaded[name] = candidate`？** 因为现存业务可能持有旧模块根表引用；需要保留 `live` 身份，在上面原地替换完整导出字段。
3. **为什么删除的旧导出字段会消失？** 因为 `replace_exports()` 先清空所有旧字段，再安装 V2 完整字段集合。
4. **为什么旧函数仍能调用？** 因为提前缓存的 Lua 函数本身是独立引用；覆盖 table 字段不改变那个已有引用。
5. **为什么 upvalue 不能简单靠覆盖导出表迁移？** 因为旧候选属于不同闭包；只有经 `export_state/import_state` 明确交换的数据才能按该合同迁移到新闭包。
6. **为什么 Abort 能恢复旧字段？** 因为 Stage 保留了 `old`，Abort 对同一张根表再次调用 `replace_exports()` 安装这些旧值。
7. **为什么 Commit 后不能立即清理 `old`？** 因为整个 Service Update 和正式文件部署还未作出发布成功决定，仍需要具备撤销能力。
8. **为什么 Finish 不能恢复旧模块？** 因为它的职责就是结束本次更新并释放快照；发布决定之后不能把它当成另一次 Abort。
9. **为什么模块 Abort 不会自动恢复玩家装备？** 因为玩家状态属于 Service Patch 的状态快照与恢复，不属于普通模块导出字段。

**本课的重点不是记住几个 API，而是你现在能够打开 `flywow_hotupgrade_module_patch.lua`，从 `stage()` 一直读到 `commit()`、`abort()` 和 `finish()`，知道每一张 table、每一份旧字段引用和每一个闭包私有状态在什么时刻产生、被修改、被保留和被释放。**

下一课将回到 Skynet Service 的真实并发模型，专门研究 `hot.patching`、业务自己的 `skynet.queue()`、Prepare 安全点以及协程 yield 对热更的影响，不再重复普通模块导出替换算法。
