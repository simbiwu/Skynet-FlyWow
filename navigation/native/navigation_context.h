// 职责：拥有一场 Battle/一次独立导航会话的 A* 可变查询状态。
// 边界：Server Runtime Battle-local Navigation；只读共享 GridMap，可写状态绝不跨 Context。
// 输入/输出：immutable GridMap -> 可重复使用的 Node/Heap scratch、动态占位和 Battle-local 格子规则。
// 生命周期：通常与一场 Battle 相同；销毁时释放 scratch、DynamicOccupancy 和格子规则。
// 不负责：不拥有 MapRegistry，不把 GridPos 暴露给 Lua 业务，不执行 Skynet yield 或跨 Battle 状态。
#pragma once

#include "dynamic_occupancy.h"
#include "grid_map.h"
#include "nav_result.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace flywow_navigation
{

// 该值只决定当前 Battle 中“已有其他单位的 Cell”是否允许重叠；空 Cell 始终可进入。
// kDefault 清除当前 Context 的覆盖，恢复默认的允许重叠行为。
enum class CellDynamicEntryRule : std::uint8_t
{
    kDefault        = 0, // 清除本格覆盖；恢复默认的允许重叠规则。
    kAllow          = 1, // 已有其他单位时仍允许重叠进入。
    kBlock          = 2, // 禁止与其他单位重叠进入；空格仍可进入。
};

// 当前 Battle 对一个格子的重叠规则；只存显式覆盖项，不为整张地图分配数组。
struct CellDynamicEntryOverride
{
    GridPos              grid;
    CellDynamicEntryRule rule = CellDynamicEntryRule::kDefault;
};

class NavigationContext final
{
  public:
    enum class NodeState : std::uint8_t
    {
        kUnseen = 0, // 本轮还没有找到到达它的合法路线。
        kOpen   = 1, // 已有候选路线，正在堆中等待被展开，成本仍可能改善。
        kClosed = 2, // 已从堆顶取出；本算法前提下最低到达成本已经确定。
    };

    struct NodeScratch
    {
        std::uint32_t generation = 0; // 只有等于 query_generation_ 时其余字段才属于当前查询。
        std::uint64_t g_cost     = 0; // 起点到当前 node 的累计整数成本；大图不会发生 uint32 回绕。
        std::int32_t  parent_index = -1; // 最优前驱 node_index；-1 表示起点/未设置。
        std::int32_t  heap_index   = -1; // 当前 node 在 binary heap 中的 slot；不在 heap 时为 -1。
        NodeState     state        = NodeState::kUnseen; // 本次 query 的 unseen/open/closed 状态。
    };

    // 为 map 分配一次 dense scratch；构造阶段会发生 O(cell_count) 内存分配。
    // map 必须非空，cell_count 必须可由 int32 node_index 表示。
    explicit NavigationContext(std::shared_ptr<const GridMap> map);

    /// 设置当前 Battle 对单个格子的动态重叠规则。
    /// @param grid 零基 Grid 坐标，必须位于当前地图内。
    /// @param rule allow/block 设置覆盖；kDefault 移除覆盖并恢复默认允许重叠行为。
    /// @return 成功返回 true；坐标越界或规则值无效时返回对应 NavError。
    /// 规则只属于当前 Context；不修改共享 GridMap，不重新分配整张地图大小的数组。
    /// 修改规则不会移走已占位单位；后续寻路和移动检查使用新规则。
    NavResult<bool> SetCellDynamicEntryRule(const GridPos &grid, CellDynamicEntryRule rule);

    /// 判断当前 Battle 在该格已有其他单位时是否允许重叠；越界返回 false。
    bool AllowsDynamicEntry(const GridPos &grid) const noexcept;

    // 开始一次新查询：递增 generation、清空 heap_size，不扫描清零全部 Node。
    // Generation 回卷时才 O(cell_count) 清零 generation 字段。
    void BeginQuery();

    // 取得 node_index 对应的当前查询 NodeScratch；首次触碰时按当前 generation 初始化。
    // node_index 必须位于 [0, cell_count)；返回引用归本 Context 所有。
    NodeScratch &TouchNode(std::int32_t node_index);

    // 只读访问共享静态地图；返回 shared_ptr 引用，不转移所有权。
    const std::shared_ptr<const GridMap> &map() const noexcept
    {
        return map_;
    }

    // 返回本 Battle 私有动态占用；调用者只能在当前 Context owner 内修改。
    DynamicOccupancy &occupancy() noexcept
    {
        return occupancy_;
    }
    const DynamicOccupancy &occupancy() const noexcept
    {
        return occupancy_;
    }

    // Binary Heap backing array；元素是 node_index。容量在构造时一次性分配为 cell_count。
    std::vector<std::int32_t> &heap_storage() noexcept
    {
        return heap_;
    }
    const std::vector<std::int32_t> &heap_storage() const noexcept
    {
        return heap_;
    }

    // 当前 heap 的有效 slot 数；[0, heap_size_) 才是本次查询数据。
    std::size_t heap_size() const noexcept
    {
        return heap_size_;
    }
    void set_heap_size(std::size_t value) noexcept
    {
        heap_size_ = value;
    }

    // 当前查询 generation；只用于 GridPathfinder，不进入业务数据。
    std::uint32_t query_generation() const noexcept
    {
        return query_generation_;
    }

    // 调试/Benchmark：本次 A* 真正 Touch 的 Node 数。
    std::uint32_t visited_nodes() const noexcept
    {
        return visited_nodes_;
    }

  private:
    std::shared_ptr<const GridMap>        map_;                 // 与 MapRegistry 共享 immutable GridMap 所有权。
    DynamicOccupancy                      occupancy_;           // 当前 Battle 的真实动态 footprint 占用。
    std::vector<CellDynamicEntryOverride> dynamic_entry_rules_; // 本 Battle 的稀疏覆盖，按 z、x 排序。
    std::vector<NodeScratch>              nodes_;               // 每 Cell 一个 scratch record，本 Context 独占。
    std::vector<std::int32_t>              heap_;                // Binary Heap 的 node_index 存储，本 Context 独占。
    std::size_t                    heap_size_        = 0; // 本次 query 的有效 heap slot 数。
    std::uint32_t                  query_generation_ = 0; // 0 保留为“从未属于任何查询”。
    std::uint32_t                  visited_nodes_    = 0; // 本次查询 Touch 的唯一 Node 计数。
};

} // namespace flywow_navigation
