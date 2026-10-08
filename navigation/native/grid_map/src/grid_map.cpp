// 职责：实现 GridMap 的构造校验、坐标换算、索引计算和单格查询。
// 边界：Server Runtime 纯内存查询；所有公开查询只读且不共享 scratch。
// 输入/输出：WorldPosition 或 GridPos -> NavResult；失败显式返回越界或溢出。
// 不负责：不加载 BMAP、不判断动态占位、不计算路径。
#include "grid_map.h"

#include <limits>
#include <stdexcept>
#include <utility>

namespace flywow_navigation
{

// ---- 构造与内存统计：一次接管数据，之后只读 ----

// cells 按值传入，再 move 到本对象；构造成功后调用方不再拥有该数组。
// 这里检查内存数据是否自洽，不替代 Reader 的文件版本、长度和 CRC 校验。
GridMap::GridMap(BMapMetadata metadata, std::vector<NavCell> cells)
    : metadata_(metadata), cells_(std::move(cells))
{
    // 先提升再相乘，避免 width*height 在 32 位就回绕；每个格子必须恰有一个 Cell。
    const std::uint64_t expected = static_cast<std::uint64_t>(metadata_.width) * metadata_.height;
    if (metadata_.cell_size_mm == 0 || expected != cells_.size())
    {
        throw std::invalid_argument("GridMap metadata/cell mismatch");
    }
}

std::size_t GridMap::memory_bytes() const noexcept
{
    // capacity 包含已经预留但未使用的空间，size 只计有效元素；这里估算占用，
    // 不包含分配器开销，也不是进程的实测内存。
    return sizeof(*this) + cells_.capacity() * sizeof(NavCell);
}

// ---- 坐标转换：世界毫米位置与地图内部格下标 ----

NavResult<GridPos> GridMap::WorldToGrid(const WorldPosition &world) const
{
    // BMAP V1 的地图原点仍是 int32；先拒绝其可表达范围之外的坐标，
    // 让后续 int64 相减安全，且不把超大业务坐标误映射进有限 Grid。
    if (world.x_mm < std::numeric_limits<std::int32_t>::min() ||
        world.x_mm > std::numeric_limits<std::int32_t>::max() ||
        world.z_mm < std::numeric_limits<std::int32_t>::min() ||
        world.z_mm > std::numeric_limits<std::int32_t>::max())
    {
        return NavResult<GridPos>::Failure(NavError::kOutOfBounds,
                                           "world position outside BMAP V1 coordinate range");
    }
    const std::int64_t relative_x = // 相对 Grid 起点的世界 X 偏移，毫米；允许负数。
        world.x_mm - metadata_.origin_x_mm;
    const std::int64_t relative_z = // 相对 Grid 起点的世界 Z 偏移，毫米；允许负数。
        world.z_mm - metadata_.origin_z_mm;

    // 先减地图原点再归格。原点 -500mm、格边 500mm 时，世界 X=-250 属于第 0 格；
    // 世界 X=-501 则在原点外，必须得到 -1，而不能被整数截断误算到第 0 格。
    // Y 不参与二维归格；地图地表高度由对应 Cell 提供。
    const std::int64_t grid_x = FloorDiv(relative_x, metadata_.cell_size_mm);
    const std::int64_t grid_z = FloorDiv(relative_z, metadata_.cell_size_mm);
    if (grid_x < std::numeric_limits<std::int32_t>::min() ||
        grid_x > std::numeric_limits<std::int32_t>::max() ||
        grid_z < std::numeric_limits<std::int32_t>::min() ||
        grid_z > std::numeric_limits<std::int32_t>::max())
    {
        return NavResult<GridPos>::Failure(NavError::kOutOfBounds,
                                           "world coordinate cannot be represented as GridPos");
    }

    GridPos grid{
        static_cast<std::int32_t>(grid_x),
        static_cast<std::int32_t>(grid_z),
    };
    if (!Contains(grid))
    {
        return NavResult<GridPos>::Failure(NavError::kOutOfBounds,
                                           "world position outside map bounds");
    }
    return NavResult<GridPos>::Success(grid);
}

NavResult<WorldPosition> GridMap::GridToWorldCenter(const GridPos &grid) const
{
    if (!Contains(grid))
    {
        return NavResult<WorldPosition>::Failure(NavError::kOutOfBounds,
                                                 "grid position outside map bounds");
    }

    // 返回格中心而不是左下角：origin=0、cell_size=500、grid.x=1 时 X=750mm。
    // 奇数边长的半格按整数除法截断；Y 始终来自地图，不从请求坐标复制。
    const NavCell     &cell = cells_[IndexOf(grid)];
    const std::int64_t x    = static_cast<std::int64_t>(metadata_.origin_x_mm) +
                           static_cast<std::int64_t>(grid.x) * metadata_.cell_size_mm +
                           metadata_.cell_size_mm / 2;
    const std::int64_t z = static_cast<std::int64_t>(metadata_.origin_z_mm) +
                           static_cast<std::int64_t>(grid.z) * metadata_.cell_size_mm +
                           metadata_.cell_size_mm / 2;
    if (x < std::numeric_limits<std::int32_t>::min() ||
        x > std::numeric_limits<std::int32_t>::max() ||
        z < std::numeric_limits<std::int32_t>::min() ||
        z > std::numeric_limits<std::int32_t>::max())
    {
        return NavResult<WorldPosition>::Failure(NavError::kSizeOverflow, "grid center overflow");
    }

    return NavResult<WorldPosition>::Success(WorldPosition{
        x,
        cell.height_mm,
        z,
    });
}

// ---- 只读 Cell 查询与不可变进入配置 ----

NavResult<NavCell> GridMap::QueryWorld(const WorldPosition &world) const
{
    NavResult<GridPos> grid = WorldToGrid(world);
    if (!grid.ok())
    {
        return NavResult<NavCell>::Failure(grid.error, grid.detail);
    }
    return NavResult<NavCell>::Success(cells_[IndexOf(grid.value)]);
}

const NavCell *GridMap::TryCell(const GridPos &grid) const noexcept
{
    if (!Contains(grid))
    {
        return nullptr;
    }
    return &cells_[IndexOf(grid)];
}

// ---- 内部边界与索引：先确认范围，再读连续数组 ----

bool GridMap::Contains(const GridPos &grid) const noexcept
{
    // 先排除负数再转无符号数比较。右/上边界不包含在地图内，
    // 例如宽 2 格只允许 x=0、1，x=2 已属于地图外。
    return grid.x >= 0 && grid.z >= 0 && static_cast<std::uint32_t>(grid.x) < metadata_.width &&
           static_cast<std::uint32_t>(grid.z) < metadata_.height;
}

std::size_t GridMap::IndexOf(const GridPos &grid) const noexcept
{
    // 每行按 X 排列，再沿 Z 排行；宽 3 时 (2,1) 的下标为 5。
    return static_cast<std::size_t>(grid.z) * metadata_.width + static_cast<std::size_t>(grid.x);
}

std::int64_t GridMap::FloorDiv(std::int64_t value, std::int64_t divisor)
{
    if (divisor <= 0)
    {
        throw std::invalid_argument("divisor must be positive");
    }
    std::int64_t       quotient  = value / divisor;
    const std::int64_t remainder = value % divisor;
    // C++ 的 -1/500 是 0，但原点左侧 1mm 必须归到 -1 格。
    // 负数且有余数时再向左退一格；-500/500 已是 -1，无需再次修正。
    if (remainder != 0 && value < 0)
    {
        --quotient;
    }
    return quotient;
}

} // namespace flywow_navigation
