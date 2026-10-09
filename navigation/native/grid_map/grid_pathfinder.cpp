// 职责：实现 Grid 8-way A*、Binary Heap、静态规则和业务回调式动态查询。
// 边界：Server Runtime Native Navigation；只读 GridMap，scratch/occupancy 来自 NavigationContext。
// 输入/输出：WorldPosition A/B + 查询策略 -> WorldPosition Path；失败使用 NavError。
// 内存：A* Node/Open 不做 per-node allocation；最终 Path 会分配结果 vector。
// 不负责：不保存 Battle 单位状态，不调用 Skynet，不执行 Unity 表现或局部 Steering。
#include "grid_pathfinder.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <vector>

namespace flywow_navigation
{
// 匿名 namespace 让下面的辅助符号只在本 .cpp 可见；它们不是其他文件可调用的公开 API。
namespace
{

// 搜索成本是“路线偏好”的整数分数，不是毫米、耗时或本 Tick 的移动预算。
// 普通地面直走一格记 1000 分，斜走约 1414 分；泥地等 Area 再放大进入成本。
// 真正的毫米长度在构建世界坐标 Path 后计算，不能把 A* 分数直接当移动距离。
constexpr std::uint32_t kStraightCost  = 1000;
constexpr std::uint32_t kDiagonalCost  = 1414;
constexpr std::size_t   kMaxPathPoints = 65535;

struct Direction
{
    std::int8_t   dx;        // Grid X 偏移。
    std::int8_t   dz;        // Grid Z 偏移。
    std::uint32_t base_cost; // 1000=直走，1414=对角。
};

constexpr std::array<Direction, 8> kDirections{{
    {-1, 0, kStraightCost},
    {1, 0, kStraightCost},
    {0, -1, kStraightCost},
    {0, 1, kStraightCost},
    {-1, -1, kDiagonalCost},
    {-1, 1, kDiagonalCost},
    {1, -1, kDiagonalCost},
    {1, 1, kDiagonalCost},
}};

// 算法阅读顺序：FindPathImpl 扩展相邻格 -> BuildPath 回溯 -> SmoothGridPath 简化。
// 生成 Path 只规划路线；AdvancePath/MoveUnit 才逐步复验并提交真实占位。

// A* 的通行策略：静态查询不带动态 policy；Battle 查询通过回调解释 Occupancy 事实。
struct QueryPolicy
{
    const DynamicNavigationPolicy *dynamic_policy = nullptr; // 借用业务层策略，不转移所有权。
    const NavigationContext      *context        = nullptr; // 当前 Battle 的动态规则 owner；仅动态查询设置。
    const NavigationAgent         *agent          = nullptr; // 当前移动者视图；借用。
    DynamicQueryPurpose            purpose        = DynamicQueryPurpose::kFindPath;
};

// 用途：把沿 Path 线段的消费进度换算成一个 X 或 Z 世界坐标，避免逐 Tick 累加坐标。
// 例如 origin=100、target=500、progress=100、length=400，结果是 200。
// 按 progress/length 在线段单轴上做整数插值；除法向 0 截断且每次都相对固定 origin。
// origin/target 是 BMAP V1 可表达范围内的 int64 世界毫米坐标；
// progress 必须不大于 length，out 由调用方提供。
// 成功返回 true；乘法溢出或参数越界返回 false；不分配、不修改共享状态。
bool InterpolateAxis(std::int64_t origin, std::int64_t target, std::uint64_t progress,
                     std::uint64_t length, std::int64_t *out)
{
    if (out == nullptr || length == 0 || progress > length ||
        origin < std::numeric_limits<std::int32_t>::min() ||
        std::numeric_limits<std::int32_t>::max() < origin ||
        target < std::numeric_limits<std::int32_t>::min() ||
        std::numeric_limits<std::int32_t>::max() < target ||
        length > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))
    {
        return false;
    }

    const std::int64_t  delta     = static_cast<std::int64_t>(target) - origin;
    const std::uint64_t magnitude = static_cast<std::uint64_t>(delta < 0 ? -delta : delta);
    if (magnitude != 0 &&
        progress > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) / magnitude)
    {
        return false;
    }

    const std::int64_t signed_progress = static_cast<std::int64_t>(progress);
    const std::int64_t offset = delta * signed_progress / static_cast<std::int64_t>(length);
    const std::int64_t value  = static_cast<std::int64_t>(origin) + offset;
    *out                      = value;
    return true;
}

// 把合法 GridPos 映射成稳定 node_index；width 来自 immutable map metadata。
std::int32_t NodeIndex(const GridMap &map, const GridPos &p)
{
    const std::uint64_t index =
        static_cast<std::uint64_t>(p.z) * map.metadata().width + static_cast<std::uint32_t>(p.x);
    return static_cast<std::int32_t>(index);
}

// 把 node_index 还原成 GridPos；node_index 必须来自当前 map。
GridPos GridFromIndex(const GridMap &map, std::int32_t node_index)
{
    const std::uint32_t width = map.metadata().width;
    return GridPos{
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) % width),
        static_cast<std::int32_t>(static_cast<std::uint32_t>(node_index) / width),
    };
}

// Octile Distance：8-way、直走1000、斜走1414 的可采纳启发式。
// 可以把它理解为“假设前方都是普通地面、没有墙，还至少要走多远”。
// 墙和泥地只会让真实路线更贵，所以该估计不会诱导搜索提前接受更差的路线。
// 已允许的 Area 成本必须 >=1000；这个前提由 ValidateAgentProfile 保证。
std::uint64_t Heuristic(const GridPos &a, const GridPos &b)
{
    // 先提升到 int64 再相减，避免极端 GridPos 的 int32 减法溢出。
    const std::uint32_t dx =
        static_cast<std::uint32_t>(std::llabs(static_cast<long long>(a.x) - b.x));
    const std::uint32_t dz =
        static_cast<std::uint32_t>(std::llabs(static_cast<long long>(a.z) - b.z));

    // 一次对角移动同时消耗 X/Z 各 1 格，所以最多能斜走较小的轴向差值。
    // 例如 a=(0,0)、b=(4,3)：dx=4、dz=3，diagonal=min(4,3)=3。
    const std::uint32_t diagonal = std::min(dx, dz);

    // 斜走后，较长轴还剩的格数只能直走；上例为 max(4,3)-3=1。
    const std::uint32_t straight = std::max(dx, dz) - diagonal;

    // 上例的估计成本为 3*1414 + 1*1000 = 5242；不考虑障碍和动态占位。
    return static_cast<std::uint64_t>(diagonal) * kDiagonalCost +
           static_cast<std::uint64_t>(straight) * kStraightCost;
}

// 函数职责：只判断一个 Grid Cell 是否满足 Agent 的“单格静态站立条件”。
// map：当前 immutable GridMap；借用，不转移所有权；查询不修改地图。
// profile：已经通过 ValidateAgentProfile() 的单位规则；借用，不修改。
// grid：当前地图的 Grid 坐标，单位为 Cell；必须使用当前 map 的坐标范围。
// 返回值：Cell 存在、Walkable、clearance 和 Area 都满足时返回 true；否则返回 false。
// 不判断 current->next 的高差、坡度、对角侧格或动态占位；这些属于移动边或 Battle 状态。
// 不执行 I/O、分配、加锁或 yield；复杂度 O(1)。
bool CanOccupyStaticCell(const GridMap &map, const AgentProfile &profile, const GridPos &grid)
{
    const NavCell *cell = map.TryCell(grid);
    if (cell == nullptr || !cell->IsWalkable())
    {
        return false;
    }

    const std::uint8_t required = RequiredClearanceCells(profile, map.metadata().cell_size_mm);
    if (cell->clearance_cells < required)
    {
        return false;
    }

    const std::uint8_t area = cell->area_type;
    return profile.area_allowed[area] != 0;
}

