// 职责：在 Lua table 与 Native 导航类型之间做参数和结果转换。
// 边界：Server Runtime Binding；只调用 MapRegistry/GridMap，不包含 Skynet 业务。
// 输入/输出：Lua map/version/WorldPosition -> 查询结果 table 或 nil + error table。
// 生命周期：Context/Path 由 Lua userdata 独占；Registry 共享已发布静态地图。
// 不保存全局 mutable scratch；每个 Battle 的 occupancy 和 Path cursor 独立。
// 不负责：不 yield、不执行 skynet.call、不管理动态单位。
#include "lua_navigation.h"
#include "agent_profile.h"
#include "grid_pathfinder.h"
#include "map_registry.h"
#include "navigation_context.h"
#include "navigation_path.h"

extern "C"
{
#include <lauxlib.h>
#include <lua.h>
}

#include <cstdint>
#include <exception>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

// 栈注释使用 [栈底 ... 栈顶]；S 代表进入该步骤前已有的栈内容。
// 正索引从栈底计数；-1 是栈顶，-2 是栈顶下面的元素。
// C 入口的 int 返回值是“返回给 Lua 的值的数量”，并非业务结果或成功状态：
// return 1 取栈顶一个值；return 2 按压栈顺序取栈顶两个值；return 0 不返回值。
// 例如先 pushinteger(500) 再 return 1，Lua 收到的是 500，而不是 1。
// 普通 C++ helper 的 return 则遵循自己的返回类型，不套用 Lua C 入口规则。
// lua_pop(L, n) 只移除栈顶 n 个值，不返回给 Lua、不立即销毁其引用的对象；
// 已弹出的值若仍被 table、参数或其他 Lua 引用持有，就仍然存活。
// C 入口退出时由 Lua 清理参数和其余临时栈值，因此返回前不应 pop 掉结果。
// 以下读取/检查 API 正常返回时不消耗被检查的值；get/push 才增加栈元素：
// luaL_checkinteger 检查能否得到整数并返回 C 数值，失败抛 Lua 错误；
// lua_isinteger 严格检查整数类型，lua_tointeger 在确认类型后读取该数值；
// luaL_checktype 检查 table 等类型，lua_istable/lua_isnil 只作条件判断；
// luaL_checkudata 根据具名 metatable 检查 userdata，返回借用的 C++ 内存地址。
// getfield/geti 读取字段或整数 key 并压入值，缺失得到 nil，不会弹出源 table；
// setfield 消耗栈顶值并写入指定 table；newtable 创建并压入空 table。
// pushinteger/pushboolean/pushstring 把 C 数据转成 Lua 值并压栈；
// pushstring/pushlstring 将字符串复制到 Lua，后者用显式长度保留内嵌零字节。
// pushcfunction 把 C 入口压成 Lua 函数；这些 push 都不自动返回结果。
// return luaL_error(...) 抛出 Lua 错误，中断当前调用，由 pcall 等捕获；
// 写 return 是满足 C++ 入口的 int 返回形式，不表示向 Lua 返回错误码。
// return push_nav_failure(...) 则正常返回 helper 给出的数量 2，结果为 nil,error。
// 参数错误通过 luaL_check*/luaL_error 抛给 Lua；业务失败返回 nil,error。
// Lua 错误可能 longjmp，不能依赖其执行 C++ 局部对象析构；userdata
// 必须在后续参数解析前挂好 __gc，才能回收已构造的持久资源。
namespace
{

using flywow_navigation::DynamicNavigationPolicy;
using flywow_navigation::MapRegistry;
using flywow_navigation::NavigationAgent;
using flywow_navigation::NavigationAgentHandle;

constexpr const char *kContextMeta = "flywow_navigation.NavigationContext";
constexpr const char *kPathMeta    = "flywow_navigation.Path";

struct LuaNavigationContext
{
    std::unique_ptr<flywow_navigation::NavigationContext> context;        // 当前 Lua State 独占。
    std::vector<flywow_navigation::AgentProfile>          profiles;       // 创建后冻结，只读查找。
    bool                                                  closed = false; // close/__gc 后拒绝调用。
};

struct LuaPath
{
    flywow_navigation::Path             path;   // userdata 独占 immutable Path 结果。
    flywow_navigation::PathFollowCursor cursor; // 这条路线自己的跟随进度。
};

// ---- Lua 参数读取与错误转换 ----

// 读取模块闭包的第一个 upvalue，并返回非 owning Registry 指针。
// Registry 生命周期覆盖 Lua State；注册阶段必须保证指针非空。
// 闭包显式捕获只读资产目录依赖；查询不捕获其它 Service 的可变状态。
// Registry 固定为进程级单例；实际工程也可由 C 入口直接调用 Instance()，省去 upvalue。
MapRegistry *registry(lua_State *L)
{
    // 闭包 upvalue 是绑定时保存的依赖，伪索引访问不压栈，仍为 [S]。
    void *p = lua_touserdata(L, lua_upvalueindex(1));
    return static_cast<MapRegistry *>(p);
}

// 从 index 指向的 Lua table 读取 AgentProfile 用的 int32 字段；缺失、类型错误或越界触发 luaL_error。
std::int32_t int32_field(lua_State *L, int index, const char *name)
{
    // [S] -> [S, field]；读完后 pop 恢复 [S]，正常返回栈净变化为 0。
    lua_getfield(L, index, name);
    if (!lua_isinteger(L, -1))
    {
        luaL_error(L, "field '%s' must be integer", name);
    }
    const lua_Integer value = lua_tointeger(L, -1);
    // lua_pop(L, 1)：弹出刚读取的字段值；整数已复制到 value，原 table 保留。
    lua_pop(L, 1);
    if (value < std::numeric_limits<std::int32_t>::min() ||
        value > std::numeric_limits<std::int32_t>::max())
    {
        luaL_error(L, "field '%s' is outside int32 range", name);
    }
    return static_cast<std::int32_t>(value);
}

// 读取 WorldPosition 的 int64 毫米字段；Lua 5.4 的 lua_Integer 与此合同同为有符号 64 位。
std::int64_t int64_field(lua_State *L, int index, const char *name)
{
    static_assert(std::numeric_limits<lua_Integer>::digits == 63,
                  "WorldPosition requires a 64-bit Lua integer");
    // [S] -> [S, field]；读完后 pop 恢复 [S]，正常返回栈净变化为 0。
    lua_getfield(L, index, name);
    if (!lua_isinteger(L, -1))
    {
        luaL_error(L, "field '%s' must be integer", name);
    }
    const lua_Integer value = lua_tointeger(L, -1);
    // lua_pop(L, 1)：弹出坐标字段值；C++ 的 value 已保存毫米整数，恢复读取前的栈。
    lua_pop(L, 1);
    return static_cast<std::int64_t>(value);
}

// 向 Lua 栈压入 nil 和 {code,message} 两个返回值；message bytes 由 Lua 复制持有。
void push_error(lua_State *L, const char *code, const std::string &message)
{
    // [S] -> [S, nil, error]；setfield 消耗字段值，保留 error table。
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, code);
    lua_setfield(L, -2, "code");
    lua_pushlstring(L, message.data(), message.size());
    lua_setfield(L, -2, "message");
}

