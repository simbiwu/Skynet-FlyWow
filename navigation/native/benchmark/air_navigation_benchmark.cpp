// 职责：同机固定热查询测量空中成功/失败/密集/预算场景，不声明 Battle Tick SLA。
#include "air_navigation.h"
#include "navigation_context.h"
#include <algorithm>
#include <chrono>
#include <iostream>
#include <map>
using namespace flywow_navigation;
namespace
{
void run(const char *name, unsigned width, unsigned height, unsigned wall, unsigned objects,
         bool budget)
{
    BMapMetadata                    meta{1, 1, width, height, 500, 0, 0, 0};
    std::vector<NavCell>            cells(std::size_t(width) * height, NavCell{0, 1, 0, 10});
    AirAsset                        asset;
    std::map<unsigned, AirInterval> static_cells;
    // 保留首轮全部地图、墙长与请求；真正不可达额外用贯穿整图的墙验证。
    const unsigned                  first = std::string(name) == "unreachable" ? 0 : 1;
    for (unsigned z = first; z < first + wall; ++z)
        static_cells[z * width + width / 2] = {0, 10000};

    for (auto &cell : static_cells)
    {
        asset.cells.push_back({cell.first, unsigned(asset.intervals.size()), 1});
        asset.intervals.push_back(cell.second);
    }
    wall     = unsigned(static_cells.size());
    auto map = std::make_shared<const GridMap>(meta, std::move(cells), std::move(asset));
    NavigationContext ctx(map);

    if (budget)
    {
        AirLimits l;
        l.buckets = 100;
        ctx.setAirLimits(l);
    }

    for (unsigned i = 0; i < objects; ++i)
    {
        // 同格不同高度的密集盒同时保留；查询必须枚举候选，不能依赖“遇到一个就假成功”。
        auto result = setAirObstacle(
            ctx, {i + 1},
            {{2000, 2000 + std::int64_t(i), 2000}, {2010, 2100 + std::int64_t(i), 2010}});
        if (!result.ok())
            throw std::runtime_error("benchmark setup failed");
    }

    const WorldPosition start{750, 1000, 2250}, end{std::int64_t(width) * 500 - 750, 1000, 2250};
    // 初始化与加载不计时；热身后每场景连续 10000 次。
    for (int i = 0; i < 10; ++i)
        findAirPath(ctx, start, end, 1000, {50, 100});

    std::vector<double> times;
    times.reserve(10000);
    std::map<std::string, unsigned> statuses;
    std::uint64_t                   expanded = 0, tests = 0, buckets = 0, length = 0;
    for (int i = 0; i < 10000; ++i)
    {
        const auto begin  = std::chrono::steady_clock::now();
        const auto result = findAirPath(ctx, start, end, 1000, {50, 100});
        const auto finish = std::chrono::steady_clock::now();
        times.push_back(std::chrono::duration<double, std::micro>(finish - begin).count());
        ++statuses[result.ok() ? "OK" : NavErrorName(result.error)];
        const auto &s = ctx.airState().stats;
        expanded += s.expanded;
        tests += s.tests;
        buckets += s.buckets;
        if (result.ok())
            length = result.value.length_mm();
    }

    std::sort(times.begin(), times.end());
    const auto dense =
        map->cell_count() * (sizeof(NavigationContext::NodeScratch) + sizeof(std::int32_t) +
                             sizeof(std::vector<NavigationAgentHandle>));
    std::cout << "AIR_BENCH case=" << name << " grid=" << width << "x" << height
              << " cell_mm=500 queries=10000 threads=1"
              << " static_intervals=" << wall << " dynamic_objects=" << objects
              << " path_length_mm=" << length << " p50_us=" << times[4999]
              << " p95_us=" << times[9499] << " p99_us=" << times[9899]
              << " max_us=" << times.back() << " avg_expanded=" << expanded / 10000.0
              << " avg_buckets=" << buckets / 10000.0 << " avg_tests=" << tests / 10000.0
              << " static_bytes=" << map->memory_bytes() << " ground_context_payload_est=" << dense
              << " air_context_bytes_est=" << ctx.airMemoryBytes();
    for (auto &status : statuses)
        std::cout << " " << status.first << "=" << status.second;
    std::cout << "\n" << std::flush;
    const std::string expected =
        budget ? "QUERY_BUDGET_EXCEEDED" : (std::string(name) == "unreachable" ? "NO_PATH" : "OK");
    if (statuses.size() != 1 || statuses[expected] != 10000)
        throw std::runtime_error(std::string("benchmark expectation failed: ") + name);
}
} // namespace
int main()
{
    run("open", 80, 60, 0, 0, false);
    run("detour", 12, 12, 6, 0, false);
    run("long_detour", 256, 256, 230, 0, false);
    run("wall_gap", 12, 12, 10, 0, false);
    run("unreachable", 12, 12, 12, 0, false);
    run("dense_dynamic", 80, 60, 0, 4096, false);
    run("budget", 512, 512, 0, 0, true);
}
