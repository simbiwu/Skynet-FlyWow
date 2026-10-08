// 职责：统一验证第二课 Agent/A*/Occupancy/Smoothing/Determinism/Concurrency 风险。
// 边界：Native Test；不启动 Skynet、不读 Unity Scene、不依赖真实 BMAP 文件。
// 输入/输出：内存 synthetic GridMap -> assert 或 ALL_TESTS_OK。
// 生命周期：每个 case 创建独立 map/context；并发 case 共享 const map 但 Context 独立。
// 不负责：不做性能结论，性能由 navigation_benchmark 单独记录条件。
#include "agent_profile.h"
#include "dynamic_occupancy.h"
#include "grid_map.h"
#include "grid_pathfinder.h"
#include "navigation_context.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using namespace flywow_navigation;

namespace
{

// 创建全可走 synthetic map；origin 是毫米制世界原点，返回 immutable shared owner。
std::shared_ptr<const GridMap> MakeMap(std::uint32_t width, std::uint32_t height,
                                       std::int32_t origin_x_mm = 0, std::int32_t origin_z_mm = 0)
{
    BMapMetadata meta;
    meta.map_id       = 9001;
    meta.map_version  = 1;
    meta.width        = width;
    meta.height       = height;
    meta.cell_size_mm = 500;
    meta.origin_x_mm  = origin_x_mm;
    meta.origin_z_mm  = origin_z_mm;

    std::vector<NavCell> cells(width * height);
    for (NavCell &cell : cells)
    {
        cell.flags           = kWalkableFlag;
        cell.height_mm       = 0;
        cell.area_type       = 0;
        cell.clearance_cells = 10;
    }
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 构造带自定义 Cell 的地图，避免测试通过 const GridMap 后再修改共享资产。
std::shared_ptr<const GridMap> MakeMapFromCells(std::uint32_t width, std::uint32_t height,
                                                std::vector<NavCell> cells,
                                                std::int32_t         origin_x_mm = 0,
                                                std::int32_t         origin_z_mm = 0)
{
    BMapMetadata meta;
    meta.map_id       = 9002;
    meta.map_version  = 1;
    meta.width        = width;
    meta.height       = height;
    meta.cell_size_mm = 500;
    meta.origin_x_mm  = origin_x_mm;
    meta.origin_z_mm  = origin_z_mm;
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 把测试 GridPos 转为 z-major 数组下标；调用者保证 x/z 在范围内。
std::size_t Idx(std::uint32_t width, int x, int z)
{
    return static_cast<std::size_t>(z) * width + x;
}

// 返回测试统一的小型地面 Agent；按值返回，不持有地图或共享状态。
AgentProfile Small()
{
    AgentProfile p       = MakeDefaultAgentProfile(1);
    p.radius_mm          = 200;
    p.max_step_mm        = 600;
    p.max_slope_permille = 1000;
    return p;
}

// 默认测试业务规则：目标 footprint 内只能出现移动者自己。
// query 中的指针由本次同步导航调用拥有；回调不保存、不分配、不 yield。
bool ExclusiveDynamicRule(void *, const DynamicNavigationQuery &query)
{
    if (query.agent == nullptr || query.agent->profile == nullptr || query.occupancy == nullptr)
    {
        return false;
    }
    return query.occupancy->ForEachFootprintCell(*query.agent->profile, query.target,
                                                 [&](const GridPos &grid)
                                                 {
                                                     bool allowed = true;
                                                     query.occupancy->ForEachOccupant(
                                                         grid,
                                                         [&](NavigationAgentHandle other)
                                                         {
                                                             if (other != query.agent->handle)
                                                             {
                                                                 allowed = false;
                                                                 return false;
                                                             }
                                                             return true;
                                                         });
                                                     return allowed;
                                                 });
}

// 构造无所有权的同步查询策略；策略只引用上面的纯函数回调。
DynamicNavigationPolicy ExclusivePolicy()
{
    return DynamicNavigationPolicy{nullptr, &ExclusiveDynamicRule};
}

// 业务允许多实体共存；地图级/Cell 级“禁止穿人”仍由底层先行检查。
bool SharedDynamicRule(void *, const DynamicNavigationQuery &query)
{
    return query.agent != nullptr && query.agent->profile != nullptr &&
           query.occupancy != nullptr &&
           query.occupancy->ForEachFootprintCell(*query.agent->profile, query.target,
                                                 [](const GridPos &) { return true; });
}

// 返回无状态的“业务允许共存”策略；回调不拥有 query 中的指针。
DynamicNavigationPolicy SharedPolicy()
{
    return DynamicNavigationPolicy{nullptr, &SharedDynamicRule};
}

// 构造 Y=0 的毫米制测试世界位置；正式地表 Y 由 GridMap 输出。
WorldPosition P(int x_mm, int z_mm)
{
    return WorldPosition{x_mm, 0, z_mm};
}

// 断言两个 Path 的所有逻辑字段完全一致；失败终止当前 Test 进程。
void AssertSamePath(const Path &a, const Path &b)
{
    assert(a.count() == b.count());
    assert(a.length_mm() == b.length_mm());
    for (std::size_t i = 0; i < a.count(); ++i)
    {
        const auto &pa = a.WorldPoint(i);
        const auto &pb = b.WorldPoint(i);
        assert(pa.x_mm == pb.x_mm);
        assert(pa.y_mm == pb.y_mm);
        assert(pa.z_mm == pb.z_mm);
    }
}

// 锁定越界、不可走起点和不可走终点的稳定错误码。
void TestBoundsAndBlockedEndpoints()
{
    auto               map = MakeMap(5, 5);
    NavigationContext  ctx(map);
    const AgentProfile p = Small();

    auto r = GridPathfinder::FindPathStatic(ctx, p, P(-1, 250), P(2250, 2250));
    assert(!r.ok() && r.error == NavError::kOutOfBounds);

    r = GridPathfinder::FindPathStatic(ctx, p, P(250, 250), P(2500, 250));
    assert(!r.ok() && r.error == NavError::kOutOfBounds);

    std::vector<NavCell> cells(25);
    for (auto &c : cells)
    {
        c.flags           = kWalkableFlag;
        c.clearance_cells = 10;
    }
    cells[Idx(5, 0, 0)].flags = 0;
    cells[Idx(5, 4, 4)].flags = 0;
    auto              blocked = MakeMapFromCells(5, 5, std::move(cells));
    NavigationContext blocked_ctx(blocked);

    r = GridPathfinder::FindPathStatic(blocked_ctx, p, P(250, 250), P(1750, 1750));
    assert(!r.ok() && r.error == NavError::kStartNotNavigable);
    r = GridPathfinder::FindPathStatic(blocked_ctx, p, P(750, 250), P(2250, 2250));
    assert(!r.ok() && r.error == NavError::kEndNotNavigable);
}

// 锁定直线成功、绕墙成功以及最终 Segment 复验。
void TestStraightAndAroundWall()
{
    auto               map = MakeMap(7, 5);
    NavigationContext  ctx(map);
    const AgentProfile p = Small();
    auto straight        = GridPathfinder::FindPathStatic(ctx, p, P(250, 1250), P(3250, 1250));
    assert(straight.ok());
    assert(straight.value.count() == 2); // 开阔直线的中间 Grid 点已被平滑掉。

    std::vector<NavCell> cells(35);
    for (auto &c : cells)
    {
        c.flags           = kWalkableFlag;
        c.clearance_cells = 10;
    }
    for (int z = 0; z < 4; ++z)
    {
        cells[Idx(7, 3, z)].flags = 0; // 墙在 z=4 留一个口。
    }
    auto              wall = MakeMapFromCells(7, 5, std::move(cells));
    NavigationContext wall_ctx(wall);
    auto around = GridPathfinder::FindPathStatic(wall_ctx, p, P(250, 250), P(3250, 250));
    assert(around.ok());
    assert(around.value.count() >= 3);
    assert(GridPathfinder::ValidatePathStatic(wall_ctx, p, around.value).ok());
}

// A/B 位于同一 Cell 时不需要搜索多个 Node，但正式 Path 仍必须到达精确 B。
void TestSameCellExactEndpoints()
{
    auto              map = MakeMap(2, 2);
    NavigationContext ctx(map);
    const auto result = GridPathfinder::FindPathStatic(ctx, Small(), P(100, 100), P(400, 400));
    assert(result.ok() && result.value.count() == 2);
    assert(result.value.WorldPoint(0).x_mm == 100);
    assert(result.value.WorldPoint(0).z_mm == 100);
    assert(result.value.WorldPoint(1).x_mm == 400);
    assert(result.value.WorldPoint(1).z_mm == 400);
}

// 锁定无路可达与 8-way 禁止切角规则。
void TestNoPathAndCornerCutting()
{
    std::vector<NavCell> cells(9);
    for (auto &c : cells)
    {
        c.flags           = kWalkableFlag;
        c.clearance_cells = 10;
    }
    // Start=(0,0)，Goal=(1,1)，两个正交侧格都阻挡；若允许切角会错误成功。
    cells[Idx(3, 1, 0)].flags = 0;
    cells[Idx(3, 0, 1)].flags = 0;
    auto              map     = MakeMapFromCells(3, 3, std::move(cells));
    NavigationContext ctx(map);
    auto              r = GridPathfinder::FindPathStatic(ctx, Small(), P(250, 250), P(750, 750));
    assert(!r.ok() && r.error == NavError::kNoPath);
}

// 锁定 Agent clearance 差异和整数坡度拒绝。
void TestClearanceAndSlope()
{
    std::vector<NavCell> cells(15);
    for (auto &c : cells)
    {
        c.flags           = kWalkableFlag;
        c.clearance_cells = 3;
    }
    // 中间列只给 clearance=1；Small 可走，Large 要 2 格，因此 Large 必须失败/绕开。
    for (int z = 0; z < 3; ++z)
    {
        cells[Idx(5, 2, z)].clearance_cells = 1;
    }
    auto              map = MakeMapFromCells(5, 3, cells);
    NavigationContext ctx_small(map);
    auto              small = Small();
    assert(GridPathfinder::FindPathStatic(ctx_small, small, P(250, 750), P(2250, 750)).ok());

    auto large      = Small();
    large.id        = 2;
    large.radius_mm = 700; // required_clearance_cells = 2。
    NavigationContext ctx_large(map);
    auto large_path = GridPathfinder::FindPathStatic(ctx_large, large, P(250, 750), P(2250, 750));
    assert(!large_path.ok() && large_path.error == NavError::kNoPath);

    // 单独锁定 slope：1 个 500mm Cell 跨 1000mm 高差，max_step 放行但 slope 拒绝。
    cells.assign(3, NavCell{});
    for (auto &c : cells)
    {
        c.flags           = kWalkableFlag;
        c.clearance_cells = 10;
    }
    cells[1].height_mm             = 1000;
    auto slope_map                 = MakeMapFromCells(3, 1, std::move(cells));
    auto slope_agent               = Small();
    slope_agent.max_step_mm        = 1500;
    slope_agent.max_slope_permille = 500;
    NavigationContext slope_ctx(slope_map);
    auto slope = GridPathfinder::FindPathStatic(slope_ctx, slope_agent, P(250, 250), P(1250, 250));
    assert(!slope.ok() && slope.error == NavError::kNoPath);
}

// 锁定 Area Cost 会改变最优路径，且 smoothing 不会切回高成本区域。
void TestAreaCostChangesRoute()
{
    const int            w = 7;
    const int            h = 3;
    std::vector<NavCell> cells(w * h);
    for (auto &c : cells)
    {
        c.flags           = kWalkableFlag;
        c.clearance_cells = 10;
        c.area_type       = 0;
    }
    // 中间直线标为 Mud(area=1)，上下两行保持 Normal。
    for (int x = 1; x < 6; ++x)
    {
        cells[Idx(w, x, 1)].area_type = 1;
    }
    auto map                = MakeMapFromCells(w, h, std::move(cells));
    auto p                  = Small();
    p.area_cost_permille[1] = 5000;
    NavigationContext ctx(map);
    auto              r = GridPathfinder::FindPathStatic(ctx, p, P(250, 750), P(3250, 750));
    assert(r.ok());
    assert(r.value.count() >= 3); // 高成本直线不能被平滑成单条捷径。

    bool left_middle_row = false;
    for (std::size_t i = 0; i < r.value.count(); ++i)
    {
        if (r.value.WorldPoint(i).z_mm != 750)
        {
            left_middle_row = true;
        }
    }
    assert(left_middle_row);
    assert(GridPathfinder::ValidatePathStatic(ctx, p, r.value).ok());
}

// 锁定平滑只删合法拐点：动态绕行保留，穿过占位格的长 Segment 必须拒绝。
void TestSmoothedPathSegments()
{
    auto                  map = MakeMap(5, 3);
    NavigationContext     ctx(map);
    const AgentProfile    profile = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &profile};
    const NavigationAgent blocker{NavigationAgentHandle{20}, &profile};
    assert(ctx.occupancy().Move(self.handle, profile, GridPos{0, 1}).ok());
    assert(ctx.occupancy().Move(blocker.handle, profile, GridPos{2, 1}).ok());

    // 同一静态地图的直线可压成两个点；动态 blocker 只属于当前 Battle Context。
    const auto static_path =
        GridPathfinder::FindPathStatic(ctx, profile, P(250, 750), P(2250, 750));
    assert(static_path.ok() && static_path.value.count() == 2);
    assert(GridPathfinder::ValidatePathStatic(ctx, profile, static_path.value).ok());

    const auto detour =
        GridPathfinder::FindPath(ctx, self, P(250, 750), P(2250, 750), ExclusivePolicy());
    assert(detour.ok() && detour.value.count() >= 3);
    assert(GridPathfinder::ValidatePath(ctx, self, detour.value, ExclusivePolicy()).ok());

    // 手工构造“直接穿过 blocker”的长线段；构造 Path 本身不代表通过动态复验。
    const Path invalid(std::vector<WorldPosition>{P(250, 750), P(2250, 750)}, 2000);
    assert(!GridPathfinder::ValidatePath(ctx, self, invalid, ExclusivePolicy()).ok());
}

// 运行时动态规则只属于设置它的 Battle Context；同地图的其他 Battle 不受影响。
void TestBattleLocalDynamicEntryRules()
{
    auto                  map = MakeMap(3, 1);
    NavigationContext     first(map);
    NavigationContext     second(map);
    const AgentProfile    profile = Small();
    const NavigationAgent mover{NavigationAgentHandle{100}, &profile};
    const NavigationAgent blocker{NavigationAgentHandle{200}, &profile};

    assert(first.occupancy().Move(blocker.handle, profile, GridPos{1, 0}).ok());
    assert(second.occupancy().Move(blocker.handle, profile, GridPos{1, 0}).ok());
    assert(first.AllowsDynamicEntry(GridPos{1, 0}));
    assert(second.AllowsDynamicEntry(GridPos{1, 0}));
    assert(first.SetCellDynamicEntryRule(GridPos{1, 0}, CellDynamicEntryRule::kBlock).ok());
    assert(!first.AllowsDynamicEntry(GridPos{1, 0}));
    assert(second.AllowsDynamicEntry(GridPos{1, 0}));

    const auto allowed =
        GridPathfinder::FindPath(first, mover, P(250, 250), P(1250, 250), SharedPolicy());
    const auto blocked =
        GridPathfinder::FindPath(second, mover, P(250, 250), P(1250, 250), SharedPolicy());
    assert(!allowed.ok());
    assert(blocked.ok());

    assert(first.SetCellDynamicEntryRule(GridPos{1, 0}, CellDynamicEntryRule::kAllow).ok());
    assert(first.AllowsDynamicEntry(GridPos{1, 0}));
    assert(first.SetCellDynamicEntryRule(GridPos{1, 0},
                                         CellDynamicEntryRule::kDefault).ok());
    assert(first.AllowsDynamicEntry(GridPos{1, 0}));
    assert(!first.SetCellDynamicEntryRule(GridPos{3, 0}, CellDynamicEntryRule::kAllow).ok());
    assert(!first.SetCellDynamicEntryRule(GridPos{1, 0},
                                          static_cast<CellDynamicEntryRule>(3)).ok());
}

// 锁定统一 Move、多个实体事实和冲突时保留旧位置。
void TestDynamicOccupancyAndAtomicMove()
{
    auto                  map = MakeMap(7, 3);
    NavigationContext     ctx(map);
    auto                  p = Small();
    const NavigationAgent a{NavigationAgentHandle{100}, &p};
    const NavigationAgent c{NavigationAgentHandle{200}, &p};

    assert(ctx.occupancy().Move(a.handle, p, GridPos{2, 1}).ok());
    assert(ctx.occupancy().Move(c.handle, p, GridPos{4, 1}).ok());
    assert(ctx.occupancy().IsBlocked(GridPos{2, 1}, NavigationAgentHandle{}));
    assert(!ctx.occupancy().IsBlocked(GridPos{2, 1}, a.handle)); // 只忽略移动者自己。

    // a 先移入空格，再尝试移入 c 的格子。第二次失败后，a 必须仍在旧位置。
    const auto first_move =
        GridPathfinder::MoveUnit(ctx, a, P(1250, 750), P(1750, 750), ExclusivePolicy());
    assert(first_move.ok());
    const auto conflict =
        GridPathfinder::MoveUnit(ctx, a, P(1750, 750), P(2250, 750), ExclusivePolicy());
    assert(!conflict.ok());
    assert(ctx.occupancy().FirstOccupantAt(GridPos{3, 1}) == a.handle);
    assert(ctx.occupancy().FirstOccupantAt(GridPos{4, 1}) == c.handle);
}

// 业务允许共存时提交两个真实 owner；较大半径仍须检查整个目标 footprint。
void TestSharedCellAndRadiusFootprint()
{
    auto                  map = MakeMap(5, 5);
    NavigationContext     ctx(map);
    const AgentProfile    small = Small();
    const NavigationAgent first{NavigationAgentHandle{100}, &small};
    const NavigationAgent second{NavigationAgentHandle{200}, &small};
    assert(ctx.occupancy().Move(first.handle, small, GridPos{2, 2}).ok());
    assert(ctx.occupancy().Move(second.handle, small, GridPos{3, 2}).ok());
    const auto moved =
        GridPathfinder::MoveUnit(ctx, second, P(1750, 1250), P(1250, 1250), SharedPolicy());
    assert(moved.ok());
    std::uint32_t count = 0;
    assert(ctx.occupancy().ForEachOccupant(GridPos{2, 2},
                                           [&](NavigationAgentHandle)
                                           {
                                               ++count;
                                               return true;
                                           }));
    assert(count == 2);

    AgentProfile large = Small();
    large.id           = 2;
    large.radius_mm    = 500;
    assert(ctx.occupancy().IsFootprintBlocked(large, GridPos{3, 2}, second.handle));
    assert(!ctx.occupancy().ForEachFootprintCell(large, GridPos{4, 4},
                                                 [](const GridPos &) { return true; }));
}

// 缓存 Path 生成后，两个对角侧格可能被其他单位占据；提交移动时仍必须拒绝切角。
void TestMoveRevalidatesDynamicCorner()
{
    auto                  map = MakeMap(3, 3);
    NavigationContext     ctx(map);
    auto                  p = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &p};
    const NavigationAgent side_x{NavigationAgentHandle{20}, &p};
    const NavigationAgent side_z{NavigationAgentHandle{30}, &p};
    assert(ctx.occupancy().Move(self.handle, p, GridPos{0, 0}).ok());
    assert(ctx.occupancy().Move(side_x.handle, p, GridPos{1, 0}).ok());
    assert(ctx.occupancy().Move(side_z.handle, p, GridPos{0, 1}).ok());

    const auto moved =
        GridPathfinder::MoveUnit(ctx, self, P(250, 250), P(750, 750), ExclusivePolicy());
    assert(!moved.ok());
    assert(ctx.occupancy().FirstOccupantAt(GridPos{0, 0}) == self.handle);
    assert(!ctx.occupancy().FirstOccupantAt(GridPos{1, 1}).valid());
}

// 攻击目标中心被目标占用时，搜索必须停在攻击范围内的其他合法 Cell。
void TestFindPathToOccupiedTargetRange()
{
    auto                  map = MakeMap(7, 3);
    NavigationContext     ctx(map);
    auto                  p = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &p};
    const NavigationAgent target{NavigationAgentHandle{20}, &p};
    assert(ctx.occupancy().Move(self.handle, p, GridPos{0, 1}).ok());
    assert(ctx.occupancy().Move(target.handle, p, GridPos{5, 1}).ok());

