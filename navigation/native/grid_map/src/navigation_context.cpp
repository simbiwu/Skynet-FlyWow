// 职责：实现 NavigationContext 的 scratch 分配、generation 生命周期和按需 Node 初始化。
// 边界：Server Runtime Battle-local Mutable State；不访问 Skynet/Lua，不执行 I/O。
// 输入/输出：immutable GridMap -> 可复用 A* scratch + Battle-local DynamicOccupancy。
// 内存：构造时按 cell_count 分配 nodes + heap；每次查询不做 per-node allocation。
// 不负责：不计算邻居、不判断 Agent、不生成 Path，也不拥有跨 Battle 的动态状态。
#include "navigation_context.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <utility>

namespace flywow_navigation
{
namespace
{

// 在构造成员 occupancy_ 之前验证 map，避免空 shared_ptr 被解引用。
const GridMap &RequireMap(const std::shared_ptr<const GridMap> &map)
{
    if (!map)
    {
        throw std::invalid_argument("NavigationContext requires map");
    }
    return *map;
}

} // namespace

// 为一张非空地图创建 Battle-local Context。
// map 的共享所有权移入本对象；构造时按 cell_count 分配 scratch 和占位索引。
// map 为空或 Cell 数无法用 int32 node_index 表示时抛出 invalid_argument。
NavigationContext::NavigationContext(std::shared_ptr<const GridMap> map)
    : map_(std::move(map)), occupancy_(RequireMap(map_))
{
    if (map_->cell_count() > static_cast<std::size_t>(std::numeric_limits<std::int32_t>::max()))
    {
        throw std::invalid_argument("map has too many cells for int32 node index");
    }

    // occupancy_ 已在初始化列表中绑定 immutable map；scratch 也在构造阶段一次分配。
    nodes_.resize(map_->cell_count());
    heap_.resize(map_->cell_count());
}

// 开始一次新查询：递增 generation 并清空 Heap 逻辑长度。
// 不清扫全部 Node；只在 uint32 generation 回卷时执行 O(cell_count) 重置。
// 不执行 I/O、加锁或 yield；调用者必须独占本 Context。
void NavigationContext::BeginQuery()
{
    // 给本次搜索发一个新编号，上一轮的 g/parent/state 即使仍留在数组里，
    // 只要编号不同就视作无效；不必为了短路径清扫整张大地图。
    // 这只清理查询 scratch，不清空 Battle 的动态占位。
    ++query_generation_;
    if (query_generation_ == 0)
    {
        // uint32 generation 回卷后必须清掉旧标记，避免几十亿次前的 Node 被误认为当前查询。
        for (NodeScratch &node : nodes_)
        {
            node.generation = 0;
        }
        query_generation_ = 1;
    }
    heap_size_     = 0;
    visited_nodes_ = 0;
}

// 返回 node_index 在当前 generation 的可变 scratch，首次触达时惰性初始化。
// node_index 必须位于 [0, cell_count)；越界抛出 out_of_range。
// 返回引用仍归本 Context 所有，不得跨下一次查询保存其语义。
NavigationContext::NodeScratch &NavigationContext::TouchNode(std::int32_t node_index)
{
    if (node_index < 0 || static_cast<std::size_t>(node_index) >= nodes_.size())
    {
        throw std::out_of_range("A* node_index outside scratch array");
    }

    NodeScratch &node = nodes_[static_cast<std::size_t>(node_index)];
    if (node.generation != query_generation_)
    {
        // 例如上一轮编号 7、本轮编号 8：第一次访问此格才将它标为未发现。
        // 同一轮再次访问时编号已一致，保留先前找到的成本、前驱和堆位置。
        // g 的最大值代表“尚无路线”，-1 表示无前驱/不在堆中；这些都是
        // 查询内部哨兵值，不会作为地图坐标或正式 Battle 数据发布。
        // 只初始化本次查询真正访问的 Node；不对整张地图 memset。
        node.generation   = query_generation_;
        node.g_cost       = std::numeric_limits<std::uint64_t>::max();
        node.parent_index = -1;
        node.heap_index   = -1;
        node.state        = NodeState::kUnseen;
        ++visited_nodes_;
    }
    return node;
}

} // namespace flywow_navigation