// 从 request table 读取 uint32；allow_zero=false 时 0 也属于合同错误。
// 字段缺失、类型错误或越界通过 luaL_error 终止当前 Lua 调用；栈净变化为 0。
std::uint32_t uint32_request_field(lua_State *L, int request_index, const char *name,
                                   bool allow_zero)
{
    // 固定 request 的位置，后续压入字段不会改变它的索引。
    const int request = lua_absindex(L, request_index);
    lua_getfield(L, request, name);
    const lua_Integer raw = luaL_checkinteger(L, -1);
    // lua_pop(L, 1)：弹出 request 字段值；raw 已保存数值，保留 request table。
    lua_pop(L, 1);
    if (raw < (allow_zero ? 0 : 1) ||
        static_cast<std::uint64_t>(raw) > std::numeric_limits<std::uint32_t>::max())
    {
        luaL_error(L, "field '%s' outside uint32 range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 校验 Context userdata 类型和生命周期；关闭后返回 nullptr，不转移所有权。
LuaNavigationContext *check_context(lua_State *L, int index)
{
    // 根据 metatable 验证类型并借用对象地址；正常返回栈不变，不复制或转移对象。
    auto *value = static_cast<LuaNavigationContext *>(luaL_checkudata(L, index, kContextMeta));
    if (value->closed || !value->context)
    {
        return nullptr;
    }
    return value;
}

// 校验 Path userdata 类型并返回 non-owning 指针；类型错误 luaL_error。
LuaPath *check_path(lua_State *L, int index)
{
    // 检查具名类型后借用内存地址；不是从栈上取走 Path，栈净变化为 0。
    return static_cast<LuaPath *>(luaL_checkudata(L, index, kPathMeta));
}

// 按稳定 profile_id 线性查找只读配置；不存在返回 nullptr。
const flywow_navigation::AgentProfile *find_profile(const LuaNavigationContext &owner,
                                                    std::uint32_t               profile_id)
{
    for (const auto &profile : owner.profiles)
    {
        if (profile.id == profile_id)
            return &profile;
    }
    return nullptr;
}

// 从 Lua table 读取 int64 毫米 WorldPosition；字段缺失或类型错误 luaL_error。
flywow_navigation::WorldPosition world_position(lua_State *L, int index)
{
    luaL_checktype(L, index, LUA_TTABLE);
    flywow_navigation::WorldPosition p;
    p.x_mm = int64_field(L, index, "x_mm");
    p.y_mm = int64_field(L, index, "y_mm");
    p.z_mm = int64_field(L, index, "z_mm");
    return p;
}

// 读取正 uint32 业务 ID；当前查询必须明确传入已有实体的 self 句柄。
// 越界通过 luaL_error 终止当前 Lua 调用，不允许 0 或负数变成有效 ID。
std::uint32_t uint32_arg(lua_State *L, int index, const char *name)
{
    const lua_Integer raw = luaL_checkinteger(L, index);
    if (raw < 1 || static_cast<std::uint64_t>(raw) > std::numeric_limits<std::uint32_t>::max())
    {
        luaL_error(L, "%s outside uint32 business range", name);
    }
    return static_cast<std::uint32_t>(raw);
}

// 把一个毫米 WorldPosition 复制为新 Lua table；栈净增加 1。
void push_world_position(lua_State *L, const flywow_navigation::WorldPosition &p)
{
    // [S] -> [S, position]；压入整数后 -2 指向 position。
    // setfield 写入并弹出栈顶字段值，每次都恢复 [S, position]。
    lua_newtable(L);

    lua_pushinteger(L, p.x_mm);
    lua_setfield(L, -2, "x_mm");

    lua_pushinteger(L, p.y_mm);
    lua_setfield(L, -2, "y_mm");

    lua_pushinteger(L, p.z_mm);
    lua_setfield(L, -2, "z_mm");
}

// 压入 nil,{code,message} 并返回 Lua 结果数量 2。
int push_nav_failure(lua_State *L, flywow_navigation::NavError error, const std::string &detail)
{
    push_error(L, flywow_navigation::NavErrorName(error), detail);
    // 返回值数量为 2：Lua 收到 nil 和 error table，可写为 local value, err = ...。
    return 2;
}

// 把 immutable Path 和该实体私有 cursor move 进新 userdata；栈净增加 1。
void push_path(lua_State *L, flywow_navigation::Path path)
{
    // Lua 分配原始内存：[S] -> [S, path]；0 表示无需 uservalue。
    // placement-new 构造 C++ 对象，__gc 负责析构，Lua 负责释放这块原始内存。
    void *storage = lua_newuserdatauv(L, sizeof(LuaPath), 0);
    new (storage) LuaPath{std::move(path), flywow_navigation::PathFollowCursor{}};
    // 取 registry 中已注册的类型表：[S, path] -> [S, path, meta]。
    // setmetatable 消耗 meta，挂到 -2 的 path，恢复 [S, path]。
    luaL_getmetatable(L, kPathMeta);
    lua_setmetatable(L, -2);
}

// 解析并验证一项 Lua Profile；返回按值快照，字段错误 luaL_error。
flywow_navigation::AgentProfile parse_profile(lua_State *L, int index)
{
    // Profile 常位于 -1；先固定绝对索引，避免压入字段后 -1 指向字段值。
    const int abs = lua_absindex(L, index);
    luaL_checktype(L, abs, LUA_TTABLE);

    flywow_navigation::AgentProfile profile = flywow_navigation::MakeDefaultAgentProfile(1);

    lua_getfield(L, abs, "id");
    const lua_Integer raw_id = luaL_checkinteger(L, -1);
    // lua_pop(L, 1)：弹出 id 字段值；raw_id 已保存，栈顶恢复为原 Profile。
    lua_pop(L, 1);
    if (raw_id <= 0 ||
        static_cast<std::uint64_t>(raw_id) > std::numeric_limits<std::uint32_t>::max())
    {
        luaL_error(L, "profile id must be positive uint32");
    }
    profile.id = static_cast<std::uint32_t>(raw_id);

    profile.radius_mm   = int32_field(L, abs, "radius_mm");
    profile.max_step_mm = int32_field(L, abs, "max_step_mm");

    lua_getfield(L, abs, "max_slope_permille");
    const lua_Integer slope = luaL_checkinteger(L, -1);
    // lua_pop(L, 1)：弹出坡度字段值；slope 已保存，栈顶恢复为原 Profile。
    lua_pop(L, 1);
    if (slope < 0 || slope > std::numeric_limits<std::uint32_t>::max())
    {
        luaL_error(L, "max_slope_permille outside uint32 range");
    }
    profile.max_slope_permille = static_cast<std::uint32_t>(slope);

    // area_cost_permille 使用 Lua key=0..255；未配置保持默认 1000。
    lua_getfield(L, abs, "area_cost_permille");
    if (lua_istable(L, -1))
    {
        for (int area = 0; area < 256; ++area)
        {
            // -1 当前是配置 table；geti 压入 table[area]，新的 -1 是字段值。
            // area 使用业务 key 0..255，不套用 profiles 数组的 1-based 下标。
            lua_geti(L, -1, area);
            if (!lua_isnil(L, -1))
            {
                const lua_Integer cost = luaL_checkinteger(L, -1);
                if (cost < 0 || cost > 65535)
                {
                    luaL_error(L, "area cost outside uint16 range");
                }
                profile.area_cost_permille[area] = static_cast<std::uint16_t>(cost);
            }
            // lua_pop(L, 1)：弹出本轮 area 的 cost（也可能是 nil），让下一轮 -1 继续指向 cost table。
            lua_pop(L, 1);
        }
    }
    // lua_pop(L, 1)：弹出整个 cost 配置值（table 或 nil），恢复进入此字段读取前的栈。
    lua_pop(L, 1);

    lua_getfield(L, abs, "area_allowed");
    if (lua_istable(L, -1))
    {
        for (int area = 0; area < 256; ++area)
        {
            // -1 当前是配置 table；geti 压入 table[area]，新的 -1 是字段值。
            // area 使用业务 key 0..255，不套用 profiles 数组的 1-based 下标。
            lua_geti(L, -1, area);
            if (!lua_isnil(L, -1))
            {
                // Lua 真值规则：只有 nil/false 为假，数字 0 也为真；读取不弹栈。
                profile.area_allowed[area] = lua_toboolean(L, -1) ? 1 : 0;
            }
            // lua_pop(L, 1)：弹出本轮 area 的 allowed（也可能是 nil），下一轮 -1 继续指向 allowed table。
            lua_pop(L, 1);
        }
    }
    // lua_pop(L, 1)：弹出整个 allowed 配置值（table 或 nil），恢复 Profile 解析前的栈。
    lua_pop(L, 1);

    // NavResult 内含 std::string；先让它离开作用域再 luaL_error，
    // 避免 Lua longjmp 跳过 C++ 对象析构。
    const char *validation_error = nullptr;
    {
        const auto valid = flywow_navigation::ValidateAgentProfile(profile);
        if (!valid.ok())
        {
            validation_error = flywow_navigation::NavErrorName(valid.error);
        }
    }
    if (validation_error != nullptr)
    {
        luaL_error(L, "invalid agent profile: %s", validation_error);
    }
    return profile;
}

// ---- 动态占位规则：只借用本次查询数据 ----

// 判断 agent 的整个目标 footprint 是否只包含自己。
// query 中所有指针只在本次同步调用期间有效；本函数不保存引用、不分配、不 yield。
bool ExclusiveDynamicRule(void *, const flywow_navigation::DynamicNavigationQuery &query)
{
    if (query.agent == nullptr || query.agent->profile == nullptr || query.occupancy == nullptr)
    {
        return false;
    }

    const flywow_navigation::NavigationAgentHandle self = query.agent->handle;
    return query.occupancy->ForEachFootprintCell(
        *query.agent->profile, query.target,
        [&](const flywow_navigation::GridPos &grid)
        {
            bool allowed = true;
            query.occupancy->ForEachOccupant(grid,
                                             [&](flywow_navigation::NavigationAgentHandle other)
                                             {
                                                 if (other != self)
                                                 {
                                                     allowed = false;
                                                     return false;
                                                 }
                                                 return true;
                                             });
            return allowed;
        });
}

// ---- 模块入口：静态地图与独占 Context ----

// Lua load_map(path) 入口；在启动阶段读取、校验并注册一份 BMAP。
// 成功返回 {map_id,map_version}；失败返回 nil,error；本函数执行文件 I/O。
int l_load_map(lua_State *L)
{
    auto       *maps   = registry(L);
    // 参数 1 是 BMAP 路径；检查并借用 Lua 字符串，当前参数仍在栈上保证其存活。
    const char *path   = luaL_checkstring(L, 1);
    const auto  loaded = maps->Load(path);
    if (!loaded.ok())
    {
        push_error(L, flywow_navigation::NavErrorName(loaded.error), loaded.detail);
        // 返回值数量为 2：Lua 收到 nil 和 error table，可写为 local value, err = ...。
        return 2;
    }

    const auto &metadata = loaded.value->metadata();
    lua_newtable(L);
    lua_pushinteger(L, metadata.map_id);
    lua_setfield(L, -2, "map_id");
    lua_pushinteger(L, metadata.map_version);
    lua_setfield(L, -2, "map_version");
    // 返回值数量为 1：Lua 收到栈顶的地图身份 table，不是数字 1。
    return 1;
}

// Lua query_cell(map_id, version, position) 入口。
// 成功返回一个结果 table；失败返回 nil,error；不 yield、不保存请求状态。
int l_query_cell(lua_State *L)
{
    auto             *maps        = registry(L);
    const lua_Integer raw_map_id  = luaL_checkinteger(L, 1);
    const lua_Integer raw_version = luaL_checkinteger(L, 2);
    if (raw_map_id <= 0 ||
        static_cast<std::uint64_t>(raw_map_id) > std::numeric_limits<std::uint32_t>::max() ||
        raw_version <= 0 ||
        static_cast<std::uint64_t>(raw_version) > std::numeric_limits<std::uint32_t>::max())
    {
        return luaL_error(L, "map_id/version must be positive uint32");
    }
    const auto map_id  = static_cast<std::uint32_t>(raw_map_id);
    const auto version = static_cast<std::uint32_t>(raw_version);
    luaL_checktype(L, 3, LUA_TTABLE);

    flywow_navigation::WorldPosition position;
    position.x_mm = int64_field(L, 3, "x_mm");
    position.y_mm = int64_field(L, 3, "y_mm");
    position.z_mm = int64_field(L, 3, "z_mm");

    const auto found = maps->Find(map_id, version);
    if (!found.ok())
    {
        push_error(L, flywow_navigation::NavErrorName(found.error), found.detail);
        // 返回值数量为 2：Lua 收到 nil 和 error table，可写为 local value, err = ...。
        return 2;
    }
    const auto &map = *found.value;

    const auto grid = map.WorldToGrid(position);
    if (!grid.ok())
    {
        push_error(L, flywow_navigation::NavErrorName(grid.error), grid.detail);
        // 返回值数量为 2：Lua 收到 nil 和 error table，可写为 local value, err = ...。
        return 2;
    }

    const auto result = map.QueryWorld(position);
    if (!result.ok())
    {
        push_error(L, flywow_navigation::NavErrorName(result.error), result.detail);
        // 返回值数量为 2：Lua 收到 nil 和 error table，可写为 local value, err = ...。
        return 2;
    }

    const auto &cell = result.value;
    lua_newtable(L);
    lua_pushinteger(L, grid.value.x);
    lua_setfield(L, -2, "grid_x");
    lua_pushinteger(L, grid.value.z);
    lua_setfield(L, -2, "grid_z");
    lua_pushinteger(L, cell.height_mm);
    lua_setfield(L, -2, "cell_height_mm");
    lua_pushinteger(L, cell.area_type);
    lua_setfield(L, -2, "area");
    lua_pushinteger(L, cell.clearance_cells);
    lua_setfield(L, -2, "clearance");
    lua_pushboolean(L, cell.IsWalkable() ? 1 : 0);
    lua_setfield(L, -2, "walkable");
    // 返回值数量为 1：Lua 收到栈顶的Cell 查询结果 table，不是数字 1。
    return 1;
}

// Lua flywow_navigation_native.new_context(map_id, map_version, profiles_array)
// 成功返回 context userdata；地图查找只持有Registry 查找短锁，不 yield。
int l_new_context(lua_State *L)
{
    // 数据准备：读取并校验地图标识和 Profile 数组参数。
    auto             *maps            = registry(L);
    const lua_Integer raw_map_id      = luaL_checkinteger(L, 1);
    const lua_Integer raw_map_version = luaL_checkinteger(L, 2);
    if (raw_map_id <= 0 || raw_map_version <= 0 ||
        static_cast<std::uint64_t>(raw_map_id) > std::numeric_limits<std::uint32_t>::max() ||
        static_cast<std::uint64_t>(raw_map_version) > std::numeric_limits<std::uint32_t>::max())
    {
        return luaL_error(L, "map_id/map_version must be positive uint32");
    }
    const auto map_id      = static_cast<std::uint32_t>(raw_map_id);
    const auto map_version = static_cast<std::uint32_t>(raw_map_version);
    luaL_checktype(L, 3, LUA_TTABLE);

    // 先构造并挂 metatable。后续 luaL_check* 可能通过 Lua longjmp 报错；
    // userdata 已受 GC 管理，profiles/context 不会因跳过 C++ 栈析构而泄漏。
    void *storage = lua_newuserdatauv(L, sizeof(LuaNavigationContext), 0);
    auto *owner   = new (storage) LuaNavigationContext;
    // [参数, context] -> [参数, context, meta]；挂接后恢复 [参数, context]。
    // 提前关联 __gc，让后续参数错误退出时仍可回收 profiles/context。
    luaL_getmetatable(L, kContextMeta);
    lua_setmetatable(L, -2);

    try
    {
        // found 的 NavResult 含 std::string；把它限制在本作用域中，确保在调用任何
        // 可能 luaL_error 的 profile parser 之前完成正常 C++ 析构。
        {
            const auto found = maps->Find(map_id, map_version);
            if (!found.ok())
            {
                return push_nav_failure(L, found.error, found.detail);
            }
            owner->context.reset(new flywow_navigation::NavigationContext(found.value));
        }

        // 核心计算：查找地图、解析 Profile，并检查 Profile ID 唯一性。
        // 获取第 3 个参数数组的长度为 C 整数，正常返回栈不变；下标使用 Lua 的 1..count。
        const lua_Integer count = luaL_len(L, 3);
        if (count <= 0)
        {
            return luaL_error(L, "profiles must not be empty");
        }
        owner->profiles.reserve(static_cast<std::size_t>(count));
        for (lua_Integer i = 1; i <= count; ++i)
        {
            // [参数, context] -> [参数, context, profiles[i]]；-1 交给 parser。
            lua_geti(L, 3, i);
            const flywow_navigation::AgentProfile profile = parse_profile(L, -1);
            // lua_pop(L, 1)：弹出 profiles[i]；profile 是 C++ 按值快照，栈顶恢复为待返回的 context。
            lua_pop(L, 1);
            for (const auto &existing : owner->profiles)
            {
                if (existing.id == profile.id)
                {
                    return luaL_error(L, "duplicate profile id: %u", profile.id);
                }
            }
            owner->profiles.push_back(profile);
        }
        // 状态修改：完成初始化后才允许 Context 被调用。
        owner->closed = false;
    }
    catch (const std::exception &exception)
    {
        // C++ exception 不能穿越 Lua C ABI；userdata 保持有效并由 __gc 析构。
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
    // 收尾：把已初始化的 Context userdata 返回 Lua。
    // 返回值数量为 1：Lua 收到栈顶的已初始化的 Context userdata，不是数字 1。
    return 1;
}

// 把 Native 状态映射为稳定 Lua 字符串；未知枚举视为 Native 编程错误。
const char *path_advance_status_name(flywow_navigation::PathAdvanceStatus status)
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

// ---- Context 方法：查询、推进与占位提交 ----

// Lua context:advance_path(request)：消费一个 fixed-tick 距离预算并返回最后成功位置。
// request 的 path/from_world 只在本次同步调用借用；函数不 I/O、不加锁、不 yield。
// blocked 是成功 result 状态；参数、生命周期或 Native 内部错误返回 nil,error。
int l_context_advance_path(lua_State *L)
{
    // 参数/状态检查：确认 Context、Profile、Unit 和 Path 都有效。
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    luaL_checktype(L, 2, LUA_TTABLE);

    const std::uint32_t profile_id  = uint32_request_field(L, 2, "profile_id", false);
    const std::uint32_t unit_id     = uint32_request_field(L, 2, "unit_id", false);
    const std::uint32_t distance_mm = uint32_request_field(L, 2, "distance_mm", true);
    const auto         *profile     = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInvalidAgent,
                                "profile_id not found");
    }

    // [self, request] -> [self, request, path]；检查的是新栈顶 -1。
    lua_getfield(L, 2, "path");
    LuaPath *path_owner = check_path(L, -1);
    // lua_pop(L, 1)：弹出临时 path 引用；request.path 仍持有 userdata，path_owner 在本次同步调用中有效。
    lua_pop(L, 1);

    // [self, request] -> [self, request, from_world]；坐标 parser 正常返回栈不变。
    lua_getfield(L, 2, "from_world");
    const flywow_navigation::WorldPosition from_world = world_position(L, -1);
    // lua_pop(L, 1)：弹出 from_world table；毫米坐标已复制到 C++ 的 from_world。
    lua_pop(L, 1);

    // 核心计算：调用 Native 同步推进路径。
    try
    {
        const NavigationAgent         agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        auto                          advanced = flywow_navigation::GridPathfinder::AdvancePath(
            *owner->context, agent, path_owner->path, path_owner->cursor, from_world, distance_mm,
            dynamic_policy);
        if (!advanced.ok())
        {
            return push_nav_failure(L, advanced.error, advanced.detail);
        }

        const char *status = path_advance_status_name(advanced.value.status);
        if (status == nullptr)
        {
            return push_nav_failure(L, flywow_navigation::NavError::kInternalError,
                                    "unknown PathAdvanceStatus");
        }
        // 收尾：把 Native 结果转换为 Lua record。
        lua_newtable(L);
        lua_pushstring(L, status);
        lua_setfield(L, -2, "status");
        push_world_position(L, advanced.value.position);
        lua_setfield(L, -2, "position");
        lua_pushinteger(L, advanced.value.consumed_mm);
        lua_setfield(L, -2, "consumed_mm");
        lua_pushboolean(L, advanced.value.moved ? 1 : 0);
        lua_setfield(L, -2, "moved");
        // 返回值数量为 1：Lua 收到栈顶的含 status/position/consumed_mm/moved 的结果 table，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
}

// Lua context:find_path：读取毫米世界坐标并同步查询；成功返回 Path userdata，失败 nil,error。
int l_context_find_path(lua_State *L)
{
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    const auto  profile_id = uint32_arg(L, 2, "profile_id");
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInvalidAgent,
                                "profile_id not found");
    }
    const auto start   = world_position(L, 3);
    const auto end     = world_position(L, 4);
    const auto self_id = uint32_arg(L, 5, "self_unit_id");

    try
    {
        const NavigationAgent         agent{NavigationAgentHandle{self_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        auto result = flywow_navigation::GridPathfinder::FindPath(*owner->context, agent, start,
                                                                  end, dynamic_policy);
        if (!result.ok())
        {
            return push_nav_failure(L, result.error, result.detail);
        }
        push_path(L, std::move(result.value));
        // 返回值数量为 1：Lua 收到栈顶的Path userdata，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
}

// Lua context:find_path_to_range：搜索合法攻击位置；不忽略 target 占位，不 yield。
int l_context_find_path_to_range(lua_State *L)
{
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    const auto  profile_id = uint32_arg(L, 2, "profile_id");
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInvalidAgent,
                                "profile_id not found");
    }
    const auto        start     = world_position(L, 3);
    const auto        target    = world_position(L, 4);
    const lua_Integer raw_range = luaL_checkinteger(L, 5);
    const auto        self_id   = uint32_arg(L, 6, "self_unit_id");
    if (raw_range < 0 || raw_range > std::numeric_limits<std::uint32_t>::max())
    {
        return luaL_error(L, "attack_range_mm outside uint32 range");
    }

    try
    {
        const NavigationAgent         agent{NavigationAgentHandle{self_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        auto                          result = flywow_navigation::GridPathfinder::FindPathToRange(
            *owner->context, agent, start, target, static_cast<std::uint32_t>(raw_range),
            dynamic_policy);
        if (!result.ok())
        {
            return push_nav_failure(L, result.error, result.detail);
        }
        push_path(L, std::move(result.value));
        // 返回值数量为 1：Lua 收到栈顶的Path userdata，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
}

// Lua context:place_unit：出生场景的薄包装；用同一个 MoveUnit 规则提交首个 footprint。
// 成功返回 Server 地表 Y 归一化的 WorldPosition；失败不改变原有动态事实。
int l_context_place_unit(lua_State *L)
{
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    const auto  profile_id = uint32_arg(L, 2, "profile_id");
    const auto  unit_id    = uint32_arg(L, 3, "unit_id");
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInvalidAgent,
                                "profile_id not found");
    }
    const auto world = world_position(L, 4);
    const auto grid  = owner->context->map()->WorldToGrid(world);
    if (!grid.ok())
        return push_nav_failure(L, grid.error, grid.detail);

    try
    {
        // 先准备返回位置；失败时尚未写入 Occupancy，不需要回滚已有 footprint。
        auto normalized = owner->context->map()->GridToWorldCenter(grid.value);
        if (!normalized.ok())
        {
            return push_nav_failure(L, normalized.error, normalized.detail);
        }

        // 出生也是一次 from==to 的 MoveUnit：使用与真实移动相同的静态、
        // Grid/Cell 动态配置和业务回调，不能直接写 DynamicOccupancy 绕过冲突规则。
        const NavigationAgent         agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        const auto                    placed = flywow_navigation::GridPathfinder::MoveUnit(
            *owner->context, agent, world, world, dynamic_policy);
        if (!placed.ok())
        {
            return push_nav_failure(L, placed.error, placed.detail);
        }

        // Battle 正式位置保留输入 XZ；Y 来自 Server Grid 的权威地表高度。
        normalized.value.x_mm = world.x_mm;
        normalized.value.z_mm = world.z_mm;
        push_world_position(L, normalized.value);
        // 返回值数量为 1：Lua 收到栈顶的权威毫米世界位置 table，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
}

// Lua context:move_unit：复验当前子步并提交占位；成功返回 Server 地表 Y 归一的世界位置。
// from/to 为毫米世界坐标，to 的 X/Z 保留，Y 由目标 Cell 的 BMAP 高度决定。
// 失败返回 nil,error 且不写入新的动态事实；同步调用，不 I/O、不 yield。
int l_context_move_unit(lua_State *L)
{
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    const auto  profile_id = uint32_arg(L, 2, "profile_id");
    const auto  unit_id    = uint32_arg(L, 3, "unit_id");
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInvalidAgent,
                                "profile_id not found");
    }
    const auto from_world = world_position(L, 4);
    const auto to_world   = world_position(L, 5);
    // 缓存路径生成后动态占位仍会变化。正式提交必须重新验证本次跨格，
    // 包括对角侧格；只检查终点 footprint 会允许动态 corner cutting。
    try
    {
        // 先准备权威返回位置；若归格失败，尚未提交 Occupancy。
        const auto to_grid = owner->context->map()->WorldToGrid(to_world);
        if (!to_grid.ok())
        {
            return push_nav_failure(L, to_grid.error, to_grid.detail);
        }
        auto normalized = owner->context->map()->GridToWorldCenter(to_grid.value);
        if (!normalized.ok())
        {
            return push_nav_failure(L, normalized.error, normalized.detail);
        }

        const NavigationAgent         agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        const auto                    moved = flywow_navigation::GridPathfinder::MoveUnit(
            *owner->context, agent, from_world, to_world, dynamic_policy);
        if (!moved.ok())
            return push_nav_failure(L, moved.error, moved.detail);
        // 成功提交后，Battle 保存与静态地图一致的 Y，不使用折线端点的 Y 插值。
        normalized.value.x_mm = to_world.x_mm;
        normalized.value.z_mm = to_world.z_mm;
        push_world_position(L, normalized.value);
        // 返回值数量为 1：Lua 收到栈顶的权威毫米世界位置 table，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
}

// 返回当前 Context 静态地图 Cell 边长，单位毫米；只读、零分配、不 yield。
int l_context_cell_size_mm(lua_State *L)
{
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    lua_pushinteger(L, owner->context->map()->metadata().cell_size_mm);
    // 返回值数量为 1：Lua 收到栈顶的Cell 边长整数（毫米），不是数字 1。
    return 1;
}

// Lua context:release_unit：释放该 handle 当前记录的 footprint；成功返回 true。
int l_context_release_unit(lua_State *L)
{
    LuaNavigationContext *owner = check_context(L, 1);
    if (owner == nullptr)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kContextClosed,
                                "context is closed");
    }
    const auto unit_id = uint32_arg(L, 2, "unit_id");
    try
    {
        const NavigationAgentHandle handle{unit_id};
        const auto                  released = owner->context->occupancy().Release(handle);
        if (!released.ok())
        {
            return push_nav_failure(L, released.error, released.detail);
        }
        // 将 C 的非零值转成 Lua true 并压栈；这里的 1 是布尔输入。
        lua_pushboolean(L, 1);
        // 返回值数量为 1：Lua 收到栈顶的布尔值 true，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_nav_failure(L, flywow_navigation::NavError::kInternalError, exception.what());
    }
}

// ---- Path 方法：只读路线与独占跟随进度 ----

// 返回 Path 世界点数量；不分配、不修改 Path。
int l_path_count(lua_State *L)
{
    auto *value = check_path(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.count()));
    // 返回值数量为 1：Lua 收到栈顶的路径点数整数，不是数字 1。
    return 1;
}