    const auto result = GridPathfinder::FindPathToRange(ctx, self, P(250, 750), P(2750, 750), 750,
                                                        ExclusivePolicy());
    assert(result.ok());
    assert(GridPathfinder::ValidatePath(ctx, self, result.value, ExclusivePolicy()).ok());

    const WorldPosition &endpoint      = result.value.WorldPoint(result.value.count() - 1);
    const auto           endpoint_grid = map->WorldToGrid(endpoint);
    assert(endpoint_grid.ok());
    assert(!(endpoint_grid.value.x == 5 && endpoint_grid.value.z == 1));
    const std::int64_t dx = static_cast<std::int64_t>(endpoint.x_mm) - 2750;
    const std::int64_t dz = static_cast<std::int64_t>(endpoint.z_mm) - 750;
    assert(dx * dx + dz * dz <= 750LL * 750LL);
    const auto no_room =
        GridPathfinder::FindPathToRange(ctx, self, P(250, 750), P(2750, 750), 0, ExclusivePolicy());
    assert(!no_room.ok());
}

// 范围 goal 的 Cell Center 合格时，真实起点仍可能位于同 Cell 的攻击范围外。
// 这种情况下必须返回可移动的 Center 终点；真实起点已在范围内则保持单点 Path。
void TestRangeGoalUsesActualStartPosition()
{
    auto                  map = MakeMap(3, 1);
    NavigationContext     ctx(map);
    auto                  profile = Small();
    const NavigationAgent self{NavigationAgentHandle{10}, &profile};
    assert(ctx.occupancy().Move(self.handle, profile, GridPos{0, 0}).ok());

    const auto outside = GridPathfinder::FindPathToRange(ctx, self, P(100, 250), P(400, 250), 200,
                                                         ExclusivePolicy());
    assert(outside.ok());
    assert(outside.value.count() == 2);
    assert(outside.value.WorldPoint(0).x_mm == 100);
    assert(outside.value.WorldPoint(1).x_mm == 250);
    assert(GridPathfinder::ValidatePath(ctx, self, outside.value, ExclusivePolicy()).ok());

    const auto inside = GridPathfinder::FindPathToRange(ctx, self, P(300, 250), P(400, 250), 200,
                                                        ExclusivePolicy());
    assert(inside.ok());
    assert(inside.value.count() == 1);
    assert(inside.value.WorldPoint(0).x_mm == 300);
}
// 锁定负世界坐标使用 floor 归格，负数不等于越界。
void TestNegativeWorldCoordinates()
{
    auto              map = MakeMap(4, 4, -1000, -1000);
    NavigationContext ctx(map);
    auto              r = GridPathfinder::FindPathStatic(ctx, Small(), P(-750, -750), P(750, 750));
    assert(r.ok());
    assert(r.value.WorldPoint(0).x_mm == -750);
    assert(r.value.WorldPoint(0).z_mm == -750);
}

