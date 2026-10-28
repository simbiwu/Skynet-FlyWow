# PlayerService 热更示例

这个示例只演示一条流程：启动 V1 PlayerService，发布 V2，观察原实例更新，再启动一个读取 V2 文件的新实例。

## 运行

从 FlyWow 根目录执行：

    bash scripts/build_flywow.sh ../skynet hotupgrade
    bash hotupgrade/sample/run_hotupgrade_sample.sh ../skynet

成功时会看到三行版本结果：

    V1 handle=... module=v1 equip=刀 level=50 schema=1 attack=105
    V2 existing handle=... module=v2 equip=剑 level=50 schema=2 attack=120
    V2 new handle=... module=v2 equip=剑 level=50 attack=120
    HOTUPGRADE_SAMPLE_OK

运行脚本把 host_v1/ 和 patches/v2/ 复制到 FlyWow 的 build/hotupgrade-sample/。示例从 Server 工作目录启动，因此 Controller 的路径直接写在 flywow_hotupgrade_sample.lua；不依赖环境变量。

## 文件

- flywow_hotupgrade_sample.lua：按顺序执行初始化、创建实例、发布、等待完成和读取结果。
- host_v1/：初始 PlayerService 和 V1 普通模块。
- patches/v2/：完整 V2 模块、新增的 combat_rules 模块、部署后的 Service 文件，以及更新现存实例的一次性 player_service.patch。
- skynet_config.lua：本示例使用的 Skynet、FlyWow 和宿主代码搜索路径。

PlayerService 的 skynet.queue() 是更新安全点的一部分：更新前停止新业务，再等待正在执行的业务结束。V1 攻击值是 105；发布后原实例的装备状态迁移为“剑”，业务函数更新为 V2，攻击值变成 120。新实例从已部署的 V2 文件启动，也得到 120。

Prepare 排空期间，队列中已进入的业务仍可正常创建 Service 或首次加载模块。Controller 会等待这些操作完成，并让新增的匹配目标也执行一次 Prepare；全部准备好后才在 Update 前关闭创建和加载门禁，后续请求由框架等待到发布结束。

Service Patch 用 new_modules 声明本 Service 首次使用的 combat_rules。Controller 先部署全部 Lua 文件，目标再加载并登记该模块，然后 Stage player_logic；因此 V2 候选中的 hotupgrade.require("combat_rules") 能命中已登记模块，不会在 UPDATE 等普通首次加载许可。新模块不加入当前批次的模块 Stage，下一批才可作为普通模块更新。Service Patch 的 update_state() 在 Update 中直接修改现存 state；未修改字段保留，嵌套赋值和赋 nil 删除遵循 Lua 语义。replace_functions 指定要替换的现有函数；旧快照仅用于恢复。

## 返回值合同

框架内部可失败操作返回 FlyWowResult<T>：先判断 ok，再读成功载荷 value；失败诊断使用 code、message 和可选 details。hotupgrade.require、newservice、uniqueservice 保持原生 Lua/Skynet 风格，成功直接返回模块表或 handle，失败抛错；首次受控加载、许可等待和 Service 创建可能 yield，调用方可用 pcall 包住这些适配入口。

模块 export_state 返回自然状态值，import_state 必须返回 FlyWowResult<nil>。默认 snapshot_state / restore_state 与 Service 自定义 snapshot / restore 分别返回 FlyWowResult<any> / FlyWowResult<nil>。before_upgrade、after_upgrade 固定返回 boolean：仅 true 表示通过，false 表示拒绝；异常由框架回调边界转换为阶段结果。
