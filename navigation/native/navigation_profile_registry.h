// 职责：进程级发布并保存按 unit_id 排序的只读 NavigationProfile 快照。
#pragma once

#include "navigation_profile.h"
#include "nav_result.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace flywow_navigation
{

class NavigationProfileRegistry final
{
  public:
    using SnapshotType = std::vector<NavigationProfile>;

    // 返回进程级 Registry；首次构造由 C++ 保证线程安全。
    static NavigationProfileRegistry &Instance();

    /// 校验完整 Profile 表后替换当前快照；调用方持有的旧快照在本次调用结束后释放。
    /// @param navigation_profiles 各项使用稳定 unit_id；允许 ID 有空洞，但不能重复或为 0。
    /// @return 成功返回 true；非法 ID 返回明确导航错误。
    NavResult<bool> Load(std::vector<NavigationProfile> navigation_profiles);

    /// 取得当前只读快照；调用方只在本次同步操作期间持有返回值。
    /// @return Registry 当前快照；尚未加载时返回空指针。
    std::shared_ptr<const SnapshotType> Snapshot() const;

  private:
    NavigationProfileRegistry() = default;

    mutable std::mutex mutex_; // 只保护当前快照的读取和替换。
    std::shared_ptr<const SnapshotType> profiles_; // Registry 只持有最新快照。
};

} // namespace flywow_navigation
