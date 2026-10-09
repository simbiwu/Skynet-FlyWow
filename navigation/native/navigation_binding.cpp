// 职责：用 LuaBinding/LuaTable 在 Lua 合同与 Native 导航类型之间转换。
// 边界：Server Runtime；不 yield，不包含 Skynet 业务，不自行操作 Lua 栈。
// 生命周期：Context/Path 由 Lua userdata 独占；Context 固定共享只读地图与 Profile 快照。
// 不保存全局 mutable scratch；每个 Battle 的 occupancy 和 Path cursor 独立。
#include "navigation_binding.h"
#include "navigation_profile.h"
#include "navigation_profile_registry.h"
#include "grid_pathfinder.h"
#include "lua_binding.h"
#include "lua_table.h"
#include "map_registry.h"
#include "navigation_context.h"
#include "navigation_path.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace
{
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
using flywow_navigation::NavigationProfileRegistry;
using flywow_navigation::DynamicNavigationPolicy;
using flywow_navigation::CellDynamicEntryRule;
using flywow_navigation::GridPos;
using flywow_navigation::MapRegistry;
using flywow_navigation::NavigationAgent;
using flywow_navigation::NavigationAgentHandle;
using flywow_navigation::WorldPosition;

// 固定类型名只读共享；用 string 常量避免每次访问 userdata 都临时分配同一份长名称。
const std::string     kContextMeta     = "flywow_navigation.NavigationContext";
const std::string     kPathMeta        = "flywow_navigation.Path";
constexpr const char *kInvalidArgument = "INVALID_ARGUMENT";

using NavigationProfileSnapshot = NavigationProfileRegistry::SnapshotType;
using NavigationProfileSnapshotPtr = std::shared_ptr<const NavigationProfileSnapshot>;

struct LuaNavigationContext
{
    std::unique_ptr<flywow_navigation::NavigationContext> context; // 当前 Lua State 独占。
    bool closed = false; // close 后保留外壳，拒绝业务访问。
};

struct LuaPath
{
    explicit LuaPath(flywow_navigation::Path value) : path(std::move(value))
    {
    }
    flywow_navigation::Path             path;   // userdata 独占 immutable Path 结果。
    flywow_navigation::PathFollowCursor cursor; // 这条路线自己的跟随进度，不能跨单位共享。
};

// 读取正 uint32 业务 ID；0 对通用 readValue 合法，但对当前地图/实体身份不合法。
bool readPositiveId(LuaBinding &lua_binding, int index, const char *name, std::uint32_t &output)
{
    if (!lua_binding.readValue(index, output))
    {
        return false;
    }
    if (output == 0)
    {
        lua_binding.setError(kInvalidArgument, std::string(name) + " must be positive uint32");
        return false;
    }
    return true;
}

bool readPositiveId(LuaBinding &lua_binding, const LuaTable &table, const char *name,
                    std::uint32_t &output)
{
    if (!table.readValue(name, output))
    {
        return false;
    }
    if (output == 0)
    {
        lua_binding.setError(kInvalidArgument, std::string(name) + " must be positive uint32");
        return false;
    }
    return true;
}

// 验证 self 类型与关闭状态；只借用 userdata，不转移 Native Context 的所有权。
bool readContext(LuaBinding &lua_binding, LuaNavigationContext *&output)
{
    if (!lua_binding.readUserdata(1, kContextMeta, output))
    {
        return false;
    }
    if (output->closed || output->context == nullptr)
    {
        lua_binding.setError("CONTEXT_CLOSED", "context is closed");
        return false;
    }
    return true;
}

// 对本次调用取得的不可变快照二分查找；快照由调用方持有到导航操作结束。
const flywow_navigation::NavigationProfile *findNavigationProfile(
    LuaBinding &lua_binding, const NavigationProfileSnapshot &profiles, std::uint32_t unit_id)
{
    const auto found = std::lower_bound(
        profiles.begin(), profiles.end(), unit_id,
        [](const flywow_navigation::NavigationProfile &profile, std::uint32_t id)
        {
            return profile.unit_id < id;
        });
    if (found == profiles.end() || found->unit_id != unit_id)
    {
        lua_binding.setError(
            flywow_navigation::NavErrorName(flywow_navigation::NavError::kInvalidAgent),
            "unit_id not found");
        return nullptr;
    }
    return &*found;
}

// Lua WorldPosition 是有符号 64 位毫米字段，不包含客户端轴转换。
bool readWorldPosition(const LuaTable &table, WorldPosition &output)
{
    WorldPosition position;
    if (!table.readValue("x_mm", position.x_mm) || !table.readValue("y_mm", position.y_mm) ||
        !table.readValue("z_mm", position.z_mm))
    {
        return false;
    }
    output = position;
    return true;
}

bool readWorldPosition(LuaBinding &lua_binding, int index, WorldPosition &output)
{
    LuaTable table;
    return lua_binding.readTable(index, table) && readWorldPosition(table, output);
}

// 位置结果复制为新 record；Table 析构只释放临时引用，returnValues 可继续持有结果。
LuaTable worldPositionTable(LuaBinding &lua_binding, const WorldPosition position)
{
    auto table = lua_binding.newTable();
    if (!table.writeValue("x_mm", position.x_mm) || !table.writeValue("y_mm", position.y_mm) ||
        !table.writeValue("z_mm", position.z_mm))
    {
        return {};
    }
    return table;
}

// area_cost_permille 使用业务 key=0..255；未配置保持默认 1000，不按 profiles 的 1-based 处理。
bool readAreaCosts(const LuaTable &table, flywow_navigation::NavigationProfile &profile)
{
    if (table.isNil("area_cost_permille"))
    {
        return true;
    }
    LuaTable costs;
    if (!table.readTable("area_cost_permille", costs))
    {
        return false;
    }
    for (int area = 0; area < 256; ++area)
    {
        if (!costs.isNil(area) && !costs.readValue(area, profile.area_cost_permille[area]))
        {
            return false;
        }
    }
    return true;
}

bool readAreaAllowed(const LuaTable &table, flywow_navigation::NavigationProfile &profile)
{
    if (table.isNil("area_allowed"))
    {
        return true;
    }
    LuaTable allowed;
    if (!table.readTable("area_allowed", allowed))
    {
        return false;
    }
    for (int area = 0; area < 256; ++area)
    {
        if (!allowed.isNil(area))
        {
            // 保留既有 Lua 真值合同：只有 nil/false 为假，数字 0 也为真。
            bool value = false;
            if (!allowed.readTruth(area, value))
            {
                return false;
            }
            profile.area_allowed[area] = value ? 1 : 0;
        }
    }
    return true;
}

// 将独立导航配置解析为按值 Profile；业务 UnitProfile 不经过此 Binding。
bool parseProfile(LuaBinding &lua_binding, const LuaTable &table,
                  flywow_navigation::NavigationProfile &output)
{
    auto profile = flywow_navigation::MakeDefaultNavigationProfile(1);
    if (!readPositiveId(lua_binding, table, "unit_id", profile.unit_id) ||
        !table.readValue("radius_mm", profile.radius_mm) ||
        !table.readValue("max_step_mm", profile.max_step_mm) ||
        !table.readValue("max_slope_permille", profile.max_slope_permille) ||
        !readAreaCosts(table, profile) || !readAreaAllowed(table, profile))
    {
        return false;
    }

    const auto valid = flywow_navigation::ValidateNavigationProfile(profile);
    if (!valid.ok())
    {
        lua_binding.setError(flywow_navigation::NavErrorName(valid.error), valid.detail);
        return false;
    }
    output = profile;
    return true;
}

// Lua 数组只负责承载配置项；Registry 发布前按 unit_id 排序并拒绝重复 ID。
bool readNavigationProfiles(LuaBinding &lua_binding, const LuaTable &table, std::size_t count,
                            std::vector<flywow_navigation::NavigationProfile> &profiles)
{
    profiles.reserve(count);
    for (std::size_t index = 1; index <= count; ++index)
    {
        LuaTable profile_table;
        flywow_navigation::NavigationProfile profile;
        if (!table.readTable(static_cast<std::int64_t>(index), profile_table) ||
            !parseProfile(lua_binding, profile_table, profile))
        {
            return false;
        }
        profiles.push_back(profile);
    }
    return true;
}

// Grid 下标仅作为查询调试信息；长期业务位置仍使用整数毫米 WorldPosition。
/// load_map(path)：读取并校验完整 BMAP，按 map_id 替换当前地图；已有 Context 继续持有旧地图。
int loadMap(lua_State *state)
{
    LuaBinding lua_binding(state);
    void *registry_pointer = nullptr;
    std::string path;
    if (!lua_binding.readUpvalue(1, registry_pointer) || !lua_binding.readValue(1, path))
        return lua_binding.pushError();
    auto *maps = static_cast<MapRegistry *>(registry_pointer);
    const auto loaded = maps->Load(path.c_str());
    if (!loaded.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(loaded.error), loaded.detail);
    const auto &metadata = loaded.value->metadata();
    auto table = lua_binding.newTable();
    if (!table.writeValue("map_id", metadata.map_id) ||
        !table.writeValue("map_version", metadata.map_version))
        return lua_binding.pushError();
    return lua_binding.returnValues(table);
}

LuaTable cellResultTable(LuaBinding &lua_binding, const flywow_navigation::GridPos &grid,
                         const flywow_navigation::NavCell &cell)
{
    auto table = lua_binding.newTable();
    if (!table.writeValue("grid_x", grid.x) || !table.writeValue("grid_z", grid.z) ||
        !table.writeValue("cell_height_mm", cell.height_mm) ||
        !table.writeValue("area", cell.area_type) ||
        !table.writeValue("clearance", cell.clearance_cells) ||
        !table.writeValue("walkable", cell.IsWalkable()))
    {
        return {};
    }
    return table;
}

/// query_cell(id,version,position)：按当前 map_id 查询并校验资产版本；只读、不 yield。
int queryCell(lua_State *state)
{
    LuaBinding lua_binding(state);
    void         *registry_pointer = nullptr;
    std::uint32_t map_id           = 0; // 必填地图身份，由正数业务检查拒绝默认 0。
    std::uint32_t map_version      = 0;
    WorldPosition position;
    if (!lua_binding.readUpvalue(1, registry_pointer) ||
        !readPositiveId(lua_binding, 1, "map_id", map_id) ||
        !readPositiveId(lua_binding, 2, "map_version", map_version) ||
        !readWorldPosition(lua_binding, 3, position))
    {
        return lua_binding.pushError();
    }

    const auto found = static_cast<MapRegistry *>(registry_pointer)->Find(map_id);
    if (!found.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(found.error), found.detail);
    }
    if (found.value->metadata().map_version != map_version)
    {
        return lua_binding.pushError("MAP_VERSION_MISMATCH", "map_version does not match current map");
    }
    const auto grid = found.value->WorldToGrid(position);
    if (!grid.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(grid.error), grid.detail);
    }
    const auto cell = found.value->QueryWorld(position);
    if (!cell.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(cell.error), cell.detail);
    }
    auto table = cellResultTable(lua_binding, grid.value, cell.value);
    return table.valid() ? lua_binding.returnValues(table) : lua_binding.pushError();
}

