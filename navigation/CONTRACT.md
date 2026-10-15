# Navigation 公开合同

## 资产与空间

BMAP V1 沿用原二进制布局：Little Endian，64-byte Header，8-byte Cell，行主序 `index = z * width + x`。Cell 依次保存 i32 地表高度、u16 flags、u8 Area、u8 Clearance。Manifest 增加 `space_type=ground_2_5d`、`coordinate_axes=x,y_height,z`、完整 BMAP 的 `content_sha256`；BMAP 字节和 format_version 没有因此变化。

原点是 Cell (0,0) 的左下边界，不是中心。第 x 格先从原点走 x 个完整格，再走半格到中心：`origin + x * cellSize + cellSize / 2`。提出共同的 cellSize 才得到 `origin + (x + 0.5) * cellSize`。原点 -15 米、边长 0.5 米、第 3 格中心为 -15 + 1.5 + 0.25 = -13.25 米。

Native/Lua 使用整数毫米世界坐标 `{x_mm,y_mm,z_mm}`。X/Z 决定归格，地面 Y 高度由静态地图提供；空中 Y 是显式整数高度。负坐标归格使用向负无穷取整；Grid 下标是实现细节，不能成为长期 Replay/Persistence 合同。Manifest 门禁输入上限为 BMAP 128 MiB、清单 64 KiB；宿主还需限制总资产数与 Context 数。

## Lua 入口

| API | 成功结果 | 用途与副作用 |
| --- | --- | --- |
| load_map(path[,airnav_path]) | {map_id,map_version,content_sha256} | 校验后按 map_id 替换当前地图；已有 Context 继续持有旧地图 |
| `query_cell(id,version,worldPosition)` | Cell 查询 record | 只读查询；返回 grid 调试下标、高度、Area、Clearance、walkable |
| load_navigation_profiles(profiles) | 成功布尔值 | 校验连续 ID 后替换当前导航表；正在执行的同步调用保留其短期快照 |
| new_context(map_id[,air_limits]) | Context userdata | 固定当前地图；每场 Battle 独占 scratch 与动态占位，Profile 每次操作按 unit_id 查当前 Registry |
| `context:set_cell_rule(x,z,rule)` | 成功布尔值 | 运行时设置当前 Battle 单格重叠规则；不影响其它 Context |
| `context:find_path(...)` | Path userdata | 按 Agent 静态规则与当前动态事实规划路径 |
| `context:find_path_to_range(...)` | Path userdata | 寻找可站立且进入目标范围的位置，不要求占据目标中心 |
| `context:place_unit(...)` / `move_unit(...)` / `release_unit(...)` | 成功布尔值或新位置 | 本 Context 的动态占位操作 |
| `context:advance_path(...)` | 移动结果 record | 消耗 Tick 距离预算，跨格复验后提交占位与 cursor |
| `context:cell_size_mm()` | 整数毫米边长 | 只读地图尺度 |
| context:unit_radius_mm(unit_id) | 整数毫米半径 | 读取当前 NavigationProfile Registry；只服务导航 |
| context:map_version() | 地图资产版本 | 读取本 Context 固定地图的实际版本 |
| `context:close()` | 无返回值 | 幂等释放 Context；后续访问返回关闭错误 |
| `path:count()` / `world_point(index)` / `length_mm()` | 点数/位置/整数长度 | Path 独占世界点和推进 cursor；不能跨单位共享推进状态 |

参数 record、稳定错误码和边界检查以 `native/navigation_binding.cpp` 为实现合同。所有公开 Binding API 的失败——包括参数类型/范围错误、地图未加载、越界、不可达、动态占用和 Context 已关闭——统一返回 `nil, {code,message}`，不通过 Lua 错误机制抛出。调用方必须检查第一个返回值，并按稳定 `code` 处理；`message` 只用于诊断。Native 查询不执行 Skynet yield。

`context:set_cell_rule(x,z,rule)` 使用零基 Grid 坐标；`rule` 为 `"allow"`、`"block"` 或 `"default"`。它只影响当前 Battle Context；`default` 清除该格覆盖，恢复默认允许重叠行为。未设置规则时无需额外配置。规则只约束已有其他单位时是否允许重叠，不会封闭空格；修改规则不移动已经占位的单位，后续寻路和移动检查使用新规则。