// 函数职责：组合静态地图判断、Context 的 Battle-local 格子规则和业务层动态回调。
// map/profile/grid：当前 immutable 地图、单位静态规则和候选中心 Cell；均只读借用。
// from：候选移动的来源中心 Cell；起点检查时 from==grid。
// policy：静态查询不带动态策略；Battle 查询带业务回调和当前 NavigationAgent。
// 返回 true 表示该中心位置允许进入；不执行 I/O、分配、加锁或 yield。
// 复杂度：静态部分 O(1)；动态回调复杂度由业务层决定，通常遍历一次 footprint。
bool CanOccupy(const GridMap &map, const AgentProfile &profile, const GridPos &from,
               const GridPos &grid, const QueryPolicy &policy, const DynamicOccupancy &occupancy)
{
    if (!CanOccupyStaticCell(map, profile, grid))
    {
        return false;
    }

    if (policy.dynamic_policy == nullptr)
    {
        return true;
    }

    // Context 的单格规则只约束“已有其他实体时能否重叠”；空 Cell 即使设为 block 仍可进入。
    // Occupancy 统一枚举半径 footprint，底层只在禁止重叠的 Cell 查找非 self 实体。
    // 业务回调随后可以进一步拒绝，但不能放宽 Context 已禁止的重叠。
    if (policy.agent == nullptr || policy.context == nullptr)
    {
        return false;
    }
    if (!occupancy.ForEachFootprintCell(profile, grid,
                                        [&](const GridPos &footprint_cell)
                                        {
                                            if (policy.context->AllowsDynamicEntry(footprint_cell))
                                            {
                                                return true;
                                            }
                                            return occupancy.ForEachOccupant(
                                                footprint_cell, [&](NavigationAgentHandle occupant)
                                                { return occupant == policy.agent->handle; });
                                        }))
    {
        return false;
    }

    const DynamicNavigationPolicy &dynamic = *policy.dynamic_policy;
    if (dynamic.callback == nullptr)
    {
        return true;
    }
    const DynamicNavigationQuery query{policy.agent, &map, &occupancy, from, grid, policy.purpose};
    return dynamic.callback(dynamic.user_data, query);
}

// 函数职责：判断 current->next 这条 Grid 边是否满足静态和可选动态规则。
// current/next：移动前后的中心 Grid 坐标；dx/dz：-1、0、1 的格偏移。
// policy：静态查询不带动态策略；非空时目标和对角侧格都调用业务动态回调。
// 返回值：目标格、台阶、坡度和 corner cutting 均通过时返回 true；复杂度为 O(1) 加 footprint 数。
bool CanTraverse(const GridMap &map, const AgentProfile &profile, const GridPos &current,
                 const GridPos &next, std::int32_t dx, std::int32_t dz, const QueryPolicy &policy,
                 const DynamicOccupancy &occupancy)
{
    if (!CanOccupy(map, profile, current, next, policy, occupancy))
    {
        return false;
    }

    const NavCell *from = map.TryCell(current);
    const NavCell *to   = map.TryCell(next);
    if (from == nullptr || to == nullptr)
    {
        return false;
    }

    // height_mm 来自 BMAP 的 Cell Center 地表高度；max_step_mm 来自 AgentProfile。
    // 先提升到 long long 再相减，避免两个 int32 高度相减时在 32 位范围内溢出。
    const std::uint64_t height_delta = static_cast<std::uint64_t>(
        std::llabs(static_cast<long long>(to->height_mm) - from->height_mm));
    if (height_delta > static_cast<std::uint64_t>(profile.max_step_mm))
    {
        return false;
    }

    // dx/dz 是 Grid 格偏移，不是毫米；两个都非 0 表示一次对角移动。
    // 对角水平距离用 1414/1000（约等于 sqrt(2)）的整数近似，避免查询热路径浮点比较。
    // 先转 uint64_t 再乘 1414，避免较大 cell_size_mm 在 32 位乘法中溢出。
    const std::uint64_t horizontal_mm =
        (dx != 0 && dz != 0) ? static_cast<std::uint64_t>(map.metadata().cell_size_mm) * 1414 / 1000
                             : map.metadata().cell_size_mm;
    // 不使用浮点除法，交叉相乘表达：height_delta / horizontal_mm
    // 不能大于 max_slope_permille / 1000；刚好相等时允许通过。
    if (height_delta * 1000 >
        static_cast<std::uint64_t>(profile.max_slope_permille) * horizontal_mm)
    {
        return false;
    }

    if (dx != 0 && dz != 0)
    {
        // 例如 (0,0)->(1,1)：即使终点空闲，(1,0) 或 (0,1) 被墙/其他单位
        // 挡住也不能走这条斜边，否则等于从障碍物的尖角穿过去。
        // 对角移动的两个侧向中心也要经过同一 policy；
        // 动态查询因此不会从两个动态 footprint 的夹角中切过去。
        const GridPos side_x{current.x + dx, current.z};
        const GridPos side_z{current.x, current.z + dz};
        if (!CanOccupy(map, profile, current, side_x, policy, occupancy) ||
            !CanOccupy(map, profile, current, side_z, policy, occupancy))
        {
            return false;
        }
    }
    return true;
}

// 计算进入 next Cell 的整数移动成本；Area Cost 属于 AgentProfile。
// 例如普通地面直走一格为 1000，成本 3000 的泥地直走一格为 3000。
// 因此绕行两步普通地面可能比直穿一步泥地更便宜；A* 优化的是此成本，
// 并不保证路点最少或世界毫米距离最短。这里收取目标格费用，不重复收取来源格。
std::uint32_t MoveCost(const GridMap &map, const AgentProfile &profile, const GridPos &next,
                       std::uint32_t base_cost)
{
    const NavCell      *cell      = map.TryCell(next);
    const std::uint32_t area_cost = profile.area_cost_permille[cell->area_type];
    const std::uint64_t scaled    = static_cast<std::uint64_t>(base_cost) * area_cost / 1000;
    return scaled > std::numeric_limits<std::uint32_t>::max()
               ? std::numeric_limits<std::uint32_t>::max()
               : static_cast<std::uint32_t>(scaled);
}

struct SegmentCheck
{
    bool          valid = false; // false=任一穿过的 Cell 边不合法。
    std::uint64_t cost  = 0;     // 使用与 A* 相同的整数 Area-adjusted cost；仅 valid 时读取。
};