/// load_navigation_profiles(profiles)：校验独立导航配置并原子替换当前只读表。
int loadNavigationProfiles(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaTable profiles;
    std::size_t profile_count = 0;
    if (!lua_binding.readTable(1, profiles) || !profiles.denseArrayLength(profile_count))
    {
        return lua_binding.pushError();
    }
    if (profile_count == 0)
    {
        return lua_binding.pushError(kInvalidArgument, "profiles must not be empty");
    }

    std::vector<flywow_navigation::NavigationProfile> navigation_profiles;
    if (!readNavigationProfiles(lua_binding, profiles, profile_count, navigation_profiles))
    {
        return lua_binding.pushError();
    }
    const auto loaded = NavigationProfileRegistry::Instance().Load(std::move(navigation_profiles));
    if (!loaded.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(loaded.error), loaded.detail);
    }
    return lua_binding.returnValues(true);
}

/// new_context(map_id)：固定当前地图和 Profile 快照，每场 Battle 独占动态状态。
int newContext(lua_State *state)
{
    LuaBinding lua_binding(state);
    void         *registry_pointer = nullptr;
    std::uint32_t map_id           = 0;
    if (!lua_binding.readUpvalue(1, registry_pointer) ||
        !readPositiveId(lua_binding, 1, "map_id", map_id))
    {
        return lua_binding.pushError();
    }

    const auto profiles = NavigationProfileRegistry::Instance().Snapshot();
    if (profiles == nullptr)
    {
        return lua_binding.pushError("INVALID_AGENT", "navigation profiles are not loaded");
    }
    const auto found = static_cast<MapRegistry *>(registry_pointer)->Find(map_id);
    if (!found.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(found.error), found.detail);
    }
    LuaNavigationContext *owner = nullptr; // Lua GC 管理外壳，本回调借用，不手动 delete。
    if (!lua_binding.newUserdata(kContextMeta, owner))
    {
        return lua_binding.pushError();
    }
    owner->context.reset(new flywow_navigation::NavigationContext(found.value));
    return lua_binding.returnValues(owner);
}

