// 职责：有界稀疏空中 A*、连续 slab 扫掠与动态 AABB 更新；普通失败保持旧状态，OOM 不要求恢复。
#include "air_navigation.h"
#include "navigation_context.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <tuple>
namespace flywow_navigation
{
namespace
{
constexpr auto kMin = std::numeric_limits<std::int64_t>::min();
constexpr auto kMax = std::numeric_limits<std::int64_t>::max();
// 有序有符号端点的无符号差允许完整 int64 范围，不先做有符号减法。
std::uint64_t  unsignedDifference(std::int64_t high, std::int64_t low)
{
    return std::uint64_t(high) - std::uint64_t(low);
}
std::int64_t signedBits(std::uint64_t value)
{
    std::int64_t result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
std::int64_t saturatingSubtract(std::int64_t a, std::uint64_t b)
{
    return unsignedDifference(a, kMin) < b ? kMin : signedBits(std::uint64_t(a) - b);
}
std::int64_t saturatingAdd(std::int64_t a, std::uint64_t b)
{
    return unsignedDifference(kMax, a) < b ? kMax : signedBits(std::uint64_t(a) + b);
}
// 内部以中心到六个面的整数距离保存体积；可移动奇数边长/非正方 XZ 的已注册 AABB。
struct SweepBody
{
    std::uint64_t x_low  = 0; ///< 中心到 X 下界距离，毫米。
    std::uint64_t x_high = 0; ///< 中心到 X 上界距离，毫米。
    std::uint64_t y_low  = 0; ///< 中心到 Y 下界距离，毫米。
    std::uint64_t y_high = 0; ///< 中心到 Y 上界距离，毫米。
    std::uint64_t z_low  = 0; ///< 中心到 Z 下界距离，毫米。
    std::uint64_t z_high = 0; ///< 中心到 Z 上界距离，毫米。
    SweepBody(AirBody b)
        : x_low(b.radius_mm), x_high(b.radius_mm), y_low(b.half_height_mm),
          y_high(b.half_height_mm), z_low(b.radius_mm), z_high(b.radius_mm)
    {
    }
};
// 欧几里得商展开比较有理数；不计算可能溢出的交叉乘积。
int compare(AirFraction a, AirFraction b)
{
    int sign = 1;
    for (;;)
    {
        const std::uint64_t qa = a.numerator / a.denominator, qb = b.numerator / b.denominator;
        if (qa != qb)
        {
            return qa < qb ? -sign : sign;
        }
        const std::uint64_t ra = a.numerator % a.denominator, rb = b.numerator % b.denominator;
        if (!ra || !rb)
        {
            return ra == rb ? 0 : (!ra ? -sign : sign);
        }
        a    = {a.denominator, ra};
        b    = {b.denominator, rb};
        sign = -sign;
    }
}
// 求 floor(value*num/den)，num<=den。每轮商余数更新不使用宽整数/浮点。
std::uint64_t fractionOf(std::uint64_t value, AirFraction t)
{
    if (value <= UINT32_MAX && t.numerator <= UINT32_MAX)
    {
        return value * t.numerator / t.denominator;
    }
    std::uint64_t q = 0, r = 0;
    for (int bit = 63; bit >= 0; --bit)
    {
        q *= 2;
        if (r >= t.denominator - r)
        {
            r -= t.denominator - r;
            ++q;
        }
        else
        {
            r *= 2;
        }
        if ((value >> bit) & 1)
        {
            if (r >= t.denominator - t.numerator)
            {
                r -= t.denominator - t.numerator;
                ++q;
            }
            else
            {
                r += t.numerator;
            }
        }
    }
    return q;
}
std::int64_t interpolate(std::int64_t a, std::int64_t b, AirFraction t)
{
    // 空中规划 Y 固定，移动插值只用于 Path 的已验证端点；XZ 均在 i32 范围。
    const std::uint64_t step =
        fractionOf(a < b ? unsignedDifference(b, a) : unsignedDifference(a, b), t);
    return a < b ? a + static_cast<std::int64_t>(step) : a - static_cast<std::int64_t>(step);
}
std::pair<std::uint64_t, std::uint64_t> square(std::uint64_t a)
{
    const std::uint64_t lo = std::uint32_t(a), hi = a >> 32, cross = lo * hi;
    const std::uint64_t base = lo * lo, shifted = cross << 33, result = base + shifted;
    return {hi * hi + (cross >> 31) + (result < base), result};
}
bool clipAxisInterval(std::int64_t a, std::int64_t b, std::int64_t lo, std::int64_t hi,
                      AirFraction &entry, AirFraction &exit)
{
    if ((a < lo && b < lo) || (a > hi && b > hi))
    {
        return false;
    }
    if (a == b)
    {
        return true;
    }
    AirFraction near{0, 1}, far{1, 1};
    if (a < b)
    {
        const std::uint64_t den = unsignedDifference(b, a);
        if (a < lo)
            near = {unsignedDifference(lo, a), den};
        if (b > hi)
            far = {unsignedDifference(hi, a), den};
    }
    else
    {
        const std::uint64_t den = unsignedDifference(a, b);
        if (a > hi)
            near = {unsignedDifference(a, hi), den};
        if (b < lo)
            far = {unsignedDifference(a, lo), den};
    }
    if (compare(near, entry) > 0)
        entry = near;
    if (compare(far, exit) < 0)
        exit = far;
    return compare(entry, exit) <= 0;
}
bool intersect(WorldPosition a, WorldPosition b, SweepBody size, const AirBox &box, AirFraction &t)
{
    AirFraction exit{1, 1};
    t = {0, 1};
    return clipAxisInterval(a.x_mm, b.x_mm, saturatingSubtract(box.min.x_mm, size.x_high),
                            saturatingAdd(box.max.x_mm, size.x_low), t, exit) &&
           clipAxisInterval(a.y_mm, b.y_mm, saturatingSubtract(box.min.y_mm, size.y_high),
                            saturatingAdd(box.max.y_mm, size.y_low), t, exit) &&
           clipAxisInterval(a.z_mm, b.z_mm, saturatingSubtract(box.min.z_mm, size.z_high),
                            saturatingAdd(box.max.z_mm, size.z_low), t, exit);
}
template <typename T> NavResult<T> fail(NavError e, const char *detail)
{
    return NavResult<T>::failure(e, detail);
}
bool consumeWorkBudget(std::uint32_t &n, std::uint32_t limit)
{
    if (n == limit)
        return false;
    ++n;
    return true;
}
bool validBody(WorldPosition a, SweepBody body)
{
    return unsignedDifference(a.y_mm, kMin) >= body.y_low &&
           unsignedDifference(kMax, a.y_mm) >= body.y_high;
}
bool same(WorldPosition a, WorldPosition b)
{
    return a.x_mm == b.x_mm && a.y_mm == b.y_mm && a.z_mm == b.z_mm;
}
WorldPosition center(const GridMap &map, std::uint32_t cell, std::int64_t flight_y_mm)
{
    const auto &m = map.metadata();
    return {m.origin_x_mm + std::int64_t(cell % m.width) * m.cell_size_mm + m.cell_size_mm / 2,
            flight_y_mm,
            m.origin_z_mm + std::int64_t(cell / m.width) * m.cell_size_mm + m.cell_size_mm / 2};
}
// 按最早接触时间选择命中。扫掠子段共用调用方的工作预算。
NavResult<AirSweepResult> sweep(NavigationContext &context, AirState &air_state, WorldPosition a,
                                WorldPosition b, SweepBody body, NavigationAgentHandle exclude,
                                AirPolicy policy, std::vector<std::uint32_t> *empty_cache = nullptr)
{
    const auto &map   = *context.map();
    const auto &m     = map.metadata();
    const auto  start = map.worldToGrid(a), end = map.worldToGrid(b);
    if (!start.ok() || !end.ok() || !validBody(a, body) || !validBody(b, body))
    {
        return fail<AirSweepResult>(NavError::kOutOfBounds,
                                    "air endpoints/body outside coordinate range");
    }

    const std::int64_t right = m.origin_x_mm + std::int64_t(m.width) * m.cell_size_mm;
    const std::int64_t top   = m.origin_z_mm + std::int64_t(m.height) * m.cell_size_mm;
    if (saturatingSubtract(std::min(a.x_mm, b.x_mm), body.x_low) < m.origin_x_mm ||
        saturatingAdd(std::max(a.x_mm, b.x_mm), body.x_high) >= right ||
        saturatingSubtract(std::min(a.z_mm, b.z_mm), body.z_low) < m.origin_z_mm ||
        saturatingAdd(std::max(a.z_mm, b.z_mm), body.z_high) >= top)
    {
        return fail<AirSweepResult>(NavError::kOutOfBounds, "air volume crosses map boundary");
    }

    AirSweepResult best;
    auto hit = [&](const AirBox &box, AirHitKind kind, std::uint64_t handle, std::uint32_t cell)
    {
        AirFraction t;
        if (intersect(a, b, body, box, t) &&
            (best.kind == AirHitKind::kClear || compare(t, best.time) < 0 ||
             (compare(t, best.time) == 0 &&
              std::make_tuple(kind, kind == AirHitKind::kStatic ? std::uint64_t(cell) : handle) <
                  std::make_tuple(best.kind, best.kind == AirHitKind::kStatic
                                                 ? std::uint64_t(best.cell_index)
                                                 : best.handle.value))))
        {
            best = {kind, {handle}, cell, t};
        }
    };
    // 整数 DDA 将中心线分成单格内的连续子段；只枚举该子段盒体实际可能触及的桶。
    // 插值向起点截断，额外 1mm 包络覆盖另一侧舍入和闭合格线；slab 仍以原端点精确过滤。
    auto visit = [&](AirFraction entry, AirFraction exit) -> bool
    {
        const auto ax = interpolate(a.x_mm, b.x_mm, entry), bx = interpolate(a.x_mm, b.x_mm, exit);
        const auto az = interpolate(a.z_mm, b.z_mm, entry), bz = interpolate(a.z_mm, b.z_mm, exit);
        const auto low_x  = saturatingSubtract(saturatingSubtract(std::min(ax, bx), body.x_low), 1);
        const auto high_x = saturatingAdd(saturatingAdd(std::max(ax, bx), body.x_high), 1);
        const auto low_z  = saturatingSubtract(saturatingSubtract(std::min(az, bz), body.z_low), 1);
        const auto high_z = saturatingAdd(saturatingAdd(std::max(az, bz), body.z_high), 1);

        const auto floor_cell = [&](std::int64_t v, std::int32_t origin) -> std::int64_t
        {
            const auto relative = v - origin;
            return relative / m.cell_size_mm - ((relative < 0 && relative % m.cell_size_mm) != 0);
        };
        const auto x0 = std::max<std::int64_t>(0, floor_cell(low_x, m.origin_x_mm));
        const auto z0 = std::max<std::int64_t>(0, floor_cell(low_z, m.origin_z_mm));
        const auto x1 = std::min<std::int64_t>(m.width - 1, floor_cell(high_x, m.origin_x_mm));
        const auto z1 = std::min<std::int64_t>(m.height - 1, floor_cell(high_z, m.origin_z_mm));

        for (auto zz = z0; zz <= z1; ++zz)
        {
            for (auto xx = x0; xx <= x1; ++xx)
            {
                const auto cell   = std::uint32_t(zz * m.width + xx);
                // 固定高度的一次搜索内复用无高度候选证明；命中缓存不访问空间索引。
                // 缓存查找计 tests，真正重复访问空间桶仍计 buckets；动态修改后重新查询。
                auto       cached = empty_cache
                                        ? std::lower_bound(empty_cache->begin(), empty_cache->end(), cell)
                                        : std::vector<std::uint32_t>::iterator{};
                if (empty_cache)
                {
                    if (!consumeWorkBudget(air_state.stats.tests, air_state.limits.tests))
                        return false;
                    if (cached != empty_cache->end() && *cached == cell)
                        continue;
                }

                if (!consumeWorkBudget(air_state.stats.buckets, air_state.limits.buckets))
                    return false;

                bool       height_empty = !policy.check_terrain;
                const auto low_y        = saturatingSubtract(a.y_mm, body.y_low),
                           high_y       = saturatingAdd(a.y_mm, body.y_high);
                AirBox column{{m.origin_x_mm + xx * m.cell_size_mm, kMin,
                               m.origin_z_mm + zz * m.cell_size_mm},
                              {m.origin_x_mm + (xx + 1) * m.cell_size_mm, kMax,
                               m.origin_z_mm + (zz + 1) * m.cell_size_mm}};
                if (policy.check_terrain)
                {
                    if (!consumeWorkBudget(air_state.stats.tests, air_state.limits.tests))
                        return false;
                    auto terrain = column;
                    terrain.max.y_mm =
                        std::int64_t(map.tryCell({std::int32_t(xx), std::int32_t(zz)})->height_mm) +
                        policy.clearance_mm;
                    hit(terrain, AirHitKind::kStatic, 0, cell);
                }

                const auto &asset  = map.airAsset();
                auto        record = std::lower_bound(asset.cells.begin(), asset.cells.end(), cell,
                                                      [](const AirCell &c, std::uint32_t id)
                                                      { return c.cell_index < id; });
                if (record != asset.cells.end() && record->cell_index == cell)
                {
                    for (unsigned i = 0; i < record->count; ++i)
                    {
                        if (!consumeWorkBudget(air_state.stats.tests, air_state.limits.tests))
                            return false;
                        const auto &interval = asset.intervals[record->offset + i];
                        if (interval.min_y_mm <= high_y && interval.max_y_mm >= low_y)
                            height_empty = false;
                        column.min.y_mm = interval.min_y_mm;
                        column.max.y_mm = interval.max_y_mm;
                        hit(column, AirHitKind::kStatic, 0, cell);
                    }
                }

                for (auto it = air_state.links.lower_bound({cell, 0});
                     it != air_state.links.end() && it->first == cell; ++it)
                {
                    if (!consumeWorkBudget(air_state.stats.tests, air_state.limits.tests))
                        return false;
                    const auto handle = it->second;
                    if (handle != exclude.value)
                    {
                        const auto &box = air_state.objects.at(handle);
                        if (box.min.y_mm <= high_y && box.max.y_mm >= low_y)
                            height_empty = false;
                        hit(box, AirHitKind::kDynamic, handle, cell);
                    }
                }

                if (empty_cache && height_empty)
                    empty_cache->insert(cached, cell);
            }
        }
        return true;
    };
    // 相邻格边的整体 XZ 包络至多跨 2x2 个中心格；一次枚举即覆盖全部连续体积。
    // 避免在同一条 A* 边的多个 DDA 子段重复查同桶；仍用完整原端点 slab，非采样。
    if (std::abs(end.value.x - start.value.x) <= 1 && std::abs(end.value.z - start.value.z) <= 1)
    {
        if (!visit({0, 1}, {1, 1}))
            return fail<AirSweepResult>(NavError::kQueryBudgetExceeded,
                                        "air sweep work budget exhausted");
        return NavResult<AirSweepResult>::success(best);
    }
    std::int64_t x = start.value.x, z = start.value.z;
    const int    sx = (b.x_mm > a.x_mm) - (b.x_mm < a.x_mm),
              sz    = (b.z_mm > a.z_mm) - (b.z_mm < a.z_mm);
    const std::uint64_t nx =
        sx ? (sx > 0 ? unsignedDifference(b.x_mm, a.x_mm) : unsignedDifference(a.x_mm, b.x_mm)) : 1;
    const std::uint64_t nz =
        sz ? (sz > 0 ? unsignedDifference(b.z_mm, a.z_mm) : unsignedDifference(a.z_mm, b.z_mm)) : 1;
    AirFraction entry{0, 1};
    for (;;)
    {
        AirFraction tx{2, 1}, tz{2, 1};
        if (sx && x != end.value.x)
        {
            const auto boundary = m.origin_x_mm + (x + (sx > 0)) * m.cell_size_mm;
            tx                  = {sx > 0 ? unsignedDifference(boundary, a.x_mm)
                                          : unsignedDifference(a.x_mm, boundary),
                  nx};
        }
        if (sz && z != end.value.z)
        {
            const auto boundary = m.origin_z_mm + (z + (sz > 0)) * m.cell_size_mm;
            tz                  = {sz > 0 ? unsignedDifference(boundary, a.z_mm)
                                          : unsignedDifference(a.z_mm, boundary),
                  nz};
        }
        const int   order = compare(tx, tz);
        AirFraction exit  = order < 0 ? tx : tz;
        if (compare(exit, {1, 1}) > 0)
            exit = {1, 1};
        if (!visit(entry, exit))
            return fail<AirSweepResult>(NavError::kQueryBudgetExceeded,
                                        "air sweep work budget exhausted");
        if (x == end.value.x && z == end.value.z)
            break;
        if (order <= 0)
            x += sx;
        if (order >= 0)
            z += sz;
        entry = exit;
    }
    return NavResult<AirSweepResult>::success(best);
}
// set/move 通过此处更新当前会话的动态盒及空间关联；所有普通失败在清旧前返回。
// context 提供不可变地图，air_state 独占对象与桶；handle 是业务句柄，box 是待登记的闭合世界 AABB。
// 不 yield、不跨线程共享；成功更新两份索引，参数/越界/容量失败保留旧状态，OOM 不承诺恢复。
NavResult<bool> set(NavigationContext &context, AirState &air_state, NavigationAgentHandle handle,
                    const AirBox &box)
{
    const auto &m = context.map()->metadata();
    if (!handle.valid() || box.min.x_mm > box.max.x_mm || box.min.y_mm > box.max.y_mm ||
        box.min.z_mm > box.max.z_mm)
    {
        return fail<bool>(NavError::kInvalidArgument, "air AABB/handle invalid");
    }

    const auto a = context.map()->worldToGrid(box.min), b = context.map()->worldToGrid(box.max);
    if (!a.ok() || !b.ok())
        return fail<bool>(NavError::kOutOfBounds, "air AABB outside map");

    // 闭下边界位于格线时必须同时关联左/下格；地图边界外不建立桶。
    auto x0 = a.value.x, z0 = a.value.z;
    if ((box.min.x_mm - m.origin_x_mm) % m.cell_size_mm == 0 && x0 > 0)
        --x0;
    if ((box.min.z_mm - m.origin_z_mm) % m.cell_size_mm == 0 && z0 > 0)
        --z0;
    const std::uint64_t count =
        std::uint64_t(b.value.x - x0 + 1) * std::uint64_t(b.value.z - z0 + 1);
    auto old = air_state.objects.find(handle.value);

    if (count > air_state.limits.object_links ||
        (old == air_state.objects.end() && air_state.objects.size() == air_state.limits.objects))
    {
        return fail<bool>(NavError::kCapacityExceeded, "air dynamic object/link capacity");
    }

    // 旧盒是关联范围的唯一来源；只重算本对象覆盖的格，不保存第二份关联清单。
    GridPos       old_min{};     // 更新已有对象时，用于删除旧盒在闭边界规则下覆盖的关联。
    GridPos       old_max{};     // 旧盒覆盖范围的右上格；首次插入时不使用。
    std::uint64_t old_count = 0; // 本对象即将释放的关联数；容量预检必须扣除这些关联。
    if (old != air_state.objects.end())
    {
        old_min = context.map()->worldToGrid(old->second.min).value;
        old_max = context.map()->worldToGrid(old->second.max).value;
        if ((old->second.min.x_mm - m.origin_x_mm) % m.cell_size_mm == 0 && old_min.x > 0)
            --old_min.x;
        if ((old->second.min.z_mm - m.origin_z_mm) % m.cell_size_mm == 0 && old_min.z > 0)
            --old_min.z;
        old_count =
            std::uint64_t(old_max.x - old_min.x + 1) * std::uint64_t(old_max.z - old_min.z + 1);
    }
    if (air_state.links.size() - old_count + count > air_state.limits.links)
    {
        return fail<bool>(NavError::kCapacityExceeded, "air total link capacity");
    }

    // 参数、地图范围和容量失败均在修改前返回；OOM 交给运行时，不构建恢复用临时 map。
    if (old != air_state.objects.end())
    {
        for (int z = old_min.z; z <= old_max.z; ++z)
        {
            for (int x = old_min.x; x <= old_max.x; ++x)
                air_state.links.erase(
                    {std::uint32_t(std::uint64_t(z) * m.width + x), handle.value});
        }
    }
    for (int z = z0; z <= b.value.z; ++z)
    {
        for (int x = x0; x <= b.value.x; ++x)
            air_state.links.emplace(std::uint32_t(std::uint64_t(z) * m.width + x), handle.value);
    }
    air_state.objects.insert_or_assign(handle.value, box);
    return NavResult<bool>::success(true);
}
NavResult<WorldPosition> move(NavigationContext &context, AirState &air_state,
                              NavigationAgentHandle handle, WorldPosition target, AirPolicy policy)
{
    const auto it = air_state.objects.find(handle.value);
    if (it == air_state.objects.end())
        return fail<WorldPosition>(NavError::kInvalidArgument, "air handle not registered");

    const auto &box = it->second;
    const auto  dx  = unsignedDifference(box.max.x_mm, box.min.x_mm),
               dy   = unsignedDifference(box.max.y_mm, box.min.y_mm),
               dz   = unsignedDifference(box.max.z_mm, box.min.z_mm);
    SweepBody body(AirBody{});
    body.x_low  = dx / 2;
    body.x_high = dx - dx / 2;
    body.y_low  = dy / 2;
    body.y_high = dy - dy / 2;
    body.z_low  = dz / 2;
    body.z_high = dz - dz / 2;

    if (!validBody(target, body))
        return fail<WorldPosition>(NavError::kInvalidArgument, "air body Y overflow");
    // 奇数毫米边长使用向下的中点；移动保存六个面相对中心的距离，不改变体积。
    WorldPosition from{saturatingAdd(box.min.x_mm, body.x_low),
                       saturatingAdd(box.min.y_mm, body.y_low),
                       saturatingAdd(box.min.z_mm, body.z_low)};
    const auto    tested = sweep(context, air_state, from, target, body, handle, policy);
    if (!tested.ok())
        return fail<WorldPosition>(tested.error, tested.detail.c_str());
    if (tested.value.kind != AirHitKind::kClear)
        return fail<WorldPosition>(NavError::kBlocked, "air move blocked");
    AirBox     moved{{saturatingSubtract(target.x_mm, body.x_low),
                      saturatingSubtract(target.y_mm, body.y_low),
                      saturatingSubtract(target.z_mm, body.z_low)},
                     {saturatingAdd(target.x_mm, body.x_high), saturatingAdd(target.y_mm, body.y_high),
                      saturatingAdd(target.z_mm, body.z_high)}};
    const auto placed = set(context, air_state, handle, moved);
    if (!placed.ok())
        return fail<WorldPosition>(placed.error, placed.detail.c_str());
    return NavResult<WorldPosition>::success(target);
}

} // namespace
std::uint64_t airDistance(WorldPosition a, WorldPosition b)
{
    const std::uint64_t dx =
        a.x_mm < b.x_mm ? unsignedDifference(b.x_mm, a.x_mm) : unsignedDifference(a.x_mm, b.x_mm);
    const std::uint64_t dz =
        a.z_mm < b.z_mm ? unsignedDifference(b.z_mm, a.z_mm) : unsignedDifference(a.z_mm, b.z_mm);
    // 两个 i32 世界坐标之差至多 UINT32_MAX；平方和使用显式双字避免 uint64 溢出。
    auto                                    x = square(dx), z = square(dz);
    std::pair<std::uint64_t, std::uint64_t> total{
        x.first + z.first + (x.second + z.second < x.second), x.second + z.second};
    std::uint64_t lo = 0, hi = std::uint64_t(1) << 33;
    while (lo + 1 < hi)
    {
        std::uint64_t mid = (lo + hi) / 2;
        if (square(mid) <= total)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}
NavResult<bool> setAirObstacle(NavigationContext &context, NavigationAgentHandle handle,
                               const AirBox &box)
{
    return set(context, context.airState(), handle, box);
}
NavResult<bool> removeAirObstacle(NavigationContext &context, NavigationAgentHandle handle)
{
    auto &air_state = context.airState();
    auto  it        = air_state.objects.find(handle.value);
    if (!handle.valid())
        return fail<bool>(NavError::kInvalidArgument, "air handle is zero");
    if (it != air_state.objects.end())
    {
        // 仅遍历本对象不超过 256 个格关联；与 set 相同的闭边界规则。
        const auto &m = context.map()->metadata();
        auto        a = context.map()->worldToGrid(it->second.min).value,
             b        = context.map()->worldToGrid(it->second.max).value;
        if ((it->second.min.x_mm - m.origin_x_mm) % m.cell_size_mm == 0 && a.x > 0)
            --a.x;
        if ((it->second.min.z_mm - m.origin_z_mm) % m.cell_size_mm == 0 && a.z > 0)
            --a.z;
        for (int z = a.z; z <= b.z; ++z)
        {
            for (int x = a.x; x <= b.x; ++x)
                air_state.links.erase(
                    {std::uint32_t(std::uint64_t(z) * m.width + x), handle.value});
        }
        air_state.objects.erase(it);
    }
    return NavResult<bool>::success(true);
}
NavResult<AirSweepResult> sweepAir(NavigationContext &context, WorldPosition a, WorldPosition b,
                                   AirBody body, NavigationAgentHandle exclude, AirPolicy policy)
{
    auto &air_state = context.airState();
    air_state.stats = {};
    return sweep(context, air_state, a, b, body, exclude, policy);
}
NavResult<WorldPosition> moveAir(NavigationContext &context, NavigationAgentHandle handle,
                                 WorldPosition to, AirPolicy policy)
{
    auto &air_state = context.airState();
    air_state.stats = {};
    return move(context, air_state, handle, to, policy);
}
NavResult<Path> findAirPath(NavigationContext &context, WorldPosition start, WorldPosition target,
                            std::int64_t flight_y_mm, AirBody body, NavigationAgentHandle exclude,
                            AirPolicy policy, std::uint32_t range_mm)
{
    auto &air_state = context.airState();
    air_state.stats = {};
    air_state.empty_cells.clear();
    air_state.empty_cells.reserve(air_state.limits.buckets);
    const auto &map = *context.map();
    const auto &m   = map.metadata();
    start.y_mm      = flight_y_mm;
    target.y_mm     = flight_y_mm;
    const auto from = map.worldToGrid(start), goal = map.worldToGrid(target);
    if (!from.ok() || !goal.ok())
        return fail<Path>(NavError::kOutOfBounds, "air path endpoints outside map");
    auto check =
        sweep(context, air_state, start, start, body, exclude, policy, &air_state.empty_cells);
    if (!check.ok())
        return fail<Path>(check.error, check.detail.c_str());
    if (check.value.kind != AirHitKind::kClear)
        return fail<Path>(NavError::kStartNotNavigable, "air start blocked");
    if (!range_mm)
    {
        check = sweep(context, air_state, target, target, body, exclude, policy,
                      &air_state.empty_cells);
        if (!check.ok())
            return fail<Path>(check.error, check.detail.c_str());
        if (check.value.kind != AirHitKind::kClear)
            return fail<Path>(NavError::kEndNotNavigable, "air end blocked");
    }
    // 仅在剩余预算内尝试捷径，其他路段沿已验证的原路线交付。
    auto make = [&](std::vector<WorldPosition> points) -> NavResult<Path>
    {
        if (points.size() > air_state.limits.path_points)
            return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
        // 构造/长度整理的有界工作也由同一预算预留，平滑耗尽只保留已验证路线。
        const auto construct_work = static_cast<std::uint32_t>(points.size() * 2);
        if (construct_work > air_state.limits.tests - air_state.stats.tests)
            return fail<Path>(NavError::kQueryBudgetExceeded,
                              "air path construction budget exhausted");
        air_state.stats.tests += construct_work;
        const auto  count = points.size();
        std::size_t write = 1, read = 1;
        while (read < count)
        {
            // 从最远候选开始，失败时折半；避免逐点延长导致长路径 O(n²) 扫掠。
            // 找到的捷径均完整验证；未验证的原路线边仍可直接保留。
            auto candidate        = count - 1;
            bool budget_exhausted = false;
            while (candidate > read)
            {
                const auto shortcut =
                    sweep(context, air_state, points[write - 1], points[candidate], body, exclude,
                          policy, &air_state.empty_cells);
                if (!shortcut.ok())
                {
                    if (shortcut.error != NavError::kQueryBudgetExceeded)
                        return fail<Path>(shortcut.error, shortcut.detail.c_str());
                    budget_exhausted = true;
                    break;
                }
                if (shortcut.value.kind == AirHitKind::kClear)
                {
                    read = candidate;
                    break;
                }
                candidate = read + (candidate - read) / 2;
            }
            if (budget_exhausted)
            {
                while (read < count)
                    points[write++] = points[read++];
                break;
            }
            points[write++] = points[read++];
        }
        points.resize(write);
        std::uint64_t length = 0;
        for (std::size_t i = 1; i < points.size(); ++i)
            length += airDistance(points[i - 1], points[i]);
        Path path(std::move(points), length);
        path.markAir(context.map(), flight_y_mm, body.radius_mm, body.half_height_mm);
        return NavResult<Path>::success(std::move(path));
    };
    auto within_range = [&](WorldPosition point)
    {
        const std::uint64_t dx = point.x_mm >= target.x_mm
                                     ? unsignedDifference(point.x_mm, target.x_mm)
                                     : unsignedDifference(target.x_mm, point.x_mm);
        const std::uint64_t dz = point.z_mm >= target.z_mm
                                     ? unsignedDifference(point.z_mm, target.z_mm)
                                     : unsignedDifference(target.z_mm, point.z_mm);
        // 圆范围判定用精确平方比较；不能把路径长度的 sqrt 向下取整误用于圆边界。
        if (dx > range_mm || dz > range_mm)
            return false;
        const std::uint64_t square = std::uint64_t(range_mm) * range_mm;
        return dz * dz <= square - dx * dx;
    };
    if (range_mm && within_range(start))
        return make({start});
    check = sweep(context, air_state, start, target, body, exclude, policy, &air_state.empty_cells);
    // 范围查询只要求最终体积在地图内；目标中心可以靠边，不能由目标盒越界拒绝整个范围。
    const bool range_target_outside = range_mm && check.error == NavError::kOutOfBounds;
    if (!check.ok() && !range_target_outside)
        return fail<Path>(check.error, check.detail.c_str());
    if (check.ok() && check.value.kind == AirHitKind::kClear && !same(start, target) &&
        air_state.limits.path_points < 2)
        return fail<Path>(NavError::kCapacityExceeded, "air direct path point capacity");
    if (check.ok() && check.value.kind == AirHitKind::kClear)
        return make(same(start, target) ? std::vector<WorldPosition>{start}
                                        : std::vector<WorldPosition>{start, target});

    // 查询 scratch 首次 reserve，随后保持有界容量；不为地图所有格分配空中数组。
    air_state.nodes.clear();
    air_state.index.clear();
    air_state.heap.clear();
    air_state.nodes.reserve(air_state.limits.nodes);
    air_state.index.reserve(air_state.limits.nodes);
    air_state.heap.reserve(air_state.limits.nodes);
    const auto destination = std::uint32_t(std::uint64_t(goal.value.z) * m.width + goal.value.x);
    const auto origin      = std::uint32_t(std::uint64_t(from.value.z) * m.width + from.value.x);
    auto       heuristic   = [&](std::uint32_t cell) -> std::uint64_t
    {
        if (range_mm)
            return 0; // 范围终点用 Dijkstra，避免不一致的离散启发式。
        const std::uint64_t dx = cell % m.width > destination % m.width
                                     ? cell % m.width - destination % m.width
                                     : destination % m.width - cell % m.width;
        const std::uint64_t dz = cell / m.width > destination / m.width
                                     ? cell / m.width - destination / m.width
                                     : destination / m.width - cell / m.width;
        // 整数 1000/1414 直/斜成本；固定邻居顺序与格号平局使结果可复现。
        return std::min(dx, dz) * 1414 + (std::max(dx, dz) - std::min(dx, dz)) * 1000;
    };
    auto less = [&](unsigned a, unsigned b)
    {
        const auto &aa = air_state.nodes[a], &bb = air_state.nodes[b];
        // 同 f 时优先靠近目标的较大 g；不改变最短路正确性，避免开放区等价路线铺满。
        if (aa.f != bb.f)
            return aa.f < bb.f;
        if (aa.g != bb.g)
            return aa.g > bb.g;
        return aa.cell < bb.cell;
    };
    auto swap_heap_slots = [&](std::size_t a, std::size_t b)
    {
        std::swap(air_state.heap[a], air_state.heap[b]);
        air_state.nodes[air_state.heap[a]].heap = std::int32_t(a);
        air_state.nodes[air_state.heap[b]].heap = std::int32_t(b);
    };
    auto up = [&](std::size_t i)
    {
        while (i && less(air_state.heap[i], air_state.heap[(i - 1) / 2]))
        {
            swap_heap_slots(i, (i - 1) / 2);
            i = (i - 1) / 2;
        }
    };
    auto offer = [&](std::uint32_t cell, std::uint64_t g, std::int32_t parent) -> bool
    {
        auto     it = std::lower_bound(air_state.index.begin(), air_state.index.end(), cell,
                                       [](const auto &v, std::uint32_t id) { return v.first < id; });
        unsigned id;
        if (it == air_state.index.end() || it->first != cell)
        {
            if (air_state.nodes.size() == air_state.limits.nodes)
                return false;
            id = static_cast<unsigned>(air_state.nodes.size());
            air_state.index.insert(it, {cell, id});
            air_state.nodes.push_back(
                {cell, g, g + heuristic(cell), parent, std::int32_t(air_state.heap.size())});
            air_state.heap.push_back(id);
        }
        else
        {
            id = it->second;
            if (air_state.nodes[id].heap < 0 || air_state.nodes[id].g <= g)
                return true;
            air_state.nodes[id].g      = g;
            air_state.nodes[id].f      = g + heuristic(cell);
            air_state.nodes[id].parent = parent;
        }
        up(std::size_t(air_state.nodes[id].heap));
        return true;
    };
    const auto first = center(map, origin, flight_y_mm);
    check = sweep(context, air_state, start, first, body, exclude, policy, &air_state.empty_cells);
    if (!check.ok())
        return fail<Path>(check.error, check.detail.c_str());
    if (check.value.kind != AirHitKind::kClear)
        return fail<Path>(NavError::kNoPath, "air start-center connection blocked");
    offer(origin, 0, -1);
    constexpr int dirs[8][2] = {{1, 0}, {0, 1},  {-1, 0},  {0, -1},
                                {1, 1}, {-1, 1}, {-1, -1}, {1, -1}};
    // 每次展开唯一的堆顶节点。邻边通过扫掠后才登记或降低候选成本。
    while (!air_state.heap.empty())
    {
        if (!consumeWorkBudget(air_state.stats.expanded, air_state.limits.expanded))
            return fail<Path>(NavError::kSearchBudgetExceeded, "air expansion budget exhausted");
        const auto id = air_state.heap.front();
        swap_heap_slots(0, air_state.heap.size() - 1);
        air_state.heap.pop_back();
        air_state.nodes[id].heap = -1;
        std::size_t slot         = 0;
        for (;;)
        {
            auto left = slot * 2 + 1;
            if (left >= air_state.heap.size())
                break;
            if (left + 1 < air_state.heap.size() &&
                less(air_state.heap[left + 1], air_state.heap[left]))
                ++left;
            if (!less(air_state.heap[left], air_state.heap[slot]))
                break;
            swap_heap_slots(left, slot);
            slot = left;
        }
        const auto current = air_state.nodes[id];
        const auto point   = center(map, current.cell, flight_y_mm);
        const bool reached = range_mm ? within_range(point) : current.cell == destination;
        if (reached)
        {
            if (!range_mm)
            {
                check = sweep(context, air_state, point, target, body, exclude, policy,
                              &air_state.empty_cells);
                if (!check.ok())
                    return fail<Path>(check.error, check.detail.c_str());
                if (check.value.kind != AirHitKind::kClear)
                    continue;
            }
            std::vector<WorldPosition> points;
            for (auto node = std::int32_t(id); node >= 0; node = air_state.nodes[node].parent)
            {
                if (points.size() == air_state.limits.path_points)
                    return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
                points.push_back(center(map, air_state.nodes[node].cell, flight_y_mm));
            }
            std::reverse(points.begin(), points.end());
            if (!same(start, points.front()))
            {
                if (points.size() == air_state.limits.path_points)
                    return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
                points.insert(points.begin(), start);
            }
            if (!range_mm && !same(target, points.back()))
            {
                if (points.size() == air_state.limits.path_points)
                    return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
                points.push_back(target);
            }
            // 所有路线边已验证；不做无预算的额外捷径。逐边路线是合法的未平滑结果。
            return make(std::move(points));
        }
        const auto x = current.cell % m.width, z = current.cell / m.width;
        for (auto &dir : dirs)
        {
            const auto nx = std::int64_t(x) + dir[0], nz = std::int64_t(z) + dir[1];
            if (nx < 0 || nz < 0 || nx >= m.width || nz >= m.height)
                continue;
            const auto cell      = std::uint32_t(nz * m.width + nx);
            const auto next_cost = current.g + ((dir[0] && dir[1]) ? 1414 : 1000);
            const auto known     = std::lower_bound(air_state.index.begin(), air_state.index.end(),
                                                    cell, [](const auto &entry, std::uint32_t candidate)
                                                    { return entry.first < candidate; });
            // 已关闭或已有不更差路线的节点无需重验一条不会参与松弛的边。
            if (known != air_state.index.end() && known->first == cell &&
                (air_state.nodes[known->second].heap < 0 ||
                 air_state.nodes[known->second].g <= next_cost))
                continue;
            check = sweep(context, air_state, point, center(map, cell, flight_y_mm), body, exclude,
                          policy, &air_state.empty_cells);
            if (!check.ok())
                return fail<Path>(check.error, check.detail.c_str());
            if (check.value.kind != AirHitKind::kClear)
                continue;
            if (!offer(cell, next_cost, std::int32_t(id)))
            {
                return fail<Path>(NavError::kSearchBudgetExceeded,
                                  "air touched-node capacity exhausted");
            }
        }
    }
    return fail<Path>(NavError::kNoPath, "air search exhausted reachable cells");
}
NavResult<PathAdvanceResult> advanceAirPath(NavigationContext    &context,
                                            NavigationAgentHandle handle, const Path &path,
                                            PathFollowCursor &cursor, std::uint32_t distance_mm,
                                            AirPolicy policy)
{
    auto &air_state = context.airState();
    air_state.stats = {};
    auto found      = air_state.objects.find(handle.value);
    if (!path.isAir() || path.airMap() != context.map().get() || !path.count() ||
        found == air_state.objects.end() || cursor.next_point_index < 1 ||
        cursor.next_point_index > path.count())
    {
        return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                       "air path/context/handle/cursor mismatch");
    }
    const auto &box = found->second;
    AirBody     actual;
    if (unsignedDifference(box.max.x_mm, box.min.x_mm) != std::uint64_t(path.airRadius()) * 2 ||
        unsignedDifference(box.max.z_mm, box.min.z_mm) != std::uint64_t(path.airRadius()) * 2 ||
        unsignedDifference(box.max.y_mm, box.min.y_mm) != std::uint64_t(path.airHalfHeight()) * 2)
    {
        return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                       "air path body changed; replan required");
    }
    actual = {path.airRadius(), path.airHalfHeight()};
    PathAdvanceResult advance_result;
    advance_result.position = {box.min.x_mm + actual.radius_mm,
                               box.min.y_mm + actual.half_height_mm,
                               box.min.z_mm + actual.radius_mm};
    if (advance_result.position.y_mm != path.flightY())
    {
        return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                       "air path height changed; replan required");
    }
    if (cursor.next_point_index == path.count() &&
        !same(advance_result.position, path.worldPoint(path.count() - 1)))
    {
        return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                       "air object moved away from completed path");
    }
    std::uint64_t left = distance_mm;
    while (cursor.next_point_index < path.count())
    {
        const auto a               = path.worldPoint(cursor.next_point_index - 1),
                   b               = path.worldPoint(cursor.next_point_index);
        const std::uint64_t length = airDistance(a, b);
        if (cursor.segment_progress_mm > length)
            return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                           "air cursor progress invalid");
        const AirFraction   current{cursor.segment_progress_mm, length ? length : 1};
        const WorldPosition expected{interpolate(a.x_mm, b.x_mm, current), a.y_mm,
                                     interpolate(a.z_mm, b.z_mm, current)};
        if (!same(advance_result.position, expected))
            return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                           "air object moved away from cursor");
        if (!length)
        {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
            continue;
        }
        if (!left)
            break;
        const std::uint64_t amount   = std::min(left, length - cursor.segment_progress_mm);
        const std::uint64_t progress = cursor.segment_progress_mm + amount;
        const AirFraction   t{progress, length};
        const WorldPosition next{interpolate(a.x_mm, b.x_mm, t), a.y_mm,
                                 interpolate(a.z_mm, b.z_mm, t)};
        const auto          moved = move(context, air_state, handle, next, policy);
        if (!moved.ok())
        {
            if (moved.error != NavError::kBlocked)
                return fail<PathAdvanceResult>(moved.error, moved.detail.c_str());
            advance_result.status = PathAdvanceStatus::kBlocked;
            return NavResult<PathAdvanceResult>::success(advance_result);
        }
        // 扫掠和占位提交成功后，再同步游标与最后提交位置。
        advance_result.moved    = advance_result.moved || !same(next, advance_result.position);
        advance_result.position = next;
        advance_result.consumed_mm += std::uint32_t(amount);
        left -= amount;
        cursor.segment_progress_mm = progress;
        if (progress == length)
        {
            ++cursor.next_point_index;
            cursor.segment_progress_mm = 0;
        }
    }
    advance_result.status = cursor.next_point_index == path.count() ? PathAdvanceStatus::kReached
                                                                    : PathAdvanceStatus::kMoving;
    return NavResult<PathAdvanceResult>::success(advance_result);
}

} // namespace flywow_navigation
