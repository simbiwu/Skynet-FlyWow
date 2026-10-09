// 职责：按 mapId 保存当前已校验的 immutable GridMap。
// 边界：Server Runtime 进程级资产目录；启动加载或显式热更时替换当前地图。
// 输入/输出：BMAP 路径或 mapId -> shared_ptr<const GridMap> 或明确错误。
// 生命周期：Registry 持有当前地图；已有 Context 通过 shared_ptr 保留创建时的地图。
// 不负责：不执行 Cell 查询、不保存动态单位、不承担高频寻路代理。
#pragma once

#include "bmap_reader.h"
#include "grid_map.h"
#include "nav_result.h"

#include <cstddef>
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
    /// 返回进程级 Registry；首次初始化由 C++ 保证线程安全。
    /// @return 进程唯一的地图 Registry。
    static MapRegistry &Instance();

    /// 读取并校验完整 BMAP，然后按 map_id 替换当前地图。
    /// 文件 I/O 和校验在锁外执行；已有 Context 持有旧 shared_ptr，不受替换影响。
    /// @param path BMAP 资产文件路径。
    /// @return 当前加载的 immutable 地图；文件错误时返回具体 NavError。
    NavResult<std::shared_ptr<const GridMap>> Load(const std::string &path);

    /// 按 map_id 取得当前地图；map_version 不参与资产选择。
    /// @param map_id BMAP Header 中的业务地图 ID。
    /// @return 共享所有权的 immutable 地图；不存在时返回 kMapNotFound。
    NavResult<std::shared_ptr<const GridMap>> Find(std::uint32_t map_id) const;

    /// 返回 Registry 当前保存的不同 map_id 数量。
    /// @return 当前地图数量。
    std::size_t map_count() const;

  private:
    MapRegistry() = default;

    mutable std::mutex mutex_; // 只保护当前地图表；不包围 Grid 查询或文件读取。
    std::unordered_map<std::uint32_t, std::shared_ptr<const GridMap>>
        maps_; // 每个 map_id 只保存最新地图。
};

} // namespace flywow_navigation