// 一次路径查询持有调用开始时的 Registry 快照，保证 Profile 指针在本次同步调用内有效。
struct PathQuery
{
    LuaNavigationContext                  *owner = nullptr;
    NavigationProfileSnapshotPtr              profiles;
    const flywow_navigation::NavigationProfile *profile = nullptr;
    WorldPosition                          start;
    WorldPosition                          target;
};

bool readPathQuery(LuaBinding &lua_binding, PathQuery &query)
{
    std::uint32_t unit_id = 0;
    if (!readContext(lua_binding, query.owner) ||
        !readPositiveId(lua_binding, 2, "unit_id", unit_id))
    {
        return false;
    }
    query.profiles = NavigationProfileRegistry::Instance().Snapshot();
    if (query.profiles == nullptr)
    {
        lua_binding.setError("INVALID_AGENT", "navigation profiles are not loaded");
        return false;
    }
    query.profile = findNavigationProfile(lua_binding, *query.profiles, unit_id);
    return query.profile != nullptr && readWorldPosition(lua_binding, 3, query.start) &&
           readWorldPosition(lua_binding, 4, query.target);
}

/// find_path(unit_id,start,end,self_id)：同步规划，返回独占 Path/cursor。
int findPath(lua_State *state)
{
    LuaBinding lua_binding(state);
    PathQuery     query;
    std::uint32_t self_id = 0;
    bool          allow_partial = false;
    if (!lua_binding.readOptionalValue(6, allow_partial) || !readPathQuery(lua_binding, query) ||
        !readPositiveId(lua_binding, 5, "unit_instance_id", self_id))
    {
        return lua_binding.pushError();
    }

    const NavigationAgent         agent{NavigationAgentHandle{self_id}, query.profile};
    const DynamicNavigationPolicy policy{};
    auto                          result = flywow_navigation::GridPathfinder::FindPath(
        *query.owner->context, agent, query.start, query.target, policy, allow_partial);
    if (!result.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);
    }
    LuaPath *path = nullptr;
    if (!lua_binding.newUserdata(kPathMeta, path, std::move(result.value)))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(path);
}

