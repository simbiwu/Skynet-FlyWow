// 职责：实现 Battle-local 动态 footprint 事实索引和统一 Move 更新。
// 边界：Server Runtime Mutable Navigation State；只读 GridMap，不访问全局 Registry。
// 输入/输出：NavigationAgentHandle + 目标中心 Cell -> 事实更新或明确参数/越界错误。
// 生命周期：由 NavigationContext 持有；无锁、无 I/O、无 yield。
// 不负责：不判断实体冲突规则；冲突由 GridPathfinder 调用的业务回调负责。
#include "dynamic_occupancy.h"

#include <algorithm>

namespace flywow_navigation
{

// 两份索引记录同一事实：occupants_[格] 找“谁在这里”，footprints_[实体] 找“它占哪些格”。
// Move/Release 必须同时维护两边；同格可以登记多个句柄，是否冲突由查询策略决定。

// ---- 索引与单格维护 ----

// 构造本 Battle 的空动态事实索引。
// map：由 NavigationContext 共享且在本对象生命周期内保持有效的 immutable GridMap。
// 返回/失败：无返回值；Cell 数量过大或内存不足按构造异常传播。
// 不执行 I/O、加锁或 yield；构造时为 Cell 列表分配初始容器。
DynamicOccupancy::DynamicOccupancy(const GridMap &map) : map_(map), occupants_(map.cell_count())
{
}

// 把合法 GridPos 转成 row-major Cell 列表下标。
// grid：当前 map 内的 Grid 坐标；调用者必须先完成边界检查。
// 返回值：occupants_ 的下标；不执行 I/O、分配或修改状态。
std::size_t DynamicOccupancy::IndexOf(const GridPos &grid) const noexcept
{
    return static_cast<std::size_t>(grid.z) * map_.metadata().width +
           static_cast<std::size_t>(grid.x);
}

// 查找指定句柄当前登记的 footprint。
// handle：本 Context 内唯一的导航句柄。
// 返回值：找到时返回本对象拥有的记录指针，否则返回 nullptr；不转移所有权。
DynamicOccupancy::AgentFootprint *
DynamicOccupancy::FindFootprint(NavigationAgentHandle handle) noexcept
{
    for (AgentFootprint &footprint : footprints_)
    {
        if (footprint.handle == handle)
        {
            return &footprint;
        }
    }
    return nullptr;
}

// const 版本的 footprint 查找；不修改动态事实。
// handle：要查询的导航句柄。
// 返回值：记录的只读借用指针，找不到时为 nullptr。
const DynamicOccupancy::AgentFootprint *
DynamicOccupancy::FindFootprint(NavigationAgentHandle handle) const noexcept
{
    for (const AgentFootprint &footprint : footprints_)
    {
        if (footprint.handle == handle)
        {
            return &footprint;
        }
    }
    return nullptr;
}

// 从一个 Cell 的实体列表中删除指定句柄。
// grid：已确认在地图内的 Cell；handle：要删除的实体。
// 失败条件：无显式错误返回；不存在时保持列表不变。
void DynamicOccupancy::RemoveHandleAt(const GridPos &grid, NavigationAgentHandle handle)
{
    auto &occupants = occupants_[IndexOf(grid)];
    // remove 先将要保留的句柄挪到前面，并返回逻辑末尾；erase 才真正缩短 vector。
    // 例如 [A,B,A] 删除 A 后只保留 B，不会清空同格其他实体。
    occupants.erase(std::remove(occupants.begin(), occupants.end(), handle), occupants.end());
}

// 向一个 Cell 的实体列表加入句柄，并保持同一实体只有一份事实。
// grid：已确认在地图内的 Cell；handle：要加入的实体。
// 失败条件：无显式错误返回；内存分配异常由调用者按 C++ 异常规则处理。
void DynamicOccupancy::AddHandleAt(const GridPos &grid, NavigationAgentHandle handle)
{
    auto &occupants = occupants_[IndexOf(grid)];
    if (std::find(occupants.begin(), occupants.end(), handle) == occupants.end())
    {
        occupants.push_back(handle);
    }
}

// ---- 只读事实查询：不作正式位置或冲突裁决 ----

// 返回一个 Cell 中任意一个实体句柄，供诊断和测试使用。
// grid：待查询的 Grid 坐标；越界或空 Cell 返回无效句柄。
// 不修改状态，不拥有返回值之外的业务对象。
NavigationAgentHandle DynamicOccupancy::FirstOccupantAt(const GridPos &grid) const noexcept
{
    if (map_.TryCell(grid) == nullptr)
    {
        return {};
    }
    const auto &occupants = occupants_[IndexOf(grid)];
    return occupants.empty() ? NavigationAgentHandle{} : occupants.front();
}

// 判断 Cell 是否存在除 ignore_handle 外的动态实体。
// grid：待查询的中心/footprint Cell；ignore_handle：只忽略当前移动者自己。
// 返回值：越界或存在其他实体时为 true；不修改状态。
bool DynamicOccupancy::IsBlocked(const GridPos        &grid,
                                 NavigationAgentHandle ignore_handle) const noexcept
{
    if (map_.TryCell(grid) == nullptr)
    {
        return true;
    }
    for (const NavigationAgentHandle handle : occupants_[IndexOf(grid)])
    {
        if (handle != ignore_handle)
        {
            return true;
        }
    }
    return false;
}

// 遍历 Agent 的完整 footprint，判断是否存在其他动态实体。
// profile：体型和半径规则；center：候选中心 Cell；ignore_handle：移动者句柄。
// 返回值：越界或任一 footprint Cell 被其他实体占用时为 true。
bool DynamicOccupancy::IsFootprintBlocked(const AgentProfile &profile, const GridPos &center,
                                          NavigationAgentHandle ignore_handle) const noexcept
{
    const bool available = ForEachFootprintCell(profile, center, [&](const GridPos &grid)
                                                { return !IsBlocked(grid, ignore_handle); });
    return !available;
}

// ---- 事实提交：先完整准备，再清旧写新 ----

// 原子更新一个实体的动态 footprint；首次调用等同于出生登记。
// handle：本 Context 内唯一且有效的句柄；profile：体型规则借用；target：目标中心 Cell。
// 返回值：成功返回 true；越界返回 OUT_OF_BOUNDS；无效句柄返回 INVALID_ARGUMENT。
// 失败时保持旧 footprint；函数不执行 I/O、加锁或 yield，复杂度为 footprint 数量加 Cell 列表维护成本。
NavResult<bool> DynamicOccupancy::Move(NavigationAgentHandle handle, const AgentProfile &profile,
                                       const GridPos &target)
{
    if (!handle.valid())
    {
        return NavResult<bool>::Failure(NavError::kInvalidArgument,
                                        "invalid NavigationAgentHandle");
    }

    // 先把整个目标覆盖范围收集完；半径较大的单位中心在图内，外围格仍可能越界。
    // 此时局部 target_cells 可以丢弃，原 footprint 与各 Cell 列表保持原样。
    std::vector<GridPos> target_cells;
    const bool           valid_target = ForEachFootprintCell(profile, target,
                                                             [&](const GridPos &grid)
                                                             {
                                                       target_cells.push_back(grid);
                                                       return true;
                                                   });
    if (!valid_target)
    {
        return NavResult<bool>::Failure(NavError::kOutOfBounds,
                                        "dynamic target footprint is outside map");
    }

    AgentFootprint *current = FindFootprint(handle);
    if (current == nullptr)
    {
        // 首次 Move：先把新记录准备好，再写入 Cell，避免半个新实体记录。
        AgentFootprint new_footprint;
        new_footprint.handle = handle;
        new_footprint.cells  = std::move(target_cells);
        for (const GridPos &grid : new_footprint.cells)
        {
            occupants_[IndexOf(grid)].reserve(occupants_[IndexOf(grid)].size() + 1);
        }
        // 先登记完整 footprint；前面的 reserve 已保证下面写入 Cell 列表不会再次分配。
        footprints_.push_back(std::move(new_footprint));
        const AgentFootprint &committed = footprints_.back();
        for (const GridPos &grid : committed.cells)
        {
            AddHandleAt(grid, handle);
        }
        return NavResult<bool>::Success(true);
    }

    // 例如旧 footprint 为 [A,B]，新范围为 [B,C]：必须清掉 A、保留一份 B、加入 C。
    // 先 reserve 所有目标列表；若分配失败，只是容量可能变了，占位事实还没变。
    // 准备完成后再清旧写新，避免写到一半发生扩容异常留下两个索引不一致。
    // 这里的“原子”是独占 Context 内的完整提交，不是跨线程同步；调用方不得并发使用。
    for (const GridPos &grid : target_cells)
    {
        occupants_[IndexOf(grid)].reserve(occupants_[IndexOf(grid)].size() + 1);
    }
    for (const GridPos &grid : current->cells)
    {
        RemoveHandleAt(grid, handle);
    }
    for (const GridPos &grid : target_cells)
    {
        AddHandleAt(grid, handle);
    }
    current->cells = std::move(target_cells);
    return NavResult<bool>::Success(true);
}

// 删除一个实体当前登记的全部 footprint。
// handle：要释放的有效句柄；重复释放返回成功；无效句柄返回 INVALID_ARGUMENT。
// 修改本对象拥有的动态事实，不执行 I/O、加锁或 yield。
NavResult<bool> DynamicOccupancy::Release(NavigationAgentHandle handle)
{
    if (!handle.valid())
    {
        return NavResult<bool>::Failure(NavError::kInvalidArgument,
                                        "invalid NavigationAgentHandle");
    }

    AgentFootprint *current = FindFootprint(handle);
    if (current == nullptr)
    {
        return NavResult<bool>::Success(true);
    }
    for (const GridPos &grid : current->cells)
    {
        RemoveHandleAt(grid, handle);
    }
    // 先按已记录的旧范围清理各格，再删除实体记录，避免丢了范围后留下幽灵占位。
    // remove_if 找出要删除的记录，erase 才改变容器长度。
    footprints_.erase(std::remove_if(footprints_.begin(), footprints_.end(),
                                     [&](const AgentFootprint &footprint)
                                     { return footprint.handle == handle; }),
                      footprints_.end());
    return NavResult<bool>::Success(true);
}

} // namespace flywow_navigation
