// 职责：保存一张已校验的静态 Grid，并提供世界坐标与 Cell 之间的只读查询。
// 边界：Server Runtime；加载后可由多个 Skynet OS Thread immutable 共享。
// 输入/输出：BMapMetadata + NavCell 数组 + 动态进入规则 -> 坐标转换结果或单格静态导航数据。
// 生命周期：由 MapRegistry 的 shared_ptr 持有；构造完成后不再修改。
// 不负责：不读磁盘、不管理动态单位、不执行寻路。
#pragma once

#include "bmap_format.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace flywow_navigation
{

// Cell 对动态单位进入规则的覆盖方式。
// 该规则是 immutable 地图配置；它只说明该 Cell 有其他实体时是否允许重叠，
// 空 Cell 不因 kBlock 而封闭；静态可走性仍由 NavCell 决定。
enum class CellDynamicEntryRule : std::uint8_t
{
    kUseGridDefault = 0, // 使用整张 Grid 的默认值。
    kAllow          = 1, // 该 Cell 覆盖为允许与其他实体重叠。
    kBlock          = 2, // 该 Cell 覆盖为禁止与其他实体重叠；空格仍可走。
};

// 一张 Grid 的动态进入静态配置。
// per_cell 为空时所有 Cell 使用 default_allow；非空时必须与 width*height 等长，
// 元素顺序与 GridMap 的 z-major Cell 数组一致。只约束有其他实体时的重叠。
struct GridDynamicEntryRules
{
    bool default_allow = true;                  // 默认允许与其他实体同格；业务回调仍可拒绝。
    std::vector<CellDynamicEntryRule> per_cell; // 可选的 Cell 级覆盖。
};

class GridMap final
{
  public:
    // 用已经校验的 metadata 和 z-major Cell 数组构造只读地图。
    // cells 的元素数必须等于 width*height；动态规则为空或同样等长，否则抛出 invalid_argument。
    GridMap(BMapMetadata metadata, std::vector<NavCell> cells,
            GridDynamicEntryRules dynamic_rules = {});

    // 返回只读元数据引用；引用生命周期不超过当前 GridMap。
    const BMapMetadata &metadata() const noexcept
    {
        return metadata_;
    }
    // 返回 Cell 总数，即 width*height。
    std::size_t cell_count() const noexcept
    {
        return cells_.size();
    }
    // 返回对象、Cell 和规则数组 capacity 占用的近似 byte 数，不统计 allocator 元数据。
    std::size_t memory_bytes() const noexcept;

    // 把毫米制世界 XZ 转成当前地图内的 Cell 下标；Y 不参与二维归格。
    // 每格包含其左/下边界，不包含右/上边界；负偏移必须向下归格，不能截成 0。
    // 地图外或结果无法用 GridPos 表示时返回 kOutOfBounds；不分配共享状态。
    NavResult<GridPos>       WorldToGrid(const WorldPosition &world) const;
    // 返回指定 Cell Center 的毫米制世界坐标；Y 取该 Cell 的静态表面高度。
    // grid 越界返回 kOutOfBounds，中心坐标溢出 int32 返回 kSizeOverflow。
    NavResult<WorldPosition> GridToWorldCenter(const GridPos &grid) const;
    // 先执行 WorldToGrid，再返回对应 NavCell 的副本；失败原样向上传递。
    NavResult<NavCell>       QueryWorld(const WorldPosition &world) const;
    // Native 导航热路径按 GridPos 读取 immutable Cell。
    // grid 越界返回 nullptr；成功指针指向 GridMap 内部 const vector，调用方不释放。
    // 本函数不分配、不加锁、不修改共享状态。
    const NavCell           *TryCell(const GridPos &grid) const noexcept;
    // 返回该 Cell 有其他实体时是否允许动态重叠；越界返回 false。
    // 空 Cell 不受此值限制；当前占用事实及更细的业务冲突由查询方判断。
    bool                     AllowsDynamicEntry(const GridPos &grid) const noexcept;

  private:
    // 判断 grid 是否落在 [0,width) x [0,height) 内。
    bool                Contains(const GridPos &grid) const noexcept;
    // 把合法 GridPos 转成 z*width+x 的 z-major 数组下标；调用前必须 Contains。
    std::size_t         IndexOf(const GridPos &grid) const noexcept;
    // 对正 divisor 做数学 floor 除法；区别于 C++ 对负数向 0 截断。
    // divisor<=0 抛出 invalid_argument。
    static std::int64_t FloorDiv(std::int64_t value, std::int64_t divisor);

    const BMapMetadata         metadata_; // 地图身份、尺寸和坐标原点；构造后只读。
    const std::vector<NavCell> cells_;    // z-major Cell 数组；元素数必须等于 width*height。
    const bool                 default_dynamic_entry_allowed_;    // Grid 级动态进入默认值。
    const std::vector<CellDynamicEntryRule> dynamic_entry_rules_; // 可选的 Cell 级覆盖。
};

} // namespace flywow_navigation
