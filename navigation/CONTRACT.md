# Navigation 公开合同

## 资产与空间

BMAP V1 沿用原二进制布局：Little Endian，64-byte Header，8-byte Cell，行主序 `index = z * width + x`。Cell 依次保存 i32 地表高度、u16 flags、u8 Area、u8 Clearance。Manifest 增加 `space_type=ground_2_5d`、`coordinate_axes=x,y_height,z`、完整 BMAP 的 `content_sha256`；BMAP 字节和 format_version 没有因此变化。

原点是 Cell (0,0) 的左下边界，不是中心。第 x 格先从原点走 x 个完整格，再走半格到中心：`origin + x * cellSize + cellSize / 2`。提出共同的 cellSize 才得到 `origin + (x + 0.5) * cellSize`。原点 -15 米、边长 0.5 米、第 3 格中心为 -15 + 1.5 + 0.25 = -13.25 米。

Native/Lua 使用整数毫米世界坐标 `{x_mm,y_mm,z_mm}`。X/Z 决定归格，Y 高度由静态地图提供。负坐标归格使用向负无穷取整；Grid 下标是实现细节，不能成为长期 Replay/Persistence 合同。Manifest 门禁输入上限为 BMAP 128 MiB、清单 64 KiB；宿主还需限制总资产数与 Context 数。

## Lua 入口

| API | 成功结果 | 用途与副作用 |
| --- | --- | --- |
| `load_map(path)` | `{map_id,map_version}` | 启动时读取及注册地图；文件 I/O、分配、Registry 短锁 |
| `query_cell(id,version,worldPosition)` | Cell 查询 record | 只读查询；返回 grid 调试下标、高度、Area、Clearance、walkable |
| `new_context(id,version,profiles)` | Context userdata | 每场 Battle 独占；分配 A* scratch 与动态占位 |
| `context:find_path(...)` | Path userdata | 按 Agent 静态规则与当前动态事实规划路径 |
| `context:find_path_to_range(...)` | Path userdata | 寻找可站立且进入目标范围的位置，不要求占据目标中心 |
| `context:place_unit(...)` / `move_unit(...)` / `release_unit(...)` | 成功布尔值或新位置 | 本 Context 的动态占位操作 |
| `context:advance_path(...)` | 移动结果 record | 消耗 Tick 距离预算，跨格复验后提交占位与 cursor |
| `context:cell_size_mm()` | 整数毫米边长 | 只读地图尺度 |
| `context:close()` | 无返回值 | 幂等释放 Context；后续访问返回关闭错误 |
| `path:count()` / `world_point(index)` / `length_mm()` | 点数/位置/整数长度 | Path 独占世界点和推进 cursor；不能跨单位共享推进状态 |

参数 record、稳定错误码和边界检查以 `native/lua/src/lua_navigation.cpp` 为实现合同。所有公开 Binding API 的失败——包括参数类型/范围错误、地图未加载、越界、不可达、动态占用和 Context 已关闭——统一返回 `nil, {code,message}`，不通过 Lua 错误机制抛出。调用方必须检查第一个返回值，并按稳定 `code` 处理；`message` 只用于诊断。Native 查询不执行 Skynet yield；动态规则回调也必须同步且不能 yield。

## 状态归属

Registry 的地图以 `shared_ptr<const GridMap>` 共享；注册受锁保护，不共享可变查询 scratch。每个 Context 拥有 Node/Heap/occupancy，单个 Context 必须由一个执行 owner 顺序使用；不同 Skynet Service 不能并发操作同一个可变 Context。

静态 Clearance 是 Bake 后到障碍和边界的保守格距，动态单位不会重写它。动态 footprint 与可通行规则在规划和移动时另外验证；旧 Path 不能直接授权移动。Clearance、footprint、A*、区域 Dijkstra、smoothing 和逐格移动复验的推导、例子及不变量保留在对应源码注释中。

Context 构造按 Cell 数分配 dense scratch，地图变大和同时 Battle 增加都会增长内存。Registry 生命周期是 OS 进程；本版没有地图卸载 API。热更不是就地修改只读地图，宿主使用新版本并决定旧 Battle 何时退出。

## Lua 栈阅读约定

Binding 注释中的 `[参数, value, meta]` 按栈底到栈顶排列。`luaL_newmetatable` 在当前 Lua State 注册类型表，首次创建时填写方法与 `__gc`；已经存在时仍把表压到栈顶。`lua_pop(L,1)` 仅移除这次注册的临时栈引用，Registry 仍保存类型表。

C 函数 `return 1` 表示交给 Lua 一个栈顶结果，**不是返回数字 1**；`return 2` 常对应 `nil,error`。`lua_setfield(L,-2,...)` 把栈顶值写进其下面的表并消费该值。每个相关步骤的栈变化、userdata 所有权及 GC 兜底在 Binding 源码中就地说明。
