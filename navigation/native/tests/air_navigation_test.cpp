// 职责：通过公开 Navigation API 验证空中几何、预算、推进、状态原子性与隔离。
#include "air_navigation.h"
#include "grid_pathfinder.h"
#include "map_registry.h"
#include "navigation_context.h"
#include <atomic>
#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <new>
#include <thread>
// 测试注入一次 C++ 分配失败；不替换生产 allocator，也不降低真实资源门禁。
std::atomic<int> allocation_failure{-1};
void            *operator new(std::size_t size)
{
    int remaining = allocation_failure.load();
    if (remaining >= 0)
    {
        if (remaining == 0)
        {
            allocation_failure = -1;
            throw std::bad_alloc();
        }
        allocation_failure = remaining - 1;
    }
    if (void *memory = std::malloc(size ? size : 1))
        return memory;
    throw std::bad_alloc();
}
void operator delete(void *memory) noexcept
{
    std::free(memory);
}
void operator delete(void *memory, std::size_t) noexcept
{
    std::free(memory);
}
using namespace flywow_navigation;
namespace
{
std::shared_ptr<const GridMap> map(bool building = true)
{
    BMapMetadata         m{17, 2, 12, 12, 500, -1000, -1000, 0};
    std::vector<NavCell> cells(144, NavCell{0, 1, 0, 10});
    AirAsset             air;
    if (building)
    {
        air.present   = true;
        air.cells     = {{5 * 12 + 5, 0, 2}, {6 * 12 + 5, 2, 1}};
        air.intervals = {{0, 10000}, {12000, 13000}, {0, 10000}};
    }
    return std::make_shared<const GridMap>(m, std::move(cells), std::move(air));
}
WorldPosition point(std::int64_t x, std::int64_t y, std::int64_t z)
{
    return {x, y, z};
}
void hashVectors()
{
    auto check = [](const std::string &input, const char *expected)
    {
        auto        h = sha256(reinterpret_cast<const std::uint8_t *>(input.data()), input.size());
        const char *digits = "0123456789abcdef";
        std::string text;
        for (auto b : h)
        {
            text += digits[b >> 4];
            text += digits[b & 15];
        }
        assert(text == expected);
    };
    check("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    check("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    check("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
          "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    check(std::string(1000000, 'a'),
          "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}
std::vector<std::uint8_t> golden(const char *name)
{
    std::ifstream file(std::string(FLYWOW_AIR_GOLDEN_ROOT) + "/" + name + ".txt");
    std::string   hex;
    file >> hex;
    assert(file);
    std::vector<std::uint8_t> bytes;
    for (std::size_t i = 0; i < hex.size(); i += 2)
        bytes.push_back(std::uint8_t(std::stoul(hex.substr(i, 2), nullptr, 16)));
    return bytes;
}
void assets()
{
    auto base = std::filesystem::temp_directory_path() / "flywow_air_golden_native";
    std::filesystem::create_directories(base);
    auto write = [&](const char *name, const std::vector<std::uint8_t> &bytes)
    {
        std::ofstream out(base / name, std::ios::binary);
        out.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    };
    auto bmap = golden("bmap_v1"), air = golden("airnav_v1");
    write("map.bmap", bmap);
    write("map.airnav", air);
    const auto path = (base / "map.bmap").string(), component = (base / "map.airnav").string();
    auto      &registry = MapRegistry::Instance();
    auto       old      = registry.Load(path, component);
    assert(old.ok() && old.value->airAsset().present);
    NavigationContext ctx(old.value);
    auto              replacement = registry.Load(path);
    assert(replacement.ok() && !replacement.value->airAsset().present);
    assert(ctx.map()->airAsset().present && ctx.map() != replacement.value);
    for (std::size_t at : {std::size_t(4), std::size_t(8), std::size_t(36), std::size_t(40),
                           std::size_t(72), std::size_t(96), std::size_t(108), std::size_t(143)})
    {
        auto corrupt = air;
        corrupt[at] ^= 255;
        write("map.airnav", corrupt);
        assert(!registry.Load(path, component).ok());
        assert(registry.Find(17).value == replacement.value);
    }
    auto truncated = air;
    truncated.pop_back();
    write("map.airnav", truncated);
    assert(!registry.Load(path, component).ok());
    auto trailing = air;
    trailing.push_back(0);
    write("map.airnav", trailing);
    assert(!registry.Load(path, component).ok());
    write("map.airnav", air);
    std::filesystem::resize_file(base / "map.airnav", 32 * 1024 * 1024 + 1);
    assert(!registry.Load(path, component).ok());
    assert(!registry.Load(path, (base / "missing.airnav").string()).ok());
    std::filesystem::remove_all(base);
}
void geometry()
{
    NavigationContext ctx(map());
    assert(ctx.airMemoryBytes() == 0);
    AirBody body{50, 200};
    auto    a = point(250, 10100, 1750), b = point(2750, 10100, 1750);
    auto    sweep = sweepAir(ctx, a, b, body);
    assert(sweep.ok() && sweep.value.kind == AirHitKind::kStatic);
    a.y_mm = b.y_mm = 10200;
    assert(sweepAir(ctx, a, b, body).value.kind == AirHitKind::kStatic);
    a.y_mm = b.y_mm = 10201;
    assert(sweepAir(ctx, a, b, body).value.kind == AirHitKind::kClear);
    a.y_mm = b.y_mm = 11000;
    assert(sweepAir(ctx, a, b, body).value.kind == AirHitKind::kClear);
    a.y_mm = b.y_mm = 12100;
    assert(sweepAir(ctx, a, b, body).value.kind == AirHitKind::kStatic);
    a.y_mm = b.y_mm = 1000;
    const auto path = findAirPath(ctx, a, b, 1000, body);
    assert(path.ok() && path.value.count() > 2);
    const auto again = findAirPath(ctx, a, b, 1000, body);
    assert(again.ok() && again.value.count() == path.value.count());
    for (std::size_t i = 0; i < path.value.count(); ++i)
    {
        assert(path.value.WorldPoint(i).x_mm == again.value.WorldPoint(i).x_mm);
        if (i)
            assert(sweepAir(ctx, path.value.WorldPoint(i - 1), path.value.WorldPoint(i), body)
                       .value.kind == AirHitKind::kClear);
    }
    // 改变高度的完整扫掠必须拦住中间区间，不能只检查端点。
    assert(sweepAir(ctx, point(1750, -1000, 1750), point(1750, 11000, 1750), body).value.kind ==
           AirHitKind::kStatic);
    auto terrain =
        sweepAir(ctx, point(-750, 200, -750), point(-250, 200, -750), body, {}, AirPolicy{true, 0});
    assert(terrain.ok() && terrain.value.kind == AirHitKind::kStatic);
    assert(
        sweepAir(ctx, point(-750, 201, -750), point(-250, 201, -750), body, {}, AirPolicy{true, 0})
            .value.kind == AirHitKind::kClear);
    auto extreme = sweepAir(ctx, point(-750, INT64_MIN + 201, -750),
                            point(-750, INT64_MAX - 201, -750), body, {}, AirPolicy{true, 0});
    assert(extreme.ok() && extreme.value.kind == AirHitKind::kStatic);
}
void dynamicAndAdvance()
{
    NavigationContext ctx(map(false)), other(map(false));
    AirBody           body{50, 100};
    auto              start = point(-750, 1000, -750), end = point(3250, 1000, -750);
    assert(setAirObstacle(ctx, {1}, {{-800, 900, -800}, {-700, 1100, -700}}).ok());
    assert(setAirObstacle(ctx, {2}, {{999, 900, -800}, {1001, 1100, -700}}).ok());
    auto hit = sweepAir(ctx, start, end, body, {1});
    assert(hit.ok() && hit.value.kind == AirHitKind::kDynamic && hit.value.handle.value == 2);
    assert(sweepAir(other, start, end, body).value.kind == AirHitKind::kClear);
    const auto old = ctx.airState().objects.at(1);
    assert(moveAir(ctx, {1}, end).error == NavError::kBlocked);
    assert(ctx.airState().objects.at(1).min.x_mm == old.min.x_mm);
    assert(setAirObstacle(ctx, {2}, {{999, 2900, -800}, {1001, 3100, -700}}).ok());
    assert(sweepAir(ctx, start, end, body, {1}).value.kind == AirHitKind::kClear);
    auto path = findAirPath(ctx, start, end, 1000, body, {1});
    assert(path.ok());
    PathFollowCursor cursor;
    auto             advanced = advanceAirPath(ctx, {1}, path.value, cursor, 701);
    assert(advanced.ok() && advanced.value.consumed_mm == 701 &&
           advanced.value.position.x_mm == -49);
    assert(setAirObstacle(ctx, {2}, {{999, 900, -800}, {1001, 1100, -700}}).ok());
    advanced = advanceAirPath(ctx, {1}, path.value, cursor, 2000);
    assert(advanced.ok() && advanced.value.status == PathAdvanceStatus::kBlocked &&
           advanced.value.position.x_mm == -49);
    assert(removeAirObstacle(ctx, {2}).ok() && removeAirObstacle(ctx, {2}).ok());
    advanced = advanceAirPath(ctx, {1}, path.value, cursor, 5000);
    assert(advanced.ok() && advanced.value.status == PathAdvanceStatus::kReached);
    assert(advanced.value.position.x_mm == end.x_mm);
    assert(moveAir(ctx, {1}, point(3250, 2000, -750)).ok());
    assert(advanceAirPath(ctx, {1}, path.value, cursor, 10).error == NavError::kInvalidArgument);
    NavigationProfile profile = MakeDefaultNavigationProfile(1);
    assert(
        GridPathfinder::AdvancePath(ctx, {{1}, &profile}, path.value, cursor, end, 10, {}).error ==
        NavError::kInvalidArgument);
    Path             ground({start, end}, 4000);
    PathFollowCursor gc;
    assert(advanceAirPath(ctx, {1}, ground, gc, 10).error == NavError::kInvalidArgument);
    // 两个同时接触的动态对象按 handle，而非插入顺序确定首命中。
    assert(setAirObstacle(ctx, {9}, {{1000, 900, 0}, {1000, 1100, 0}}).ok());
    assert(setAirObstacle(ctx, {3}, {{1000, 900, 0}, {1000, 1100, 0}}).ok());
    auto tie = sweepAir(ctx, point(0, 1000, 0), point(2000, 1000, 0), {0, 0});
    assert(tie.ok() && tie.value.handle.value == 3);
}
void resourceBoundaries()
{
    NavigationContext ctx(map(false));
    assert(setAirObstacle(ctx, {1}, {{1, 100, 1}, {2, 201, 4}}).ok());
    // 非正方、奇数尺寸保形移动；中点向下，不能把任意障碍暗中改成正方盒。
    assert(moveAir(ctx, {1}, {1000, 1000, 1000}).ok());
    const auto box = ctx.airState().objects.at(1);
    assert(box.max.x_mm - box.min.x_mm == 1 && box.max.z_mm - box.min.z_mm == 3 &&
           box.max.y_mm - box.min.y_mm == 101);
    assert(box.min.y_mm == 950 && box.max.y_mm == 1051);
    const auto count = ctx.airState().links.size();
    for (int k = 0; k < 25; ++k)
    {
        allocation_failure = k;
        const auto changed = setAirObstacle(ctx, {1}, {{100, 0, 100}, {1200, 10, 1200}});
        allocation_failure = -1;
        if (!changed.ok())
        {
            assert(changed.error == NavError::kCapacityExceeded);
            assert(ctx.airState().objects.at(1).min.x_mm == box.min.x_mm);
            assert(ctx.airState().links.size() == count);
        }
        else
        {
            assert(setAirObstacle(ctx, {1}, box).ok());
        }
    }
    NavigationContext objects(map(false));
    for (unsigned i = 1; i <= 4096; ++i)
        assert(setAirObstacle(objects, {i}, {{1, 0, 1}, {2, 10, 2}}).ok());
    assert(setAirObstacle(objects, {4097}, {{1, 0, 1}, {2, 10, 2}}).error ==
           NavError::kCapacityExceeded);
    BMapMetadata m{1, 1, 128, 128, 500, 0, 0, 0};
    auto         large =
        std::make_shared<const GridMap>(m, std::vector<NavCell>(128 * 128, NavCell{0, 1, 0, 10}));
    NavigationContext links(large);
    for (unsigned i = 1; i <= 1024; ++i)
        assert(setAirObstacle(links, {i}, {{1, 0, 1}, {7501, 10, 7501}}).ok());
    assert(links.airState().links.size() == 262144);
    assert(setAirObstacle(links, {1025}, {{1, 0, 1}, {2, 10, 2}}).error ==
           NavError::kCapacityExceeded);
    assert(setAirObstacle(links, {1}, {{1, 0, 1}, {8001, 10, 7501}}).error ==
           NavError::kCapacityExceeded);
    assert(links.airState().links.size() == 262144);
    assert(removeAirObstacle(links, {1}).ok());
    assert(setAirObstacle(links, {1025}, {{1, 0, 1}, {2, 10, 2}}).ok());
    for (bool nodes : {false, true})
    {
        NavigationContext small(map());
        AirLimits         l;
        if (nodes)
            l.nodes = 1;
        else
            l.expanded = 1;
        assert(small.setAirLimits(l).ok());
        assert(findAirPath(small, {250, 1000, 1750}, {2750, 1000, 1750}, 1000, {50, 200}).error ==
               NavError::kSearchBudgetExceeded);
    }
    NavigationContext points(map(false));
    AirLimits         l;
    l.path_points = 1;
    assert(points.setAirLimits(l).ok());
    assert(findAirPath(points, {250, 1000, 250}, {1250, 1000, 250}, 1000, {}).error ==
           NavError::kCapacityExceeded);
    // 多段推进后段碰撞保留第一段合法提交，而单次 move 仍全成或全不成。
    NavigationContext partial(map(false));
    assert(setAirObstacle(partial, {1}, {{200, 900, 200}, {300, 1100, 300}}).ok());
    assert(setAirObstacle(partial, {2}, {{1200, 900, 700}, {1300, 1100, 800}}).ok());
    Path path({{250, 1000, 250}, {750, 1000, 250}, {1250, 1000, 750}}, 1207);
    path.markAir(partial.map(), 1000, 50, 100);
    PathFollowCursor cursor;
    auto             result = advanceAirPath(partial, {1}, path, cursor, 2000);
    assert(result.ok() && result.value.status == PathAdvanceStatus::kBlocked);
    assert(result.value.position.x_mm == 750 && result.value.position.z_mm == 250 &&
           result.value.consumed_mm == 500);
    NavigationContext budget_partial(map(false));
    AirLimits         budget_limits;
    budget_limits.buckets = 3;
    assert(budget_partial.setAirLimits(budget_limits).ok());
    assert(setAirObstacle(budget_partial, {1}, {{250, 1000, 250}, {250, 1000, 250}}).ok());
    Path budget_path({{250, 1000, 250}, {750, 1000, 250}, {2250, 1000, 250}}, 2000);
    budget_path.markAir(budget_partial.map(), 1000, 0, 0);
    PathFollowCursor budget_cursor;
    auto budget_result = advanceAirPath(budget_partial, {1}, budget_path, budget_cursor, 2000);
    assert(budget_result.error == NavError::kQueryBudgetExceeded);
    assert(budget_partial.airState().objects.at(1).min.x_mm == 750);
    assert(budget_cursor.next_point_index == 2 && budget_cursor.segment_progress_mm == 0);
    assert(budget_partial.airState().stats.buckets == 3);
}
// 独立 oracle 用小范围整数交叉乘积；全量扫描仅在测试，避免复用生产 DDA/slab。
struct OracleFraction
{
    std::int64_t numerator   = 0; ///< 测试坐标限制下可安全交叉乘的有符号分子。
    std::int64_t denominator = 1; ///< 正分母；小坐标范围保证乘法不溢出。
};
int oracleCompare(OracleFraction a, OracleFraction b)
{
    const auto difference = a.numerator * b.denominator - b.numerator * a.denominator;
    return (difference > 0) - (difference < 0);
}
bool oracleIntersect(WorldPosition a, WorldPosition b, AirBody body, const AirBox &box,
                     OracleFraction &enter)
{
    enter = {0, 1};
    OracleFraction     exit{1, 1};
    const std::int64_t start[3] = {a.x_mm, a.y_mm, a.z_mm};
    const std::int64_t end[3]   = {b.x_mm, b.y_mm, b.z_mm};
    const std::int64_t low[3]  = {box.min.x_mm - body.radius_mm, box.min.y_mm - body.half_height_mm,
                                  box.min.z_mm - body.radius_mm};
    const std::int64_t high[3] = {box.max.x_mm + body.radius_mm, box.max.y_mm + body.half_height_mm,
                                  box.max.z_mm + body.radius_mm};
    for (unsigned axis = 0; axis < 3; ++axis)
    {
        const auto delta = end[axis] - start[axis];
        if (!delta)
        {
            if (start[axis] < low[axis] || start[axis] > high[axis])
                return false;
            continue;
        }
        OracleFraction first{low[axis] - start[axis], delta};
        OracleFraction last{high[axis] - start[axis], delta};
        if (delta < 0)
        {
            first = {start[axis] - high[axis], -delta};
            last  = {start[axis] - low[axis], -delta};
        }
        if (oracleCompare(first, enter) > 0)
            enter = first;
        if (oracleCompare(last, exit) < 0)
            exit = last;
        if (oracleCompare(enter, exit) > 0)
            return false;
    }
    return true;
}
void denseCandidateBudget()
{
    BMapMetadata         metadata{17, 2, 80, 60, 500, 0, 0, 0};
    std::vector<NavCell> cells(80 * 60, NavCell{0, 1, 0, 10});
    auto                 dense_map = std::make_shared<const GridMap>(metadata, std::move(cells));
    NavigationContext    context(dense_map);
    for (unsigned handle = 1; handle <= 4096; ++handle)
        assert(setAirObstacle(context, {handle}, {{5000, 0, 5000}, {5010, 10, 5010}}).ok());
    // 高度不相交但不能未遍历就返回 clear；大体积跨多桶重复候选真实触达硬 tests 上限。
    const auto result = sweepAir(context, {5250, 5000, 5250}, {11000, 5000, 5250}, {5000, 0});
    assert(result.error == NavError::kQueryBudgetExceeded);
    assert(context.airState().stats.tests == 65536);
    assert(context.airState().objects.size() == 4096);
}
void continuousOracle()
{
    NavigationContext context(map());
    std::uint32_t     random = 0x741093u;
    auto              next   = [&]()
    {
        random = random * 1664525u + 1013904223u;
        return random;
    };
    for (unsigned handle = 1; handle <= 20; ++handle)
    {
        const auto x = std::int64_t(next() % 5000) - 500;
        const auto z = std::int64_t(next() % 5000) - 500;
        const auto y = std::int64_t(next() % 14000) - 1000;
        assert(setAirObstacle(context, {handle}, {{x, y, z}, {x + 1, y + 100, z + 70}}).ok());
    }
    const unsigned radii[] = {0, 50, 250, 500, 1000};
    for (unsigned query = 0; query < 3000; ++query)
    {
        const unsigned radius = radii[query % 5];
        const AirBody  body{radius, query % 301};
        const auto     span  = 6000 - 2 * radius - 2;
        auto           point = [&]() -> WorldPosition
        {
            return {std::int64_t(-999) + radius + next() % span,
                    std::int64_t(next() % 16000) - 1000,
                    std::int64_t(-999) + radius + next() % span};
        };
        auto a = point(), b = point();
        if (query % 7 == 0)
            b.x_mm = a.x_mm;
        if (query % 11 == 0)
            b.z_mm = a.z_mm;
        if (query % 13 == 0)
            b.y_mm = a.y_mm;
        if (query % 17 == 0)
            a.x_mm = b.x_mm = 1500; // 精确格线与垂直段。
        const NavigationAgentHandle excluded{query % 21};
        AirHitKind                  expected = AirHitKind::kClear;
        OracleFraction              time;
        std::uint64_t               identity = 0;
        auto                        test = [&](const AirBox &box, AirHitKind kind, std::uint64_t id)
        {
            OracleFraction hit;
            if (!oracleIntersect(a, b, body, box, hit))
                return;
            const auto comparison = oracleCompare(hit, time);
            if (expected == AirHitKind::kClear || comparison < 0 ||
                (comparison == 0 && std::make_pair(kind, id) < std::make_pair(expected, identity)))
            {
                expected = kind;
                time     = hit;
                identity = id;
            }
        };
        const auto &asset = context.map()->airAsset();
        for (const auto &cell : asset.cells)
        {
            const auto x = -1000 + std::int64_t(cell.cell_index % 12) * 500;
            const auto z = -1000 + std::int64_t(cell.cell_index / 12) * 500;
            for (unsigned i = 0; i < cell.count; ++i)
            {
                const auto &interval = asset.intervals[cell.offset + i];
                test({{x, interval.min_y_mm, z}, {x + 500, interval.max_y_mm, z + 500}},
                     AirHitKind::kStatic, cell.cell_index);
            }
        }
        for (const auto &object : context.airState().objects)
            if (object.first != excluded.value)
                test(object.second, AirHitKind::kDynamic, object.first);
        const auto actual = sweepAir(context, a, b, body, excluded);
        assert(actual.ok() && actual.value.kind == expected);
        if (expected != AirHitKind::kClear)
        {
            const auto actual_identity = expected == AirHitKind::kStatic
                                             ? actual.value.cell_index
                                             : actual.value.handle.value;
            assert(actual_identity == identity);
            assert(oracleCompare({std::int64_t(actual.value.time.numerator),
                                  std::int64_t(actual.value.time.denominator)},
                                 time) == 0);
        }
    }
}
void limits()
{
    NavigationContext ctx(map(false));
    AirLimits         l;
    l.buckets      = 2;
    l.objects      = 1;
    l.object_links = 2;
    l.links        = 2;
    assert(ctx.setAirLimits(l).ok());
    assert(sweepAir(ctx, point(0, 1000, 0), point(1000, 1000, 0), {}).error ==
           NavError::kQueryBudgetExceeded);
    assert(setAirObstacle(ctx, {1}, {{1, 0, 1}, {2, 10, 2}}).ok());
    const auto size = ctx.airState().links.size();
    assert(setAirObstacle(ctx, {1}, {{1, 0, 1}, {1001, 10, 1001}}).error ==
           NavError::kCapacityExceeded);
    assert(ctx.airState().links.size() == size && ctx.airState().objects.at(1).max.x_mm == 2);
    assert(setAirObstacle(ctx, {2}, {{1, 0, 1}, {2, 10, 2}}).error == NavError::kCapacityExceeded);
    assert(!ctx.setAirLimits(l).ok());
    assert(airDistance({INT32_MIN, 0, INT32_MIN}, {INT32_MAX, 0, INT32_MAX}) == 6074000998ull);
    // 空桶证明只属于当次固定高度查询；动态更新、不同高度和排除句柄均重新验证。
    NavigationContext   cache(map(false));
    const WorldPosition start{250, 1000, 250}, target{2250, 1000, 250};
    assert(findAirPath(cache, start, target, 1000, {}).ok());
    assert(setAirObstacle(cache, {9}, {{-999, 900, -999}, {4999, 1100, 4999}}).ok());
    assert(findAirPath(cache, start, target, 1000, {}).error == NavError::kStartNotNavigable);
    assert(findAirPath(cache, start, target, 2000, {}).ok());
    assert(findAirPath(cache, start, target, 1000, {}, {9}).ok());
    assert(removeAirObstacle(cache, {9}).ok());
    assert(findAirPath(cache, start, target, 1000, {}).ok());
}
} // namespace
int main()
{
    hashVectors();
    assets();
    geometry();
    continuousOracle();
    denseCandidateBudget();
    dynamicAndAdvance();
    limits();
    resourceBoundaries();
    const auto shared = map();
    auto       run    = [&]()
    {
        NavigationContext ctx(shared);
        for (int i = 0; i < 100; ++i)
            assert(findAirPath(ctx, {250, 1000, 1750}, {2750, 1000, 1750}, 1000, {50, 200}).ok());
    };
    std::thread a(run), b(run);
    a.join();
    b.join();
    std::cout << "FLYWOW_AIR_NAVIGATION_OK\n";
}
