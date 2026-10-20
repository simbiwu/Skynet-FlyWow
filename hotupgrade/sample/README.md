# PlayerService 热更示例

示例在真实 Skynet 进程中运行完整发布：以 V1 创建 PlayerService，更新同一实例的模块、状态和业务函数，再创建一个读取 V2 宿主文件的新实例。示例不修改 HotUpgrade 核心或 Skynet。

## 构建和运行

从 FlyWow 根目录执行：

```sh
bash scripts/build_flywow.sh ../skynet hotupgrade
bash hotupgrade/sample/run_hotupgrade_sample.sh ../skynet
```

运行脚本在 Native 文件缺失时调用现有构建脚本，并在 `build/hotupgrade-sample/` 创建运行目录和日志。Skynet 根目录是脚本的唯一位置参数。成功时输出 `HOTUPGRADE_SAMPLE_OK`；失败时输出错误及 Controller 生命周期状态并返回非零状态。

## 文件职责

- `run_hotupgrade_sample.sh`：准备独立运行目录并启动 Skynet。
- `skynet_config.lua`：按真实集成测试配置 loader、Service、Lua 和 Native 搜索路径。
- `flywow_hotupgrade_sample.lua`：初始化 Controller，创建实例，依次执行 begin、部署、cache clear、apply 和验收。
- `host_v1/`：初始宿主文件；Service 入口在 `service/player_service.lua`，普通模块在 `lualib/player_logic.lua`。
- `patches/v2/`：完整普通模块 V2 和一次性 Service Patch。

## 调用顺序和代码差异

主 Service 在 Skynet 协程内加载 `flywow_hotupgrade`，用 `skynet.uniqueservice("flywow_hotupgrade_service")` 取得 Controller 并初始化配置。它通过 `hotupgrade.newservice("player_service")` 创建 Service，再发送 `init`。PlayerService 以 `hotupgrade.require("player_logic")` 加载模块，最后通过 `register_service()` 声明 `service_module = "player"`、状态根表和业务函数表。

V1 的 `make_load(state)` 返回捕获状态表的函数：装备为“刀”时基础攻击力加 5。初始化状态是“刀”、等级 50、schema 1。主 Service 从 PlayerService 的 Guard 保护查询读取真实 RPC 返回值，断言模块版本 v1 且 `load(100) = 105`。

主 Service 调用 `begin`，轮询状态直到 `DEPLOYING`，再把 V2 普通模块及 Service Patch 完整复制到运行时 `root_path` 对应位置。复制失败不会继续；成功后调用 `skynet.cache.clear()`，以同一个 `batch_id` 调用 `apply(path = "v2")`，并轮询到 `COMPLETED`。所有等待都有 tick 上限。

V2 普通模块完整替换导出内容：`version()` 返回 v2，装备为“剑”时 `make_load(state)` 计算基础攻击力加 20 再加 1。模块导出表和两种 `package.loaded` 名称仍保持同一张表，但这不会改写 PlayerService 缓存的旧 `business.load` 函数变量。示例保留旧函数引用，并检查 Service Patch 是否显式替换了 `business.load`。

Service Patch 的 `migrate(old_state)` 检查 schema 1 并返回完整的新状态：装备“剑”、等级 50、schema 2。其 `functions.load` 捕获该 Service 的状态根表并安装 V2 计算。原实例完成后须保持 handle、状态根表和模块导出表身份（通过 Service 实际返回的稳定身份标识比较），版本、状态和函数均已更新，攻击值为 121，Guard 已开放。

随后创建第二个 PlayerService。它从已部署的宿主文件加载 V2，以“剑”和 schema 2 初始化；通过自己的 `make_load(state)` 得到 `load(100) = 121`，与原实例业务版本一致。
