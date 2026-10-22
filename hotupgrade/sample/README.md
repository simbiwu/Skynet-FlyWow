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
- patches/v2/：完整 V2 模块、部署后的 Service 文件，以及更新现存实例的一次性 player_service.patch。
- skynet_config.lua：本示例使用的 Skynet、FlyWow 和宿主代码搜索路径。

PlayerService 的 skynet.queue() 是更新安全点的一部分：更新前停止新业务，再等待正在执行的业务结束。V1 攻击值是 105；发布后原实例的装备状态迁移为“剑”，业务函数更新为 V2，攻击值变成 120。新实例从已部署的 V2 文件启动，也得到 120。

Service Patch 的 `migrate` 只返回要改的字段；未提供字段保留，嵌套 Table 递归合并，`nil` 不用于删除字段。
