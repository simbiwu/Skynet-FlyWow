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
| `context:set_cell_rule(x,z,rule)` | 成功布尔值 | 运行时设置当前 Battle 单格重叠规则；不影响其它 Context |
| `context:find_path(...)` | Path userdata | 按 Agent 静态规则与当前动态事实规划路径 |
| `context:find_path_to_range(...)` | Path userdata | 寻找可站立且进入目标范围的位置，不要求占据目标中心 |
| `context:place_unit(...)` / `move_unit(...)` / `release_unit(...)` | 成功布尔值或新位置 | 本 Context 的动态占位操作 |
| `context:advance_path(...)` | 移动结果 record | 消耗 Tick 距离预算，跨格复验后提交占位与 cursor |
| `context:cell_size_mm()` | 整数毫米边长 | 只读地图尺度 |
| `context:close()` | 无返回值 | 幂等释放 Context；后续访问返回关闭错误 |
| `path:count()` / `world_point(index)` / `length_mm()` | 点数/位置/整数长度 | Path 独占世界点和推进 cursor；不能跨单位共享推进状态 |

参数 record、稳定错误码和边界检查以 `native/lua/src/lua_navigation.cpp` 为实现合同。所有公开 Binding API 的失败——包括参数类型/范围错误、地图未加载、越界、不可达、动态占用和 Context 已关闭——统一返回 `nil, {code,message}`，不通过 Lua 错误机制抛出。调用方必须检查第一个返回值，并按稳定 `code` 处理；`message` 只用于诊断。Native 查询不执行 Skynet yield。

`context:set_cell_rule(x,z,rule)` 使用零基 Grid 坐标；`rule` 为 `"allow"`、`"block"` 或 `"default"`。它只影响当前 Battle Context；`default` 清除该格覆盖，恢复默认允许重叠行为。未设置规则时无需额外配置。规则只约束已有其他单位时是否允许重叠，不会封闭空格；修改规则不移动已经占位的单位，后续寻路和移动检查使用新规则。

## 状态归属

Registry 的地图以 `shared_ptr<const GridMap>` 共享；注册受锁保护，不共享可变查询 scratch。每个 Context 拥有 Node/Heap/occupancy 和稀疏动态规则，单个 Context 必须由一个执行 owner 顺序使用；不同 Skynet Service 不能并发操作同一个可变 Context。

静态 Clearance 是 Bake 后到障碍和边界的保守格距，动态单位不会重写它。动态 footprint 与可通行规则在规划和移动时另外验证；旧 Path 不能直接授权移动。Clearance、footprint、A*、区域 Dijkstra、smoothing 和逐格移动复验的推导、例子及不变量保留在对应源码注释中。

Context 构造按 Cell 数分配 dense scratch，地图变大和同时 Battle 增加都会增长内存。Registry 生命周期是 OS 进程；本版没有地图卸载 API。热更不是就地修改只读地图，宿主使用新版本并决定旧 Battle 何时退出。

## Native Binding 实现边界

导航通过 `lua-binding/` 的 LuaBinding/LuaTable 读取参数、创建结果和管理 userdata，不直接维护 Lua 栈。Lua API、坐标与领域错误码保持上述合同。C++ 入口只交给初始化适配器；普通失败正常返回，C++ exception 在统一入口转为 INTERNAL_ERROR。

Context/Path 使用统一类型核验与 GC。close 幂等释放 Context 大块内存，profiles/vector 外壳由最终 GC 析构；已关闭的 Context 返回 CONTEXT_CLOSED。重复 GC 不重复析构，不匹配或已经析构的 userdata 返回 INVALID_ARGUMENT。

封装内部注释按栈底到栈顶用 `[S, table, value]` 说明 Lua C API；S 是进入操作前已有内容。栈、registry 引用、closure/upvalue 和 GC 的详细合同见 [Lua Binding 使用说明](../lua-binding/使用说明.md)及对应实现，不在导航业务函数中重复 Lua 栈教程。


## 单位边缘范围与部分路径

`find_path_to_range(profile_id, start, target, range_mm, mover_unit_id[, allow_partial])`
保持中心距离语义。`find_path` 也在最后增加同样的可选参数。省略、nil、false
均关闭部分路径；错误类型返回 `INVALID_ARGUMENT`。

新增 `find_path_to_unit_range(mover_profile_id, start_world, target_profile_id,
target_world, edge_range_mm, mover_unit_id[, allow_partial])`。双方半径来自 Context
构造时复制的 Profile，目标位置和 Profile 必须由调用者保持一致，不反查 Occupancy。
`mover_unit_id` 用于忽略移动者自身占位。允许重叠也不把目标圆形体型内部作为终点。
正范围的终点满足 `r_mover+r_target <= 中心距离 <= r_mover+r_target+edge_range_mm`。
这只约束终点，沿途仍使用原有格子重叠策略。

零范围采用 `ceil(sqrt(2)*cell_size_mm)` 接近容差，在容差内选择中心距离最小的
可达合法格，再按路径成本、格子索引打破平局。需要遍历当前可达区域，最坏与 NO_PATH
搜索相同。该规则是格子接近，不是几何接触；静态净空与动态占位仍可能返回 NO_PATH。

成功结果可调用 `path:status()`：`reached` 表示终点满足查询目标；`partial` 表示
搜索耗尽后返回最接近目标中心的可达合法格（单位查询排除体型内部）。距离相同按
最低已走成本、稳定格子索引选择。默认关闭；非法参数、越界、非法起点不会转为成功。
没有更接近目标的实际移动仍返回 NO_PATH。精确终点不可站立时默认返回
END_NOT_NAVIGABLE；开启 partial 后继续搜索。查询状态与 advance_path 的执行状态独立。
旧 Lua 调用保持兼容；新增 C++ 可选参数需要重新编译使用者。
