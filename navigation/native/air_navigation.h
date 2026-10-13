// 职责：现有 NavigationContext 的可选空中查询合同；固定高度规划与连续盒体扫掠。
#pragma once
#include "navigation_agent.h"
#include "navigation_path.h"
#include <map>
namespace flywow_navigation
{
class NavigationContext;
struct AirBody
{
    std::uint32_t radius_mm      = 0; ///< XZ 轴对齐盒半宽，毫米。
    std::uint32_t half_height_mm = 0; ///< Y 轴半高，毫米；不是圆柱模型。
};
struct AirPolicy
{
    bool          check_terrain = false; ///< 显式启用 BMAP 地表体积下界检查。
    std::uint32_t clearance_mm  = 0;     ///< 体积底部必须严格高于地表加此毫米数。
};
struct AirLimits
{
    std::uint32_t expanded     = 4096;   ///< 单次 A* 展开上限。
    std::uint32_t nodes        = 8192;   ///< touched/open 总节点上限。
    std::uint32_t buckets      = 8192;   ///< 整次查询重复桶访问也计数。
    std::uint32_t tests        = 65536;  ///< 整次查询区间/候选/地形测试数。
    std::uint32_t path_points  = 4096;   ///< 返回折线路点上限。
    std::uint32_t objects      = 4096;   ///< 当前 Context 动态对象上限。
    std::uint32_t object_links = 256;    ///< 一个动态盒关联桶数上限。
    std::uint32_t links        = 262144; ///< Context 动态桶关联总上限。
};
struct AirBox
{
    WorldPosition min; ///< 闭合世界 AABB 下界，调用者提供；XZ 必须在地图内。
    WorldPosition max; ///< 闭合世界 AABB 上界，不允许反向区间。
};
struct AirFraction
{
    std::uint64_t numerator   = 0; ///< 段参数分子；0 表示从起点就接触。
    std::uint64_t denominator = 1; ///< 正分母；值为 numerator/denominator，范围 [0,1]。
};
enum class AirHitKind : std::uint8_t
{
    kClear   = 0, // 整段无碰撞。
    kStatic  = 1, // 导出区间或显式地表。
    kDynamic = 2, // 当前 Context 动态障碍。
};
struct AirSweepResult
{
    AirHitKind            kind = AirHitKind::kClear; ///< 同时接触静态优先，再按格/句柄排序。
    NavigationAgentHandle handle{};                  ///< 动态命中对象；静态/clear 为 0。
    std::uint32_t         cell_index = 0;            ///< 静态首命中格，仅用于诊断。
    AirFraction           time{};                    ///< 确定有理数接触参数；不依赖浮点时间。
};
struct AirStats
{
    std::uint32_t expanded = 0; ///< 最近操作展开数；不是进程级 metrics。
    std::uint32_t buckets  = 0; ///< 包括重复访问的桶数。
    std::uint32_t tests    = 0; ///< 包括重复候选的测试数。
};
struct AirNode
{
    std::uint32_t cell   = 0;     ///< 稀疏搜索节点格编号。
    std::uint64_t g      = 0;     ///< 从起点累计整数成本。
    std::uint64_t f      = 0;     ///< g 加一致 octile 启发式。
    std::int32_t  parent = -1;    ///< 前驱 scratch 下标；-1 为起点。
    std::int32_t  heap   = -1;    ///< heap slot；-1 为已取出。
    bool          closed = false; ///< 本轮已经展开。
};
struct AirState
{
    using ObjectIndex = std::map<std::uint64_t, AirBox>;
    using BucketIndex = std::map<std::pair<std::uint32_t, std::uint64_t>, bool>;
    using NodeIndex   = std::vector<std::pair<std::uint32_t, std::uint32_t>>;

