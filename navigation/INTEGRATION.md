# Navigation 接入指南

## 1. 安装 Unity 包

在固定提交的 FlyWow 中选择 `navigation/unity`，不要再复制旧课程 Runtime/Editor 文件。UPM 包名是 `com.flywow.navigation`；三个程序集为 `FlyWow.Navigation.Runtime`、`FlyWow.Navigation.Editor`、`FlyWow.Navigation.EditorTests`。

同一台机器上可用 Package Manager 的 Add package from disk，选择 `navigation/unity/package.json`。框架开发源在 WSL 而 Editor 在 Windows 时，生成离线包，避免把 WSL UNC 路径作为 UPM 本地目录依赖：

```bash
python3 navigation/tools/package_unity.py --output "$ARTIFACT_DIR"
```

工具返回完整 `.tgz` 路径。Windows Package Manager 使用 Add package from tarball 选择该产物。归档按内容 SHA-256 命名；相同源码重复构建结果一致。归档只是构建产物，源码仍只维护在 FlyWow。

若宿主使用 asmdef，Runtime 调用方引用 `FlyWow.Navigation.Runtime`；Editor 调用方再引用 `FlyWow.Navigation.Editor`。不要让 Player Runtime 引用 Editor 程序集。

## 2. 新场景配置

可以从示例菜单创建地面与障碍，再逐步替换为项目几何。每张场景包含一个 `NavigationMapRoot`，明确设置：

| 字段 | 含义 |
| --- | --- |
| `mapId` / `mapVersion` | 非零资产身份；导航语义变化需递增版本 |
| `originMeters` | Grid 左下角的世界 XZ，允许负坐标 |
| `sizeXMeters` / `sizeZMeters` | 覆盖范围，必须整除 Cell 边长 |
| `cellSizeMeters` | 格子精度；0.5 米是默认值，并非写死限制 |
| `multiLayerSeparationMeters` | 同层采样误差合并阈值，不用它吞掉真实楼层 |
| `exportDirectory` | 完整候选包输出根；相对 Unity 工程根或显式绝对离线路径 |

添加 `NavMeshSurface`，设置收集范围、Collider 几何、Agent、Area。只打开当前目标导航场景；`NavMesh.CalculateTriangulation` 会汇总当前已加载的 NavMesh，额外加载的 NavMesh 会参与采样。若项目使用 Additive 场景，先隔离 Bake/导出上下文，不能假设 Active Scene 会自动过滤 NavMesh。

按菜单顺序：`01 校验当前战斗场景` → `02 烘焙当前场景 NavMesh` → `03 导出当前场景 BMAP`。Bake 生成 Unity NavMesh，导出把它采样成 Server Grid；两者不能互相替代。检查 Overlay 与日志，尤其是窄道、坡地、边界和障碍。

需要出生点或项目规则时，由宿主 Editor 订阅 `NavigationMapExporter.ValidateCandidate`。事件同步执行；抛异常阻止写盘，不改 Snapshot。不要把项目专用组件放进通用包。

## 3. 发布完整资产

每次导出得到：

```text
map-{map_id}-v{map_version}-{content_sha256}/
  map.bmap
  map.manifest.json
```

工具先写独占 `.staging-*`，两份文件写完后以同文件系统目录 rename 提交。失败清理 staging；相同内容重复导出复用已验证候选。改变内容会产生不同候选目录；**这并不授权在正式发布时复用旧 mapVersion**。

发布前执行：

```bash
python3 navigation/tools/verify_asset.py \
    --bmap "$CANDIDATE/map.bmap" \
    --manifest "$CANDIDATE/map.manifest.json" \
    --map-id "$MAP_ID" --map-version "$MAP_VERSION"
```

发布系统把验证通过的完整目录交给 Server，并锁定 ID、版本和 SHA-256。不要分别替换 BMAP 与 Manifest，不从 Server 读取 Unity 工程。当前 Native Reader 校验 BMAP 格式、长度与 CRC；SHA-256 和空间合同由此发布门禁校验。未经门禁的单独 `load_map` 不构成内容身份验证。

## 4. 构建 Native 并配置运行时路径

从 Server 根目录执行唯一公开构建命令：

~~~bash
./scripts/linux/run_server.sh build
~~~

该命令调用 third_party/skynet-flywow/scripts/build_flywow.sh third_party/skynet，生成：
third_party/skynet-flywow/build/native/*.so。Navigation、Gateway Crypto 和 Logger 共用该目录；CMake 中间文件位于 FlyWow build/cmake/<module>/。不需要生成另一个路径配置文件。

Skynet 配置本身以 server/ 为当前工作目录，直接列出真实模块目录。例如 Battle 配置中：

~~~lua
lua_path = "./third_party/skynet-flywow/navigation/lualib/?.lua;" ..
           "./third_party/skynet-flywow/logger/lualib/?.lua"
lua_cpath = "./third_party/skynet-flywow/build/native/?.so"
cpath = "./third_party/skynet-flywow/build/native/?.so"
~~~

lua_path 查找 Lua Wrapper，lua_cpath 查找 require 加载的 Lua Native Binding，cpath 查找 Skynet Native Service。Gateway 进程另外列出 Gateway 的 lualib 和 service 目录；Battle 不加入 Gateway 搜索路径。Logger 的 logservice、logger 输出目录、等级与 preload 也直接配置在各进程配置中。这样从配置即可看出模块由谁使用、从哪里加载，不需要环境变量或生成器间接拼接。

路径相对 Server 根目录，因此启动配置时工作目录必须为 server/；run_server.sh 已固定满足该条件。独立新项目按自己的 third_party/skynet-flywow 相对目录填写相同字段，无需改模块代码。

~~~bash
cd /path/to/project/server
./scripts/linux/run_server.sh build
~~~

~~~
## 5. Lua 使用及清理

普通模块使用 `require "flywow_navigation"`。它不创建 Skynet Service；地图加载放在进程启动阶段，地图只读共享。Battle 自己创建 `new_context`，管理动态占位；具体参数、返回值和错误分支见 [公开合同](CONTRACT.md) 与 C++ Binding 注释。

先检查 `load_map` 返回身份，再按指定 ID/版本查询。资源退出时显式 `context:close()`；GC 负责遗漏清理兜底。Path 已计算出来，不代表下一 Tick 仍可走，移动前由 `move_unit` / `advance_path` 重新验证动态占位。

首次接入至少验证：新场景导出、错误版本/损坏文件拒绝、Native 加载、一次路径、两个 Context 状态隔离、Context 关闭、宿主回放。课程宿主可执行原有 Battle_1001 集成验证；通用包不依赖该地图。