// 使用整数 Supercover 思路逐 Cell 穿过一条 Grid 直线。
// 例如 (0,0)->(3,0) 会逐个检查 (1,0)、(2,0)、(3,0)，而不是只验证两个端点。
// 每一步都重新调用与 A* 相同的 CanTraverse，因此 corner/clearance/slope/dynamic 不会绕过。
// map/profile：当前 immutable 地图与体型规则；policy/occupancy：本次查询的只读动态事实。
// from/to：已经验证在同一 GridMap 内的 Cell 坐标；调用期间不修改 Occupancy。
// 返回 valid=false 表示候选捷径不可用；valid=true 时 cost 为进入各 Cell 的累计成本。
// 不执行 I/O、分配、加锁或 yield；复杂度与线段穿过的 Cell 数成正比。
// 只处理整数 Cell Center 间的线段；正式移动仍由 MoveUnit 按单格提交。
SegmentCheck ValidateGridSegment(const GridMap &map, const AgentProfile &profile,
                                 const QueryPolicy &policy, const DynamicOccupancy &occupancy,
                                 GridPos from, const GridPos &to)
{
    // 先提升再相减；GridPos 虽为 int32，两个坐标之差不保证仍落在 int32。
    const std::int64_t delta_x = static_cast<std::int64_t>(to.x) - from.x;
    const std::int64_t delta_z = static_cast<std::int64_t>(to.z) - from.z;
    const int          step_x  = delta_x > 0 ? 1 : (delta_x < 0 ? -1 : 0);
    const int          step_z  = delta_z > 0 ? 1 : (delta_z < 0 ? -1 : 0);
    const std::int64_t nx      = delta_x < 0 ? -delta_x : delta_x;
    const std::int64_t nz      = delta_z < 0 ? -delta_z : delta_z;

    std::int64_t  ix   = 0;
    std::int64_t  iz   = 0;
    std::uint64_t cost = 0;
    while (ix < nx || iz < nz)
    {
        // 想象从一个格中心拉一条线到另一个格中心：每次只推进到它接下来
        // 穿过的相邻格。ix/iz 记录已跨过多少次 X/Z 边界，而非世界坐标。
        // 下面比较哪条轴的下一条边界先被碰到；使用整数交叉比较，避免
        // 浮点误差把“刚好碰到格角”的情况误判成只跨一条边界。
        const std::int64_t lhs = (1 + 2 * ix) * nz;
        const std::int64_t rhs = (1 + 2 * iz) * nx;

        GridPos       next = from;
        std::uint32_t base = kStraightCost;
        int           dx   = 0;
        int           dz   = 0;
        if (lhs == rhs)
        {
            // 同时碰到格角，两轴各推进一格；CanTraverse 还会检查两侧格。
            // 例如 (0,0)->(2,2) 会走两条斜边，每条都不能贴着阻挡侧格切角。
            dx = step_x;
            dz = step_z;
            ++ix;
            ++iz;
            base = kDiagonalCost;
        }
        else if (lhs < rhs)
        {
            dx = step_x;
            ++ix;
        }
        else
        {
            dz = step_z;
            ++iz;
        }
        next.x += dx;
        next.z += dz;

        // 捷径的两个端点可站立，不等于中间通道可走。逐边检查让平滑不能
        // 跳过墙、窄通道、陡坡或当前动态占位；失败立即放弃这一条捷径。
        if (!CanTraverse(map, profile, from, next, dx, dz, policy, occupancy))
        {
            return SegmentCheck{};
        }
        cost += MoveCost(map, profile, next, base);
        from = next;
    }
    return SegmentCheck{true, cost};
}
// 在已经由 A* 验证的原始 Grid 路径上尝试有限窗口的等价捷径。
// map/profile/policy/occupancy：与本次 A* 相同的只读地图、体型及动态事实；均只借用。
// raw：按起点到终点排列的相邻 Cell；返回新 vector，由调用者拥有。
// 只有直达边合法且代价不超过原子路径才删除中间点；失败保留原段。
// 每个锚点最多检查 32 个后续点，不执行 I/O、加锁或 yield。
std::vector<GridPos> SmoothGridPath(const GridMap &map, const AgentProfile &profile,
                                    const QueryPolicy &policy, const DynamicOccupancy &occupancy,
                                    const std::vector<GridPos> &raw)
{
    if (raw.size() <= 2)
    {
        return raw;
    }

    // 平滑是删除不必要的转折点，并不移动原路点，也不生成圆弧或转弯动画。
    // 例如 A->B->C 的拐弯其实在空地上，若 A->C 合法且不更贵，就只保留 A、C。
    // 若 B 是绕墙必需的拐角，则直达验证失败，B 会保留。
    // 限制观察窗口，避免长路径对每一对远端路点都作重复通道检查。
    constexpr std::size_t kMaxShortcutLookahead = 32;
    std::vector<GridPos>  out;
    out.reserve(raw.size());
    out.push_back(raw.front());
    std::size_t anchor = 0;
    while (anchor + 1 < raw.size())
    {
        // anchor 是已经保留的最后一个点；best 默认选紧邻点，保证始终能前进。
        // 后续没有任何合格捷径时，原 A* 相邻边就是安全的退路。
        std::size_t   best          = anchor + 1;
        std::uint64_t original_cost = 0;
        for (std::size_t candidate = anchor + 1;
             candidate < raw.size() && candidate <= anchor + kMaxShortcutLookahead; ++candidate)
        {
            // A* 的原始相邻边已合法；逐项累计其真实 Area-adjusted 成本。
            const GridPos prev     = raw[candidate - 1];
            const GridPos next     = raw[candidate];
            const bool    diagonal = prev.x != next.x && prev.z != next.z;
            original_cost += MoveCost(map, profile, next, diagonal ? kDiagonalCost : kStraightCost);
            const SegmentCheck direct =
                ValidateGridSegment(map, profile, policy, occupancy, raw[anchor], next);
            // “看得到终点”还不够：直线可能穿过高成本泥地，而原路绕走普通地面。
            // 即使直线更短，只要成本更高就不替换，否则会抹掉 A* 的区域偏好。
            // 候选依次向远处推进，best 记窗口内最远的合格点；并非选最便宜的捷径。
            // 某个 shortcut 不合格，不代表更远的候选不合格：不同终点连出的
            // 直线经过的格子不同，所以失败时继续尝试，而不是直接结束本窗口。
            if (direct.valid && direct.cost <= original_cost)
            {
                best = candidate;
            }
        }
        // 保留选出的落点，中间被跳过的点不进入结果；从新锚点重复上述步骤。
        out.push_back(raw[best]);
        anchor = best;
    }
    return out;
}

// 同一搜索主循环的终点条件：精确 Cell 或 target 周围可站立的攻击范围。
struct GoalPolicy
{
    bool          exact = true;        // true=exact_grid；false=target_world 的范围条件。
    GridPos       exact_grid{};        // 精确目标 Grid Cell；仅 exact=true 时读取。
    WorldPosition target_world{};      // 目标世界毫米坐标；仅 exact=false 时读取。
    std::uint32_t min_range_mm    = 0; // 单位目标：双方半径之和，候选不能位于其内部。
    std::uint32_t attack_range_mm = 0; // 目标中心到候选 Cell Center 的 XZ 半径。
};

// 用整数平方距离判断真实世界点是否已进入目标攻击范围。
// world/target：借用的 XZ 毫米坐标；range_mm：包含边界的非负半径。
// 返回 true 表示无需再向 Cell Center 移动；不分配、不加锁、不 yield。
bool WorldWithinAttackRange(const WorldPosition &world, const WorldPosition &target,
                            std::uint32_t range_mm)
{
    const std::int64_t  dx = static_cast<std::int64_t>(world.x_mm) - target.x_mm;
    const std::int64_t  dz = static_cast<std::int64_t>(world.z_mm) - target.z_mm;
    const std::uint64_t ax = static_cast<std::uint64_t>(dx < 0 ? -dx : dx);
    const std::uint64_t az = static_cast<std::uint64_t>(dz < 0 ? -dz : dz);
    if (ax > range_mm || az > range_mm)
    {
        return false;
    }
    const std::uint64_t range2 = static_cast<std::uint64_t>(range_mm) * range_mm;
    const std::uint64_t ax2    = ax * ax;
    // 先检查单轴，再做减法；避免两个极端坐标平方相加溢出 uint64。
    return az * az <= range2 - ax2;
}

// 精确保存最多 65-bit 的平方距离，避免极端 int32 坐标相加溢出。
struct DistanceScore
{
    bool          carry = false;
    std::uint64_t low   = 0;
    bool          operator<(const DistanceScore &other) const
    {
        return carry != other.carry ? !carry : low < other.low;
    }
    bool operator==(const DistanceScore &other) const
    {
        return carry == other.carry && low == other.low;
    }
};

DistanceScore distanceScore(const WorldPosition &a, const WorldPosition &b)
{
    const auto dx = static_cast<std::uint64_t>(std::llabs(static_cast<long long>(a.x_mm) - b.x_mm));
    const auto dz = static_cast<std::uint64_t>(std::llabs(static_cast<long long>(a.z_mm) - b.z_mm));
    const auto x2 = dx * dx;
    const auto z2 = dz * dz;
    return DistanceScore{x2 + z2 < x2, x2 + z2};
}

bool outsideUnit(const WorldPosition &world, const GoalPolicy &goal)
{
    const DistanceScore minimum{false,
                                static_cast<std::uint64_t>(goal.min_range_mm) * goal.min_range_mm};
    return !(distanceScore(world, goal.target_world) < minimum);
}

// 搜索 goal 使用 Cell Center；世界点检查与它共用相同距离公式。
// map/grid：借用的合法地图与 Cell；转换失败时返回 false；不加锁、不 yield。
bool InAttackRange(const GridMap &map, const GridPos &grid, const WorldPosition &target,
                   std::uint32_t range_mm)
{
    const auto world = map.GridToWorldCenter(grid);
    return world.ok() && WorldWithinAttackRange(world.value, target, range_mm);
}

// 判断当前已弹出的可站立 Cell 是否满足本次目标条件。
// exact 模式直接比较 Grid；范围模式使用 Cell Center 到目标世界点的 XZ 距离。
bool IsGoal(const GridMap &map, const GridPos &current, const GoalPolicy &goal)
{
    if (goal.exact)
    {
        return current.x == goal.exact_grid.x && current.z == goal.exact_grid.z;
    }
    const auto world = map.GridToWorldCenter(current);
    return world.ok() && outsideUnit(world.value, goal) &&
           InAttackRange(map, current, goal.target_world, goal.attack_range_mm);
}

