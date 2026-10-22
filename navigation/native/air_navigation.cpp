// 职责：有界稀疏空中 A*、连续 slab 扫掠与动态 AABB 原子提交。
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
using U             = std::uint64_t;
constexpr auto kMin = std::numeric_limits<std::int64_t>::min();
constexpr auto kMax = std::numeric_limits<std::int64_t>::max();
// 有序有符号端点的无符号差允许完整 int64 范围，不先做有符号减法。
U              distance(std::int64_t high, std::int64_t low)
{
    return U(high) - U(low);
}
std::int64_t signedBits(U value)
{
    std::int64_t result;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
std::int64_t minus(std::int64_t a, U b)
{
    return distance(a, kMin) < b ? kMin : signedBits(U(a) - b);
}
std::int64_t plus(std::int64_t a, U b)
{
    return distance(kMax, a) < b ? kMax : signedBits(U(a) + b);
}
// 内部以中心到六个面的整数距离保存体积；可移动奇数边长/非正方 XZ 的已注册 AABB。
struct SweepBody
{
    U x_low  = 0; ///< 中心到 X 下界距离，毫米。
    U x_high = 0; ///< 中心到 X 上界距离，毫米。
    U y_low  = 0; ///< 中心到 Y 下界距离，毫米。
    U y_high = 0; ///< 中心到 Y 上界距离，毫米。
    U z_low  = 0; ///< 中心到 Z 下界距离，毫米。
    U z_high = 0; ///< 中心到 Z 上界距离，毫米。
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
        const U qa = a.numerator / a.denominator, qb = b.numerator / b.denominator;
        if (qa != qb)
        {
            return qa < qb ? -sign : sign;
        }
        const U ra = a.numerator % a.denominator, rb = b.numerator % b.denominator;
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
U fractionOf(U value, AirFraction t)
{
    if (value <= UINT32_MAX && t.numerator <= UINT32_MAX)
    {
        return value * t.numerator / t.denominator;
    }
    U q = 0, r = 0;
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
    const U step = fractionOf(a < b ? distance(b, a) : distance(a, b), t);
    return a < b ? a + static_cast<std::int64_t>(step) : a - static_cast<std::int64_t>(step);
}
std::pair<U, U> square(U a)
{
    const U lo = std::uint32_t(a), hi = a >> 32, cross = lo * hi;
    const U base = lo * lo, shifted = cross << 33, result = base + shifted;
    return {hi * hi + (cross >> 31) + (result < base), result};
}
bool axis(std::int64_t a, std::int64_t b, std::int64_t lo, std::int64_t hi, AirFraction &entry,
          AirFraction &exit)
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
        const U den = distance(b, a);
        if (a < lo)
            near = {distance(lo, a), den};
        if (b > hi)
            far = {distance(hi, a), den};
    }
    else
    {
        const U den = distance(a, b);
        if (a > hi)
            near = {distance(a, hi), den};
        if (b < lo)
            far = {distance(a, lo), den};
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
    return axis(a.x_mm, b.x_mm, minus(box.min.x_mm, size.x_high), plus(box.max.x_mm, size.x_low), t,
                exit) &&
           axis(a.y_mm, b.y_mm, minus(box.min.y_mm, size.y_high), plus(box.max.y_mm, size.y_low), t,
                exit) &&
           axis(a.z_mm, b.z_mm, minus(box.min.z_mm, size.z_high), plus(box.max.z_mm, size.z_low), t,
                exit);
}
template <typename T> NavResult<T> fail(NavError e, const char *s)
{
    return NavResult<T>::Failure(e, s);
}
bool take(std::uint32_t &n, std::uint32_t limit)
{
    if (n == limit)
        return false;
    ++n;
    return true;
}
bool validBody(WorldPosition a, SweepBody body)
{
    return distance(a.y_mm, kMin) >= body.y_low && distance(kMax, a.y_mm) >= body.y_high;
}
bool same(WorldPosition a, WorldPosition b)
{
    return a.x_mm == b.x_mm && a.y_mm == b.y_mm && a.z_mm == b.z_mm;
}
WorldPosition center(const GridMap &map, std::uint32_t cell, std::int64_t y)
{
    const auto &m = map.metadata();
    return {m.origin_x_mm + std::int64_t(cell % m.width) * m.cell_size_mm + m.cell_size_mm / 2, y,
            m.origin_z_mm + std::int64_t(cell / m.width) * m.cell_size_mm + m.cell_size_mm / 2};
}
NavResult<AirSweepResult> sweep(NavigationContext &ctx, AirState &s, WorldPosition a,
                                WorldPosition b, SweepBody body, NavigationAgentHandle exclude,
                                AirPolicy policy, std::vector<std::uint32_t> *empty_cache = nullptr)
{
    const auto &map   = *ctx.map();
    const auto &m     = map.metadata();
    const auto  start = map.WorldToGrid(a), end = map.WorldToGrid(b);
    if (!start.ok() || !end.ok() || !validBody(a, body) || !validBody(b, body))
    {
        return fail<AirSweepResult>(NavError::kOutOfBounds,
                                    "air endpoints/body outside coordinate range");
    }

    const std::int64_t right = m.origin_x_mm + std::int64_t(m.width) * m.cell_size_mm;
    const std::int64_t top   = m.origin_z_mm + std::int64_t(m.height) * m.cell_size_mm;
    if (minus(std::min(a.x_mm, b.x_mm), body.x_low) < m.origin_x_mm ||
        plus(std::max(a.x_mm, b.x_mm), body.x_high) >= right ||
        minus(std::min(a.z_mm, b.z_mm), body.z_low) < m.origin_z_mm ||
        plus(std::max(a.z_mm, b.z_mm), body.z_high) >= top)
    {
        return fail<AirSweepResult>(NavError::kOutOfBounds, "air volume crosses map boundary");
    }

    AirSweepResult best;
    auto           hit = [&](const AirBox &box, AirHitKind kind, U handle, std::uint32_t cell)
    {
        AirFraction t;
        if (intersect(a, b, body, box, t) &&
            (best.kind == AirHitKind::kClear || compare(t, best.time) < 0 ||
             (compare(t, best.time) == 0 &&
              std::make_tuple(kind, kind == AirHitKind::kStatic ? U(cell) : handle) <
                  std::make_tuple(best.kind, best.kind == AirHitKind::kStatic
                                                 ? U(best.cell_index)
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
        const auto low_x      = minus(minus(std::min(ax, bx), body.x_low), 1);
        const auto high_x     = plus(plus(std::max(ax, bx), body.x_high), 1);
        const auto low_z      = minus(minus(std::min(az, bz), body.z_low), 1);
        const auto high_z     = plus(plus(std::max(az, bz), body.z_high), 1);

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
                    if (!take(s.stats.tests, s.limits.tests))
                        return false;
                    if (cached != empty_cache->end() && *cached == cell)
                        continue;
                }

                if (!take(s.stats.buckets, s.limits.buckets))
                    return false;

                bool       height_empty = !policy.check_terrain;
                const auto low_y = minus(a.y_mm, body.y_low), high_y = plus(a.y_mm, body.y_high);
                AirBox     column{{m.origin_x_mm + xx * m.cell_size_mm, kMin,
                                   m.origin_z_mm + zz * m.cell_size_mm},
                                  {m.origin_x_mm + (xx + 1) * m.cell_size_mm, kMax,
                                   m.origin_z_mm + (zz + 1) * m.cell_size_mm}};
                if (policy.check_terrain)
                {
                    if (!take(s.stats.tests, s.limits.tests))
                        return false;
                    auto terrain = column;
                    terrain.max.y_mm =
                        std::int64_t(map.TryCell({std::int32_t(xx), std::int32_t(zz)})->height_mm) +
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
                        if (!take(s.stats.tests, s.limits.tests))
                            return false;
                        const auto &interval = asset.intervals[record->offset + i];
                        if (interval.min_y_mm <= high_y && interval.max_y_mm >= low_y)
                            height_empty = false;
                        column.min.y_mm = interval.min_y_mm;
                        column.max.y_mm = interval.max_y_mm;
                        hit(column, AirHitKind::kStatic, 0, cell);
                    }
                }

                for (auto it = s.links.lower_bound({cell, 0});
                     it != s.links.end() && it->first.first == cell; ++it)
                {
                    if (!take(s.stats.tests, s.limits.tests))
                        return false;
                    const auto handle = it->first.second;
                    if (handle != exclude.value)
                    {
                        const auto &box = s.objects.at(handle);
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
        return NavResult<AirSweepResult>::Success(best);
    }
    std::int64_t x = start.value.x, z = start.value.z;
    const int    sx = (b.x_mm > a.x_mm) - (b.x_mm < a.x_mm),
              sz    = (b.z_mm > a.z_mm) - (b.z_mm < a.z_mm);
    const U     nx  = sx ? (sx > 0 ? distance(b.x_mm, a.x_mm) : distance(a.x_mm, b.x_mm)) : 1;
    const U     nz  = sz ? (sz > 0 ? distance(b.z_mm, a.z_mm) : distance(a.z_mm, b.z_mm)) : 1;
    AirFraction entry{0, 1};
    for (;;)
    {
        AirFraction tx{2, 1}, tz{2, 1};
        if (sx && x != end.value.x)
        {
            const auto boundary = m.origin_x_mm + (x + (sx > 0)) * m.cell_size_mm;
            tx = {sx > 0 ? distance(boundary, a.x_mm) : distance(a.x_mm, boundary), nx};
        }
        if (sz && z != end.value.z)
        {
            const auto boundary = m.origin_z_mm + (z + (sz > 0)) * m.cell_size_mm;
            tz = {sz > 0 ? distance(boundary, a.z_mm) : distance(a.z_mm, boundary), nz};
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
    return NavResult<AirSweepResult>::Success(best);
}
NavResult<bool> set(NavigationContext &ctx, AirState &s, NavigationAgentHandle h, const AirBox &box)
{
    const auto &m = ctx.map()->metadata();
    if (!h.valid() || box.min.x_mm > box.max.x_mm || box.min.y_mm > box.max.y_mm ||
        box.min.z_mm > box.max.z_mm)
    {
        return fail<bool>(NavError::kInvalidArgument, "air AABB/handle invalid");
    }

    const auto a = ctx.map()->WorldToGrid(box.min), b = ctx.map()->WorldToGrid(box.max);
    if (!a.ok() || !b.ok())
        return fail<bool>(NavError::kOutOfBounds, "air AABB outside map");

    // 闭下边界位于格线时必须同时关联左/下格；地图边界外不建立桶。
    auto x0 = a.value.x, z0 = a.value.z;
    if ((box.min.x_mm - m.origin_x_mm) % m.cell_size_mm == 0 && x0 > 0)
        --x0;
    if ((box.min.z_mm - m.origin_z_mm) % m.cell_size_mm == 0 && z0 > 0)
        --z0;
    const U count = U(b.value.x - x0 + 1) * U(b.value.z - z0 + 1);
    auto    old   = s.objects.find(h.value);

    if (count > s.limits.object_links ||
        (old == s.objects.end() && s.objects.size() == s.limits.objects))
    {
        return fail<bool>(NavError::kCapacityExceeded, "air dynamic object/link capacity");
    }

    // 旧关联数只遍历旧盒覆盖的有界区域；不扫描 Context 的全部关联。
    std::vector<std::pair<std::uint32_t, U>> previous;
    previous.reserve(s.limits.object_links);
    if (old != s.objects.end())
    {
        auto oa = ctx.map()->WorldToGrid(old->second.min).value,
             ob = ctx.map()->WorldToGrid(old->second.max).value;
        if ((old->second.min.x_mm - m.origin_x_mm) % m.cell_size_mm == 0 && oa.x > 0)
            --oa.x;
        if ((old->second.min.z_mm - m.origin_z_mm) % m.cell_size_mm == 0 && oa.z > 0)
            --oa.z;
        for (int z = oa.z; z <= ob.z; ++z)
        {
            for (int x = oa.x; x <= ob.x; ++x)
                previous.emplace_back(std::uint32_t(U(z) * m.width + x), h.value);
        }
    }
    if (s.links.size() - previous.size() + count > s.limits.links)
    {
        return fail<bool>(NavError::kCapacityExceeded, "air total link capacity");
    }

    // 所有可能失败的分配先完成；C++17 相同 allocator 的 map merge 转移节点不分配。
    std::map<std::pair<std::uint32_t, U>, bool> prepared;
    for (int z = z0; z <= b.value.z; ++z)
    {
        for (int x = x0; x <= b.value.x; ++x)
            prepared.emplace(std::make_pair(std::uint32_t(U(z) * m.width + x), h.value), true);
    }

    std::map<U, AirBox> object;
    if (old == s.objects.end())
        object.emplace(h.value, box);
    for (auto key : previous)
        s.links.erase(key);
    s.links.merge(prepared);
    if (old != s.objects.end())
        old->second = box;
    else
        s.objects.merge(object);
    return NavResult<bool>::Success(true);
}
NavResult<WorldPosition> move(NavigationContext &ctx, AirState &s, NavigationAgentHandle h,
                              WorldPosition target, AirPolicy policy)
{
    const auto it = s.objects.find(h.value);
    if (it == s.objects.end())
        return fail<WorldPosition>(NavError::kInvalidArgument, "air handle not registered");

    const auto &box = it->second;
    const auto dx = distance(box.max.x_mm, box.min.x_mm), dy = distance(box.max.y_mm, box.min.y_mm),
               dz = distance(box.max.z_mm, box.min.z_mm);
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
    WorldPosition from{plus(box.min.x_mm, body.x_low), plus(box.min.y_mm, body.y_low),
                       plus(box.min.z_mm, body.z_low)};
    const auto    tested = sweep(ctx, s, from, target, body, h, policy);
    if (!tested.ok())
        return fail<WorldPosition>(tested.error, tested.detail.c_str());
    if (tested.value.kind != AirHitKind::kClear)
        return fail<WorldPosition>(NavError::kBlocked, "air move blocked");
    AirBox     moved{{minus(target.x_mm, body.x_low), minus(target.y_mm, body.y_low),
                      minus(target.z_mm, body.z_low)},
                     {plus(target.x_mm, body.x_high), plus(target.y_mm, body.y_high),
                      plus(target.z_mm, body.z_high)}};
    const auto placed = set(ctx, s, h, moved);
    if (!placed.ok())
        return fail<WorldPosition>(placed.error, placed.detail.c_str());
    return NavResult<WorldPosition>::Success(target);
}

} // namespace
std::uint64_t airDistance(WorldPosition a, WorldPosition b)
{
    const U         dx = a.x_mm < b.x_mm ? distance(b.x_mm, a.x_mm) : distance(a.x_mm, b.x_mm);
    const U         dz = a.z_mm < b.z_mm ? distance(b.z_mm, a.z_mm) : distance(a.z_mm, b.z_mm);
    // 两个 i32 世界坐标之差至多 UINT32_MAX；平方和使用显式双字避免 uint64 溢出。
    auto            x = square(dx), z = square(dz);
    std::pair<U, U> total{x.first + z.first + (x.second + z.second < x.second),
                          x.second + z.second};
    U               lo = 0, hi = U(1) << 33;
    while (lo + 1 < hi)
    {
        U mid = (lo + hi) / 2;
        if (square(mid) <= total)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}
NavResult<bool> setAirObstacle(NavigationContext &ctx, NavigationAgentHandle h, const AirBox &box)
{
    try
    {
        return set(ctx, ctx.airState(), h, box);
    }
    catch (const std::bad_alloc &)
    {
        return fail<bool>(NavError::kCapacityExceeded, "air allocation failed");
    }
}
NavResult<bool> removeAirObstacle(NavigationContext &ctx, NavigationAgentHandle h)
{
    try
    {
        auto &s  = ctx.airState();
        auto  it = s.objects.find(h.value);
        if (!h.valid())
            return fail<bool>(NavError::kInvalidArgument, "air handle is zero");
        if (it != s.objects.end())
        {
            // 仅遍历本对象不超过 256 个格关联；与 set 相同的闭边界规则。
            const auto &m = ctx.map()->metadata();
            auto        a = ctx.map()->WorldToGrid(it->second.min).value,
                 b        = ctx.map()->WorldToGrid(it->second.max).value;
            if ((it->second.min.x_mm - m.origin_x_mm) % m.cell_size_mm == 0 && a.x > 0)
                --a.x;
            if ((it->second.min.z_mm - m.origin_z_mm) % m.cell_size_mm == 0 && a.z > 0)
                --a.z;
            for (int z = a.z; z <= b.z; ++z)
            {
                for (int x = a.x; x <= b.x; ++x)
                    s.links.erase({std::uint32_t(U(z) * m.width + x), h.value});
            }
            s.objects.erase(it);
        }
        return NavResult<bool>::Success(true);
    }
    catch (const std::bad_alloc &)
    {
        return fail<bool>(NavError::kCapacityExceeded, "air allocation failed");
    }
}
NavResult<AirSweepResult> sweepAir(NavigationContext &ctx, WorldPosition a, WorldPosition b,
                                   AirBody body, NavigationAgentHandle exclude, AirPolicy policy)
{
    try
    {
        auto &s = ctx.airState();
        s.stats = {};
        return sweep(ctx, s, a, b, body, exclude, policy);
    }
    catch (const std::bad_alloc &)
    {
        return fail<AirSweepResult>(NavError::kCapacityExceeded, "air allocation failed");
    }
}
NavResult<WorldPosition> moveAir(NavigationContext &ctx, NavigationAgentHandle h, WorldPosition to,
                                 AirPolicy policy)
{
    try
    {
        auto &s = ctx.airState();
        s.stats = {};
        return move(ctx, s, h, to, policy);
    }
    catch (const std::bad_alloc &)
    {
        return fail<WorldPosition>(NavError::kCapacityExceeded, "air allocation failed");
    }
}
NavResult<Path> findAirPath(NavigationContext &ctx, WorldPosition start, WorldPosition target,
                            std::int64_t y, AirBody body, NavigationAgentHandle exclude,
                            AirPolicy policy, std::uint32_t range)
{
    try
    {
        auto &s = ctx.airState();
        s.stats = {};
        s.empty_cells.clear();
        s.empty_cells.reserve(s.limits.buckets);
        const auto &map = *ctx.map();
        const auto &m   = map.metadata();
        start.y_mm      = y;
        target.y_mm     = y;
        const auto from = map.WorldToGrid(start), goal = map.WorldToGrid(target);
        if (!from.ok() || !goal.ok())
            return fail<Path>(NavError::kOutOfBounds, "air path endpoints outside map");
        auto check = sweep(ctx, s, start, start, body, exclude, policy, &s.empty_cells);
        if (!check.ok())
            return fail<Path>(check.error, check.detail.c_str());
        if (check.value.kind != AirHitKind::kClear)
            return fail<Path>(NavError::kStartNotNavigable, "air start blocked");
        if (!range)
        {
            check = sweep(ctx, s, target, target, body, exclude, policy, &s.empty_cells);
            if (!check.ok())
                return fail<Path>(check.error, check.detail.c_str());
            if (check.value.kind != AirHitKind::kClear)
                return fail<Path>(NavError::kEndNotNavigable, "air end blocked");
        }
        auto make = [&](std::vector<WorldPosition> points) -> NavResult<Path>
        {
            if (points.size() > s.limits.path_points)
                return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
            // 构造/长度整理的有界工作也由同一预算预留，平滑耗尽只保留已验证路线。
            const auto construct_work = static_cast<std::uint32_t>(points.size() * 2);
            if (construct_work > s.limits.tests - s.stats.tests)
                return fail<Path>(NavError::kQueryBudgetExceeded,
                                  "air path construction budget exhausted");
            s.stats.tests += construct_work;
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
                    const auto shortcut = sweep(ctx, s, points[write - 1], points[candidate], body,
                                                exclude, policy, &s.empty_cells);
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
            U length = 0;
            for (std::size_t i = 1; i < points.size(); ++i)
                length += airDistance(points[i - 1], points[i]);
            Path path(std::move(points), length);
            path.markAir(ctx.map(), y, body.radius_mm, body.half_height_mm);
            return NavResult<Path>::Success(std::move(path));
        };
        auto within_range = [&](WorldPosition point)
        {
            const U dx = point.x_mm >= target.x_mm ? distance(point.x_mm, target.x_mm)
                                                   : distance(target.x_mm, point.x_mm);
            const U dz = point.z_mm >= target.z_mm ? distance(point.z_mm, target.z_mm)
                                                   : distance(target.z_mm, point.z_mm);
            // 圆范围判定用精确平方比较；不能把路径长度的 sqrt 向下取整误用于圆边界。
            if (dx > range || dz > range)
                return false;
            const U square = U(range) * range;
            return dz * dz <= square - dx * dx;
        };
        if (range && within_range(start))
            return make({start});
        check = sweep(ctx, s, start, target, body, exclude, policy, &s.empty_cells);
        // 范围查询只要求最终体积在地图内；目标中心可以靠边，不能由目标盒越界拒绝整个范围。
        const bool range_target_outside = range && check.error == NavError::kOutOfBounds;
        if (!check.ok() && !range_target_outside)
            return fail<Path>(check.error, check.detail.c_str());
        if (check.ok() && check.value.kind == AirHitKind::kClear && !same(start, target) &&
            s.limits.path_points < 2)
            return fail<Path>(NavError::kCapacityExceeded, "air direct path point capacity");
        if (check.ok() && check.value.kind == AirHitKind::kClear)
            return make(same(start, target) ? std::vector<WorldPosition>{start}
                                            : std::vector<WorldPosition>{start, target});

        // 查询 scratch 首次 reserve，随后保持有界容量；不为地图所有格分配空中数组。
        s.nodes.clear();
        s.index.clear();
        s.heap.clear();
        s.nodes.reserve(s.limits.nodes);
        s.index.reserve(s.limits.nodes);
        s.heap.reserve(s.limits.nodes);
        const auto destination = std::uint32_t(U(goal.value.z) * m.width + goal.value.x);
        const auto origin      = std::uint32_t(U(from.value.z) * m.width + from.value.x);
        auto       heuristic   = [&](std::uint32_t cell) -> U
        {
            if (range)
                return 0; // 范围终点用 Dijkstra，避免不一致的离散启发式。
            const U dx = cell % m.width > destination % m.width
                             ? cell % m.width - destination % m.width
                             : destination % m.width - cell % m.width;
            const U dz = cell / m.width > destination / m.width
                             ? cell / m.width - destination / m.width
                             : destination / m.width - cell / m.width;
            // 整数 1000/1414 直/斜成本；固定邻居顺序与格号平局使结果可复现。
            return std::min(dx, dz) * 1414 + (std::max(dx, dz) - std::min(dx, dz)) * 1000;
        };
        auto less = [&](unsigned a, unsigned b)
        {
            const auto &aa = s.nodes[a], &bb = s.nodes[b];
            // 同 f 时优先靠近目标的较大 g；不改变最短路正确性，避免开放区等价路线铺满。
            if (aa.f != bb.f)
                return aa.f < bb.f;
            if (aa.g != bb.g)
                return aa.g > bb.g;
            return aa.cell < bb.cell;
        };
        auto swap_heap = [&](std::size_t a, std::size_t b)
        {
            std::swap(s.heap[a], s.heap[b]);
            s.nodes[s.heap[a]].heap = std::int32_t(a);
            s.nodes[s.heap[b]].heap = std::int32_t(b);
        };
        auto up = [&](std::size_t i)
        {
            while (i && less(s.heap[i], s.heap[(i - 1) / 2]))
            {
                swap_heap(i, (i - 1) / 2);
                i = (i - 1) / 2;
            }
        };
        auto offer = [&](std::uint32_t cell, U g, std::int32_t parent) -> bool
        {
            auto it =
                std::lower_bound(s.index.begin(), s.index.end(), cell,
                                 [](const auto &v, std::uint32_t id) { return v.first < id; });
            unsigned id;
            if (it == s.index.end() || it->first != cell)
            {
                if (s.nodes.size() == s.limits.nodes)
                    return false;
                id = static_cast<unsigned>(s.nodes.size());
                s.index.insert(it, {cell, id});
                s.nodes.push_back(
                    {cell, g, g + heuristic(cell), parent, std::int32_t(s.heap.size()), false});
                s.heap.push_back(id);
            }
            else
            {
                id = it->second;
                if (s.nodes[id].closed || s.nodes[id].g <= g)
                    return true;
                s.nodes[id].g      = g;
                s.nodes[id].f      = g + heuristic(cell);
                s.nodes[id].parent = parent;
            }
            up(std::size_t(s.nodes[id].heap));
            return true;
        };
        const auto first = center(map, origin, y);
        check            = sweep(ctx, s, start, first, body, exclude, policy, &s.empty_cells);
        if (!check.ok())
            return fail<Path>(check.error, check.detail.c_str());
        if (check.value.kind != AirHitKind::kClear)
            return fail<Path>(NavError::kNoPath, "air start-center connection blocked");
        offer(origin, 0, -1);
        constexpr int dirs[8][2] = {{1, 0}, {0, 1},  {-1, 0},  {0, -1},
                                    {1, 1}, {-1, 1}, {-1, -1}, {1, -1}};
        while (!s.heap.empty())
        {
            if (!take(s.stats.expanded, s.limits.expanded))
                return fail<Path>(NavError::kSearchBudgetExceeded,
                                  "air expansion budget exhausted");
            const auto id = s.heap.front();
            swap_heap(0, s.heap.size() - 1);
            s.heap.pop_back();
            s.nodes[id].heap = -1;
            std::size_t slot = 0;
            for (;;)
            {
                auto left = slot * 2 + 1;
                if (left >= s.heap.size())
                    break;
                if (left + 1 < s.heap.size() && less(s.heap[left + 1], s.heap[left]))
                    ++left;
                if (!less(s.heap[left], s.heap[slot]))
                    break;
                swap_heap(left, slot);
                slot = left;
            }
            s.nodes[id].closed = true;
            const auto current = s.nodes[id];
            const auto point   = center(map, current.cell, y);
            const bool reached = range ? within_range(point) : current.cell == destination;
            if (reached)
            {
                if (!range)
                {
                    check = sweep(ctx, s, point, target, body, exclude, policy, &s.empty_cells);
                    if (!check.ok())
                        return fail<Path>(check.error, check.detail.c_str());
                    if (check.value.kind != AirHitKind::kClear)
                        continue;
                }
                std::vector<WorldPosition> points;
                for (auto node = std::int32_t(id); node >= 0; node = s.nodes[node].parent)
                {
                    if (points.size() == s.limits.path_points)
                        return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
                    points.push_back(center(map, s.nodes[node].cell, y));
                }
                std::reverse(points.begin(), points.end());
                if (!same(start, points.front()))
                {
                    if (points.size() == s.limits.path_points)
                        return fail<Path>(NavError::kCapacityExceeded, "air path point capacity");
                    points.insert(points.begin(), start);
                }
                if (!range && !same(target, points.back()))
                {
                    if (points.size() == s.limits.path_points)
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
                const auto known     = std::lower_bound(s.index.begin(), s.index.end(), cell,
                                                        [](const auto &entry, std::uint32_t candidate)
                                                        { return entry.first < candidate; });
                // 已关闭或已有不更差路线的节点无需重验一条不会参与松弛的边。
                if (known != s.index.end() && known->first == cell &&
                    (s.nodes[known->second].closed || s.nodes[known->second].g <= next_cost))
                    continue;
                check = sweep(ctx, s, point, center(map, cell, y), body, exclude, policy,
                              &s.empty_cells);
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
    catch (const std::bad_alloc &)
    {
        return fail<Path>(NavError::kCapacityExceeded, "air allocation failed");
    }
}
NavResult<PathAdvanceResult> advanceAirPath(NavigationContext &ctx, NavigationAgentHandle h,
                                            const Path &path, PathFollowCursor &cursor,
                                            std::uint32_t stride, AirPolicy policy)
{
    try
    {
        auto &s    = ctx.airState();
        s.stats    = {};
        auto found = s.objects.find(h.value);
        if (!path.isAir() || path.airMap() != ctx.map().get() || !path.count() ||
            found == s.objects.end() || cursor.next_point_index < 1 ||
            cursor.next_point_index > path.count())
        {
            return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                           "air path/context/handle/cursor mismatch");
        }
        const auto &box = found->second;
        AirBody     actual;
        if (distance(box.max.x_mm, box.min.x_mm) != U(path.airRadius()) * 2 ||
            distance(box.max.z_mm, box.min.z_mm) != U(path.airRadius()) * 2 ||
            distance(box.max.y_mm, box.min.y_mm) != U(path.airHalfHeight()) * 2)
        {
            return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                           "air path body changed; replan required");
        }
        actual = {path.airRadius(), path.airHalfHeight()};
        PathAdvanceResult out;
        out.position = {box.min.x_mm + actual.radius_mm, box.min.y_mm + actual.half_height_mm,
                        box.min.z_mm + actual.radius_mm};
        if (out.position.y_mm != path.flightY())
        {
            return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                           "air path height changed; replan required");
        }
        if (cursor.next_point_index == path.count() &&
            !same(out.position, path.WorldPoint(path.count() - 1)))
        {
            return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                           "air object moved away from completed path");
        }
        U left = stride;
        while (cursor.next_point_index < path.count())
        {
            const auto a   = path.WorldPoint(cursor.next_point_index - 1),
                       b   = path.WorldPoint(cursor.next_point_index);
            const U length = airDistance(a, b);
            if (cursor.segment_progress_mm > length)
                return fail<PathAdvanceResult>(NavError::kInvalidArgument,
                                               "air cursor progress invalid");
            const AirFraction   current{cursor.segment_progress_mm, length ? length : 1};
            const WorldPosition expected{interpolate(a.x_mm, b.x_mm, current), a.y_mm,
                                         interpolate(a.z_mm, b.z_mm, current)};
            if (!same(out.position, expected))
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
            const U             amount   = std::min(left, length - cursor.segment_progress_mm);
            const U             progress = cursor.segment_progress_mm + amount;
            const AirFraction   t{progress, length};
            const WorldPosition next{interpolate(a.x_mm, b.x_mm, t), a.y_mm,
                                     interpolate(a.z_mm, b.z_mm, t)};
            const auto          moved = move(ctx, s, h, next, policy);
            if (!moved.ok())
            {
                if (moved.error != NavError::kBlocked)
                    return fail<PathAdvanceResult>(moved.error, moved.detail.c_str());
                out.status = PathAdvanceStatus::kBlocked;
                return NavResult<PathAdvanceResult>::Success(out);
            }
            out.moved    = out.moved || !same(next, out.position);
            out.position = next;
            out.consumed_mm += std::uint32_t(amount);
            left -= amount;
            cursor.segment_progress_mm = progress;
            if (progress == length)
            {
                ++cursor.next_point_index;
                cursor.segment_progress_mm = 0;
            }
        }
        out.status = cursor.next_point_index == path.count() ? PathAdvanceStatus::kReached
                                                             : PathAdvanceStatus::kMoving;
        return NavResult<PathAdvanceResult>::Success(out);
    }
    catch (const std::bad_alloc &)
    {
        return fail<PathAdvanceResult>(NavError::kCapacityExceeded, "air allocation failed");
    }
}

} // namespace flywow_navigation
