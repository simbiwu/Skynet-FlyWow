// 职责：定义 GridPathfinder 查询动态业务规则时使用的无分配回调合同。
// 边界：Server Runtime Native Navigation；只描述查询参数，不拥有 Battle 状态。
// 输入/输出：当前 NavigationAgent、候选 Cell、DynamicOccupancy 事实 -> 业务层允许/拒绝。
// 生命周期：回调 user_data 和其中引用必须覆盖一次 FindPath/MoveUnit 调用；查询不保存它们。
// 不负责：不实现阵营、实体类型、技能、碰撞规则，也不执行 I/O、Skynet call 或 yield。
#pragma once

#include "navigation_agent.h"

#include <cstdint>

namespace flywow_navigation
{

class DynamicOccupancy;
class GridMap;

// 区分规划查询和实际移动提交前查询；两者使用同一个业务规则，但时机不同。
enum class DynamicQueryPurpose : std::uint8_t
{
    kFindPath = 0, // A* 查看当前状态下候选 Cell 是否可进入。
    kMove     = 1, // 单步移动提交前再次查看最新状态。
};

// 回调收到的只读动态事实。
// agent、map、occupancy 都由当前调用方拥有；回调只能读取，不得保存引用或修改它们。
struct DynamicNavigationQuery
{
    const NavigationAgent  *agent     = nullptr; // 当前单位视图；不转移所有权。
    const GridMap          *map       = nullptr; // 当前 immutable 地图配置。
    const DynamicOccupancy *occupancy = nullptr; // 当前 Battle 的动态 footprint 事实索引。
    GridPos                 from{};              // 本次判断的来源中心 Cell。
    GridPos                 target{};            // 候选目标中心 Cell。
    DynamicQueryPurpose     purpose = DynamicQueryPurpose::kFindPath;
};

// 返回 true 表示业务层允许该 Agent 进入 target；false 表示该候选不可用。
// 不执行 I/O、分配、加锁或 yield；函数指针本身不拥有 user_data。
using DynamicEnterCallback = bool (*)(void *user_data, const DynamicNavigationQuery &query);

// 由 Battle/业务层传入的动态查询策略。
// callback 可以通过 query.agent->profile 和 query.occupancy 查询 footprint 与当前实体。
// callback 为空时仍执行 Context 的 Battle-local 格子规则，但不调用额外业务动态阻挡判断。
// callback 可以进一步拒绝 Context 已允许的进入，但不能放宽 Context 单格规则已禁止的重叠，
// 也不能在搜索途中移动单位来改变判断依据。
struct DynamicNavigationPolicy
{
    void                *user_data = nullptr; // 业务层状态；不由导航底层释放。
    DynamicEnterCallback callback  = nullptr; // 允许进入判断；只读、无 yield。
};

} // namespace flywow_navigation