// 精确目标用可采纳 Octile；区域目标先用 h=0 的 Dijkstra 保证不高估。
// 范围目标不是“到目标中心”：敌人已占中心格，停在周边合法攻击位置即可。
// 若仍估计走到中心的成本，可能把已经接近攻击圈的候选估得过贵。
// 这里保守地不给剩余路程加分，只按已经走过的成本排序（Dijkstra）；
// 搜索可能多看一些格子，但最先出堆的合法攻击位置拥有最低搜索成本。
// current/goal 只读，不修改搜索状态；返回非负整数成本下界。
std::uint64_t GoalHeuristic(const GridPos &current, const GoalPolicy &goal)
{
    return goal.exact ? Heuristic(current, goal.exact_grid) : 0;
}

// heap 中两个 node 谁优先：f=g+h 更小优先；f 相同则 h 小，再 node_index 小。
// 最后的 node_index tie-break 保证相同输入下顺序稳定。
bool HeapLess(NavigationContext &context, const GridMap &map, std::int32_t lhs, std::int32_t rhs,
              const GoalPolicy &goal)
{
    auto               &left  = context.TouchNode(lhs);
    auto               &right = context.TouchNode(rhs);
    const std::uint64_t lh    = GoalHeuristic(GridFromIndex(map, lhs), goal);
    const std::uint64_t rh    = GoalHeuristic(GridFromIndex(map, rhs), goal);
    // g 是目前已知“走到这里”的成本，h 是“从这里还至少要走”的估计。
    // 合在一起决定先探索谁，而不是单纯挑离终点最近的格子。
    // 例如左节点 g=2000,h=3000，右节点 g=4500,h=1000，优先左节点：
    // 右节点虽看起来离目标更近，但走到那里已经付出了更多成本。
    const std::uint64_t lf    = left.g_cost + lh;
    const std::uint64_t rf    = right.g_cost + rh;
    if (lf != rf)
        return lf < rf;
    if (lh != rh)
        return lh < rh;
    return lhs < rhs;
}

// 交换 heap 两个 slot，同时维护对应 NodeScratch.heap_index。
void HeapSwap(NavigationContext &context, std::size_t a, std::size_t b)
{
    auto &heap = context.heap_storage();
    // heap 保存的是节点编号，node.heap_index 反过来记录节点在哪个堆槽位。
    // 两边必须一起更新；否则更便宜路线到来时，会调整错误节点的位置。
    std::swap(heap[a], heap[b]);
    context.TouchNode(heap[a]).heap_index = static_cast<std::int32_t>(a);
    context.TouchNode(heap[b]).heap_index = static_cast<std::int32_t>(b);
}

// 插入新候选或降低已有候选的 g 后，让它向堆顶移动到正确优先级位置。
// 只借用并调整本 Context 的预分配 heap，不复制节点、不分配内存。
void SiftUp(NavigationContext &context, const GridMap &map, std::size_t slot,
            const GoalPolicy &goal)
{
    auto &heap = context.heap_storage();
    while (slot > 0)
    {
        // 数组把二叉堆逐层排开：槽位 1、2 的父节点是 0，3、4 的父节点是 1。
        // 子节点比父节点更优就交换；不再更优时，其上方也无需继续调整。
        const std::size_t parent_slot = (slot - 1) / 2;
        if (!HeapLess(context, map, heap[slot], heap[parent_slot], goal))
        {
            break;
        }
        HeapSwap(context, slot, parent_slot);
        slot = parent_slot;
    }
}

// 弹出堆顶后，用末尾候选填洞，再向下放到正确位置；不要求整个数组排序。
void SiftDown(NavigationContext &context, const GridMap &map, std::size_t slot,
              const GoalPolicy &goal)
{
    auto             &heap = context.heap_storage();
    const std::size_t size = context.heap_size();
    for (;;)
    {
        const std::size_t left = slot * 2 + 1;
        if (left >= size)
            break;
        const std::size_t right = left + 1;
        // 从两个子节点中选更优的那个与父节点比较，不能只检查左孩子。
        // 这样每次都把剩余候选中更值得先探索的一支提上来。
        std::size_t       best  = left;
        if (right < size && HeapLess(context, map, heap[right], heap[left], goal))
        {
            best = right;
        }
        if (!HeapLess(context, map, heap[best], heap[slot], goal))
        {
            break;
        }
        HeapSwap(context, slot, best);
        slot = best;
    }
}

// 将 unseen 节点首次加入 OPEN；调用方保证每个节点最多占一个堆槽位。
void HeapPush(NavigationContext &context, const GridMap &map, std::int32_t node_index,
              const GoalPolicy &goal)
{
    auto             &heap = context.heap_storage();
    const std::size_t slot = context.heap_size();
    heap[slot]             = node_index;
    context.set_heap_size(slot + 1);
    context.TouchNode(node_index).heap_index = static_cast<std::int32_t>(slot);
    SiftUp(context, map, slot, goal);
}

// 取出当前最优候选；调用者保证 heap 非空。出堆不等于已经找到目标，
// 还要由搜索循环判断目标条件，再决定回溯或继续扩展邻居。
std::int32_t HeapPop(NavigationContext &context, const GridMap &map, const GoalPolicy &goal)
{
    auto              &heap     = context.heap_storage();
    const std::int32_t result   = heap[0];
    const std::size_t  new_size = context.heap_size() - 1;
    context.set_heap_size(new_size);
    context.TouchNode(result).heap_index = -1;
    if (new_size > 0)
    {
        // 堆顶移走后不挪动整个数组，只将最后一个有效元素补到根部。
        // new_size 之外的旧值不再属于 OPEN；随后下沉修复堆的优先级关系。
        heap[0]                               = heap[new_size];
        context.TouchNode(heap[0]).heap_index = 0;
        SiftDown(context, map, 0, goal);
    }
    return result;
}

// 根据世界毫米端点计算 XZ 直线长度，再四舍五入成整数毫米。
// 这里使用 long double 求距离；最终存储为整数，不是 A* 的整数成本分数。
// 例如 X 差 300mm、Z 差 400mm，线段长 500mm；不计 Y 高差和动画耗时。
std::uint64_t SegmentLengthMm(const WorldPosition &a, const WorldPosition &b)
{
    const long double dx = static_cast<long double>(b.x_mm) - a.x_mm;
    const long double dz = static_cast<long double>(b.z_mm) - a.z_mm;
    return static_cast<std::uint64_t>(std::llround(std::sqrt(dx * dx + dz * dz)));
}

