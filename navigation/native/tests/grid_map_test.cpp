// 职责：用最小 2x2 地图锁定 GridMap 的坐标、越界和 Cell 查询合同。
// 边界：Native 单元测试；不读取真实 BMAP，也不启动 Skynet。
// 输入/输出：进程内构造的 metadata/cells -> assert 结果和成功标记。
// 不负责：不替代 BMapReader 损坏文件测试和真实资产联调。
#include "grid_map.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

using flywow_navigation::BMapMetadata;
using flywow_navigation::GridMap;
using flywow_navigation::NavCell;
using flywow_navigation::WorldPosition;

int main()
{
    // 准备一张 X 原点为负、Z 原点为正的 2x2 小图，暴露忽略 origin 的错误。
    BMapMetadata metadata;
    metadata.map_id       = 1001;
    metadata.map_version  = 1;
    metadata.width        = 2;
    metadata.height       = 2;
    metadata.cell_size_mm = 500;
    metadata.origin_x_mm  = -500;
    metadata.origin_z_mm  = 1000;

    std::vector<NavCell> cells(4);
    cells[0].flags           = flywow_navigation::kWalkableFlag;
    cells[0].height_mm       = 100;
    cells[0].clearance_cells = 1;

    const GridMap map(metadata, std::move(cells));

    // 原点加半格正好是 (0,0) 的中心；验证毫米到 Cell 的换算。
    const auto first = map.WorldToGrid(WorldPosition{-250, 0, 1250});
    assert(first.ok());
    assert(first.value.x == 0 && first.value.z == 0);

    // 只比 X 原点少 1mm：若使用 C++ 向 0 截断，会误落在第 0 格。
    const auto before_origin = map.WorldToGrid(WorldPosition{-501, 0, 1250});
    assert(!before_origin.ok());
    assert(before_origin.error == flywow_navigation::NavError::kOutOfBounds);

    // 请求故意带错误高度；查询必须返回地图的 100mm，而非客户端给出的 9999。
    const auto query = map.QueryWorld(WorldPosition{-250, 9999, 1250});
    assert(query.ok());
    assert(query.value.IsWalkable());
    assert(query.value.height_mm == 100);

    std::cout << "GRID_MAP_TEST_OK\n";
    // Standalone main 的 0 是进程成功退出码，与 Lua C 入口的“结果数量”不同。
    return 0;
}