// 在同一 Context 重复查询，锁定 generation 复用与稳定 tie-break。
void TestDeterministicRepeatedQuery()
{
    auto              map = MakeMap(20, 20);
    NavigationContext ctx(map);
    auto first = GridPathfinder::FindPathStatic(ctx, Small(), P(250, 250), P(9250, 9250));
    assert(first.ok());
    for (int i = 0; i < 100; ++i)
    {
        auto next = GridPathfinder::FindPathStatic(ctx, Small(), P(250, 250), P(9250, 9250));
        assert(next.ok());
        AssertSamePath(first.value, next.value);
    }
}

// 多线程只共享 immutable map，各线程 Context 独占；结果必须与 baseline 一致。
void TestIndependentContextsConcurrent()
{
    auto                map   = MakeMap(64, 64);
    const AgentProfile  p     = Small();
    const WorldPosition start = P(250, 250);
    const WorldPosition end   = P(31750, 31750);

    NavigationContext baseline_ctx(map);
    auto              baseline = GridPathfinder::FindPathStatic(baseline_ctx, p, start, end);
    assert(baseline.ok());

    const int                thread_count = 8;
    const int                iterations   = 500;
    std::vector<std::thread> threads;
    // 不使用 vector<bool>：它按 bit 打包，不同线程写“不同元素”仍可能落在同一机器字。
    std::vector<int>         ok(thread_count, 1);
    for (int t = 0; t < thread_count; ++t)
    {
        threads.emplace_back(
            [&, t]()
            {
                // 关键：每个线程/模拟 owner 都有独立 Context；只共享 const GridMap。
                NavigationContext local(map);
                for (int i = 0; i < iterations; ++i)
                {
                    auto r = GridPathfinder::FindPathStatic(local, p, start, end);
                    if (!r.ok())
                    {
                        ok[t] = 0;
                        return;
                    }
                    if (r.value.count() != baseline.value.count() ||
                        r.value.length_mm() != baseline.value.length_mm())
                    {
                        ok[t] = 0;
                        return;
                    }
                    for (std::size_t point = 0; point < r.value.count(); ++point)
                    {
                        const auto &a = baseline.value.WorldPoint(point);
                        const auto &b = r.value.WorldPoint(point);
                        if (a.x_mm != b.x_mm || a.y_mm != b.y_mm || a.z_mm != b.z_mm)
                        {
                            ok[t] = 0;
                            return;
                        }
                    }
                }
            });
    }
    for (auto &thread : threads)
        thread.join();
    for (int value : ok)
        assert(value == 1);
}

} // namespace

// 运行全部第二课 Native correctness/stress case；任一 assert 失败返回非零。
int main()
{
    // 先验证基本坐标/通行，再验证平滑与动态状态，最后验证重复查询和并发隔离。
    // 每个 case 用 assert 锁定可观察行为；Debug 构建确保断言实际执行。
    TestBoundsAndBlockedEndpoints();
    TestStraightAndAroundWall();
    TestSameCellExactEndpoints();
    TestNoPathAndCornerCutting();
    TestClearanceAndSlope();
    TestAreaCostChangesRoute();
    TestSmoothedPathSegments();
    TestBattleLocalDynamicEntryRules();
    TestDynamicOccupancyAndAtomicMove();
    TestSharedCellAndRadiusFootprint();
    TestMoveRevalidatesDynamicCorner();
    TestFindPathToOccupiedTargetRange();
    TestRangeGoalUsesActualStartPosition();
    TestNegativeWorldCoordinates();
    TestDeterministicRepeatedQuery();
    TestIndependentContextsConcurrent();

    std::cout << "ALL_TESTS_OK\n";
    return 0;
}
