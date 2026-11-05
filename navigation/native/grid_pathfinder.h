// 职责：声明 Grid 8-way A* 的静态和 Battle-local 动态路径查询入口。
// 边界：Server Runtime Native Navigation；内部使用 GridPos，外部只接受/返回 WorldPosition。
// 输入/输出：NavigationContext + NavigationProfile + A/B 世界坐标 -> Path 或显式 NavError。
// 生命周期：不保存全局状态；所有 scratch 和动态占用由调用者传入的 Context 拥有。
// 不负责：不调用 Skynet，不执行 Unity 表现，不实现局部 Steering/Crowd 避碰。
#pragma once

#include "navigation_agent.h"
#include "navigation_context.h"
#include "navigation_path.h"
#include "navigation_profile.h"
#include "navigation_query.h"

#include <cstdint>

namespace flywow_navigation
{
// 调用顺序：findPath 规划路线，advancePath 按 Tick 预算推进；底层 moveUnit
// 逐步复验和提交占位。只有 Path 并不能证明下一 Tick 的道路仍然空闲。
class GridPathfinder final
{
  public:
    /// 在 immutable GridMap 上寻找不读取动态占位的静态 A->B 路径。
    /// @param context 规划期间独占的查询缓冲和地图。
    /// @param profile 已校验的体型及地表通行配置。
    /// @param start 移动者的世界毫米起点，使用 X/Z 归格。
    /// @param end 调用方请求的世界毫米终点，地面高度由地图确定。
    /// @return 成功返回拥有 Path 数据的 NavResult；越界、不可达或参数非法返回明确 NavError。
    /// 不执行 I/O、加锁或 yield；A* 使用 Context scratch，最终 Path 可能分配结果数组。
    static NavResult<Path> findPathStatic(NavigationContext       &context,
                                          const NavigationProfile &profile,
                                          const WorldPosition &start, const WorldPosition &end);

    /// 在静态地图、Context 的 Battle-local 格子规则和业务回调上寻找 A->B 路径。
    /// @param context 提供本场战斗的地图、占位和独占搜索缓冲。
    /// @param agent 借用的移动者句柄和导航配置。
    /// @param start 移动者的当前世界毫米位置。
    /// @param end 请求的世界毫米终点。
    /// @param policy 借用至查询返回的动态规则及回调参数。
    /// @return 成功返回 Path；参数、静态规则或动态回调拒绝时返回明确 NavError。
    /// @param allow_partial 默认 false；开启后失败目标可返回最近可达且有进展的 partial Path。
    /// 动态状态只代表查询时刻的快照；真正跨格前仍必须调用 moveUnit 再次验证。
    static NavResult<Path> findPath(NavigationContext &context, const NavigationAgent &agent,
                                    const WorldPosition &start, const WorldPosition &end,
                                    const DynamicNavigationPolicy &policy,
                                    bool                           allow_partial = false);

    /// 诊断一条 Path 的每个 Grid Segment 是否仍符合静态地图规则。
    /// @param context 借用验证用的地图和查询环境。
    /// @param profile 借用移动者的体型及地表规则。
    /// @param path 待复验的只读世界毫米路线。
    /// @return 成功返回 true。空路径、越界、无效体型或非法边返回明确 NavError。
    /// 不修改 Occupancy、不执行 I/O、加锁或 yield；按 Segment 穿过的 Cell 数线性检查。
    static NavResult<bool> validatePathStatic(NavigationContext       &context,
                                              const NavigationProfile &profile, const Path &path);

    /// 用与 findPath 相同的动态策略复验 Path；结果仅代表调用时刻的动态事实。
    /// @param context 借用地图和当前占位，验证不修改占位。
    /// @param agent 本次同步调用所借用的实体句柄及配置。
    /// @param path 待复验的只读世界毫米路线。
    /// @param policy 借用至返回的动态通行规则。
    /// @return 成功返回 true。非法句柄/体型、越界或动态阻挡返回明确 NavError。
    static NavResult<bool> validatePath(NavigationContext &context, const NavigationAgent &agent,
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
    static NavResult<Path> findPathToRange(NavigationContext &context, const NavigationAgent &agent,
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

    /// 重新验证一个单位从 from 到 to 的单步移动，并在成功后原子提交动态 footprint。
    /// @param context 拥有地图和本场战斗占位的会话。
    /// @param agent 借用实体句柄及静态导航配置。
    /// @param from 当前已提交的世界毫米位置。
    /// @param to 待提交的世界毫米位置，须与 from 同格或相邻。
    /// @param policy 与 findPath 使用同一业务规则；成功后才更新 DynamicOccupancy。
    /// @return 成功返回 true；越界、非相邻、静态边或动态规则失败返回明确 NavError。
    static NavResult<bool> moveUnit(NavigationContext &context, const NavigationAgent &agent,
                                    const WorldPosition &from, const WorldPosition &to,
                                    const DynamicNavigationPolicy &policy);

    /// 沿同一实体独占的 Path 消耗一次 fixed-tick 距离预算。
    /// @param context 提供地图和待提交的动态占位。
    /// @param agent 本次同步调用借用的实体及导航配置。
    /// @param path 当前实体所跟随的只读路线。
    /// @param cursor 路径 userdata 独占的进度，每个成功子步后更新。
    /// @param from 当前权威世界毫米位置。
    /// @param distance_mm Battle 已结算的本 Tick 非负移动预算。
    /// @param policy 借用至调用结束的动态通行规则。
    /// @return 返回 moving/reached/blocked 及最后提交位置，非法参数返回 NavError。
    /// @note 路线、游标和位置必须属于同一实体。外力改位或换路时丢弃旧游标。
    static NavResult<PathAdvanceResult>
    advancePath(NavigationContext &context, const NavigationAgent &agent, const Path &path,
                PathFollowCursor &cursor, const WorldPosition &from, std::uint32_t distance_mm,
                const DynamicNavigationPolicy &policy);
};

} // namespace flywow_navigation
