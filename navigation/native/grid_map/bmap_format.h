// 职责：定义 BMAP V1 常量以及 Server 内存中的地图、Cell 和坐标 record。
// 边界：Server Runtime 公共类型；由 Reader、GridMap、Registry 和 Binding 共用。
// 输入/输出：承接 Unity BMAP 合同 -> 强类型 Native 数据；加载后按地图生命周期存活。
// 不负责：不直接解析磁盘字节，不定义动态占位或寻路类型。
#pragma once

#include <cstdint>

namespace flywow_navigation
{

// BMAP V1 磁盘合同：必须与 Unity BMapFormat 完全一致。
constexpr std::uint16_t kBMapFormatVersion = 1;
// Header 固定长度，单位 byte；不是 sizeof(BMapMetadata)。
constexpr std::uint16_t kBMapHeaderSize    = 64;
// 每条 Cell Payload 的磁盘长度，单位 byte；解码时逐字段读，不能用 sizeof(NavCell) 当文件步长。
constexpr std::uint16_t kBMapCellStride    = 8;
// 单个文件的离线和 Runtime 读取上限；在分配文件缓冲前拒绝超限输入。
// 128 MiB 是明确资源保护，不代表同时加载任意数量地图或 Context 都安全。
constexpr std::uint64_t kBMapMaxFileSize   = 128ull * 1024ull * 1024ull;
// NavCell::flags 的 bit 0；表示该 Cell Center 对静态地图可走。
constexpr std::uint16_t kWalkableFlag      = 1u << 0;

// 加载后的地图元数据。这是 Runtime record，不是磁盘 Header 的 struct cast。
struct BMapMetadata
{
    std::uint32_t map_id       = 0; // 业务地图 ID；0 为非法值。
    std::uint32_t map_version  = 0; // 地图内容版本；导航语义变化时递增。
    std::uint32_t width        = 0; // Grid X 方向 Cell 数；合法下标 [0, width)。
    std::uint32_t height       = 0; // Grid Z 方向 Cell 数；合法下标 [0, height)。
    std::uint32_t cell_size_mm = 0; // 正方形 Cell 边长，毫米；必须大于 0。
    std::int32_t  origin_x_mm  = 0; // BMAP V1 原点 X，磁盘字段为 i32 毫米；允许负数。
    std::int32_t  origin_z_mm  = 0; // BMAP V1 原点 Z，磁盘字段为 i32 毫米；允许负数。
    std::uint32_t flags        = 0; // V1 保留标记；必须为 0，不进入协议。
};

// 一个 Server Grid Cell 的静态导航数据；地图加载后 immutable 共享。
struct NavCell
{
    std::int32_t  height_mm       = 0; // BMAP V1 Cell 地表 Y，磁盘字段为 i32 毫米。
    std::uint16_t flags           = 0; // 静态属性 bitset；bit 0=Walkable。
    std::uint8_t  area_type       = 0; // 稳定地表编码；不是 Unity Area 下标。
    std::uint8_t  clearance_cells = 0; // 到静态障碍/边界的距离，单位 Cell。

    // 只读取 Walkable bit，不会把其他 flags 误当成布尔值。
    // 例如 flags=2 虽是非零，但 bit 0 未设置，仍不可走。
    bool IsWalkable() const noexcept
    {
        return (flags & kWalkableFlag) != 0;
    }
};

// Server 业务位置：世界坐标、整数毫米；三轴均为 int64，可进入协议和战斗快照。
struct WorldPosition
{
    std::int64_t x_mm = 0; // 世界 X，毫米；允许负数。
    std::int64_t y_mm = 0; // 世界高度 Y，毫米。
    std::int64_t z_mm = 0; // 世界 Z，毫米；允许负数。
};

// 当前地图内的二维 Cell 下标，只用于 Native 查询和 Debug API。
struct GridPos
{
    std::int32_t x = 0; // X 方向列下标；合法范围 [0, width)。
    std::int32_t z = 0; // Z 方向行下标；合法范围 [0, height)。
};

} // namespace flywow_navigation