// 返回 Lua 1-based index 对应的毫米 WorldPosition table；越界 luaL_error。
int l_path_world_point(lua_State *L)
{
    auto             *value     = check_path(L, 1);
    const lua_Integer lua_index = luaL_checkinteger(L, 2);
    if (lua_index <= 0 || static_cast<std::size_t>(lua_index) > value->path.count())
    {
        return luaL_error(L, "path index out of range");
    }
    push_world_position(L, value->path.WorldPoint(static_cast<std::size_t>(lua_index - 1)));
    // 返回值数量为 1：Lua 收到栈顶的路径点的毫米世界位置 table，不是数字 1。
    return 1;
}

// 返回 XZ 折线总长度，单位毫米。
int l_path_length_mm(lua_State *L)
{
    auto *value = check_path(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.length_mm()));
    // 返回值数量为 1：Lua 收到栈顶的路径长度整数（毫米），不是数字 1。
    return 1;
}

// 析构 placement-new LuaPath；仅由 Lua __gc 调用一次。
int l_path_gc(lua_State *L)
{
    auto *value = check_path(L, 1);
    value->~LuaPath();
    // 不向 Lua 返回任何值；0 是返回值数量，不是布尔 false 或业务错误码。
    return 0;
}

// ---- Context 生命周期 ----

