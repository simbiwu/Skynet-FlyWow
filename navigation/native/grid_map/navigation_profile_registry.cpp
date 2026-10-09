// 职责：实现 NavigationProfile 快照校验、发布和线程安全读取。
#include "navigation_profile_registry.h"

#include <algorithm>

#include <utility>

namespace flywow_navigation
{

NavigationProfileRegistry &NavigationProfileRegistry::Instance()
{
    static NavigationProfileRegistry registry;
    return registry;
}

NavResult<bool> NavigationProfileRegistry::Load(std::vector<NavigationProfile> navigation_profiles)
{
    if (navigation_profiles.empty())
    {
        return NavResult<bool>::Failure(NavError::kInvalidAgent,
                                        "navigation profiles must not be empty");
    }

    std::sort(navigation_profiles.begin(), navigation_profiles.end(),
              [](const NavigationProfile &lhs, const NavigationProfile &rhs)
              {
                  return lhs.unit_id < rhs.unit_id;
              });
    for (std::size_t index = 0; index < navigation_profiles.size(); ++index)
    {
        const auto valid = ValidateNavigationProfile(navigation_profiles[index]);
        if (!valid.ok())
        {
            return valid;
        }
        if (index > 0 && navigation_profiles[index - 1].unit_id == navigation_profiles[index].unit_id)
        {
            return NavResult<bool>::Failure(NavError::kInvalidAgent,
                                            "navigation profile unit_id must be unique");
        }
    }

    auto snapshot = std::make_shared<const SnapshotType>(std::move(navigation_profiles));
    std::lock_guard<std::mutex> lock(mutex_);
    profiles_ = std::move(snapshot);
    return NavResult<bool>::Success(true);
}

std::shared_ptr<const NavigationProfileRegistry::SnapshotType> NavigationProfileRegistry::Snapshot() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return profiles_;
}

} // namespace flywow_navigation