// 函数职责：把已经找到的 goal parent 链转换为最终 WorldPosition Path，并收敛业务端点。
// context：当前查询的 NavigationContext；借用 NodeScratch，不转移所有权。
// map：当前 immutable GridMap；借用，负责 node_index -> GridPos -> WorldPosition。
// profile/policy/occupancy：与产生 parent 链的查询使用同一份规则和动态事实；只读借用。
// 平滑时只在原成本内替换合法 Segment；查询同步执行，期间不 yield 或修改 Occupancy。
// goal_index：已经到达的目标 node_index；必须属于当前 map。
// start_world：业务传入的真实起点；只读取 X/Z，Y 仍由地图 Cell 高度提供。
// exact_end_world：可选的业务终点；非空时只覆盖最后点的 X/Z，nullptr 时保留 goal Cell Center。
// 返回值：成功返回从起点到终点排列的 Path；失败返回 parent 链过长或坐标转换错误。
// 所有权与复杂度：Path 拥有最终 points；平滑窗口最多 32 个候选；不执行 I/O、加锁或 yield。
// 平滑的最坏成本是 O(L*32*32) 次 Cell 边检查；L 为原始路径点数。
NavResult<Path> BuildPath(NavigationContext &context, const GridMap &map,
                          const AgentProfile &profile, const QueryPolicy &policy,
                          const DynamicOccupancy &occupancy, std::int32_t goal_index,
                          const WorldPosition &start_world, const WorldPosition *exact_end_world)
{
    // 搜索只记每个格子“从谁走过来更便宜”，无需给每个候选复制整条路线。
    // 命中目标后再沿 parent 回溯：若 S->A->B->G，则依次读取 G、B、A、S。
    // parent_index 从目标指向起点；先得到 goal -> start 的反向序列。
    std::vector<std::int32_t> reversed;
    reversed.reserve(64);

    std::int32_t current = goal_index;
    // 每个 Node 沿 parent 只访问一次；上限防止损坏链导致无限增长。
    while (current >= 0)
    {
        if (reversed.size() >= kMaxPathPoints)
        {
            return NavResult<Path>::Failure(NavError::kPathTooLong,
                                            "path point count exceeds safety limit");
        }
        reversed.push_back(current);
        const auto &node = context.TouchNode(current);
        current          = node.parent_index;
    }

    // 回溯得到的是终点到起点，Path 必须按实际行进方向排列。
    std::reverse(reversed.begin(), reversed.end());

    // 先保留 Grid 相邻链，再用同一静态/动态判定选择可替换的 Segment。
    std::vector<GridPos> raw;
    raw.reserve(reversed.size());
    for (const std::int32_t node_index : reversed)
    {
        raw.push_back(GridFromIndex(map, node_index));
    }
    const std::vector<GridPos> smoothed = SmoothGridPath(map, profile, policy, occupancy, raw);

    // 这里只分配最终 Path 的点；A* 搜索阶段没有为每个 Node 分配对象。
    std::vector<WorldPosition> points;
    points.reserve(smoothed.size() + 2);
    for (const GridPos &grid : smoothed)
    {
        // node_index 只在 Native 内部使用；输出前转换成地图定义的世界毫米坐标。
        const auto world = map.GridToWorldCenter(grid);
        if (!world.ok())
        {
            return NavResult<Path>::Failure(world.error, world.detail);
        }
        points.push_back(world.value);
    }

    const WorldPosition start_cell_center = points.front();
    const WorldPosition end_cell_center   = points.back();
    if (!points.empty())
    {
        // 起点 Cell 的 Y 仍来自 GridMap，只有 X/Z 恢复为业务输入位置。
        points.front().x_mm = start_world.x_mm;
        points.front().z_mm = start_world.z_mm;
    }

    if (exact_end_world != nullptr && !points.empty())
    {
        if (points.size() == 1 && (points.front().x_mm != exact_end_world->x_mm ||
                                   points.front().z_mm != exact_end_world->z_mm))
        {
            // A/B 在同一 Cell 但毫米位置不同；追加真实终点，避免丢失 B。
            WorldPosition exact_end = points.front();
            exact_end.x_mm          = exact_end_world->x_mm;
            exact_end.z_mm          = exact_end_world->z_mm;
            points.push_back(exact_end);
        }
        else
        {
            // 多个 Cell 时，只修正最后一个点的 X/Z；Y 仍保留目标 Cell 高度。
            points.back().x_mm = exact_end_world->x_mm;
            points.back().z_mm = exact_end_world->z_mm;
        }
    }

    // SmoothGridPath 验证的是格心之间的线段；端点恢复为精确坐标后，首尾线段可能改变经过的 Cell。
    // 在端点与格心不重合时保留格心锚点，使新增线段留在已验证的端点 Cell 内。
    const bool endpoints_share_cell = start_cell_center.x_mm == end_cell_center.x_mm &&
                                      start_cell_center.z_mm == end_cell_center.z_mm;
    const bool start_needs_center_anchor =
        !endpoints_share_cell && (points.front().x_mm != start_cell_center.x_mm ||
                                  points.front().z_mm != start_cell_center.z_mm);
    if (start_needs_center_anchor)
    {
        points.insert(points.begin() + 1, start_cell_center);
    }

    const bool end_needs_center_anchor =
        !endpoints_share_cell && exact_end_world != nullptr &&
        (points.back().x_mm != end_cell_center.x_mm || points.back().z_mm != end_cell_center.z_mm);
    const std::size_t last_index                 = points.size() - 1;
    const bool        end_center_already_present = last_index > 0 &&
                                            points[last_index - 1].x_mm == end_cell_center.x_mm &&
                                            points[last_index - 1].y_mm == end_cell_center.y_mm &&
                                            points[last_index - 1].z_mm == end_cell_center.z_mm;
    if (end_needs_center_anchor && !end_center_already_present)
    {
        points.insert(points.end() - 1, end_cell_center);
    }

    // 端点已经修正，必须重新计算长度；不能使用修改前的 Cell Center 长度。
    std::uint64_t length_mm = 0;
    for (std::size_t i = 1; i < points.size(); ++i)
    {
        length_mm += SegmentLengthMm(points[i - 1], points[i]);
    }

    // Path 接管 points 的所有权；调用者通过 NavResult 获取最终结果。
    return NavResult<Path>::Success(Path(std::move(points), length_mm));
}

// 以生成路径时同一套静态/动态边规则复验每个输出 Segment。
// context：借用当前地图及动态事实；profile/path/policy：同步只读输入。
// 成功返回 true；空路径、越界、不可站立或非法 Segment 返回明确 NavError。
// 不修改 Context scratch/Occupancy，不执行 I/O、加锁或 yield；复杂度与穿过的 Cell 数成正比。
NavResult<bool> ValidatePathImpl(NavigationContext &context, const AgentProfile &profile,
                                 const Path &path, const QueryPolicy &policy)
{
    const auto valid_profile = ValidateAgentProfile(profile);
    if (!valid_profile.ok())
    {
        return NavResult<bool>::Failure(valid_profile.error, valid_profile.detail);
    }
    if (path.count() == 0)
    {
        return NavResult<bool>::Failure(NavError::kNoPath, "empty path");
    }
    const GridMap &map   = *context.map();
    const auto     first = map.WorldToGrid(path.WorldPoint(0));
    if (!first.ok())
    {
        return NavResult<bool>::Failure(first.error, first.detail);
    }
    if (!CanOccupy(map, profile, first.value, first.value, policy, context.occupancy()))
    {
        return NavResult<bool>::Failure(NavError::kStartNotNavigable, "path start rejected");
    }
    GridPos from = first.value;
    for (std::size_t index = 1; index < path.count(); ++index)
    {
        const auto to = map.WorldToGrid(path.WorldPoint(index));
        if (!to.ok())
        {
            return NavResult<bool>::Failure(to.error, to.detail);
        }
        if (!ValidateGridSegment(map, profile, policy, context.occupancy(), from, to.value).valid)
        {
            return NavResult<bool>::Failure(NavError::kNoPath,
                                            "path contains invalid Grid segment");
        }
        from = to.value;
    }
    return NavResult<bool>::Success(true);
}
} // namespace

