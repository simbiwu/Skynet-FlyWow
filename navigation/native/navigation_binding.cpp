// 职责：用 LuaBinding/LuaTable 在 Lua 合同与 Native 导航类型之间转换。
// 边界：Server Runtime；不 yield，不包含 Skynet 业务，不自行操作 Lua 栈。
// 生命周期：Context/Path 由 Lua userdata 独占；Context 固定共享只读地图与 Profile 快照。
// 不保存全局 mutable scratch；每个 Battle 的 occupancy 和 Path cursor 独立。
#include "navigation_binding.h"
#include "grid_pathfinder.h"
#include "lua_binding.h"
#include "lua_table.h"
#include "map_registry.h"
#include "navigation_context.h"
#include "navigation_path.h"
#include "navigation_profile.h"
#include "navigation_profile_registry.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace
{
using flywow_lua_binding::LuaBinding;
using flywow_lua_binding::LuaTable;
using flywow_navigation::CellDynamicEntryRule;
using flywow_navigation::DynamicNavigationPolicy;
using flywow_navigation::GridPos;
using flywow_navigation::MapRegistry;
using flywow_navigation::NavigationAgent;
using flywow_navigation::NavigationAgentHandle;
using flywow_navigation::NavigationProfileRegistry;
using flywow_navigation::WorldPosition;

// 固定类型名只读共享；用 string 常量避免每次访问 userdata 都临时分配同一份长名称。
const std::string     kContextMeta     = "flywow_navigation.NavigationContext";
const std::string     kPathMeta        = "flywow_navigation.Path";
constexpr const char *kInvalidArgument = "INVALID_ARGUMENT";

using NavigationProfileSnapshot    = NavigationProfileRegistry::SnapshotType;
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
const flywow_navigation::NavigationProfile *
findNavigationProfile(LuaBinding &lua_binding, const NavigationProfileSnapshot &profiles,
                      std::uint32_t unit_id)
{
    const auto found = std::lower_bound(profiles.begin(), profiles.end(), unit_id,
                                        [](const flywow_navigation::NavigationProfile &profile,
                                           std::uint32_t id) { return profile.unit_id < id; });
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
        LuaTable                             profile_table;
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
    LuaBinding  lua_binding(state);
    void       *registry_pointer = nullptr;
    std::string path;
    if (!lua_binding.readUpvalue(1, registry_pointer) || !lua_binding.readValue(1, path))
        return lua_binding.pushError();
    auto       *maps = static_cast<MapRegistry *>(registry_pointer);
    std::string air_path;
    if (!lua_binding.readOptionalValue(2, air_path))
        return lua_binding.pushError();
    if (!lua_binding.isNoneOrNil(2) && air_path.empty())
        return lua_binding.pushError(kInvalidArgument, "explicit airnav path is empty");
    const auto loaded = maps->Load(path, air_path);
    if (!loaded.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(loaded.error), loaded.detail);
    const auto &metadata = loaded.value->metadata();
    // 已加载快照的完整BMAP身份；在Lua边界转为64位十六进制文本，不重新读取文件。
    constexpr char digits[] = "0123456789abcdef";
    std::string content_sha256(64, '0');
    const auto &hash = loaded.value->airAsset().bmap_hash;
    for (std::size_t i = 0; i < hash.size(); ++i)
    {
        content_sha256[i * 2] = digits[hash[i] >> 4];
        content_sha256[i * 2 + 1] = digits[hash[i] & 15];
    }
    auto        table    = lua_binding.newTable();
    if (!table.writeValue("map_id", metadata.map_id) ||
        !table.writeValue("map_version", metadata.map_version) ||
        !table.writeValue("content_sha256", content_sha256))
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
    LuaBinding    lua_binding(state);
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
        return lua_binding.pushError("MAP_VERSION_MISMATCH",
                                     "map_version does not match current map");
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
int load_navigation_profiles(lua_State *state)
{
    LuaBinding  lua_binding(state);
    LuaTable    profiles;
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

/// new_context(map_id[,air_limits])：固定地图；owner 独占动态状态，Profile 在地面操作时读取。
int newContext(lua_State *state)
{
    LuaBinding    lua_binding(state);
    void         *registry_pointer = nullptr;
    std::uint32_t map_id           = 0;
    if (!lua_binding.readUpvalue(1, registry_pointer) ||
        !readPositiveId(lua_binding, 1, "map_id", map_id))
    {
        return lua_binding.pushError();
    }

    // Context 只固定静态地图；纯空中调用不依赖 ground Profile。
    // 地面入口各自读取/校验当前 Profile，保持未配置时的 INVALID_AGENT 失败语义。
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
    if (!lua_binding.isNoneOrNil(2))
    {
        LuaTable                     limits;
        flywow_navigation::AirLimits air;
        if (!lua_binding.readTable(2, limits))
            return lua_binding.pushError();
        if (!limits.isNil("expanded") && !limits.readValue("expanded", air.expanded))
            return lua_binding.pushError();
        if (!limits.isNil("nodes") && !limits.readValue("nodes", air.nodes))
            return lua_binding.pushError();
        if (!limits.isNil("buckets") && !limits.readValue("buckets", air.buckets))
            return lua_binding.pushError();
        if (!limits.isNil("tests") && !limits.readValue("tests", air.tests))
            return lua_binding.pushError();
        if (!limits.isNil("path_points") && !limits.readValue("path_points", air.path_points))
            return lua_binding.pushError();
        if (!limits.isNil("objects") && !limits.readValue("objects", air.objects))
            return lua_binding.pushError();
        if (!limits.isNil("object_links") && !limits.readValue("object_links", air.object_links))
            return lua_binding.pushError();
        if (!limits.isNil("links") && !limits.readValue("links", air.links))
            return lua_binding.pushError();

        const auto valid = owner->context->setAirLimits(air);
        if (!valid.ok())
            return lua_binding.pushError(flywow_navigation::NavErrorName(valid.error),
                                         valid.detail);
    }

    return lua_binding.returnValues(owner);
}

// 一次路径查询持有调用开始时的 Registry 快照，保证 Profile 指针在本次同步调用内有效。
struct PathQuery
{
    LuaNavigationContext                       *owner = nullptr;
    NavigationProfileSnapshotPtr                profiles;
    const flywow_navigation::NavigationProfile *profile = nullptr;
    WorldPosition                               start;
    WorldPosition                               target;
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
    LuaBinding    lua_binding(state);
    PathQuery     query;
    std::uint32_t self_id       = 0;
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
    LuaBinding    lua_binding(state);
    PathQuery     query;
    std::uint32_t range_mm      = 0; // uint32 毫米距离，0 合法，不作为实体 ID 检查。
    std::uint32_t self_id       = 0;
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
int find_path_to_unit_range(lua_State *state)
{
    LuaBinding            binding(state);
    LuaNavigationContext *owner            = nullptr;
    std::uint32_t         mover_unit_id    = 0;
    std::uint32_t         target_unit_id   = 0;
    std::uint32_t         unit_instance_id = 0;
    WorldPosition         start{}, target{};
    bool                  allow_partial = false;
    if (!readContext(binding, owner) ||
        !readPositiveId(binding, 2, "mover_unit_id", mover_unit_id) ||
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
    const auto *mover_profile  = findNavigationProfile(binding, *profiles, mover_unit_id);
    const auto *target_profile = findNavigationProfile(binding, *profiles, target_unit_id);
    if (mover_profile == nullptr || target_profile == nullptr)
    {
        return binding.pushError();
    }

    const NavigationAgent mover{NavigationAgentHandle{unit_instance_id}, mover_profile};
    auto                  result = flywow_navigation::GridPathfinder::findPathToUnitRange(
        *owner->context, mover, start, *target_profile, target, DynamicNavigationPolicy{},
        allow_partial);
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
    std::uint32_t unit_id          = 0;
    std::uint32_t unit_instance_id = 0;
    if (!readContext(lua_binding, owner) || !readPositiveId(lua_binding, 2, "unit_id", unit_id) ||
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
int place_unit(lua_State *state)
{
    LuaBinding                   lua_binding(state);
    LuaNavigationContext        *owner = nullptr;
    NavigationProfileSnapshotPtr profiles;
    NavigationAgent              agent;
    WorldPosition                world;
    if (!readMoveAgent(lua_binding, owner, profiles, agent) ||
        !readWorldPosition(lua_binding, 4, world))
    {
        return lua_binding.pushError();
    }
    return commitMove(lua_binding, *owner, agent, world, world);
}

/// move_unit：复验当前子步并提交占位，成功返回 Server 地表 Y 归一的世界位置。
int move_unit(lua_State *state)
{
    LuaBinding                   lua_binding(state);
    LuaNavigationContext        *owner = nullptr;
    NavigationProfileSnapshotPtr profiles;
    NavigationAgent              agent;
    WorldPosition                from;
    WorldPosition                to;
    if (!readMoveAgent(lua_binding, owner, profiles, agent) ||
        !readWorldPosition(lua_binding, 4, from) || !readWorldPosition(lua_binding, 5, to))
    {
        return lua_binding.pushError();
    }
    return commitMove(lua_binding, *owner, agent, from, to);
}

struct AdvanceRequest
{
    LuaPath      *path             = nullptr; // request.path 保留 Lua 引用，本回调只借用。
    std::uint32_t unit_id          = 0;       // 静态 Unit 类型 ID，用于本次 Registry 查找。
    std::uint32_t unit_instance_id = 0;       // 当前 Battle 中实体实例的动态句柄。
    std::uint32_t distance_mm      = 0;       // 本次 fixed-tick 预算，0 合法。
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
int advance_path(lua_State *state)
{
    LuaBinding            lua_binding(state);
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
int cell_size_mm(lua_State *state)
{
    LuaBinding            lua_binding(state);
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
    std::string rule_name;
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
    LuaBinding            lua_binding(state);
    LuaNavigationContext *owner  = nullptr;
    std::int32_t          grid_x = 0;
    std::int32_t          grid_z = 0;
    CellDynamicEntryRule  rule   = CellDynamicEntryRule::kDefault;
    if (!readContext(lua_binding, owner) || !lua_binding.readValue(2, grid_x) ||
        !lua_binding.readValue(3, grid_z) || !readCellDynamicEntryRule(lua_binding, 4, rule))
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
int release_unit(lua_State *state)
{
    LuaBinding            lua_binding(state);
    LuaNavigationContext *owner            = nullptr;
    std::uint32_t         unit_instance_id = 0;
    if (!readContext(lua_binding, owner) ||
        !readPositiveId(lua_binding, 2, "unit_instance_id", unit_instance_id))
    {
        return lua_binding.pushError();
    }
    const auto released =
        owner->context->occupancy().Release(NavigationAgentHandle{unit_instance_id});
    if (!released.ok())
    {
        return lua_binding.pushError(flywow_navigation::NavErrorName(released.error),
                                     released.detail);
    }
    return lua_binding.returnValues(true);
}

/// unit_radius_mm：每次调用按静态 unit_id 查询当前 Registry 的导航半径。
int unit_radius_mm(lua_State *state)
{
    LuaBinding            binding(state);
    LuaNavigationContext *owner   = nullptr;
    std::uint32_t         unit_id = 0;
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
    return profile == nullptr ? binding.pushError() : binding.returnValues(profile->radius_mm);
}

/// map_version：返回该 Context 固定地图的资产版本。
int mapVersion(lua_State *state)
{
    LuaBinding            binding(state);
    LuaNavigationContext *owner = nullptr;
    if (!readContext(binding, owner))
    {
        return binding.pushError();
    }
    return binding.returnValues(owner->context->map()->metadata().map_version);
}

/// close：幂等释放大块 Context 内存；userdata 外壳由统一 GC 最终析构。
int close(lua_State *state)
{
    LuaBinding            lua_binding(state);
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
    LuaPath   *path = nullptr;
    if (!lua_binding.readUserdata(1, kPathMeta, path))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(path->path.count());
}

/// world_point：Lua 1-based index 对应的毫米 WorldPosition；越界返回 nil,error。
int pathWorldPoint(lua_State *state)
{
    LuaBinding   lua_binding(state);
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
    LuaPath   *path = nullptr;
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

// 空中入口全部使用具名 record；这里只转换合同，不维护第二套 Context/Path 类型。
bool readAirPolicy(const LuaTable &request, flywow_navigation::AirPolicy &policy)
{
    if (!request.isNil("check_terrain") &&
        !request.readValue("check_terrain", policy.check_terrain))
        return false;
    return request.isNil("clearance_mm") || request.readValue("clearance_mm", policy.clearance_mm);
}
bool readAirPosition(const LuaTable &request, const char *name, WorldPosition &position)
{
    LuaTable table;
    return request.readTable(name, table) && readWorldPosition(table, position);
}
bool readAirBody(const LuaTable &request, flywow_navigation::AirBody &body)
{
    LuaTable table;
    return request.readTable("body", table) && table.readValue("radius_mm", body.radius_mm) &&
           table.readValue("half_height_mm", body.half_height_mm);
}
int setAirObstacle(lua_State *state)
{
    LuaBinding                lua_binding(state);
    LuaNavigationContext     *owner = nullptr;
    LuaTable                  request;
    std::uint64_t             handle = 0;
    flywow_navigation::AirBox box;
    if (!readContext(lua_binding, owner) || !lua_binding.readTable(2, request) ||
        !request.readValue("handle", handle) || !readAirPosition(request, "min", box.min) ||
        !readAirPosition(request, "max", box.max))
        return lua_binding.pushError();

    const auto result = flywow_navigation::setAirObstacle(*owner->context, {handle}, box);
    if (!result.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);
    return lua_binding.returnValues(true);
}
int removeAirObstacle(lua_State *state)
{
    LuaBinding            lua_binding(state);
    LuaNavigationContext *owner = nullptr;
    LuaTable              request;
    std::uint64_t         handle = 0;
    if (!readContext(lua_binding, owner) || !lua_binding.readTable(2, request) ||
        !request.readValue("handle", handle))
        return lua_binding.pushError();

    const auto result = flywow_navigation::removeAirObstacle(*owner->context, {handle});
    if (!result.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);
    return lua_binding.returnValues(true);
}
int sweepAir(lua_State *state)
{
    LuaBinding                   lua_binding(state);
    LuaNavigationContext        *owner = nullptr;
    LuaTable                     request;
    WorldPosition                from, to;
    flywow_navigation::AirBody   body;
    flywow_navigation::AirPolicy policy;
    std::uint64_t                exclude = 0;
    if (!readContext(lua_binding, owner) || !lua_binding.readTable(2, request) ||
        !readAirPosition(request, "from", from) || !readAirPosition(request, "to", to) ||
        !readAirBody(request, body) || !readAirPolicy(request, policy) ||
        (!request.isNil("exclude_handle") && !request.readValue("exclude_handle", exclude)))
        return lua_binding.pushError();

    const auto result =
        flywow_navigation::sweepAir(*owner->context, from, to, body, {exclude}, policy);
    if (!result.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);

    auto        out  = lua_binding.newTable();
    const auto &hit  = result.value;
    const char *kind = hit.kind == flywow_navigation::AirHitKind::kClear    ? "clear"
                       : hit.kind == flywow_navigation::AirHitKind::kStatic ? "static"
                                                                            : "dynamic";
    // 完整 uint64 有理数可大于 Lua 正整数范围；十进制串保留精确值，不以浮点时间排序。
    if (!out.writeValue("kind", kind) || !out.writeValue("handle", hit.handle.value) ||
        !out.writeValue("cell_index", hit.cell_index) ||
        !out.writeValue("time_numerator", std::to_string(hit.time.numerator)) ||
        !out.writeValue("time_denominator", std::to_string(hit.time.denominator)))
        return lua_binding.pushError();
    return lua_binding.returnValues(out);
}
int findAirPath(lua_State *state)
{
    LuaBinding                   lua_binding(state);
    LuaNavigationContext        *owner = nullptr;
    LuaTable                     request;
    WorldPosition                from, to;
    flywow_navigation::AirBody   body;
    flywow_navigation::AirPolicy policy;
    std::uint64_t                exclude = 0;
    std::int64_t                 y       = 0;
    std::uint32_t                range   = 0;
    if (!readContext(lua_binding, owner) || !lua_binding.readTable(2, request) ||
        !readAirPosition(request, "start", from) || !readAirPosition(request, "target", to) ||
        !readAirBody(request, body) || !readAirPolicy(request, policy) ||
        !request.readValue("flight_y_mm", y) ||
        (!request.isNil("exclude_handle") && !request.readValue("exclude_handle", exclude)) ||
        (!request.isNil("range_mm") && !request.readValue("range_mm", range)))
        return lua_binding.pushError();

    auto result = flywow_navigation::findAirPath(*owner->context, from, to, y, body, {exclude},
                                                 policy, range);
    if (!result.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);

    LuaPath *path = nullptr;
    if (!lua_binding.newUserdata(kPathMeta, path, std::move(result.value)))
        return lua_binding.pushError();
    return lua_binding.returnValues(path);
}
int moveAir(lua_State *state)
{
    LuaBinding                   lua_binding(state);
    LuaNavigationContext        *owner = nullptr;
    LuaTable                     request;
    WorldPosition                target;
    flywow_navigation::AirPolicy policy;
    std::uint64_t                handle = 0;
    if (!readContext(lua_binding, owner) || !lua_binding.readTable(2, request) ||
        !request.readValue("handle", handle) || !readAirPosition(request, "target", target) ||
        !readAirPolicy(request, policy))
        return lua_binding.pushError();

    const auto result = flywow_navigation::moveAir(*owner->context, {handle}, target, policy);
    if (!result.ok())
        return lua_binding.pushError(flywow_navigation::NavErrorName(result.error), result.detail);

    auto out = worldPositionTable(lua_binding, result.value);
    return out.valid() ? lua_binding.returnValues(out) : lua_binding.pushError();
}
int advanceAirPath(lua_State *state)
{
    LuaBinding                   lua_binding(state);
    LuaNavigationContext        *owner = nullptr;
    LuaTable                     request;
    LuaPath                     *path = nullptr;
    flywow_navigation::AirPolicy policy;
    std::uint64_t                handle   = 0;
    std::uint32_t                distance = 0;
    if (!readContext(lua_binding, owner) || !lua_binding.readTable(2, request) ||
        !request.readValue("handle", handle) || !request.readUserdata("path", kPathMeta, path) ||
        !request.readValue("distance_mm", distance) || !readAirPolicy(request, policy))
        return lua_binding.pushError();

    const auto result = flywow_navigation::advanceAirPath(*owner->context, {handle}, path->path,
                                                          path->cursor, distance, policy);
    if (!result.ok())
    {
        // 推进可在后段失败前已有合法提交；错误 record 携带真实位置，Lua owner 不会丢失恢复依据。
        auto error = lua_binding.newTable();
        if (!error.writeValue("code", flywow_navigation::NavErrorName(result.error)) ||
            !error.writeValue("message", result.detail))
            return lua_binding.pushError();
        const auto &objects = owner->context->airState().objects;
        auto        it      = objects.find(handle);
        if (it != objects.end())
        {
            const auto         &box = it->second;
            WorldPosition       position{box.min.x_mm + (box.max.x_mm - box.min.x_mm) / 2, 0,
                                   box.min.z_mm + (box.max.z_mm - box.min.z_mm) / 2};
            const std::uint64_t y_bits =
                std::uint64_t(box.min.y_mm) +
                (std::uint64_t(box.max.y_mm) - std::uint64_t(box.min.y_mm)) / 2;
            std::memcpy(&position.y_mm, &y_bits, sizeof(y_bits));
            auto world = worldPositionTable(lua_binding, position);
            if (!world.valid() || !error.writeValue("position", world))
                return lua_binding.pushError();
        }
        return lua_binding.returnValues(nullptr, error);
    }

    auto out = advanceResultTable(lua_binding, result.value);
    return out.valid() ? lua_binding.returnValues(out) : lua_binding.pushError();
}
template <int (*Callback)(lua_State *)> int airBoundary(lua_State *state)
{
    try
    {
        return Callback(state);
    }
    catch (const std::bad_alloc &)
    {
        LuaBinding binding(state);
        return binding.pushError("CAPACITY_EXCEEDED", "air allocation failed");
    }
    catch (const std::exception &)
    {
        LuaBinding binding(state);
        return binding.pushError("INTERNAL_ERROR", "air native exception");
    }
    catch (...)
    {
        LuaBinding binding(state);
        return binding.pushError("INTERNAL_ERROR", "unknown air native exception");
    }
}
int load_map(lua_State *state)
{
    return airBoundary<loadMap>(state);
}

int new_context(lua_State *state)
{
    return airBoundary<newContext>(state);
}

int set_air_obstacle(lua_State *state)
{
    return airBoundary<setAirObstacle>(state);
}

int remove_air_obstacle(lua_State *state)
{
    return airBoundary<removeAirObstacle>(state);
}

int sweep_air(lua_State *state)
{
    return airBoundary<sweepAir>(state);
}

bool registerContext(LuaBinding &lua_binding)
{
    LuaTable meta;
    if (!lua_binding.registerUserdata<LuaNavigationContext>(kContextMeta, meta))
    {
        return false;
    }
    auto methods = lua_binding.newTable();
    return methods.setFunction("set_air_obstacle", &set_air_obstacle) &&
           methods.setFunction("remove_air_obstacle", &remove_air_obstacle) &&
           methods.setFunction("find_air_path", &airBoundary<findAirPath>) &&
           methods.setFunction("sweep_air", &sweep_air) &&
           methods.setFunction("move_air", &airBoundary<moveAir>) &&
           methods.setFunction("advance_air_path", &airBoundary<advanceAirPath>) &&
           methods.setFunction("find_path", &findPath) &&
           methods.setFunction("set_cell_rule", &setCellRule) &&
           methods.setFunction("find_path_to_range", &findPathToRange) &&
           methods.setFunction("find_path_to_unit_range", &find_path_to_unit_range) &&
           methods.setFunction("place_unit", &place_unit) &&
           methods.setFunction("move_unit", &move_unit) &&
           methods.setFunction("release_unit", &release_unit) &&
           methods.setFunction("advance_path", &advance_path) &&
           methods.setFunction("cell_size_mm", &cell_size_mm) &&
           methods.setFunction("unit_radius_mm", &unit_radius_mm) &&
           methods.setFunction("map_version", &mapVersion) &&
           methods.setFunction("close", &close) && meta.writeValue("__index", methods);
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
    if (!module.setFunction("load_navigation_profiles", &load_navigation_profiles) ||
        !module.setFunction("load_map", &load_map, maps) ||
        !module.setFunction("query_cell", &queryCell, maps) ||
        !module.setFunction("new_context", &new_context, maps))
    {
        return lua_binding.pushError();
    }
    return lua_binding.returnValues(module);
}