// 幂等关闭 Context 的大块 Native 内存；userdata 本体保留到 __gc。
int l_context_close(lua_State *L)
{
    auto *owner = static_cast<LuaNavigationContext *>(luaL_checkudata(L, 1, kContextMeta));
    if (!owner->closed)
    {
        owner->context.reset();
        owner->closed = true;
    }
    // 不向 Lua 返回任何值；0 是返回值数量，不是布尔 false 或业务错误码。
    return 0;
}

// __gc 必须真正调用 placement-new 对象析构函数；vector capacity 才会释放。
// 析构 placement-new owner，释放 profiles capacity 和尚未 close 的 Context。
int l_context_gc(lua_State *L)
{
    auto *owner = static_cast<LuaNavigationContext *>(luaL_checkudata(L, 1, kContextMeta));
    owner->~LuaNavigationContext();
    // 不向 Lua 返回任何值；0 是返回值数量，不是布尔 false 或业务错误码。
    return 0;
}

// ---- 类型注册：方法查找与资源回收 ----

// 在当前 Lua State 注册一次 Path metatable；栈净变化为 0。
void register_path_meta(lua_State *L)
{
    // 建立本 State 的具名类型表，供 checkudata 识别类型、方法查找和 GC 使用。
    // luaL_newmetatable 首次创建返回 1，已存在返回 0；两种情况都压入 meta：
    // [S] -> [S, meta]。只在首次创建时填表，但末尾两条分支都必须 pop。
    if (luaL_newmetatable(L, kPathMeta))
    {
        // [S, meta] -> [S, meta, gc_function]；setfield 写入 __gc 后弹出函数。
        // Lua 回收 userdata 时会调用它，以释放 placement-new 对象持有的 C++ 资源。
        lua_pushcfunction(L, l_path_gc);
        lua_setfield(L, -2, "__gc");
        // 写完 __gc 后仍为 [S, meta]；新建方法表得到 [S, meta, methods]。
        // pushcfunction/setfield 把函数放入 methods，每次恢复这三个元素。
        lua_newtable(L);
        lua_pushcfunction(L, l_path_count);
        lua_setfield(L, -2, "count");
        lua_pushcfunction(L, l_path_world_point);
        lua_setfield(L, -2, "world_point");
        lua_pushcfunction(L, l_path_length_mm);
        lua_setfield(L, -2, "length_mm");
        // userdata 查找方法时由 __index 转到 methods；冒号调用再把 userdata
        // 作为 self 传入。这里 -2 是 meta，setfield 消耗 methods：
        // [S, meta, methods] -> [S, meta]；末尾 pop 恢复 [S]。
        lua_setfield(L, -2, "__index");
    }
    // lua_pop(L, 1)：弹出用于注册的 Path metatable，恢复 [S]；registry 仍持有该表，并未删除类型。
    lua_pop(L, 1);
}