// 函数职责：组织一次可配置策略的 Grid 8-way A* 查询。
// context：当前 Battle/Query 的 scratch owner；函数会修改 generation、NodeScratch 和 Binary Heap。
// profile：单位导航规则；查询期间只读，不转移所有权。
// start/end：整数毫米 WorldPosition；精确模式 end 为目标点，范围模式为目标实体中心。
// policy：静态查询不读取动态事实；Battle 查询通过 callback 解释 Context 的 DynamicOccupancy。
// range_goal/attack_range_mm：精确点用 false/0；区域目标用 true 和非负 XZ 范围毫米。
// 返回值：成功返回按行进顺序排列的世界坐标 Path；失败返回明确 NavError。
// 分配与状态：重置当前 Context 查询状态并为最终 Path 分配结果内存；不执行 I/O、加锁或 yield；最坏时间 O(V log V)，scratch 空间 O(V)。
static NavResult<Path> FindPathImpl(NavigationContext &context, const AgentProfile &profile,
                                    const WorldPosition &start, const WorldPosition &end,
                                    const QueryPolicy &policy, bool range_goal,
                                    std::uint32_t attack_range_mm, bool allow_partial = false,
                                    std::uint32_t min_range_mm = 0, bool nearest_edge = false)
{
    // 先验证 profile 的 id、体型和 Area Cost 前提；失败立即返回，不启动查询或修改 scratch。
    const auto valid_profile = ValidateAgentProfile(profile);
    if (!valid_profile.ok())
    {
        return NavResult<Path>::Failure(valid_profile.error, valid_profile.detail);
    }

    // 运行时只从 context 取得 immutable GridMap；WorldPosition 先按地图 origin/cell_size 转成 GridPos。
    const GridMap &map        = *context.map();
    const auto     start_grid = map.WorldToGrid(start);
    if (!start_grid.ok())
    {
        return NavResult<Path>::Failure(NavError::kOutOfBounds, "start outside map");
    }
    const auto end_grid = map.WorldToGrid(end);
    if (!end_grid.ok())
    {
        return NavResult<Path>::Failure(NavError::kOutOfBounds, "end outside map");
    }
    GoalPolicy goal;
    goal.exact           = !range_goal;
    goal.exact_grid      = end_grid.value;
    goal.target_world    = end;
    goal.attack_range_mm = attack_range_mm;
    goal.min_range_mm    = min_range_mm;
    // 起点和终点必须先满足单格站立条件；边坡度和切角规则留给邻居扩展阶段。
    if (!CanOccupy(map, profile, start_grid.value, start_grid.value, policy, context.occupancy()))
    {
        return NavResult<Path>::Failure(NavError::kStartNotNavigable,
                                        "start cell rejected by walkable/clearance/area");
    }
    if (goal.exact && !allow_partial &&
        !CanOccupy(map, profile, end_grid.value, end_grid.value, policy, context.occupancy()))
    {
        return NavResult<Path>::Failure(NavError::kEndNotNavigable,
                                        "end cell rejected by walkable/clearance/area");
    }

    // 到这里才启动搜索：参数、起点以及精确终点已验证，不为无效请求展开节点。
    // OPEN 是已发现但尚待展开的候选；CLOSED 是已经确认最低到达成本的节点。
    // 起点没有前驱，已走成本为 0；先把它加入 OPEN，随后由统一主循环处理。
    // BeginQuery 递增 generation 并清空本次 Heap 的逻辑范围；不会逐个 memset 整张地图。
    context.BeginQuery();
    const std::int32_t start_index = NodeIndex(map, start_grid.value);
    auto              &start_node  = context.TouchNode(start_index);
    start_node.g_cost              = 0;
    start_node.parent_index        = -1;
    start_node.state               = NavigationContext::NodeState::kOpen;
    HeapPush(context, map, start_index, goal);

    std::int32_t  reached_index = -1;
    DistanceScore reached_distance{};
    std::uint64_t reached_cost  = 0;
    std::int32_t  closest_index = -1;
    DistanceScore closest_distance{};
    std::uint64_t closest_cost = 0;
    while (context.heap_size() > 0)
    {
        // HeapPop 取出当前 f 最小的候选；节点改善时用 decrease-key 原地调整，不会留下重复旧条目。
        const std::int32_t current_index = HeapPop(context, map, goal);
        auto              &current_node  = context.TouchNode(current_index);
        if (current_node.state == NavigationContext::NodeState::kClosed)
        {
            continue;
        }
        // 精确目标的估计在每条合法边上都不会比真实成本下降得更快；
        // 范围目标的估计恒为 0。配合固定地图/策略与非负成本，出堆时该节点
        // 的最低到达成本已确定，因此 CLOSED 不必重新加入 OPEN。
        current_node.state         = NavigationContext::NodeState::kClosed;
        const GridPos current_grid = GridFromIndex(map, current_index);
        if (allow_partial)
        {
            const auto world = map.GridToWorldCenter(current_grid);
            if (world.ok() && outsideUnit(world.value, goal))
            {
                const auto distance = distanceScore(world.value, end);
                if (closest_index < 0 || distance < closest_distance ||
                    (distance == closest_distance &&
                     (current_node.g_cost < closest_cost ||
                      (current_node.g_cost == closest_cost && current_index < closest_index))))
                {
                    closest_index    = current_index;
                    closest_distance = distance;
                    closest_cost     = current_node.g_cost;
                }
            }
        }
        // 必须在目标“出堆”时结束，不能在第一次看到它作为邻居时结束：
        // 第一次发现可能是绕了一大圈的路线，OPEN 中仍可能藏着更便宜的入口。
        const bool is_goal = IsGoal(map, current_grid, goal);
        if (is_goal && nearest_edge)
        {
            const auto world    = map.GridToWorldCenter(current_grid);
            const auto distance = distanceScore(world.value, end);
            if (reached_index < 0 || distance < reached_distance ||
                (distance == reached_distance &&
                 (current_node.g_cost < reached_cost ||
                  (current_node.g_cost == reached_cost && current_index < reached_index))))
            {
                reached_index    = current_index;
                reached_distance = distance;
                reached_cost     = current_node.g_cost;
            }
        }
        if (is_goal && !nearest_edge)
        {
            auto path = BuildPath(context, map, profile, policy, context.occupancy(), current_index,
                                  start, goal.exact ? &end : nullptr);
            if (!path.ok() || !range_goal || current_index != start_index ||
                path.value.count() != 1 ||
                (WorldWithinAttackRange(start, end, attack_range_mm) && outsideUnit(start, goal)))
            {
                return path;
            }

            // 范围搜索按 Cell Center 判定 goal，但真实 start 可能在同一 Cell
            // 的远端、尚未进入攻击范围。单点 Path 会让 Battle 原地等待重寻路；
            // 此时补入已验证可站立的 Cell Center，保持世界坐标终点语义。
            const auto center = map.GridToWorldCenter(current_grid);
            if (!center.ok())
            {
                return NavResult<Path>::Failure(center.error, center.detail);
            }
            std::vector<WorldPosition> points;
            points.reserve(2);
            points.push_back(path.value.WorldPoint(0));
            points.push_back(center.value);
            const std::uint64_t length_mm = SegmentLengthMm(points[0], points[1]);
            return NavResult<Path>::Success(Path(std::move(points), length_mm));
        }

        // 当前节点出堆后才扩展它的 8 个邻居；每条边都重新执行目标格、坡度和切角验证。
        for (const Direction &direction : kDirections)
        {
            const GridPos next{
                current_grid.x + direction.dx,
                current_grid.z + direction.dz,
            };
            if (!CanTraverse(map, profile, current_grid, next, direction.dx, direction.dz, policy,
                             context.occupancy()))
            {
                continue;
            }

            // node_index 是当前 map 内稳定的一维索引；NodeScratch 由 Context 独占。
            const std::int32_t next_index = NodeIndex(map, next);
            auto              &next_node  = context.TouchNode(next_index);
            if (next_node.state == NavigationContext::NodeState::kClosed)
            {
                continue;
            }

            // 尝试“经 current 到 next”能否改善已有路线，这一步常称为松弛。
            // 例如 next 原来花 6000 才能到，这次 current 花 3000、再走一步花 1000，
            // 新方案为 4000，应换前驱；若新方案是 7000，则保持原来那条路线。
            // candidate 是经当前节点到 next 的真实 g-cost；Area Cost 已在 MoveCost 中加入。
            const std::uint32_t step      = MoveCost(map, profile, next, direction.base_cost);
            const std::uint64_t candidate = current_node.g_cost + step;
            if (next_node.state != NavigationContext::NodeState::kUnseen &&
                candidate >= next_node.g_cost)
            {
                continue;
            }

            // 只有发现新节点或找到更低 g-cost 时才改 parent；否则保留已有最优候选。
            next_node.g_cost       = candidate;
            next_node.parent_index = current_index;
            if (next_node.state == NavigationContext::NodeState::kUnseen)
            {
                next_node.state = NavigationContext::NodeState::kOpen;
                HeapPush(context, map, next_index, goal);
            }
            else
            {
                // 已在 OPEN 的节点不重复入堆；只降低成本并上浮，称为 decrease-key。
                // 地图位置没有变化，h 也不变，因此优先级只会变好，不需要下沉。
                // heap_index 让我们直接找到它，无需扫描 OPEN。
                SiftUp(context, map, static_cast<std::size_t>(next_node.heap_index), goal);
            }
        }
    }

    if (reached_index >= 0)
    {
        auto path = BuildPath(context, map, profile, policy, context.occupancy(), reached_index,
                              start, nullptr);
        if (!path.ok() || reached_index != start_index ||
            (WorldWithinAttackRange(start, end, attack_range_mm) && outsideUnit(start, goal)))
        {
            return path;
        }
        const auto                 center = map.GridToWorldCenter(start_grid.value);
        std::vector<WorldPosition> points{path.value.WorldPoint(0), center.value};
        const auto                 length = SegmentLengthMm(points[0], points[1]);
        return NavResult<Path>::Success(Path(std::move(points), length));
    }
    if (allow_partial && closest_index >= 0)
    {
        auto path = BuildPath(context, map, profile, policy, context.occupancy(), closest_index,
                              start, nullptr);
        if (!path.ok())
        {
            return path;
        }
        // 同格实际起点可能偏离格中心；有真实接近进展时也可返回 partial。
        if (closest_index == start_index)
        {
            const auto center = map.GridToWorldCenter(start_grid.value);
            std::vector<WorldPosition> points{path.value.WorldPoint(0), center.value};
            const auto length = SegmentLengthMm(points[0], points[1]);
            path = NavResult<Path>::Success(Path(std::move(points), length));
        }
        // 起点已经更接近目标时，不交付向后退的零价值 partial。
        const auto endpoint = path.value.WorldPoint(path.value.count() - 1);
        if (path.value.length_mm() > 0 && distanceScore(endpoint, end) < distanceScore(start, end))
        {
            return NavResult<Path>::Success(
                Path(path.value.points(), path.value.length_mm(), true));
        }
    }
    // OPEN 耗尽仍未弹出 goal：在本次静态/动态策略下，没有可达的合法目标。
    // 这不代表以后也不可达；其他单位让路后，下一次查询可能成功。
    return NavResult<Path>::Failure(NavError::kNoPath,
                                    "open list exhausted before reaching goal region");
}