## 状态归属

MapRegistry 按 map_id 只保存当前只读 GridMap；NavigationProfileRegistry 保存当前导航配置。启动时主动加载配置中的全部地图和完整导航 Profile 表。运行期重新调用 load_map 或 load_navigation_profiles 可替换当前表；地图由 Context 固定持有，Profile 则在每次同步导航操作时短暂持有当前不可变表并按 unit_id 二分查找，替换不会让本次调用失效。UnitProfile 是独立 sharedata 业务配置，Native Navigation 不读取它。每个 Context 只拥有自己的 Node/Heap scratch、occupancy 和稀疏动态规则；单个 Context 必须由一个执行 owner 顺序使用，不同 Battle 不共享这些可变状态。

静态 Clearance 是 Bake 后到障碍和边界的保守格距，动态单位不会重写它。动态 footprint 与可通行规则在规划和移动时另外验证；旧 Path 不能直接授权移动。Clearance、footprint、A*、区域 Dijkstra、smoothing 和逐格移动复验的推导、例子及不变量保留在对应源码注释中。

Context 构造按 Cell 数分配 dense scratch，地图变大和同时 Battle 增加都会增长内存。Registry 生命周期是 OS 进程；本版没有地图卸载 API。热更通过加载完整新对象并替换 Registry 当前指针，不原地修改只读对象；旧对象在引用它的 Context 结束后释放。map_version 仍是地图资产身份，也可用于协议请求校验，但不参与 Registry 选取地图。

## Native Binding 实现边界

导航通过 `lua-binding/` 的 LuaBinding/LuaTable 读取参数、创建结果和管理 userdata，不直接维护 Lua 栈。Lua API、坐标与领域错误码保持上述合同。C++ 入口只交给初始化适配器；普通失败正常返回，C++ exception 在统一入口转为 INTERNAL_ERROR。

Context/Path 使用统一类型核验与 GC。close 幂等释放 Context 大块内存；已关闭的 Context 返回 CONTEXT_CLOSED。重复 GC 不重复析构，不匹配或已经析构的 userdata 返回 INVALID_ARGUMENT。

封装内部注释按栈底到栈顶用 `[S, table, value]` 说明 Lua C API；S 是进入操作前已有内容。栈、registry 引用、closure/upvalue 和 GC 的详细合同见 [Lua Binding 使用说明](../lua-binding/使用说明.md)及对应实现，不在导航业务函数中重复 Lua 栈教程。


## 单位接近范围与部分路径

find_path_to_range(unit_id, start, target, range_mm, unit_instance_id[, allow_partial])
是通用导航范围查询：寻找以目标中心为圆心、距离不超过 range_mm 的可站立 Cell。
这个参数不来源于 UnitProfile.combat.attack_range_mm，也不定义战斗规则。

find_path_to_unit_range(mover_unit_id, start_world, target_unit_id, target_world,
mover_unit_instance_id[, allow_partial]) 按双方当前 NavigationProfile 的半径寻找可站立接近点。
有效中心距区间为 r_mover+r_target 到 r_mover+r_target+ceil(sqrt(2)*cell_size_mm)：
下界避免单位体型重叠，上界只补偿离散 Grid 的接近误差。该查询不接收攻击距离。
Battle 独立按 UnitProfile.combat.attack_range_mm 判定是否攻击；该值是中心点间最大 XZ 距离。

部分路径参数省略、nil、false 均关闭；错误类型返回 INVALID_ARGUMENT。
成功结果可调用 `path:status()`：`reached` 表示终点满足查询目标；`partial` 表示
搜索耗尽后返回最接近目标中心的可达合法格（单位查询排除体型内部）。距离相同按
最低已走成本、稳定格子索引选择。默认关闭；非法参数、越界、非法起点不会转为成功。
没有更接近目标的实际移动仍返回 NO_PATH。精确终点不可站立时默认返回
END_NOT_NAVIGABLE；开启 partial 后继续搜索。查询状态与 advance_path 的执行状态独立。
单位接近 Lua API 已移除 edge_range_mm 参数，所有仓库调用点与签名同步更新；C++ 使用者需重新编译。

## 可选 AIRN V1 资产

