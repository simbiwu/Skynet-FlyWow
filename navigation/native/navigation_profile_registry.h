// 职责：进程级发布并保存按 unit_id 排序的只读 NavigationProfile 快照。
#pragma once

#include "nav_result.h"
#include "navigation_profile.h"

#include <cstddef>
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
    static NavigationProfileRegistry &instance();

    /// 无活跃 Context 时发布完整 Profile 表；占位会话存活期间拒绝替换。
    /// @param navigation_profiles 各项使用稳定 unit_id；允许 ID 有空洞，但不能重复或为 0。
    /// @return 成功 true；非法配置返回 INVALID_AGENT，有活跃 Context 返回 PROFILES_IN_USE。
    NavResult<bool> load(std::vector<NavigationProfile> navigation_profiles);

    /// 取得当前只读快照；调用方只在本次同步操作期间持有返回值。
    /// @return Registry 当前快照；尚未加载时返回空指针。
    std::shared_ptr<const SnapshotType> snapshot() const;

  private:
    NavigationProfileRegistry() = default;
    friend class NavigationContext;

    /// Context 完成构造后登记；与 load 共用发布锁，禁止替换活跃占位所依赖的规则。
    void acquireContext();
    /// Context 析构时注销；最后一个 owner 释放后允许发布新表。
    void releaseContext();

    std::size_t active_contexts_ =
        0; // 有效 Context 数；构造完成后登记，析构时注销，仅在 mutex_ 内访问。

    mutable std::mutex                  mutex_;    // 保护快照读取、活跃会话计数和配置发布门禁。
    std::shared_ptr<const SnapshotType> profiles_; // Registry 只持有最新快照。
};

} // namespace flywow_navigation