/// find_path_to_range：搜索进入指定通用中心距范围的可站立位置；不定义战斗规则。
int findPathToRange(lua_State *state)
{
    LuaBinding lua_binding(state);
    PathQuery     query;
    std::uint32_t range_mm = 0; // uint32 毫米距离，0 合法，不作为实体 ID 检查。
    std::uint32_t self_id  = 0;
    bool          allow_partial = false;
    if (!lua_binding.readOptionalValue(7, allow_partial) || !readPathQuery(lua_binding, query) ||
        !lua_binding.readValue(5, range_mm) ||
        !readPositiveId(lua_binding, 6, "unit_instance_id", self_id))
    {
        return lua_binding.pushError();
    }

    const NavigationAgent         agent{NavigationAgentHandle{self_id}, query.profile};
    const DynamicNavigationPolicy policy{};
    auto                          result = flywow_navigation::GridPathfinder::FindPathToRange(
        *query.owner->context, agent, query.start, query.target, range_mm, policy, allow_partial);
    if (!result.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);
    }
    LuaPath *path = nullptr;
    if (!lua_binding.newUserdata(kPathMeta, path, std::move(result.value)))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(path);
}

/// find_path_to_unit_range：按双方导航半径寻找合法接近点；不接收战斗攻击距离。
int findPathToUnitRange(lua_State *state)
{
    LuaBinding binding(state);
    LuaNavigationContext *owner = nullptr;
    std::uint32_t mover_unit_id = 0;
    std::uint32_t target_unit_id = 0;
    std::uint32_t unit_instance_id = 0;
    WorldPosition start{}, target{};
    bool allow_partial = false;
    if (!readContext(binding, owner) || !readPositiveId(binding, 2, "mover_unit_id", mover_unit_id) ||
        !readWorldPosition(binding, 3, start) ||
        !readPositiveId(binding, 4, "target_unit_id", target_unit_id) ||
        !readWorldPosition(binding, 5, target) ||
        !readPositiveId(binding, 6, "mover_unit_instance_id", unit_instance_id) ||
        !binding.readOptionalValue(7, allow_partial))
    {
        return binding.pushError();
    }

    const auto profiles = NavigationProfileRegistry::Instance().Snapshot();
    if (profiles == nullptr)
    {
        return binding.pushError("INVALID_AGENT", "navigation profiles are not loaded");
    }
    const auto *mover_profile = findNavigationProfile(binding, *profiles, mover_unit_id);
    const auto *target_profile = findNavigationProfile(binding, *profiles, target_unit_id);
    if (mover_profile == nullptr || target_profile == nullptr)
    {
        return binding.pushError();
    }

    const NavigationAgent mover{NavigationAgentHandle{unit_instance_id}, mover_profile};
    auto result = flywow_navigation::GridPathfinder::findPathToUnitRange(
        *owner->context, mover, start, *target_profile, target,
        DynamicNavigationPolicy{}, allow_partial);
    if (!result.ok())
    {
        return binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);
    }
    LuaPath *path = nullptr;
    return binding.newUserdata(kPathMeta, path, std::move(result.value))
               ? binding.returnValues(path)
               : binding.pushError();
}

