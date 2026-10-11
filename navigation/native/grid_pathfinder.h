// 职责：声明 Grid 8-way A* 的静态和 Battle-local 动态路径查询入口。
// 边界：Server Runtime Native Navigation；内部使用 GridPos，外部只接受/返回 WorldPosition。
// 输入/输出：NavigationContext + NavigationProfile + A/B 世界坐标 -> Path 或显式 NavError。
// 生命周期：不保存全局状态；所有 scratch 和动态占用由调用者传入的 Context 拥有。
// 不负责：不调用 Skynet，不执行 Unity 表现，不实现局部 Steering/Crowd 避碰。
#pragma once

#include "navigation_profile.h"
#include "navigation_agent.h"
#include "navigation_context.h"
#include "navigation_path.h"
#include "navigation_query.h"

#include <cstdint>

namespace flywow_navigation
{
// 调用顺序：FindPath 规划路线，AdvancePath 按 Tick 预算推进；底层 MoveUnit
// 逐步复验和提交占位。只有 Path 并不能证明下一 Tick 的道路仍然空闲。
class GridPathfinder final
{
  public:
    // 在 immutable GridMap 上寻找不读取动态占位的静态 A->B 路径。
    // context：本次查询独占的 scratch；profile：已校验的体型/Area 规则。
    // start/end：整数毫米 WorldPosition；只使用 X/Z 归格，Y 不覆盖地图地表高度。
    // 返回值：成功返回拥有 Path 数据的 NavResult；越界、不可达或参数非法返回明确 NavError。
    // 不执行 I/O、加锁或 yield；A* 使用 Context scratch，最终 Path 可能分配结果数组。
    static NavResult<Path> FindPathStatic(NavigationContext &context, const NavigationProfile &profile,
                                          const WorldPosition &start, const WorldPosition &end);

    // 在静态地图、Context 的 Battle-local 格子规则和业务回调上寻找 A->B 路径。
    // context：本 Battle 的 scratch 和动态事实 owner；agent：借用的当前实体视图。
    // start/end：整数毫米 WorldPosition；policy/user_data 由调用方拥有，查询期间必须有效。
    // 返回值：成功返回 Path；参数、静态规则或动态回调拒绝时返回明确 NavError。
    // allow_partial 默认 false；开启后失败目标可返回最近可达且有进展的 partial Path。
    // 动态状态只代表查询时刻的快照；真正跨格前仍必须调用 MoveUnit 再次验证。
    static NavResult<Path> FindPath(NavigationContext &context, const NavigationAgent &agent,
                                    const WorldPosition &start, const WorldPosition &end,
                                    const DynamicNavigationPolicy &policy,
                                    bool                           allow_partial = false);

    // 诊断一条 Path 的每个 Grid Segment 是否仍符合静态地图规则。
    // context：借用地图和本次查询环境；profile：只读 Agent 规则；path：只读世界毫米点。
    // 成功返回 true；空路径、越界、无效体型或非法边返回明确 NavError。
    // 不修改 Occupancy、不执行 I/O、加锁或 yield；按 Segment 穿过的 Cell 数线性检查。
    static NavResult<bool> ValidatePathStatic(NavigationContext  &context,
                                              const NavigationProfile &profile, const Path &path);

    // 用与 FindPath 相同的动态策略复验 Path；结果仅代表调用时刻的动态事实。
    // agent/profile/policy 的借用生命周期须覆盖本次同步调用；不修改 Occupancy。
    // 成功返回 true，非法句柄/体型、越界或动态阻挡返回明确 NavError。
    static NavResult<bool> ValidatePath(NavigationContext &context, const NavigationAgent &agent,
                                        const Path &path, const DynamicNavigationPolicy &policy);