// 在当前 Lua State 注册一次 Context metatable；栈净变化为 0。
void register_context_meta(lua_State *L)
{
    // 建立本 State 的具名类型表，供 checkudata 识别类型、方法查找和 GC 使用。
    // luaL_newmetatable 首次创建返回 1，已存在返回 0；两种情况都压入 meta：
    // [S] -> [S, meta]。只在首次创建时填表，但末尾两条分支都必须 pop。
    if (luaL_newmetatable(L, kContextMeta))
    {
        // [S, meta] -> [S, meta, gc_function]；setfield 写入 __gc 后弹出函数。
        // 回收 userdata 时调用 C++ 析构，不只释放 Lua 分配的原始内存。
        lua_pushcfunction(L, l_context_gc);
        lua_setfield(L, -2, "__gc");
        // 写完 __gc 后仍为 [S, meta]；新建方法表得到 [S, meta, methods]。
        // pushcfunction/setfield 把函数放入 methods，每次恢复这三个元素。
        lua_newtable(L);
        lua_pushcfunction(L, l_context_find_path);
        lua_setfield(L, -2, "find_path");
        lua_pushcfunction(L, l_context_find_path_to_range);
        lua_setfield(L, -2, "find_path_to_range");
        lua_pushcfunction(L, l_context_place_unit);
        lua_setfield(L, -2, "place_unit");
        lua_pushcfunction(L, l_context_move_unit);
        lua_setfield(L, -2, "move_unit");
        lua_pushcfunction(L, l_context_release_unit);
        lua_setfield(L, -2, "release_unit");
        lua_pushcfunction(L, l_context_advance_path);
        lua_setfield(L, -2, "advance_path");
        lua_pushcfunction(L, l_context_cell_size_mm);
        lua_setfield(L, -2, "cell_size_mm");
        lua_pushcfunction(L, l_context_close);
        lua_setfield(L, -2, "close");
        // userdata 查找方法时由 __index 转到 methods；冒号调用再把 userdata
        // 作为 self 传入。这里 -2 是 meta，setfield 消耗 methods：
        // [S, meta, methods] -> [S, meta]；末尾 pop 恢复 [S]。
        lua_setfield(L, -2, "__index");
    }
    // lua_pop(L, 1)：弹出用于注册的 Context metatable，恢复 [S]；registry 仍持有该表，并未删除类型。
    lua_pop(L, 1);
}

} // namespace

