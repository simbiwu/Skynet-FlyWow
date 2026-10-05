--- 职责：提供可被业务 require 的 Navigation 入口与编辑器可识别的公开合同。
--- 边界：普通 Lua 模块；不创建 Service、不启动进程、不负责地图发布门禁。
--- 生命周期：每个 Lua State require 缓存此模块；静态地图由 Native 进程 Registry 持有。
--- Native 查询同步且不 yield；同一 Context 只允许其 owner 顺序调用。

---@class FlyWowNavigationPosition
---@field x_mm integer 世界 X，整数毫米；调用方持有的纯数据。
---@field y_mm integer 世界高度 Y，整数毫米；移动成功值由地图归一化。
---@field z_mm integer 世界 Z，整数毫米；不是 Grid 下标。

---@class FlyWowNavigationError
---@field code string 稳定机器错误码；按此字段分支，不解析文案。
---@field message string 诊断上下文；只用于日志，不进入业务判断。

---@class FlyWowNavigationProfile
---@field id integer 正 uint32 Profile 身份；构造 Context 时复制且不得重复。
---@field radius_mm integer 非负体型半径，毫米；静态/动态 footprint 共同使用。
---@field max_step_mm integer 非负最大跨格高度差，毫米。
---@field max_slope_permille integer 非负坡度上限；1000 表示高差等于水平距离。
---@field area_cost_permille? table<integer,integer> Area 0..255 成本；未配置默认 1000。
---@field area_allowed? table<integer,boolean> Area 0..255 通行开关；未配置使用 Native 默认。

---@class FlyWowNavigationPath
---@field count fun(self:FlyWowNavigationPath):integer 点数；只读、不 yield。
---@field world_point fun(self:FlyWowNavigationPath,index:integer):FlyWowNavigationPosition 下标从 1 开始；越界抛错。
---@field length_mm fun(self:FlyWowNavigationPath):integer XZ 路径长度；毫米。

---@class FlyWowNavigationAdvanceRequest
---@field profile_id integer 当前单位使用的 Profile 身份。
---@field unit_id integer 本 Context 的正 uint32 单位句柄。
---@field path FlyWowNavigationPath 此单位独占 Path/cursor，不可跨单位共享推进状态。
---@field from_world FlyWowNavigationPosition 当前权威位置，调用方拥有且只读。
---@field distance_mm integer 本 Tick 非负 uint32 距离预算，毫米。

---@class FlyWowNavigationAdvanceResult
---@field status string moving/reached/blocked；代表本次已提交的推进结果。
---@field position FlyWowNavigationPosition 最后成功提交的位置，供业务保存。
---@field consumed_mm integer 实际消费预算；毫米，不是 Tick 数。
---@field moved boolean 是否有已成功提交的 XZ 变化。

---@class FlyWowNavigationContext
---@field find_path fun(self:FlyWowNavigationContext,profile_id:integer,start:FlyWowNavigationPosition,goal:FlyWowNavigationPosition,self_unit_id:integer):FlyWowNavigationPath?,FlyWowNavigationError?
---@field find_path_to_range fun(self:FlyWowNavigationContext,profile_id:integer,start:FlyWowNavigationPosition,target:FlyWowNavigationPosition,attack_range_mm:integer,self_unit_id:integer):FlyWowNavigationPath?,FlyWowNavigationError?
---@field place_unit fun(self:FlyWowNavigationContext,profile_id:integer,unit_id:integer,position:FlyWowNavigationPosition):FlyWowNavigationPosition?,FlyWowNavigationError?
---@field move_unit fun(self:FlyWowNavigationContext,profile_id:integer,unit_id:integer,from_world:FlyWowNavigationPosition,to_world:FlyWowNavigationPosition):FlyWowNavigationPosition?,FlyWowNavigationError?
---@field release_unit fun(self:FlyWowNavigationContext,unit_id:integer):boolean?,FlyWowNavigationError?
---@field advance_path fun(self:FlyWowNavigationContext,request:FlyWowNavigationAdvanceRequest):FlyWowNavigationAdvanceResult?,FlyWowNavigationError?
---@field cell_size_mm fun(self:FlyWowNavigationContext):integer?,FlyWowNavigationError?
---@field close fun(self:FlyWowNavigationContext) 幂等释放大块 Context 内存，无返回值；GC 兜底析构 userdata。

---@class FlyWowNavigationIdentity
---@field map_id integer BMAP 实际地图身份；不能忽略并只相信输入文件名。
---@field map_version integer BMAP 实际内容版本；不可用 format_version 代替。

---@class FlyWowNavigationCell
---@field grid_x integer 当前 Grid 的调试列下标；不是长期位置合同。
---@field grid_z integer 当前 Grid 的调试行下标。
---@field cell_height_mm integer 地表高度，整数毫米。
---@field area integer 稳定地表编码；不是 Unity NavMesh Area 下标。
---@field clearance integer 静态保守格距；单位 Cell，动态单位不重算此值。
---@field walkable boolean 静态 Walkable bit；不代表所有 Agent 都能站立。

---@class FlyWowNavigationModule
---@field load_map fun(path:string):FlyWowNavigationIdentity?,FlyWowNavigationError? 文件 I/O/分配/Registry 短锁；启动阶段调用。
---@field query_cell fun(map_id:integer,map_version:integer,position:FlyWowNavigationPosition):FlyWowNavigationCell?,FlyWowNavigationError? 只读同步查询；Registry 查找短锁。
---@field new_context fun(map_id:integer,map_version:integer,profiles:FlyWowNavigationProfile[]):FlyWowNavigationContext?,FlyWowNavigationError? 分配私有 scratch/occupancy，返回调用方独占 userdata。

--- Lua 模块入口转交真实 Native API；没有第二份算法或包装状态。
---@type FlyWowNavigationModule
local navigation = require "flywow_navigation"
return navigation
