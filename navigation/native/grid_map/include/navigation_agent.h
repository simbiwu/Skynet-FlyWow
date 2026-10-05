// 职责：定义导航层使用的实体句柄和 Agent 查询上下文。
// 边界：Server Runtime Native Navigation；不拥有业务实体，不保存 Battle 位置。
// 输入/输出：业务层提供稳定 opaque handle + AgentProfile -> 导航查询对象。
// 生命周期：NavigationAgent 只借用 profile；调用期间 profile 必须保持有效。
// 不负责：不把业务指针、Lua userdata 或具体业务 ID 直接存入导航资产。

#pragma once

#include "agent_profile.h"

#include <cstdint>

namespace flywow_navigation
{

// 导航层自己的实体身份；value 由调用方提供，导航层不解释其来源。
// 业务已有 uint64_t Handle 时可直接包装；业务使用指针时应先自行映射成稳定 token。
struct NavigationAgentHandle
{
    std::uint64_t value = 0; // 0 保留为无效句柄；同一 NavigationContext 内必须唯一。

    // 返回值：句柄非 0 时为 true；无 I/O、分配或状态修改。
    bool valid() const noexcept
    {
        return value != 0;
    }
};

// 比较两个导航句柄的数值身份；不访问业务对象。
inline bool operator==(const NavigationAgentHandle &lhs, const NavigationAgentHandle &rhs) noexcept
{
    return lhs.value == rhs.value;
}

// 比较两个导航句柄是否不同；不访问业务对象。
inline bool operator!=(const NavigationAgentHandle &lhs, const NavigationAgentHandle &rhs) noexcept
{
    return !(lhs == rhs);
}

// 一次导航查询所需的 Agent 视图。
// profile 可被多个 Agent 共享；handle 标识当前具体实体。
// 例如两个同体型单位共用一份 profile，但必须使用不同 handle，
// 否则忽略 self 的占位检查会把另一个单位也当成自己。
struct NavigationAgent
{
    NavigationAgentHandle handle;            // 当前实体的导航层身份。
    const AgentProfile   *profile = nullptr; // 共享静态导航配置；不转移所有权。
};

} // namespace flywow_navigation
