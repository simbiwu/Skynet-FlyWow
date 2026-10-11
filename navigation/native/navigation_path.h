// 职责：保存一次成功地面导航产生的不可变世界坐标路径。
// 边界：Server Runtime Navigation Result；Lua/Battle/Replay 只看 WorldPosition。
// 输入/输出：有序 WorldPosition 点 -> 只读 Path 和总长度。
// 生命周期：由调用者或 Lua userdata 持有；构建完成后不再修改。
// 不负责：不保存 A* node、GridPos、dynamic occupancy 或未来 Off-Mesh 语义。
#pragma once

#include "bmap_format.h"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace flywow_navigation
{

// Path 跟随状态只描述本次 Tick 的导航结果；业务层决定何时重寻路或攻击。
enum class PathAdvanceStatus : std::uint8_t
{
    kMoving  = 0, // 预算已经用完，Path 后面仍有路点。
    kReached = 1, // 已经消费到 Path 最后一个路点。
    kBlocked = 2, // 某个子步被最新静态/动态规则拒绝，位置停在最后一次成功提交处。
};

// 一个 Path userdata 独占一个 cursor；下标使用 C++ 0-based，不进入 Snapshot/Event。
// 例如路线 [A,B,C] 初始 next=1、progress=0，表示沿 A->B 走；到 B 后改为
// next=2、progress=0，再沿 B->C 走。Path 保存路线，cursor 保存这个单位走到哪。
// 两个单位即使路线相同也不能共用 cursor，否则一个推进会改变另一个的进度。
struct PathFollowCursor
{
    std::size_t   next_point_index    = 1; // 下一个待追踪路点；count 表示已结束。
    std::uint64_t segment_progress_mm = 0; // 当前线段从固定起点累计消费的毫米数。
};

// Native 一次 fixed-tick 推进的结果；position 是已经成功提交的权威位置。
struct PathAdvanceResult
{
    PathAdvanceStatus status = PathAdvanceStatus::kMoving;
    WorldPosition     position{};
    std::uint32_t     consumed_mm = 0;     // 本次调用真正消费的距离预算。
    bool              moved       = false; // X/Z 是否至少发生过一次成功变化。
};

class Path final
{
  public:
    // 构造空路径结果；不分配内存，通常只用于结果容器初始化。
    Path() = default;

    // 接管已经按行进顺序排列的世界坐标点。
    // points 可以只含一个点（start==end）；本构造不执行地图合法性检查。
    explicit Path(std::vector<WorldPosition> points, std::uint64_t length_mm, bool partial = false)
        : points_(std::move(points)), length_mm_(length_mm), partial_(partial)
    {
    }

    /// 查询结果是否进入目标区域；与 AdvancePath 的执行状态独立。
    const char *status() const noexcept
    {
        return partial_ ? "partial" : "reached";
    }

    // 返回路径点数量；不分配、不加锁、不 yield。
    std::size_t count() const noexcept
    {
        return points_.size();
    }

    // 读取 index 对应的世界坐标点；越界抛 out_of_range，仅供已验证调用者使用。
    const WorldPosition &WorldPoint(std::size_t index) const
    {
        if (index >= points_.size())
        {
            throw std::out_of_range("path point index out of range");
        }
        return points_[index];
    }

    // 返回整条路径在 XZ 平面的整数毫米长度；不包含动画或墙钟时间。
    std::uint64_t length_mm() const noexcept
    {
        return length_mm_;
    }

    // Native 内部只读访问连续点数组；返回引用不拥有数据。
    const std::vector<WorldPosition> &points() const noexcept
    {
        return points_;
    }

  private:
    std::vector<WorldPosition> points_;        // 按移动顺序保存；Path 独占内存。
    std::uint64_t              length_mm_ = 0; // XZ 折线总长度，单位毫米。
    bool                       partial_   = false; // true 表示搜索耗尽后返回的最近可达路线。
};

} // namespace flywow_navigation