Context 创建只需要已加载地图，纯空中调用不需要 ground Profile；地面操作仍在各自入口读取/验证当前 Profile，未配置返回 INVALID_AGENT。

空中能力是现有 GridMap 的可选不可变组成部分，沿用 MapRegistry、NavigationContext、Path 和同一构建产物。BMAP V1 不增加位或字段。Runtime 不读 Manifest，不推断建筑，不自动探测邻接文件。`load_map(bmap[,airnav])` 的显式第二参数缺失/损坏/不配对返回失败，Registry 不替换；空字符串非法。已有 Context 保留原来的完整静态快照。Native `airAsset()` 保存两份文件 SHA-256，Path 持有强快照引用。

`map.airnav` 显式 little-endian；不 dump struct。Header 96 字节：

|偏移|类型/长度|语义|
|---:|---|---|
|0|4 bytes|ASCII AIRN|
|4|u16|format_version=1|
|6|u16|header_size=96|
|8/12|u32/u32|map_id/map_version，必须配对 BMAP|
|16/20/24|u32/u32/u32|width/height/cell_size_mm|
|28/32|i32/i32|origin_x_mm/origin_z_mm|
|36|u32|保留，必须 0|
|40|32 bytes|完整 BMAP 文件 SHA-256 原始字节|
|72/76|u32/u32|稀疏格记录数/总区间数|
|80|16 bytes|保留，全部 0|

接着是按 cell_index 严格递增的 12-byte 格记录：u32 cell_index、u32 interval_offset、u32 count。offset 必须从 0 连续消费完整区间数组，count 为 1..64。之后每区间为 i64 min_y_mm、i64 max_y_mm（16 bytes）；min<=max，同格按高度递增且不重叠。文件长度必须精确 `96 + records*12 + intervals*16`，上限 32 MiB、总区间 1048576。BMAP 的尺寸、原点、身份和完整 hash 必须一致；截断、尾随字节、保留值、错误 offset 均拒绝。Unity/Native/Python 共用 `unity/Tests/Editor/Fixtures` golden bytes。

闭高度区间、静态整格 XZ 保守覆盖；接触边界阻挡。Unity 离线下界 floor/上界 ceil 毫米，负坐标向负无穷取整，格线闭接触包括两侧。仅选择显式 LayerMask 的启用 Collider，默认关闭导出；旋转盒/其它 Collider 使用世界包围盒并警告。保留拱洞需作者用多个盒，不承诺网格精确碰撞。

有空中组件时 Manifest 增加 `capabilities=["air_2_5d"]`、`airnav_sha256`、`package_hash`。包身份是 SHA-256(`ASCII "FlyWow.Navigation.Package.V1\0" + BMAP原始hash32 + byte(1) + airnav原始hash32`)；不包含 Manifest 自己。旧无空中包仍保持旧文件及命名字节。staging 内写入、读回验证全部文件，然后同文件系统原子目录 rename；目标已存在时校验地面、空中与 Manifest 后才幂等成功。失败清理 staging，不发布半包。

## 空中公开操作与所有权

Lua 的六个新增操作都接收一个具名 request；C++ 对应 lowerCamelCase，返回 NavResult。全部同步、不 yield、不 I/O、不回调 Service。字段标准类型见 LuaDoc：

|操作|请求字段|成功结果/语义|
|---|---|---|
|set_air_obstacle|handle,min,max|true；闭整数 AABB，插入/瞬时更新，不代表扫掠移动|
|remove_air_obstacle|handle|true；不存在也成功|
|find_air_path|start,target,flight_y_mm,body,exclude_handle?,range_mm?,策略|Path；起终点 XZ 使用指定 Y，固定高度八邻接；range 为 XZ 中心距离|
|sweep_air|from,to,body,exclude_handle?,策略|首个接触 record；只读连续扫掠，Y 可变|
|move_air|handle,target,策略|新中心；保留注册盒尺寸，包括奇数/矩形边长，全成或全不成|
|advance_air_path|handle,path,distance_mm,策略|moving/reached/blocked、position、consumed_mm、moved|

