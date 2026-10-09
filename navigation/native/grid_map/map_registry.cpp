// 职责：实现当前地图快照的加载、替换和线程安全查找。
// 边界：Server Runtime 资产注册层；文件校验委托给 BMapReader。
// 输入/输出：路径或地图键 -> immutable GridMap shared_ptr 或 NavError。
// 不负责：不原地修改 GridMap；锁不覆盖文件 I/O 或地图查询。
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

    // 完整读取和校验已在锁外完成；此处只替换当前快照。
    const std::uint32_t map_id = loaded.value->metadata().map_id;
    std::lock_guard<std::mutex> lock(mutex_);
    maps_[map_id] = loaded.value;
    return loaded;
}

NavResult<std::shared_ptr<const GridMap>> MapRegistry::Find(std::uint32_t map_id) const
{
    std::lock_guard<std::mutex> lock(mutex_);
    const auto                  iterator = maps_.find(map_id);
    if (iterator == maps_.end())
    {
        std::ostringstream detail;
        detail << "map_id=" << map_id;
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
