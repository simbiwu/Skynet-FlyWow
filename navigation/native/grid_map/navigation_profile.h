// 职责：定义地面单位在 Grid 导航中的静态通行规则。
// 边界：Server Runtime Navigation Input；由 Battle 配置创建，A* 只读使用。
// 输入/输出：单位体型、坡度和 Area 策略 -> Cell 可通行判定参数。
// 生命周期：由进程 Registry 发布为不可变快照；每次 Native 调用临时持有当前快照.
// 不负责：不保存单位当前位置，不保存动态占位，不执行寻路。
#pragma once

#include "bmap_format.h"
#include "nav_result.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace flywow_navigation
{

struct NavigationProfile
{
    std::uint32_t unit_id = 0; // Battle 内稳定 Profile ID；0 保留为非法值。
    std::int32_t  radius_mm   = 0; // 地面圆形 footprint 半径，毫米；合法范围 [0, INT32_MAX]。
    std::int32_t  max_step_mm = 0; // 相邻 Cell 允许的最大高度跳变，毫米；必须 >=0。
    std::uint32_t max_slope_permille = 0; // 高差/水平距离 *1000 的上限。

    // area_type 是 uint8，因此固定 256 项避免 map 查找和查询期动态分配。
    std::array<std::uint8_t, 256>  area_allowed{};       // 1=允许进入，0=禁止。
    std::array<std::uint16_t, 256> area_cost_permille{}; // 1000=基础成本，>=1000。
};

// 构造一份最常用的“全部 Area 允许、基础成本 1000”默认表。
// 仅分配/返回一个小值对象；不访问地图、不加锁、不 yield。
inline NavigationProfile MakeDefaultNavigationProfile(std::uint32_t unit_id)
{
    NavigationProfile profile;
    profile.unit_id = unit_id;
    profile.area_allowed.fill(1);
    profile.area_cost_permille.fill(1000);
    return profile;
}

// 验证 Profile 是否满足本课 A* 的整数成本与 Heuristic 前提。
// 成功返回 true；失败返回 kInvalidAgent + detail。
inline NavResult<bool> ValidateNavigationProfile(const NavigationProfile &profile)
{
    if (profile.unit_id == 0 || profile.radius_mm < 0 || profile.max_step_mm < 0)
    {
        return NavResult<bool>::Failure(NavError::kInvalidAgent,
                                        "agent id/radius/max_step is invalid");
    }

    for (std::size_t area = 0; area < profile.area_allowed.size(); ++area)
    {
        if (profile.area_allowed[area] == 0)
        {
            continue;
        }
        // 允许通行的地面不能比启发式采用的普通地面更便宜，否则 A* 的
        // “至少还要花多少成本”可能高估，出堆后不重开 CLOSED 的前提就不成立。
        if (profile.area_cost_permille[area] < 1000)
        {
            return NavResult<bool>::Failure(NavError::kInvalidAgent,
                                            "allowed area cost must be >= 1000 permille");
        }
    }
    return NavResult<bool>::Success(true);
}

// 把毫米制半径转换为第一课 clearance_cells 的保守需求。
// cell_size_mm 必须 >0；返回值至少为 1，并在 uint8 范围饱和。
inline std::uint8_t RequiredClearanceCells(const NavigationProfile &profile, std::uint32_t cell_size_mm)
{
    if (cell_size_mm == 0)
    {
        return std::numeric_limits<std::uint8_t>::max();
    }
    const std::uint64_t radius = static_cast<std::uint64_t>(profile.radius_mm);

    // 这是非负整数的向上除法 ceil(radius / cell_size_mm)。
    // 例如 radius=600、cell_size_mm=500 时，直接相除会得到 1，
    // 而 (600 + 500 - 1) / 500 得到 2，才能拒绝只有一格空间的 Cell。
    const std::uint64_t cells = (radius + cell_size_mm - 1) / cell_size_mm;

    // 半径为 0 的单位仍至少按一个 Cell 需求处理，避免把 clearance=0 的障碍格当成可站立格。
    const std::uint64_t at_least_one = cells == 0 ? 1 : cells;

    // BMAP 字段是 uint8_t；超出可表达范围时饱和为 255，而不是发生窄化回绕。
    return static_cast<std::uint8_t>(at_least_one > 255 ? 255 : at_least_one);
}

} // namespace flywow_navigation