body 为非负 uint32 `{radius_mm,half_height_mm}`，代表 XZ 对称轴对齐半宽与 Y 半高。handle 为 Context 私有正整数。动态 AABB 的 XZ 必须在地图内，Y 可用完整 int64（体积平移溢出拒绝）。策略 `check_terrain=false`、`clearance_mm=0`；显式启用时盒底必须严格高于所有覆盖格的地表加 clearance。静态/动态默认检查；排除自身不排除静态。ground 与 air 占位独立，不自动同步。

扫掠结果 `{kind="clear"|"static"|"dynamic",handle,cell_index,time_numerator,time_denominator}`。时间分子/分母为十进制字符串，保留完整 uint64；范围 [0,1]。相同时间静态优先，再按格索引/动态 handle。采用完整连续 Minkowski/slab，有理数比较不溢出，不用离散采样或浮点决定顺序。DDA 子段枚举盒体覆盖桶，闭格线和角点保守包含；相邻格边一次包络枚举避免重复。固定高度单次搜索可缓存已经证明没有高度候选的桶；不访问空间桶的缓存复用仍计 tests，真实重复桶访问照常计数。缓存每次搜索清空，不跨动态更新复用。

A* 固定 1000/1414 直/斜成本、固定邻居顺序；同 f 优先较大 g，再按格号。每条参与松弛的边、起终点连接及平滑都使用完整扫掠，斜走不穿角。查询返回的尺寸、高度和静态快照随 Path 保存，不能混用 ground/air 推进。Path 不借用 scratch，也不管理动态对象。动态变化之后每次移动仍复验，不自动重规划。

推进按整数平方根向下取整的 XZ 段长累计 stride，插值向段起点截断；不是每轴独立走 stride。对象必须匹配 Path 的盒尺寸、固定高度和 cursor 实际位置。已完成段逐段提交，后段 BLOCKED 返回成功的 blocked 结果及合法前缀；预算失败返回明确错误，合法前缀和 cursor 同样保留，Lua error.position 给出实际已提交位置。单次 move 失败旧 AABB/索引不变。set/move 先准备所有关联及分配，再提交；分配/容量失败保留旧状态。

## 空中资源和失败

Context 单 owner 顺序使用；共享静态图不可变，不共享全局查询 scratch。未调用空中操作时不分配 AirState，ground 原 dense scratch 不变。空中节点/堆/排序索引/空桶缓存只按硬预算 reserve、复用，不按地图格数增加数组。动态对象和桶关联用有界排序结构，无退化 hash 假设；Context close/析构统一释放。

|资源|默认/硬上限|
|---|---:|
|展开/touched 节点|4096/8192|
|整次操作桶访问/tests|8192/65536|
|路径点|4096|
|动态对象/单对象关联/总关联|4096/256/262144|
|文件/总区间/每格区间|32 MiB/1048576/64|

`new_context(map_id,air_limits)` 可调低 expanded/nodes/buckets/tests/path_points/objects/object_links/links，不可调高、不可为零；Native setAirLimits 只允许首次空中操作前调用。预算在超额工作之前检查，覆盖 A*、Sweep、连接、构造、平滑及整次多段推进；嵌套调用不重置。平滑耗尽可保留已验证原路线，不返回未经验证捷径。

稳定错误：INVALID_AIR_ASSET（格式）、ASSET_MISMATCH（配对）、SEARCH_BUDGET_EXCEEDED（展开/节点）、QUERY_BUDGET_EXCEEDED（桶/tests）、CAPACITY_EXCEEDED（资源/分配）、NO_PATH（完整搜索无路）、BLOCKED（移动碰撞），以及现有参数/IO/越界错误。Lua 始终 nil,{code,message}；预算耗尽不能表示 NO_PATH/clear。新增 Binding 和扩展加载入口捕获 C++ 异常，bad_alloc 映射容量失败，其它异常为 INTERNAL_ERROR。

单次预算不等于耗时 SLA，也不限制宿主发起的每帧请求数。应用负责帧预算、请求数量、同时移动顺序和重新规划时机。本次不接入 Frame Core、Battle 或弹丸业务。

load_map返回的content_sha256是已校验完整BMAP字节的64字符小写SHA-256。加载阶段计算一次，查询不重复hash；BMAP字节布局不变。宿主可在启动阶段对照发布清单拒绝同ID/版本但内容不同的资产。