    AirLimits                  limits;      ///< 首次操作前确定，不超过硬上限。
    AirStats                   stats;       ///< 整次操作共享计数；嵌套扫掠不重置。
    ObjectIndex                objects;     ///< handle -> AABB，owner 顺序修改。
    BucketIndex                links;       ///< 有界排序桶关联，无退化哈希。
    std::vector<std::uint32_t> empty_cells; ///< 单次固定高度空桶证明；每次清空。
    std::vector<AirNode>       nodes;       ///< 有界 reserve 并复用，不按全图分配。
    NodeIndex                  index;       ///< 格编号到 nodes 下标的排序索引。
    std::vector<std::uint32_t> heap;        ///< 唯一 open 节点堆；容量与 nodes 相同。
};
/// 动态状态设置，不表示移动已扫掠；准备全部新关联后提交，失败旧状态不变。
/// @param context 单 owner 的可变导航会话；可能按需分配私有 AirState/桶节点。
/// @param handle 会话内非零对象身份，不持有业务对象。
/// @param box 闭整数毫米 AABB；XZ 在地图内，Y 可用完整 int64。
/// @return 成功 true；非法体积、越界或容量/分配失败返回稳定错误。
/// @note 同步，不 I/O、不 yield、不加全局锁；动态状态不隐式同步 ground。
NavResult<bool> setAirObstacle(NavigationContext &context, NavigationAgentHandle handle,
                               const AirBox &box);
/// 不存在也成功；只释放当前 Context 关联。
/// @param context 单 owner 会话；首次操作可能分配 AirState。
/// @param handle 非零身份，释放所有桶关联但不管理业务对象。
/// @return true 或参数/分配失败；同步，不 I/O/yield。
NavResult<bool> removeAirObstacle(NavigationContext &context, NavigationAgentHandle handle);
/// 只读连续盒体扫掠；查询预算耗尽返回明确错误，不返回 clear。
/// @param from 段起点中心，整数毫米；to 为终点，允许 Y 不同。
/// @param body 对称轴对齐半宽/半高，毫米；不是圆柱。
/// @param exclude 仅排除对应动态身份，0 不排除；policy 显式控制地形。
/// @return 首个确定接触/clear 或稳定错误；不改变占位，仅使用有界 scratch。
/// @note 单 owner，同步无 I/O/yield，首次可按需分配。
NavResult<AirSweepResult> sweepAir(NavigationContext &context, WorldPosition from, WorldPosition to,
                                   AirBody body, NavigationAgentHandle exclude = {},
                                   AirPolicy policy = {});
/// 固定 flight_y_mm 的八邻接搜索；range_mm=0 为精确终点，>0 沿用中心 XZ 距离语义。
/// @param start 起点 XZ，Y 用 flight_y_mm；target 同理。
/// @param flight_y_mm 固定 int64 高度，毫米，不选择自动爬升。
/// @param body 路径保存的对称查询体；exclude/policy 与 sweep 相同。
/// @return 独占世界点的 Path 强持有地图快照；失败区分无路与预算。
/// @note 单 owner，同步无 I/O/yield；有界 reserve/结果分配，不拥有动态对象。
NavResult<Path> findAirPath(NavigationContext &context, WorldPosition start, WorldPosition target,
                            std::int64_t flight_y_mm, AirBody body,
                            NavigationAgentHandle exclude = {}, AirPolicy policy = {},
                            std::uint32_t range_mm = 0);
/// 注册对象按原尺寸移动；全段通过才原子提交，失败旧 AABB 保持不变。
/// @param handle 当前 Context 已注册的对象；target 为整数毫米新中心。
/// @return 新中心或稳定错误，原盒的矩形/奇数边长保持。
/// @note 单 owner，同步无 I/O/yield；新关联可分配，提交前失败不改旧状态。
NavResult<WorldPosition>     moveAir(NavigationContext &context, NavigationAgentHandle handle,
                                     WorldPosition target, AirPolicy policy = {});
/// 累计真实折线距离；后段阻挡保留已成功提交的部分与 cursor。预算错误也保留已提交进度。
/// @param path 本快照的空中路径；高度/尺寸与注册对象匹配。
/// @param cursor 对象独占的推进游标，调用成功段后原地更新。
/// @param stride_mm 非负整次 XZ 折线距离预算，毫米。
/// @return 实际位置/已消费距离/状态或错误；错误不撤销合法前缀。
/// @note 单 owner，同步无 I/O/yield；不自动重新寻路，不管理业务生命周期。
NavResult<PathAdvanceResult> advanceAirPath(NavigationContext    &context,
                                            NavigationAgentHandle handle, const Path &path,
                                            PathFollowCursor &cursor, std::uint32_t stride_mm,
                                            AirPolicy policy = {});
/// 整数平方根距离，向下取整；无浮点参与确定性。
std::uint64_t                airDistance(WorldPosition a, WorldPosition b);
} // namespace flywow_navigation