// 出生与移动本次调用持有 Registry 快照，handle 使用运行时 unit_instance_id。
bool readMoveAgent(LuaBinding &lua_binding, LuaNavigationContext *&owner,
                   NavigationProfileSnapshotPtr &profiles, NavigationAgent &agent)
{
    std::uint32_t unit_id = 0;
    std::uint32_t unit_instance_id = 0;
    if (!readContext(lua_binding, owner) ||
        !readPositiveId(lua_binding, 2, "unit_id", unit_id) ||
        !readPositiveId(lua_binding, 3, "unit_instance_id", unit_instance_id))
    {
        return false;
    }

    profiles = NavigationProfileRegistry::Instance().Snapshot();
    if (profiles == nullptr)
    {
        lua_binding.setError("INVALID_AGENT", "navigation profiles are not loaded");
        return false;
    }
    const auto *profile = findNavigationProfile(lua_binding, *profiles, unit_id);
    if (profile == nullptr)
    {
        return false;
    }
    agent = NavigationAgent{NavigationAgentHandle{unit_instance_id}, profile};
    return true;
}

// 缓存路径生成后动态事实会变化；提交必须重新验证跨格及对角侧格。
// 出生用 from==to 的 MoveUnit；不能直接写 Occupancy 绕过静态/动态和业务规则。
int commitMove(LuaBinding &lua_binding, LuaNavigationContext &owner, const NavigationAgent &agent,
               const WorldPosition from, const WorldPosition to)
{
    // 先准备权威位置；归格失败时尚未写入 Occupancy，不需要回滚原 footprint。
    const auto grid = owner.context->map()->WorldToGrid(to);
    if (!grid.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(grid.error), grid.detail);
    }
    auto normalized = owner.context->map()->GridToWorldCenter(grid.value);
    if (!normalized.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(normalized.error),
                                     normalized.detail);
    }

    const DynamicNavigationPolicy policy{};
    const auto                    moved =
        flywow_navigation::GridPathfinder::MoveUnit(*owner.context, agent, from, to, policy);
    if (!moved.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(moved.error), moved.detail);
    }
    // Battle 正式位置保留输入 XZ；Y 由 Server BMAP 高度决定，不用折线 Y 插值。
    normalized.value.x_mm = to.x_mm;
    normalized.value.z_mm = to.z_mm;
    auto table            = worldPositionTable(lua_binding, normalized.value);
    return table.valid() ? lua_binding.returnValues(table) : lua_binding.pushError();
}