// 静态复验入口：不读动态回调，失败按 NavResult 显式返回。
NavResult<bool> GridPathfinder::ValidatePathStatic(NavigationContext  &context,
                                                   const AgentProfile &profile, const Path &path)
{
    return ValidatePathImpl(context, profile, path, QueryPolicy{});
}

// Battle 复验入口：与 FindPath 使用同一业务动态策略，只读取当前事实。
NavResult<bool> GridPathfinder::ValidatePath(NavigationContext     &context,
                                             const NavigationAgent &agent, const Path &path,
                                             const DynamicNavigationPolicy &dynamic_policy)
{
    if (agent.profile == nullptr || !agent.handle.valid())
    {
        return NavResult<bool>::Failure(NavError::kInvalidArgument,
                                        "NavigationAgent requires a valid handle and profile");
    }
    QueryPolicy policy;
    policy.dynamic_policy = &dynamic_policy;
    policy.context        = &context;
    policy.agent          = &agent;
    policy.purpose        = DynamicQueryPurpose::kFindPath;
    return ValidatePathImpl(context, *agent.profile, path, policy);
}

// 静态入口：不叠加 DynamicOccupancy，供静态 Golden Test 和无 Battle 占用查询使用。
NavResult<Path> GridPathfinder::FindPathStatic(NavigationContext   &context,
                                               const AgentProfile  &profile,
                                               const WorldPosition &start, const WorldPosition &end)
{
    return FindPathImpl(context, profile, start, end, QueryPolicy{}, false, 0);
}

// Battle 入口：在相同 A* 主循环上叠加当前 Context 的动态 footprint 快照。
NavResult<Path> GridPathfinder::FindPath(NavigationContext &context, const NavigationAgent &agent,
                                         const WorldPosition &start, const WorldPosition &end,
                                         const DynamicNavigationPolicy &dynamic_policy,
                                         bool                           allow_partial)
{
    if (agent.profile == nullptr || !agent.handle.valid())
    {
        return NavResult<Path>::Failure(NavError::kInvalidArgument,
                                        "NavigationAgent requires a valid handle and profile");
    }
    QueryPolicy policy;
    policy.dynamic_policy = &dynamic_policy;
    policy.context        = &context;
    policy.agent          = &agent;
    policy.purpose        = DynamicQueryPurpose::kFindPath;
    return FindPathImpl(context, *agent.profile, start, end, policy, false, 0, allow_partial);
}

// Battle 范围入口：目标中心只需在地图内，不要求该中心可站立或未被占用。
// agent/policy 借用到同步调用返回；结果 Path 由调用者拥有；不执行 I/O、加锁或 yield。
NavResult<Path>
GridPathfinder::FindPathToRange(NavigationContext &context, const NavigationAgent &agent,
                                const WorldPosition &start, const WorldPosition &target,
                                                std::uint32_t                  attack_range_mm,
                                const DynamicNavigationPolicy &dynamic_policy, bool allow_partial)
{
    if (agent.profile == nullptr || !agent.handle.valid())
    {
        return NavResult<Path>::Failure(NavError::kInvalidArgument,
                                        "NavigationAgent requires a valid handle and profile");
    }
    QueryPolicy policy;
    policy.dynamic_policy = &dynamic_policy;
    policy.context        = &context;
    policy.agent          = &agent;
    policy.purpose        = DynamicQueryPurpose::kFindPath;
    return FindPathImpl(context, *agent.profile, start, target, policy, true, attack_range_mm,
                        allow_partial);
}

NavResult<Path> GridPathfinder::findPathToUnitRange(
    NavigationContext &context, const NavigationAgent &mover, const WorldPosition &start,
    const AgentProfile &target_profile, const WorldPosition &target, std::uint32_t edge_range_mm,
    const DynamicNavigationPolicy &dynamic_policy, bool allow_partial)
{
    const auto valid = ValidateAgentProfile(target_profile);
    if (!valid.ok())
    {
        return NavResult<Path>::Failure(valid.error, valid.detail);
    }
    if (mover.profile == nullptr || !mover.handle.valid())
    {
        return NavResult<Path>::Failure(NavError::kInvalidArgument,
                                        "invalid mover or target profile");
    }
    const auto valid_mover = ValidateAgentProfile(*mover.profile);
    if (!valid_mover.ok())
    {
        return NavResult<Path>::Failure(valid_mover.error, valid_mover.detail);
    }
    const auto minimum =
        static_cast<std::uint64_t>(mover.profile->radius_mm) + target_profile.radius_mm;
    const auto    cell      = context.map()->metadata().cell_size_mm;
    // ceil(sqrt(2) * cell)，通过整数平方复验避免浮点舍入影响边界。
    std::uint64_t tolerance = static_cast<std::uint64_t>(std::sqrt(2.0L) * cell);
    if (tolerance > std::numeric_limits<std::uint32_t>::max())
    {
        return NavResult<Path>::Failure(NavError::kInvalidArgument,
                                        "grid tolerance exceeds uint32 millimeters");
    }
    const std::uint64_t cell2 = static_cast<std::uint64_t>(cell) * cell;
    const DistanceScore diagonal2{cell2 + cell2 < cell2, cell2 + cell2};
    while (DistanceScore{false, tolerance * tolerance} < diagonal2)
    {
        ++tolerance;
    }
    const auto maximum = minimum + (edge_range_mm == 0 ? tolerance : edge_range_mm);
    if (maximum > std::numeric_limits<std::uint32_t>::max())
    {
        return NavResult<Path>::Failure(NavError::kInvalidArgument,
                                        "unit range exceeds uint32 millimeters");
    }
    QueryPolicy policy;
    policy.dynamic_policy = &dynamic_policy;
    policy.context        = &context;
    policy.agent          = &mover;
    policy.purpose        = DynamicQueryPurpose::kFindPath;
    return FindPathImpl(context, *mover.profile, start, target, policy, true,
                        static_cast<std::uint32_t>(maximum), allow_partial,
                        static_cast<std::uint32_t>(minimum), edge_range_mm == 0);
}

// 重新验证并提交一次相邻 Cell 移动；这是缓存 Path 消费时的权威边界。
NavResult<bool> GridPathfinder::MoveUnit(NavigationContext &context, const NavigationAgent &agent,
                                         const WorldPosition &from, const WorldPosition &to,
                                         const DynamicNavigationPolicy &dynamic_policy)
{
    if (agent.profile == nullptr || !agent.handle.valid())
    {
        return NavResult<bool>::Failure(NavError::kInvalidArgument,
                                        "NavigationAgent requires a valid handle and profile");
    }
    const AgentProfile &profile = *agent.profile;

    const GridMap &map       = *context.map();
    const auto     from_grid = map.WorldToGrid(from);
    if (!from_grid.ok())
    {
        return NavResult<bool>::Failure(from_grid.error, from_grid.detail);
    }
    const auto to_grid = map.WorldToGrid(to);
    if (!to_grid.ok())
    {
        return NavResult<bool>::Failure(to_grid.error, to_grid.detail);
    }

    const long long dx = static_cast<long long>(to_grid.value.x) - from_grid.value.x;
    const long long dz = static_cast<long long>(to_grid.value.z) - from_grid.value.z;
    if (std::llabs(dx) > 1 || std::llabs(dz) > 1)
    {
        return NavResult<bool>::Failure(NavError::kMoveBlocked,
                                        "MoveUnit accepts one Grid edge at a time");
    }

    QueryPolicy policy;
    policy.dynamic_policy = &dynamic_policy;
    policy.context        = &context;
    policy.agent          = &agent;
    policy.purpose        = DynamicQueryPurpose::kMove;
    if (dx != 0 || dz != 0)
    {
        // 复用 A* 的目标、坡度和 corner-cutting 验证，避免缓存 Path 绕过动态规则。
        if (!CanTraverse(map, profile, from_grid.value, to_grid.value,
                         static_cast<std::int32_t>(dx), static_cast<std::int32_t>(dz), policy,
                         context.occupancy()))
        {
            return NavResult<bool>::Failure(NavError::kMoveBlocked,
                                            "cached path transition is no longer traversable");
        }
    }
    else if (!CanOccupy(map, profile, from_grid.value, from_grid.value, policy,
                        context.occupancy()))
    {
        return NavResult<bool>::Failure(NavError::kMoveBlocked,
                                        "current Cell is no longer navigable");
    }

    // 所有规则已复验，DynamicOccupancy 再以 validate-before-commit 更新真实 owner。
    return context.occupancy().Move(agent.handle, profile, to_grid.value);
}

