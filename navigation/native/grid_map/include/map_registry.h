// 职责：按 mapId + mapVersion 注册和查找已经校验的 immutable GridMap。
// 边界：Server Runtime 进程级资产目录；启动阶段写入，Freeze 后只读查询。
// 输入/输出：BMAP 路径或地图键 -> shared_ptr<const GridMap> 或明确错误。
// 生命周期：进程级单例；地图由 Registry 的 shared_ptr 持有到进程退出。
// 不负责：不执行 Cell 查询、不保存动态单位、不承担高频寻路代理。
#pragma once

#include "bmap_reader.h"
#include "grid_map.h"
#include "nav_result.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace flywow_navigation
{

class MapRegistry final
{
  public:
    // 返回进程级 Registry；C++11 保证首次初始化线程安全。
    static MapRegistry &Instance();

    // 在锁外读取/校验 path，在短锁内按 Header mapId+version 注册地图。
    // 冻结或重复键返回明确错误；成功 shared_ptr 与 Registry 共享所有权。
    NavResult<std::shared_ptr<const GridMap>> Load(const std::string &path);
    // 把 Registry 从启动写入阶段切换为运行期只读；重复调用成功返回 false。
    NavResult<bool>                           Freeze();
    // 在线程安全短锁内查找地图，并返回共享所有权的 immutable 指针。
    // 找不到完整 mapId+version 键时返回 kMapNotFound。
    NavResult<std::shared_ptr<const GridMap>> Find(std::uint32_t map_id,
                                                   std::uint32_t map_version) const;
    // 在线程安全短锁内返回当前已注册地图数；主要用于启动日志和测试。
    std::size_t                               map_count() const;

  private:
    struct Key
    {
        std::uint32_t map_id;      // 业务地图 ID。
        std::uint32_t map_version; // 对应地图资产版本。

        bool operator==(const Key &other) const noexcept
        {
            return map_id == other.map_id && map_version == other.map_version;
        }
    };

    struct KeyHash
    {
        // hash 只用于分桶，不是内容 hash 或唯一身份；冲突时仍由 Key::operator==
        // 同时比较 map_id/version，因此不同版本不会仅凭 hash 相同被误认为同一地图。
        std::size_t operator()(const Key &key) const noexcept
        {
            return static_cast<std::size_t>(key.map_id) * 0x9e3779b1u ^ key.map_version;
        }
    };

    MapRegistry() = default;

    mutable std::mutex mutex_;          // 只保护 Registry 容器和冻结状态，不包围 Grid 查询。
    bool               frozen_ = false; // true 后拒绝新增地图，使运行期资产集合稳定。
    std::unordered_map<Key, std::shared_ptr<const GridMap>, KeyHash>
        maps_; // Registry 拥有的只读地图。
};

} // namespace flywow_navigation