/// place_unit：出生也是一次正常占位提交；失败不改变现有动态事实。
int placeUnit(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    NavigationProfileSnapshotPtr profiles;
    NavigationAgent agent;
    WorldPosition world;
    if (!readMoveAgent(lua_binding, owner, profiles, agent) ||
        !readWorldPosition(lua_binding, 4, world))
    {
        return lua_binding.pushError();
    }
    return commitMove(lua_binding, *owner, agent, world, world);
}

/// move_unit：复验当前子步并提交占位，成功返回 Server 地表 Y 归一的世界位置。
int moveUnit(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    NavigationProfileSnapshotPtr profiles;
    NavigationAgent agent;
    WorldPosition from;
    WorldPosition         to;
    if (!readMoveAgent(lua_binding, owner, profiles, agent) ||
        !readWorldPosition(lua_binding, 4, from) ||
        !readWorldPosition(lua_binding, 5, to))
    {
        return lua_binding.pushError();
    }
    return commitMove(lua_binding, *owner, agent, from, to);
}

struct AdvanceRequest
{
    LuaPath *path = nullptr; // request.path 保留 Lua 引用，本回调只借用。
    std::uint32_t unit_id = 0; // 静态 Unit 类型 ID，用于本次 Registry 查找。
    std::uint32_t unit_instance_id = 0; // 当前 Battle 中实体实例的动态句柄。
    std::uint32_t distance_mm = 0; // 本次 fixed-tick 预算，0 合法。
    WorldPosition from_world;
};

bool readAdvanceRequest(LuaBinding &lua_binding, AdvanceRequest &request)
{
    LuaTable table;
    LuaTable from;
    return lua_binding.readTable(2, table) &&
           readPositiveId(lua_binding, table, "unit_id", request.unit_id) &&
           readPositiveId(lua_binding, table, "unit_instance_id", request.unit_instance_id) &&
           table.readValue("distance_mm", request.distance_mm) &&
           table.readUserdata("path", kPathMeta, request.path) &&
           table.readTable("from_world", from) && readWorldPosition(from, request.from_world);
}

// Native 状态映射为稳定 Lua 字符串；未知枚举视为 Native 编程错误。
const char *pathAdvanceStatusName(flywow_navigation::PathAdvanceStatus status)
{
    switch (status)
    {
    case flywow_navigation::PathAdvanceStatus::kMoving:
        return "moving";
    case flywow_navigation::PathAdvanceStatus::kReached:
        return "reached";
    case flywow_navigation::PathAdvanceStatus::kBlocked:
        return "blocked";
    }
    return nullptr;
}

LuaTable advanceResultTable(LuaBinding                                 &lua_binding,
                            const flywow_navigation::PathAdvanceResult &advanced)
{
    const char *status = pathAdvanceStatusName(advanced.status);
    if (status == nullptr)
    {
        lua_binding.setError("INTERNAL_ERROR", "unknown PathAdvanceStatus");
        return {};
    }
    auto table    = lua_binding.newTable();
    auto position = worldPositionTable(lua_binding, advanced.position);
    if (!position.valid() || !table.writeValue("status", status) ||
        !table.writeValue("position", position) ||
        !table.writeValue("consumed_mm", advanced.consumed_mm) ||
        !table.writeValue("moved", advanced.moved))
    {
        return {};
    }
    return table;
}

/// advance_path(request)：消费 fixed-tick 距离预算；blocked 是成功 result 状态。
/// request 的 path/from_world 本次同步借用；失败返回 nil,error。
int advancePath(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    AdvanceRequest        request;
    if (!readContext(lua_binding, owner) || !readAdvanceRequest(lua_binding, request))
    {
        return lua_binding.pushError();
    }
    const auto profiles = NavigationProfileRegistry::Instance().Snapshot();
    if (profiles == nullptr)
    {
        return lua_binding.pushError("INVALID_AGENT", "navigation profiles are not loaded");
    }
    const auto *profile = findNavigationProfile(lua_binding, *profiles, request.unit_id);
    if (profile == nullptr)
    {
        return lua_binding.pushError();
    }

    const NavigationAgent         agent{NavigationAgentHandle{request.unit_instance_id}, profile};
    const DynamicNavigationPolicy policy{};
    auto                          advanced = flywow_navigation::GridPathfinder::AdvancePath(
        *owner->context, agent, request.path->path, request.path->cursor, request.from_world,
        request.distance_mm, policy);
    if (!advanced.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(advanced.error),
                                     advanced.detail);
    }
    auto table = advanceResultTable(lua_binding, advanced.value);
    return table.valid() ? lua_binding.returnValues(table) : lua_binding.pushError();
}