// 沿已有 Path 消耗一次 fixed-tick 距离预算；完整合同见头文件声明。
NavResult<PathAdvanceResult>
GridPathfinder::AdvancePath(NavigationContext &context, const NavigationAgent &agent,
                            const Path &path, PathFollowCursor &cursor, const WorldPosition &from,
                            std::uint32_t distance_mm, const DynamicNavigationPolicy &policy)
{
    if (agent.profile == nullptr || !agent.handle.valid() || path.count() == 0)
    {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument, "AdvancePath requires valid agent and non-empty path");
    }
    const auto valid_profile = ValidateAgentProfile(*agent.profile);
    if (!valid_profile.ok())
    {
        return NavResult<PathAdvanceResult>::Failure(valid_profile.error, valid_profile.detail);
    }
    if (cursor.next_point_index > path.count() ||
        (path.count() > 1 && cursor.next_point_index == 0))
    {
        return NavResult<PathAdvanceResult>::Failure(NavError::kInvalidArgument,
                                                     "Path cursor is outside path");
    }

    // position 从 Battle 的权威输入开始；返回前会更新为最后成功提交的位置。
    PathAdvanceResult output;
    output.position = from;
    if (cursor.next_point_index == path.count())
    {
        output.status = PathAdvanceStatus::kReached;
        return NavResult<PathAdvanceResult>::Success(output);
    }

    const std::uint64_t     cell_size_mm        = context.map()->metadata().cell_size_mm;
    // 平滑后相邻路点可能相隔很多格，但 MoveUnit 只允许同格或相邻格提交。
    // 半格长度的小步限制每次坐标变化，避免一次跨过中间障碍而只验证终点。
    // 例如格边长 500mm、预算 600mm，会尝试 250、250、100mm 的小步；
    // 若途经路点，则先截到该路点，再用剩余预算推进下一段。
    const std::uint64_t     max_substep_mm      = std::max<std::uint64_t>(1, cell_size_mm / 2);
    constexpr std::uint64_t kMaxSubstepsPerCall = 4096;
    if (distance_mm > max_substep_mm * kMaxSubstepsPerCall)
    {
        return NavResult<PathAdvanceResult>::Failure(
            NavError::kInvalidArgument, "distance budget exceeds bounded substep count");
    }

    // 把本 Tick 的距离预算分成小步；每步复用 MoveUnit 重新验证并提交。
    std::uint64_t budget   = distance_mm;
    std::uint64_t substeps = 0;
    while (budget > 0 && cursor.next_point_index < path.count())
    {
        // cursor 指向下一个路点；前一个点是当前线段的固定起点。
        const WorldPosition &origin = path.WorldPoint(cursor.next_point_index - 1);
        const WorldPosition &goal   = path.WorldPoint(cursor.next_point_index);
        const std::uint64_t  length = SegmentLengthMm(origin, goal);
        if (length == 0)
        {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
            continue;
        }
        if (cursor.segment_progress_mm >= length)
        {
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInternalError, "Path cursor progress is outside current segment");
        }
        if (++substeps > kMaxSubstepsPerCall)
        {
            output.status = PathAdvanceStatus::kMoving;
            return NavResult<PathAdvanceResult>::Success(output);
        }

        const std::uint64_t remaining = length - cursor.segment_progress_mm;
        const std::uint64_t step =
            std::min<std::uint64_t>(budget, std::min(remaining, max_substep_mm));
        // step 同时受 Tick 剩余预算、线段剩余长度、小步上限限制。
        // progress 始终相对固定线段起点累计，避免每个 Tick 在上次取整坐标上
        // 再插值而积累漂移；这也让多个 Tick 分段消费能稳定落到同一个终点。
        const std::uint64_t progress = cursor.segment_progress_mm + step;

        WorldPosition candidate = output.position;
        if (progress == length)
        {
            // 线段走完直接使用精确端点，避免整数取整让单位永远差最后 1mm。
            candidate.x_mm = goal.x_mm;
            candidate.z_mm = goal.z_mm;
        }
        else if (!InterpolateAxis(origin.x_mm, goal.x_mm, progress, length, &candidate.x_mm) ||
                 !InterpolateAxis(origin.z_mm, goal.z_mm, progress, length, &candidate.z_mm))
        {
            if (output.consumed_mm > 0)
            {
                output.status = PathAdvanceStatus::kBlocked;
                return NavResult<PathAdvanceResult>::Success(output);
            }
            return NavResult<PathAdvanceResult>::Failure(
                NavError::kInvalidArgument, "Path segment interpolation exceeds integer range");
        }

        if (candidate.x_mm != output.position.x_mm || candidate.z_mm != output.position.z_mm)
        {
            // 先做只读转换，确保地图坐标错误不会在 Occupancy 提交后才报告。
            const auto checked_grid = context.map()->WorldToGrid(candidate);
            if (!checked_grid.ok())
            {
                if (output.consumed_mm > 0)
                {
                    output.status = PathAdvanceStatus::kBlocked;
                    return NavResult<PathAdvanceResult>::Success(output);
                }
                return NavResult<PathAdvanceResult>::Failure(checked_grid.error,
                                                             checked_grid.detail);
            }
            const auto checked_world = context.map()->GridToWorldCenter(checked_grid.value);
            if (!checked_world.ok())
            {
                if (output.consumed_mm > 0)
                {
                    output.status = PathAdvanceStatus::kBlocked;
                    return NavResult<PathAdvanceResult>::Success(output);
                }
                return NavResult<PathAdvanceResult>::Failure(checked_world.error,
                                                             checked_world.detail);
            }
            const auto moved = MoveUnit(context, agent, output.position, candidate, policy);
            if (!moved.ok())
            {
                if (moved.error == NavError::kMoveBlocked ||
                    moved.error == NavError::kDynamicOccupied ||
                    moved.error == NavError::kOutOfBounds ||
                    moved.error == NavError::kStartNotNavigable ||
                    moved.error == NavError::kEndNotNavigable)
                {
                    output.status = PathAdvanceStatus::kBlocked;
                    return NavResult<PathAdvanceResult>::Success(output);
                }
                if (output.consumed_mm > 0)
                {
                    output.status = PathAdvanceStatus::kBlocked;
                    return NavResult<PathAdvanceResult>::Success(output);
                }
                return NavResult<PathAdvanceResult>::Failure(moved.error, moved.detail);
            }

            // MoveUnit 已提交目标 footprint；权威 Y 使用提交前验证的目标 Cell 地表高度。
            output.position      = checked_world.value;
            output.position.x_mm = candidate.x_mm;
            output.position.z_mm = candidate.z_mm;
            output.moved         = true;
        }

        // 只有本子步成功（或取整后 XZ 暂未变化）才消费预算、更新 cursor。
        // 若前面被挡住就已经返回，拒绝的小步不会被记作“走过”。
        // 小预算可能只推进逻辑进度、尚未改变整数坐标，所以 consumed 与 moved
        // 分开返回；遇阻时已完成的子步保留，position 仍是最后成功位置。
        cursor.segment_progress_mm = progress;
        budget -= step;
        output.consumed_mm += static_cast<std::uint32_t>(step);
        if (progress == length)
        {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
        }
    }

    output.status = cursor.next_point_index == path.count() ? PathAdvanceStatus::kReached
                                                            : PathAdvanceStatus::kMoving;
    return NavResult<PathAdvanceResult>::Success(output);
}

} // namespace flywow_navigation
