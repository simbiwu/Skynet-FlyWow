// 职责：实现地图加载、去重、冻结和线程安全查找。
// 边界：Server Runtime 资产注册层；文件校验委托给 BMapReader。
// 输入/输出：路径或地图键 -> immutable GridMap shared_ptr 或 NavError。
// 不负责：锁不覆盖 GridMap 查询；不在运行期热改静态地图。
#include "map_registry.h"

#include <sstream>
#include <utility>

namespace flywow_navigation
{

// ---- 进程级资产目录：共享地图，不共享可变查询状态 ----

MapRegistry &MapRegistry::Instance()
{
    // 函数内 static 只构造一次；多线程首次调用的初始化由 C++ 保证同步。
    // 后续容器访问仍要显式加锁，static 本身不会让所有成员操作自动线程安全。
    static MapRegistry registry;
    return registry;
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Load(const std::string &path)
{
    // 文件 I/O 和 CRC 不占用 Registry Lock。
    NavResult<std::shared_ptr<const GridMap>> loaded = BMapReader::Read(path);
    if (!loaded.ok())
    {
        return loaded;
    }

    // 读取完成后再抢短锁：另一个线程可能已冻结或登记同键地图，
    // 因此必须在锁内复验，而不能依赖文件读取前观察到的状态。
    const BMapMetadata         &metadata = loaded.value->metadata();
    const Key                   key{metadata.map_id, metadata.map_version};
    // lock_guard 在作用域结束（包括提前 return 或异常）时解锁，不需要手写 unlock。
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_)
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kRegistryFrozen,
                                                                  "load attempted after freeze");
    }
    if (maps_.find(key) != maps_.end())
    {
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kDuplicateMap,
                                                                  "duplicate map/version");
    }

    // 同键拒绝替换，避免不同 Battle 在同一 map/version 下读取到不同内容。
    // shared_ptr 副本让 Registry 与调用方共同持有同一份不可变地图数据。
    maps_.emplace(key, loaded.value);
    return loaded;
}

NavResult<bool> MapRegistry::Freeze()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (frozen_)
    {
        // 已经冻结也是成功；value=false 表示这次没有发生状态转换。
        return NavResult<bool>::Success(false);
    }
    frozen_ = true;
    return NavResult<bool>::Success(true);
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Find(std::uint32_t map_id,
                                                            std::uint32_t map_version) const
{
    std::lock_guard<std::mutex> lock(mutex_);
    const auto                  iterator = maps_.find(Key{map_id, map_version});
    if (iterator == maps_.end())
    {
        std::ostringstream detail;
        detail << "map_id=" << map_id << " map_version=" << map_version;
        return NavResult<std::shared_ptr<const GridMap>>::Failure(NavError::kMapNotFound,
                                                                  detail.str());
    }
    // 在锁内复制 shared_ptr，离开函数后释放锁；调用方查询 Cell/A* 时不占 Registry 锁。
    return NavResult<std::shared_ptr<const GridMap>>::Success(iterator->second);
}

std::size_t MapRegistry::map_count() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return maps_.size();
}

} // namespace flywow_navigation