// 标准 Lua require 入口：为当前 Lua State 创建模块 table，并把进程级 Registry
// 指针绑定到三个函数的 closure。Registry 由 C++ 单例持有，Lua 只保存 non-owning
// lightuserdata；本函数不执行文件 I/O、不分配跨调用 scratch、不 yield。
// 返回 1 表示把栈顶模块 table 交给 require 缓存并返回。
extern "C" int luaopen_flywow_navigation_native(lua_State *L)
{
    // 检查宿主 Lua 版本及数值 ABI，避免不同 Lua 构建的模块进入当前 State。
    // 正常情况下不改变参数栈。
    luaL_checkversion(L);

    register_context_meta(L);
    register_path_meta(L);
    // 类型注册已恢复原栈；压入将交给 require 的模块 table：[S] -> [S, module]。
    lua_newtable(L);

    // [S, module] -> [S, module, registry_ptr]；lightuserdata 只借用指针。
    // pushcclosure 消耗 1 个值并保存为 upvalue，得到 [S, module, function]；
    // setfield 消耗 function，恢复 [S, module]。三个模块入口使用同样步骤。
    lua_pushlightuserdata(L, &MapRegistry::Instance());

    // 创建一个 Lua 可以调用的 C 函数 l_load_map，并且从当前 Lua 栈顶拿走 1 个值，保存到这个函数自己的 upvalue 里面。
    //closure
    //{
    //       function = l_load_map,
    //       upvalue1 = registry_ptr
    //}
    //然后把这个 closure 压回 Lua 栈顶
    //[S, module] -> [S, module, registry_ptr]->[S, module, closure]
    lua_pushcclosure(L, l_load_map, 1);

    // module.load_map = function
    //lua_setfield 会把栈顶的 function 消耗掉，所以又恢复：S, module]
    lua_setfield(L, -2, "load_map");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_query_cell, 1);
    lua_setfield(L, -2, "query_cell");

    lua_pushlightuserdata(L, &MapRegistry::Instance());
    lua_pushcclosure(L, l_new_context, 1);
    lua_setfield(L, -2, "new_context");
    // 返回值数量为 1：Lua 收到栈顶的模块 table，不是数字 1。
    return 1;
}
