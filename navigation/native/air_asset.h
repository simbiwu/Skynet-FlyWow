// 职责：定义 Navigation 可选的只读空中区间资产；BMAP V1 不变。
#pragma once
#include "bmap_format.h"
#include "nav_result.h"
#include <array>
#include <string>
#include <vector>
namespace flywow_navigation
{
using AssetHash = std::array<std::uint8_t, 32>;
struct AirInterval
{
    std::int64_t min_y_mm = 0; ///< 闭区间下界，世界毫米。
    std::int64_t max_y_mm = 0; ///< 闭区间上界，接触也阻挡。
};
struct AirCell
{
    std::uint32_t cell_index = 0; ///< 与 BMAP 相同的 z-major 格编号。
    std::uint32_t offset     = 0; ///< 本格区间在连续数组的起点。
    std::uint32_t count      = 0; ///< 本格排序且不重叠的区间数，1..64。
};
struct AirAsset
{
    std::vector<AirCell>     cells;           ///< 稀疏格记录，严格递增。
    std::vector<AirInterval> intervals;       ///< 记录连续引用的高度区间。
    AssetHash                bmap_hash{};     ///< 完整配对 BMAP 的 SHA-256。
    AssetHash                air_hash{};      ///< 完整 airnav 的 SHA-256；无组件时为零。
    bool                     present = false; ///< 区分未加载与显式空区间资产。
};
/// 只用于离线/加载阶段；无共享可变状态，输出完整 SHA-256。
AssetHash           sha256(const std::uint8_t *data, std::size_t size);
/// 在分配前拒绝超过 32 MiB 的文件，完整配对成功后接管数据；不修改 Registry。
NavResult<AirAsset> readAirAsset(const std::string &path, const BMapMetadata &metadata,
                                 const AssetHash &bmap_hash);
} // namespace flywow_navigation
