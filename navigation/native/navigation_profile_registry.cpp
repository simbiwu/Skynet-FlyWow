// 职责：实现 NavigationProfile 快照校验、发布和线程安全读取。
#include "navigation_profile_registry.h"

#include <algorithm>
#include <utility>

namespace flywow_navigation
{

NavigationProfileRegistry &NavigationProfileRegistry::instance()
{
    static NavigationProfileRegistry registry;
    return registry;
}

NavResult<bool> NavigationProfileRegistry::load(std::vector<NavigationProfile> navigation_profiles)
{
    if (navigation_profiles.empty())
    {
        return NavResult<bool>::failure(NavError::kInvalidAgent,
                                        "navigation profiles must not be empty");
    }

    // 在锁外排序和校验整份输入；失败不会替换当前可用快照。
    std::sort(navigation_profiles.begin(), navigation_profiles.end(),
              [](const NavigationProfile &lhs, const NavigationProfile &rhs)
              { return lhs.unit_id < rhs.unit_id; });

    for (std::size_t index = 0; index < navigation_profiles.size(); ++index)
    {
        const auto valid = validateNavigationProfile(navigation_profiles[index]);
        if (!valid.ok())
        {
            return valid;
        }
        if (index > 0 &&
            navigation_profiles[index - 1].unit_id == navigation_profiles[index].unit_id)
        {
            return NavResult<bool>::failure(NavError::kInvalidAgent,
                                            "navigation profile unit_id must be unique");
        }
    }

    // 构建完成后才获取发布锁；查询者持有的旧 shared_ptr 继续有效。
    auto snapshot = std::make_shared<const SnapshotType>(std::move(navigation_profiles));
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_contexts_ != 0)
    {
        return NavResult<bool>::failure(NavError::kProfilesInUse,
                                        "close all navigation contexts before replacing profiles");
    }
    profiles_ = std::move(snapshot);
    return NavResult<bool>::success(true);
}

// 所有可失败的构造步骤已完成；与配置发布串行登记，不再额外保存 Profile 快照。
void NavigationProfileRegistry::acquireContext()
{
    std::lock_guard<std::mutex> lock(mutex_);
    ++active_contexts_;
}

// 会话停止导航操作后才注销；与 load 使用同一把锁，最后一个 owner 释放后才能换表。
void NavigationProfileRegistry::releaseContext()
{
    std::lock_guard<std::mutex> lock(mutex_);
    --active_contexts_;
}

std::shared_ptr<const NavigationProfileRegistry::SnapshotType>
NavigationProfileRegistry::snapshot() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return profiles_;
}

} // namespace flywow_navigation
