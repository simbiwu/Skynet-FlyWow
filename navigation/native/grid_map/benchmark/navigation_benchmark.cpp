// 职责：在固定 synthetic Grid/query set 下记录 Grid A* 延迟、QPS、访问节点和 Context 内存条件。
// 边界：Standalone Benchmark；不启动 Skynet/Unity，不作为 correctness test。
// 输入/输出：固定地图尺寸/blocked ratio/query count -> 条件化性能统计。
// 生命周期：每组 case 创建一个 immutable map 和一个独立 NavigationContext。
// 不负责：不宣称跨机器性能，不把 Benchmark 数字写成产品 SLA。
#include "grid_pathfinder.h"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <memory>
#include <utility>
#include <vector>

using namespace flywow_navigation;

namespace
{

// 推进固定 LCG；state 由当前 Benchmark case 独占，返回下一 uint32 样本。
std::uint32_t Next(std::uint32_t &state)
{
    // 固定初始种子给出可复现序列，便于同样输入比较版本；不用于游戏随机裁决。
    state = state * 1664525u + 1013904223u;
    return state;
}

// 创建给定尺寸和阻挡率的可复现 synthetic map；外围 Cell 保持可走，保证随机抽样可终止。
std::shared_ptr<const GridMap> MakeSynthetic(std::uint32_t width, std::uint32_t height,
                                             std::uint32_t blocked_percent, std::uint32_t seed)
{
    BMapMetadata meta;
    meta.map_id       = width * 10000 + height;
    meta.map_version  = 1;
    meta.width        = width;
    meta.height       = height;
    meta.cell_size_mm = 500;

    std::vector<NavCell> cells(static_cast<std::size_t>(width) * height);
    for (std::uint32_t z = 0; z < height; ++z)
    {
        for (std::uint32_t x = 0; x < width; ++x)
        {
            NavCell   &cell      = cells[static_cast<std::size_t>(z) * width + x];
            const bool border    = x == 0 || z == 0 || x + 1 == width || z + 1 == height;
            const bool blocked   = !border && (Next(seed) % 100u) < blocked_percent;
            cell.flags           = blocked ? 0 : kWalkableFlag;
            cell.clearance_cells = blocked ? 0 : 10;
            cell.area_type       = 0;
            cell.height_mm       = 0;
        }
    }
    return std::make_shared<const GridMap>(meta, std::move(cells));
}

// 从 map 中确定性抽取一个可走 Cell Center；外围可走 Cell 保证至少存在候选点。
WorldPosition RandomWalkable(const GridMap &map, std::uint32_t &seed)
{
    for (;;)
    {
        const GridPos grid{
            static_cast<std::int32_t>(Next(seed) % map.metadata().width),
            static_cast<std::int32_t>(Next(seed) % map.metadata().height),
        };
        const NavCell *cell = map.TryCell(grid);
        if (cell != nullptr && cell->IsWalkable())
        {
            const auto world = map.GridToWorldCenter(grid);
            if (world.ok())
                return world.value;
        }
    }
}

// 对耗时副本排序并返回 [0,1] 分位点；values 必须非空。
double Percentile(std::vector<double> values, double p)
{
    // 排序的是副本，不改变原始耗时样本；p95 表示约 95% 样本不高于该值。
    // 这里取离散下标，不做插值，不能把它解释成平均耗时。
    std::sort(values.begin(), values.end());
    const std::size_t index = static_cast<std::size_t>((values.size() - 1) * p);
    return values[index];
}

// 单线程执行一组固定 query set，并输出带完整条件的延迟/访问量统计。
void RunCase(std::uint32_t width, std::uint32_t height)
{
    constexpr std::uint32_t kBlockedPercent = 15;
    constexpr int           kQueries        = 2000;
    auto                    map = MakeSynthetic(width, height, kBlockedPercent, 0x12345678u);
    NavigationContext       context(map);
    NavigationProfile            profile = MakeDefaultNavigationProfile(1);
    profile.radius_mm               = 200;
    profile.max_step_mm             = 500;
    profile.max_slope_permille      = 1000;

    std::uint32_t       seed = 0xabcdef01u;
    std::vector<double> microseconds;
    microseconds.reserve(kQueries);
    std::uint64_t visited_sum     = 0;
    std::uint64_t path_points_sum = 0;
    int           success         = 0;
    int           no_path         = 0;

    const auto all_begin = std::chrono::steady_clock::now();
    for (int i = 0; i < kQueries; ++i)
    {
        const WorldPosition start  = RandomWalkable(*map, seed);
        const WorldPosition end    = RandomWalkable(*map, seed);
        // 单次延迟只计 FindPathStatic（含平滑与结果构造），不计端点抽样。
        const auto          begin  = std::chrono::steady_clock::now();
        const auto          result = GridPathfinder::FindPathStatic(context, profile, start, end);
        const auto          finish = std::chrono::steady_clock::now();
        microseconds.push_back(std::chrono::duration<double, std::micro>(finish - begin).count());
        visited_sum += context.visited_nodes();
        if (result.ok())
        {
            ++success;
            path_points_sum += result.value.count();
        }
        else if (result.error == NavError::kNoPath)
        {
            ++no_path;
        }
    }
    const auto   all_end = std::chrono::steady_clock::now();
    // 整组 QPS 的时间范围还包括端点抽样、记录统计及循环内结果释放；
    // 因此不能直接用单次延迟的平均值倒数替代这里的 QPS。
    const double seconds = std::chrono::duration<double>(all_end - all_begin).count();

    const std::size_t cells              = map->cell_count();
    // 仅估算 Context 固定数组下界；不包含 vector capacity 余量、footprint、
    // GridMap、Path、allocator metadata，因此不能当作进程实测内存。
    const std::size_t node_scratch_bytes = cells * sizeof(NavigationContext::NodeScratch);
    const std::size_t heap_bytes         = cells * sizeof(std::int32_t);
    const std::size_t occupancy_index_bytes_est =
        cells * sizeof(std::vector<NavigationAgentHandle>);
    const std::size_t context_payload_bytes_est =
        node_scratch_bytes + heap_bytes + occupancy_index_bytes_est;
    // 只累计成功 Path 点数组的按元素下界，不含 vector capacity 余量。
    const std::uint64_t path_points_bytes_est = path_points_sum * sizeof(WorldPosition);

    std::cout << "BENCH width=" << width << " height=" << height
              << " blocked_percent=" << kBlockedPercent << " queries=" << kQueries << " threads=1"
              << " success=" << success << " no_path=" << no_path
              << " p50_us=" << Percentile(microseconds, 0.50)
              << " p95_us=" << Percentile(microseconds, 0.95)
              << " p99_us=" << Percentile(microseconds, 0.99) << " qps=" << (kQueries / seconds)
              << " avg_visited=" << (visited_sum / static_cast<double>(kQueries))
              << " node_scratch_bytes=" << node_scratch_bytes << " heap_bytes=" << heap_bytes
              << " occupancy_index_bytes_est=" << occupancy_index_bytes_est
              << " context_payload_bytes_est=" << context_payload_bytes_est
              << " path_points=" << path_points_sum
              << " path_points_bytes_est=" << path_points_bytes_est << "\n";
}

} // namespace

// 依次运行三种地图尺寸；成功返回 0，不把结果解释成产品 SLA。
int main()
{
    RunCase(80, 60);
    RunCase(256, 256);
    RunCase(512, 512);
    return 0;
}