    /// 寻找位于目标中心通用距离范围内的可站立 Cell；目标中心本身可以被占用。
    /// @param context 当前 Battle/查询 owner 的 scratch 与动态占位；本次调用借用，不转移所有权。
    /// @param agent 当前移动者及其 NavigationProfile；同步借用至调用返回。
    /// @param start 起点整数毫米世界坐标；必须在地图内且可站立。
    /// @param target 目标中心整数毫米世界坐标；只用于计算 XZ 距离，不要求该 Cell 可站立。
    /// @param range_mm 目标中心周围包含边界的 XZ 最大距离，单位毫米；不代表或读取战斗攻击距离。
    /// @param policy 当前同步动态规则；其中指针和 user_data 的生命周期须覆盖本次调用。
    /// @param allow_partial 默认 false；开启后搜索耗尽时可返回有进展的 partial Path。
    /// @return 终点为命中范围的 Cell Center；参数非法、越界、无效 Agent 或不可达时返回 NavError。
    /// @note 范围目标使用同一 Heap/Relax 主循环的 h=0 Dijkstra；不执行 I/O、加锁或 yield。
    static NavResult<Path> FindPathToRange(NavigationContext &context, const NavigationAgent &agent,
                                           const WorldPosition &start, const WorldPosition &target,
                                           std::uint32_t                  range_mm,
                                           const DynamicNavigationPolicy &policy,
                                           bool                           allow_partial = false);
    /// 寻找与目标单位保持可导航间距的可站立终点；攻击距离不属于此查询。
    /// @param context 当前 Battle 的 scratch 与动态占位；同步借用，不转移所有权。
    /// @param mover 移动者句柄及 NavigationProfile；同步借用至调用返回。
    /// @param start 移动者当前整数毫米世界坐标；必须在地图内且可站立。
    /// @param target_profile 目标单位 NavigationProfile；由调用方按静态 unit_id 查得并借用。
    /// @param target 目标单位当前整数毫米世界坐标；只读，不要求目标中心可站立。
    /// @param policy 当前同步动态规则；其中指针和 user_data 的生命周期须覆盖本次调用。
    /// @param allow_partial 默认 false；开启后耗尽搜索可返回最近且有进展的 partial Path。
    /// @return 终点保持双方导航半径间距；参数非法、越界、不可达时返回 NavError。
    /// @note 半径下界避免体型重叠，Grid 对角线容差补偿离散终点；不执行 I/O、加锁或 yield。
    static NavResult<Path>
    findPathToUnitRange(NavigationContext &context, const NavigationAgent &mover,
                        const WorldPosition &start, const NavigationProfile &target_profile,
                        const WorldPosition &target, const DynamicNavigationPolicy &policy,
                        bool allow_partial = false);

    // 重新验证一个单位从 from 到 to 的单步移动，并在成功后原子提交动态 footprint。
    // context：当前 Battle 状态 owner；agent：当前实体句柄和静态 profile 的借用视图。
    // from/to：整数毫米 WorldPosition，必须落在同一 Cell 或相邻 Cell。
    // policy：与 FindPath 使用同一业务规则；成功后才更新 DynamicOccupancy。
    // 返回值：成功返回 true；越界、非相邻、静态边或动态规则失败返回明确 NavError。
    static NavResult<bool> MoveUnit(NavigationContext &context, const NavigationAgent &agent,
                                    const WorldPosition &from, const WorldPosition &to,
                                    const DynamicNavigationPolicy &policy);

    // 沿同一实体独占的 Path 消耗一次 fixed-tick 距离预算。
    // context/agent/path/policy：同步借用；cursor 由该 Path userdata 独占并在成功子步后更新。
    // cursor、path、agent 和 from 必须始终属于同一单位；外力改位或换 Path 时应丢弃旧 cursor。
    // from：当前权威世界毫米位置；distance_mm：Battle 已结算的本 Tick 非负移动预算。
    // 返回 moving/reached/blocked 和最后成功位置；blocked 是正常业务结果，不作为 NavError。
    // 参数非法才返回失败；函数不执行 I/O、加锁或 yield，但会修改 cursor 和 Occupancy。
    static NavResult<PathAdvanceResult>
    AdvancePath(NavigationContext &context, const NavigationAgent &agent, const Path &path,
                PathFollowCursor &cursor, const WorldPosition &from, std::uint32_t distance_mm,
                const DynamicNavigationPolicy &policy);
};

} // namespace flywow_navigation
