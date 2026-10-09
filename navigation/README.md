# FlyWow Navigation

本模块把地图生产工具和 Server 导航运行时放在同一个功能目录，支持 Unity Authoring → BMAP 候选包 → 验证发布 → Native 加载 → Lua 查询。Gateway 可单独安装；Navigation 不依赖 Gateway、Cluster、Protobuf 或具体战斗规则。

## 目录与边界

| 目录 | 职责 |
| --- | --- |
| `unity/Runtime` | 地图根配置、地表编码、Cell 数据；UPM 运行时程序集 |
| `unity/Editor` | Bake 编排、单层采样、Clearance、校验、Overlay、候选包导出 |
| `unity/Tests/Editor` | 二进制、Clearance、坐标以及新场景 Bake/发布测试 |
| `native/grid_map` | BMAP Reader、只读地图、Registry、A*、smoothing、动态占位、Context |
| `native` | 使用根模块 lua-binding/ 封装的 Skynet Lua ABI 绑定，产出 `flywow_navigation_native.so` |
| `lualib/flywow_navigation.lua` | 宿主 `require "flywow_navigation"` 的稳定入口 |
| scripts/build_flywow.sh (FlyWow 根目录) | 唯一公开构建入口；构建全部 FlyWow Native 模块并执行各自 CTest |
| `tools` | 资产门禁、可复现离线 UPM 安装包构建 |

Battle_1001 场景、出生点、战斗 Tick、技能、协议及 Replay 留在宿主。新增普通导航场景无需课程出生点组件。Unity 原脚本 `.meta` GUID 保留，既有 Scene 的序列化配置通过同一 GUID 绑定到包中的组件。

## 固定基线

C++17、CMake/Linux/WSL2、Skynet v1.8.0 自带修改版 Lua 5.4.7；团结引擎 1.10.0（Unity 2022.3 LTS）、AI Navigation 1.1.7。当前空间是 `ground_2_5d`：XZ 导航平面、Y 地表高度，每个 Cell 只能表达一个高度层。

不要把修改版 Lua 绑定链接到系统 Lua；不要将同 XZ 的两层道路混成一张 Grid。包会明确拒绝多层歧义。本模块未提供飞行、跳跃、Crowd 或 Recast 实现。

## 接入与阅读

- [新 Unity 工程及 Server 接入](导航接入指南.md)：安装、场景配置、Bake、导出、发布和加载。
- [公开合同与生命周期](CONTRACT.md)：坐标、资产、Lua 返回值、状态归属和失败处理。
- [迁移与回滚](UPGRADE.md)：旧路径、旧模块名以及成套升级范围。

可运行的最小新场景入口是 `Tools/FlyWow/Navigation/创建最小接入场景`。`NavigationPublicationTests` 使用公开组件与方法完成 Bake→采样→Clearance→校验→导出，不依赖课程代码；它同时锁定幂等导出和损坏清单拒绝。

## 独立验证

从 Server 根目录执行；命令中的两个相对路径分别指向固定 Skynet 与 FlyWow submodule：

```bash
bash third_party/skynet-flywow/scripts/build_flywow.sh third_party/skynet
python3 -m unittest discover -s third_party/skynet-flywow/navigation/tests -p 'test_navigation_tools.py'
python3 third_party/skynet-flywow/scripts/ci/check_repository.py
```

Unity 工程在 manifest 的 `testables` 中加入 `com.flywow.navigation`，在 Test Runner 执行 `FlyWow.Navigation.EditorTests`。测试应在隔离工程运行，避免加载其它 Scene 的 NavMesh。

`navigation_benchmark` 是单独产物，不是 CTest 门禁。吞吐、总地图数、总 Context 内存和商业负载容量需要宿主按地图规模另外验证；不能从这些功能测试推断上线容量。

单位间接近使用 `context:find_path_to_unit_range`，坐标范围查询保留中心语义。
可选 `allow_partial` 默认关闭，通过 `path:status()` 区分 `reached` 与 `partial`。
几何边界、零范围接近容差及失败合同见 [CONTRACT.md](CONTRACT.md)。