/// cell_size_mm：只读地图边长，单位毫米。
int cellSizeMm(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    if (!readContext(lua_binding, owner))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(owner->context->map()->metadata().cell_size_mm);
}

// 读取 Lua 的规则名；default 删除当前格覆盖，恢复默认允许重叠行为。
bool readCellDynamicEntryRule(LuaBinding &lua_binding, int index, CellDynamicEntryRule &output)
{
    std::string           rule_name;
    if (!lua_binding.readValue(index, rule_name))
    {
        return false;
    }

    if (rule_name == "allow")
    {
        output = CellDynamicEntryRule::kAllow;
    }
    else if (rule_name == "block")
    {
        output = CellDynamicEntryRule::kBlock;
    }
    else if (rule_name != "default")
    {
        lua_binding.setError(kInvalidArgument, "rule must be 'allow', 'block', or 'default'");
        return false;
    }
    else
    {
        output = CellDynamicEntryRule::kDefault;
    }
    return true;
}

/// set_cell_rule(grid_x,grid_z,rule)：零基格坐标；rule 为 allow/block/default。
/// 成功返回 true；失败返回 nil,error。只影响当前 Battle，规则变化不移动已有单位。
int setCellRule(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    std::int32_t          grid_x = 0;
    std::int32_t          grid_z = 0;
    CellDynamicEntryRule  rule   = CellDynamicEntryRule::kDefault;
    if (!readContext(lua_binding, owner) || !lua_binding.readValue(2, grid_x) ||
        !lua_binding.readValue(3, grid_z) ||
        !readCellDynamicEntryRule(lua_binding, 4, rule))
    {
        return lua_binding.pushError();
    }
    const auto changed = owner->context->SetCellDynamicEntryRule(GridPos{grid_x, grid_z}, rule);
    if (!changed.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(changed.error),
                                     changed.detail);
    }
    return lua_binding.returnValues(true);
}

/// release_unit：释放该 handle 当前 footprint，成功返回 true。
int releaseUnit(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner   = nullptr;
    std::uint32_t unit_instance_id = 0;
    if (!readContext(lua_binding, owner) ||
        !readPositiveId(lua_binding, 2, "unit_instance_id", unit_instance_id))
    {
        return lua_binding.pushError();
    }
    const auto released = owner->context->occupancy().Release(NavigationAgentHandle{unit_instance_id});
    if (!released.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(released.error),
                                     released.detail);
    }
    return lua_binding.returnValues(true);
}

/// unit_radius_mm：每次调用按静态 unit_id 查询当前 Registry 的导航半径。
int unitRadiusMm(lua_State *state)
{
    LuaBinding binding(state);
    LuaNavigationContext *owner = nullptr;
    std::uint32_t unit_id = 0;
    if (!readContext(binding, owner) || !readPositiveId(binding, 2, "unit_id", unit_id))
    {
        return binding.pushError();
    }
    const auto profiles = NavigationProfileRegistry::Instance().Snapshot();
    if (profiles == nullptr)
    {
        return binding.pushError("INVALID_AGENT", "navigation profiles are not loaded");
    }
    const auto *profile = findNavigationProfile(binding, *profiles, unit_id);
    return profile == nullptr ? binding.pushError()
                              : binding.returnValues(profile->radius_mm);
}

/// map_version：返回该 Context 固定地图的资产版本。
int mapVersion(lua_State *state)
{
    LuaBinding binding(state);
    LuaNavigationContext *owner = nullptr;
    if (!readContext(binding, owner))
    {
        return binding.pushError();
    }
    return binding.returnValues(owner->context->map()->metadata().map_version);
}

/// close：幂等释放大块 Context 内存；userdata 外壳由统一 GC 最终析构。
int closeContext(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    if (!lua_binding.readUserdata(1, kContextMeta, owner))
    {
        return lua_binding.pushError();
    }
    if (!owner->closed)
    {
        owner->context.reset();
        owner->closed = true;
    }
    return lua_binding.returnValues();
}

/// count：返回 Path 世界点数量，不修改 Path。
int pathCount(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaPath *path = nullptr;
    if (!lua_binding.readUserdata(1, kPathMeta, path))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(path->path.count());
}

/// world_point：Lua 1-based index 对应的毫米 WorldPosition；越界返回 nil,error。
int pathWorldPoint(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaPath     *path  = nullptr;
    std::int64_t index = 0; // Lua 下标先保留有符号值，验证后转为 Native 0-based。
    if (!lua_binding.readUserdata(1, kPathMeta, path) || !lua_binding.readValue(2, index))
    {
        return lua_binding.pushError();
    }
    if (index <= 0 || static_cast<std::uint64_t>(index) > path->path.count())
    {
        return lua_binding.pushError(kInvalidArgument, "path index out of range");
    }
    auto table =
        worldPositionTable(lua_binding, path->path.WorldPoint(static_cast<std::size_t>(index - 1)));
    return table.valid() ? lua_binding.returnValues(table) : lua_binding.pushError();
}

/// length_mm：XZ 折线总长度，单位毫米。
int pathLengthMm(lua_State *state)
{
    LuaBinding lua_binding(state);
    LuaPath *path = nullptr;
    if (!lua_binding.readUserdata(1, kPathMeta, path))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(path->path.length_mm());
}

/// status：查询终点 reached/partial，不代表单位已走完路径。
int pathStatus(lua_State *state)
{
    LuaBinding binding(state);
    LuaPath   *path = nullptr;
    if (!binding.readUserdata(1, kPathMeta, path))
    {
        return binding.pushError();
    }
    return binding.returnValues(path->path.status());
}

// 在当前 State 注册一次类型与方法；方法表和 metatable 都是普通 LuaTable。
bool registerPath(LuaBinding &lua_binding)
{
    LuaTable meta;
    if (!lua_binding.registerUserdata<LuaPath>(kPathMeta, meta))
    {
        return false;
    }
    auto methods = lua_binding.newTable();
    return methods.setFunction("count", &pathCount) && methods.setFunction("status", &pathStatus) &&
           methods.setFunction("world_point", &pathWorldPoint) &&
           methods.setFunction("length_mm", &pathLengthMm) && meta.writeValue("__index", methods);
}

bool registerContext(LuaBinding &lua_binding)
{
    LuaTable meta;
    if (!lua_binding.registerUserdata<LuaNavigationContext>(kContextMeta, meta))
    {
        return false;
    }
    auto methods = lua_binding.newTable();
    return methods.setFunction("find_path", &findPath) &&
           methods.setFunction("set_cell_rule", &setCellRule) &&
           methods.setFunction("find_path_to_range", &findPathToRange) &&
           methods.setFunction("find_path_to_unit_range", &findPathToUnitRange) &&
           methods.setFunction("place_unit", &placeUnit) &&
           methods.setFunction("move_unit", &moveUnit) &&
           methods.setFunction("release_unit", &releaseUnit) &&
           methods.setFunction("advance_path", &advancePath) &&
           methods.setFunction("cell_size_mm", &cellSizeMm) &&
           methods.setFunction("unit_radius_mm", &unitRadiusMm) &&
           methods.setFunction("map_version", &mapVersion) &&
           methods.setFunction("close", &closeContext) && meta.writeValue("__index", methods);
}

// Registry 是进程级只读地图集合；可变 context/scratch 不共享。
} // namespace

extern "C" int luaopen_flywow_navigation_native(lua_State *state)
{
    LuaBinding lua_binding(state);
    if (!registerContext(lua_binding) || !registerPath(lua_binding))
    {
        return lua_binding.pushError();
    }
    auto  module = lua_binding.newTable();
    void *maps   = &MapRegistry::Instance(); // closure 只借用，单例 owner 覆盖所有 State。
    if (!module.setFunction("load_navigation_profiles", &loadNavigationProfiles) ||
        !module.setFunction("load_map", &loadMap, maps) ||
        !module.setFunction("query_cell", &queryCell, maps) ||
        !module.setFunction("new_context", &newContext, maps))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(module);
}
