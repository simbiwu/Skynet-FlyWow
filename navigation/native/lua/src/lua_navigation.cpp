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
// 成功通常返回 1 个值；任何 API 失败都返回 nil,error 两个值。
// 写 return 只是满足 C++ 入口的 int 返回形式；真正交给 Lua 的是栈顶对应数量的值。
// Lua 调用方必须检查第一个返回值，不能把 nil 当作成功结果继续使用。
// 例如先 pushinteger(500) 再 return 1，Lua 收到的是 500，而不是 1。
// 普通 C++ helper 的 return 则遵循自己的返回类型，不套用 Lua C 入口规则。
// lua_pop(L, n) 只移除栈顶 n 个值，不返回给 Lua、不立即销毁其引用的对象；
// 已弹出的值若仍被 table、参数或其他 Lua 引用持有，就仍然存活。
// C 入口退出时由 Lua 清理参数和其余临时栈值，因此返回前不应 pop 掉结果。
// 参数检查使用 lua_is* / lua_type 等非抛错读取，再由入口显式 push_error 返回失败。
// lua_isinteger 严格检查整数类型，lua_tointeger 在确认类型后读取该数值；
// lua_istable/lua_isnil 只作条件判断；userdata 类型以具名 metatable 比较验证。
// 解析 helper 只填写 BindingError，不暗中修改 Lua 栈；入口统一 return push_error(...)。
// 参数错误不使用 luaL_error/luaL_check*，C++ 局部对象沿正常返回路径析构。
// luaL_checkversion 仅校验模块加载时的 Lua ABI，不属于调用方 API 错误。
// raw_get_field/rawgeti 读取字段或整数 key 并压入值，缺失得到 nil，不会弹出源 table；
// setfield 消耗栈顶值并写入指定 table；newtable 创建并压入空 table。
// pushinteger/pushboolean/pushstring 把 C 数据转成 Lua 值并压栈；
// pushstring/pushlstring 将字符串复制到 Lua，后者用显式长度保留内嵌零字节。
// pushcfunction 把 C 入口压成 Lua 函数；这些 push 都不自动返回结果。
// return push_error(...) 压入 nil,error 并返回 2；Native 错误码通过 NavErrorName 转为稳定字符串。
// userdata 在构造后立即挂好 __gc，确保正常返回错误时 Lua 可回收其持有的资源。
// C++ 异常在 Binding 入口内捕获并转换为 INTERNAL_ERROR，不穿越 Lua C ABI。
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

constexpr const char *kInvalidArgument = "INVALID_ARGUMENT";

struct BindingError
{
    std::string code;
    std::string message;
};

int push_error(lua_State *L, const char *code, const std::string &message);

// 以 raw lookup 读取 record 字段，避免调用输入 table 的 __index 元方法。
void raw_get_field(lua_State *L, int index, const char *name)
{
    const int absolute_index = lua_absindex(L, index);
    lua_pushstring(L, name);
    lua_rawget(L, absolute_index);
}

// 读取 table 的正整数数组部分长度，并验证 key 为 1..length；忽略非数组字段且保持 Lua 栈不变。
bool dense_array_length(lua_State *L, int index, std::size_t *length)
{
    const int absolute_index = lua_absindex(L, index);
    lua_Integer max_index = 0;
    std::size_t array_entries = 0;

    lua_pushnil(L);
    while (lua_next(L, absolute_index) != 0)
    {
        if (lua_isinteger(L, -2))
        {
            const lua_Integer key = lua_tointeger(L, -2);
            if (key > 0)
            {
                if (key > max_index)
                {
                    max_index = key;
                }
                ++array_entries;
            }
        }
        lua_pop(L, 1);
    }

    if (max_index <= 0 || static_cast<std::uint64_t>(max_index) != array_entries ||
        static_cast<std::uint64_t>(max_index) > std::numeric_limits<std::size_t>::max())
    {
        return false;
    }

    *length = static_cast<std::size_t>(max_index);
    return true;
}

// 判断 userdata 是否绑定了模块私有 metatable；调用后 Lua 栈保持不变。
bool has_metatable(lua_State *L, int index, const char *name)
{
    if (lua_getmetatable(L, index) == 0)
    {
        return false;
    }
    luaL_getmetatable(L, name);
    const bool matches = lua_rawequal(L, -1, -2) != 0;
    lua_pop(L, 2);
    return matches;
}

// 读取严格 Lua integer；失败只填 BindingError，不修改 Lua 栈。
bool read_integer(lua_State *L, int index, const char *name, lua_Integer *value,
                  BindingError *error)
{
    if (!lua_isinteger(L, index))
    {
        error->code = kInvalidArgument;
        error->message = std::string(name) + " must be integer";
        return false;
    }
    *value = lua_tointeger(L, index);
    return true;
}

// 从 index 指向的 Lua table 读取 AgentProfile 用的 int32 字段；缺失、类型错误或越界写入 BindingError。
bool int32_field(lua_State *L, int index, const char *name, std::int32_t *value,
                 BindingError *error)
{
    // [S] -> [S, field]；成功读取后 pop 恢复 [S]，正常路径栈净变化为 0。
    raw_get_field(L, index, name);
    lua_Integer raw = 0;
    if (!read_integer(L, -1, name, &raw, error))
    {
        return false;
    }
    // lua_pop(L, 1)：弹出字段值；raw 已复制到 C++，原 table 仍保留。
    lua_pop(L, 1);

    if (raw < std::numeric_limits<std::int32_t>::min() ||
        raw > std::numeric_limits<std::int32_t>::max())
    {
        error->code = kInvalidArgument;
        error->message = std::string(name) + " is outside int32 range";
        return false;
    }
    *value = static_cast<std::int32_t>(raw);
    return true;
}

// 读取 WorldPosition 的 int64 毫米字段；Lua 5.4 的 lua_Integer 与此合同同为有符号 64 位。
bool int64_field(lua_State *L, int index, const char *name, std::int64_t *value,
                 BindingError *error)
{
    static_assert(std::numeric_limits<lua_Integer>::digits == 63,
                  "WorldPosition requires a 64-bit Lua integer");
    // [S] -> [S, field]；成功读取后 pop 恢复 [S]，正常路径栈净变化为 0。
    raw_get_field(L, index, name);
    lua_Integer raw = 0;
    if (!read_integer(L, -1, name, &raw, error))
    {
        return false;
    }
    // lua_pop(L, 1)：弹出坐标字段值；整数已复制到 C++，恢复读取前的栈。
    lua_pop(L, 1);
    *value = static_cast<std::int64_t>(raw);
    return true;
}

// 向 Lua 栈压入 nil 和 {code,message} 两个返回值；message bytes 由 Lua 复制持有。
int push_error(lua_State *L, const char *code, const std::string &message)
{
    // [S] -> [S, nil, error]；setfield 消耗字段值，保留 error table。
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, code);
    lua_setfield(L, -2, "code");
    lua_pushlstring(L, message.data(), message.size());
    lua_setfield(L, -2, "message");
    return 2;
}

// 从 request table 读取 uint32；allow_zero=false 时 0 也属于合同错误；失败不修改 Lua 栈。
bool uint32_request_field(lua_State *L, int request_index, const char *name,
                          bool allow_zero, std::uint32_t *value, BindingError *error)
{
    // 固定 request 的位置，后续压入字段不会改变它的索引。
    const int request = lua_absindex(L, request_index);
    raw_get_field(L, request, name);
    lua_Integer raw = 0;
    if (!read_integer(L, -1, name, &raw, error))
    {
        return false;
    }
    // lua_pop(L, 1)：弹出 request 字段值；raw 已保存数值，保留 request table。
    lua_pop(L, 1);
    if (raw < (allow_zero ? 0 : 1) ||
        static_cast<std::uint64_t>(raw) > std::numeric_limits<std::uint32_t>::max())
    {
        error->code = kInvalidArgument;
        error->message = std::string(name) + " outside uint32 range";
        return false;
    }
    *value = static_cast<std::uint32_t>(raw);
    return true;
}

// 校验 Context userdata 类型并借用地址；失败写入 BindingError，不转移所有权。
LuaNavigationContext *check_context_userdata(lua_State *L, int index, BindingError *error)
{
    if (lua_type(L, index) != LUA_TUSERDATA ||
        lua_rawlen(L, index) != sizeof(LuaNavigationContext) ||
        !has_metatable(L, index, kContextMeta))
    {
        error->code = kInvalidArgument;
        error->message = "context must be a NavigationContext userdata";
        return nullptr;
    }
    auto *value = static_cast<LuaNavigationContext *>(lua_touserdata(L, index));
    return value;
}

// 校验 Context 类型和生命周期；关闭后写入 CONTEXT_CLOSED，不转移 userdata 所有权。
LuaNavigationContext *check_context(lua_State *L, int index, BindingError *error)
{
    LuaNavigationContext *value = check_context_userdata(L, index, error);
    if (value == nullptr)
    {
        return nullptr;
    }
    if (value->closed || value->context == nullptr)
    {
        error->code = "CONTEXT_CLOSED";
        error->message = "context is closed";
        return nullptr;
    }
    return value;
}

// 校验 Path userdata 类型并返回 non-owning 指针；失败写入 BindingError。
LuaPath *check_path(lua_State *L, int index, BindingError *error)
{
    if (lua_type(L, index) != LUA_TUSERDATA ||
        lua_rawlen(L, index) != sizeof(LuaPath) ||
        !has_metatable(L, index, kPathMeta))
    {
        error->code = kInvalidArgument;
        error->message = "path must be a Path userdata";
        return nullptr;
    }
    return static_cast<LuaPath *>(lua_touserdata(L, index));
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

// 从 Lua table 读取 int64 毫米 WorldPosition；字段顺序为 x/y/z，失败写入 BindingError。
bool world_position(lua_State *L, int index, flywow_navigation::WorldPosition *position,
                    BindingError *error)
{
    if (!lua_istable(L, index))
    {
        error->code = kInvalidArgument;
        error->message = "position must be a table";
        return false;
    }
    if (!int64_field(L, index, "x_mm", &position->x_mm, error) ||
        !int64_field(L, index, "y_mm", &position->y_mm, error) ||
        !int64_field(L, index, "z_mm", &position->z_mm, error))
    {
        return false;
    }
    return true;
}

// 读取正 uint32 业务 ID；当前查询必须明确传入已有实体的 self 句柄。
// 不允许 0 或负数变成有效 ID；失败写入 BindingError，不修改 Lua 栈。
bool uint32_arg(lua_State *L, int index, const char *name, std::uint32_t *value,
                BindingError *error)
{
    lua_Integer raw = 0;
    if (!lua_isinteger(L, index))
    {
        error->code = kInvalidArgument;
        error->message = std::string(name) + " must be integer";
        return false;
    }
    raw = lua_tointeger(L, index);
    if (raw < 1 || static_cast<std::uint64_t>(raw) > std::numeric_limits<std::uint32_t>::max())
    {
        error->code = kInvalidArgument;
        error->message = std::string(name) + " outside uint32 business range";
        return false;
    }
    *value = static_cast<std::uint32_t>(raw);
    return true;
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

// 解析并验证一项 Lua Profile；返回按值快照，字段错误写入 BindingError。
bool parse_profile(lua_State *L, int index, flywow_navigation::AgentProfile *output,
                   BindingError *error)
{
    // Profile 常位于 -1；先固定绝对索引，避免压入字段后 -1 指向字段值。
    const int abs = lua_absindex(L, index);
    if (!lua_istable(L, abs))
    {
        error->code = kInvalidArgument;
        error->message = "profile must be a table";
        return false;
    }

    flywow_navigation::AgentProfile profile = flywow_navigation::MakeDefaultAgentProfile(1);

    // [S, profile] -> [S, profile, id]；字段值读取成功后再弹出，恢复 Profile 栈顶。
    raw_get_field(L, abs, "id");
    lua_Integer raw_id = 0;
    if (!read_integer(L, -1, "profile.id", &raw_id, error))
    {
        return false;
    }
    // lua_pop(L, 1)：弹出 id 字段值；raw_id 已保存，栈顶恢复为原 Profile。
    lua_pop(L, 1);
    if (raw_id <= 0 ||
        static_cast<std::uint64_t>(raw_id) > std::numeric_limits<std::uint32_t>::max())
    {
        error->code = kInvalidArgument;
        error->message = "profile.id must be positive uint32";
        return false;
    }
    profile.id = static_cast<std::uint32_t>(raw_id);

    if (!int32_field(L, abs, "radius_mm", &profile.radius_mm, error) ||
        !int32_field(L, abs, "max_step_mm", &profile.max_step_mm, error))
    {
        return false;
    }

    // [S, profile] -> [S, profile, slope]；字段值读取成功后恢复原 Profile 栈顶。
    raw_get_field(L, abs, "max_slope_permille");
    lua_Integer slope = 0;
    if (!read_integer(L, -1, "profile.max_slope_permille", &slope, error))
    {
        return false;
    }
    // lua_pop(L, 1)：弹出坡度字段值；slope 已保存，栈顶恢复为原 Profile。
    lua_pop(L, 1);
    if (slope < 0 || slope > std::numeric_limits<std::uint32_t>::max())
    {
        error->code = kInvalidArgument;
        error->message = "profile.max_slope_permille outside uint32 range";
        return false;
    }
    profile.max_slope_permille = static_cast<std::uint32_t>(slope);

    // area_cost_permille 使用 Lua key=0..255；未配置保持默认 1000。
    raw_get_field(L, abs, "area_cost_permille");
    if (!lua_isnil(L, -1) && !lua_istable(L, -1))
    {
        lua_pop(L, 1);
        error->code = kInvalidArgument;
        error->message = "profile.area_cost_permille must be a table or nil";
        return false;
    }
    if (lua_istable(L, -1))
    {
        for (int area = 0; area < 256; ++area)
        {
            // -1 当前是配置 table；rawgeti 压入 table[area]，新的 -1 是字段值。
            // area 使用业务 key 0..255，不套用 profiles 数组的 1-based 下标。
            lua_rawgeti(L, -1, area);
            if (!lua_isnil(L, -1))
            {
                lua_Integer cost = 0;
                if (!read_integer(L, -1, "profile.area_cost_permille entry", &cost, error))
                {
                    return false;
                }
                if (cost < 0 || cost > 65535)
                {
                    lua_pop(L, 2);
                    error->code = kInvalidArgument;
                    error->message = "profile.area_cost_permille entry outside uint16 range";
                    return false;
                }
                profile.area_cost_permille[area] = static_cast<std::uint16_t>(cost);
            }
            // lua_pop(L, 1)：弹出本轮 area 的 cost（也可能是 nil），让下一轮 -1 继续指向 cost table。
            lua_pop(L, 1);
        }
    }
    // lua_pop(L, 1)：弹出整个 cost 配置值（table 或 nil），恢复进入此字段读取前的栈。
    lua_pop(L, 1);

    raw_get_field(L, abs, "area_allowed");
    if (!lua_isnil(L, -1) && !lua_istable(L, -1))
    {
        lua_pop(L, 1);
        error->code = kInvalidArgument;
        error->message = "profile.area_allowed must be a table or nil";
        return false;
    }
    if (lua_istable(L, -1))
    {
        for (int area = 0; area < 256; ++area)
        {
            // -1 当前是配置 table；geti 压入 table[area]，新的 -1 是字段值。
            // area 使用业务 key 0..255，不套用 profiles 数组的 1-based 下标。
            lua_rawgeti(L, -1, area);
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

    const auto valid = flywow_navigation::ValidateAgentProfile(profile);
    if (!valid.ok())
    {
        error->code = flywow_navigation::NavErrorName(valid.error);
        error->message = valid.detail;
        return false;
    }
    *output = profile;
    return true;
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
    // 从当前闭包 upvalue 读取 Registry；其生命周期覆盖 Lua State。
    auto *maps = static_cast<MapRegistry *>(lua_touserdata(L, lua_upvalueindex(1)));
    if (lua_type(L, 1) != LUA_TSTRING)
    {
        return push_error(L, kInvalidArgument, "path must be a string");
    }
    // 参数 1 是 BMAP 路径；参数栈保持输入字符串存活，Native Load 只在本次同步调用期间借用其地址。
    const char *path = lua_tostring(L, 1);
    const auto  loaded = maps->Load(path);
    if (!loaded.ok())
    {
        return push_error(L, flywow_navigation::NavErrorName(loaded.error), loaded.detail);
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
    // 从当前闭包 upvalue 读取共享的只读地图 Registry。
    auto *maps = static_cast<MapRegistry *>(lua_touserdata(L, lua_upvalueindex(1)));
    std::uint32_t map_id = 0;
    std::uint32_t version = 0;
    BindingError error;
    if (!uint32_arg(L, 1, "map_id", &map_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_arg(L, 2, "map_version", &version, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!lua_istable(L, 3))
    {
        return push_error(L, kInvalidArgument, "position must be a table");
    }

    flywow_navigation::WorldPosition position;
    if (!world_position(L, 3, &position, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }

    // 地图、归格或 Cell 查询失败时，NavErrorName 给出稳定 code，detail 作为诊断 message。
    const auto found = maps->Find(map_id, version);
    if (!found.ok())
    {
        return push_error(L, flywow_navigation::NavErrorName(found.error), found.detail);
    }
    const auto &map = *found.value;

    const auto grid = map.WorldToGrid(position);
    if (!grid.ok())
    {
        return push_error(L, flywow_navigation::NavErrorName(grid.error), grid.detail);
    }

    const auto result = map.QueryWorld(position);
    if (!result.ok())
    {
        return push_error(L, flywow_navigation::NavErrorName(result.error), result.detail);
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
    // 从当前闭包 upvalue 读取共享 Registry；每个 Context 自己持有动态状态。
    auto *maps = static_cast<MapRegistry *>(lua_touserdata(L, lua_upvalueindex(1)));
    std::uint32_t map_id = 0;
    std::uint32_t map_version = 0;
    BindingError error;
    if (!uint32_arg(L, 1, "map_id", &map_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_arg(L, 2, "map_version", &map_version, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!lua_istable(L, 3))
    {
        return push_error(L, kInvalidArgument, "profiles must be an array table");
    }

    std::size_t profile_count = 0;
    if (!dense_array_length(L, 3, &profile_count) || profile_count > static_cast<std::size_t>(
            std::numeric_limits<lua_Integer>::max()))
    {
        return push_error(L, kInvalidArgument,
                          "profiles must be a non-empty dense 1-based array");
    }

    // [参数, context] -> [参数, context, meta]；lua_setmetatable 消耗 meta 并恢复 [参数, context]。
    // 提前关联 __gc；后续以 nil,error 正常返回时，Lua 仍能回收已创建的 Context 资源。
    void *storage = lua_newuserdatauv(L, sizeof(LuaNavigationContext), 0);
    auto *owner = new (storage) LuaNavigationContext;
    luaL_getmetatable(L, kContextMeta);
    lua_setmetatable(L, -2);

    try
    {
        // 核心计算：查找地图、解析 Profile，并检查 Profile ID 唯一性。
        // Find 失败直接把 Native 稳定错误码和诊断信息作为 nil,error 返回。
        const auto found = maps->Find(map_id, map_version);
        if (!found.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(found.error), found.detail);
        }
        owner->context.reset(new flywow_navigation::NavigationContext(found.value));

        // 原始数组读取不调用 __len/__index；缺失元素会由 parse_profile 填充 BindingError。
        owner->profiles.reserve(profile_count);
        for (std::size_t i = 1; i <= profile_count; ++i)
        {
            // [参数, context] -> [参数, context, profiles[i]]；-1 传给 Profile parser。
            lua_rawgeti(L, 3, static_cast<lua_Integer>(i));
            flywow_navigation::AgentProfile profile;
            if (!parse_profile(L, -1, &profile, &error))
            {
                return push_error(L, error.code.c_str(), error.message);
            }
            // lua_pop(L, 1)：弹出 profiles[i]；profile 已复制为 C++ 快照，context 留在栈顶。
            lua_pop(L, 1);

            for (const auto &existing : owner->profiles)
            {
                if (existing.id == profile.id)
                {
                    return push_error(L, "DUPLICATE_PROFILE_ID",
                                      "profile IDs must be unique within a Context");
                }
            }
            owner->profiles.push_back(profile);
        }
        // 状态修改：所有 Profile 初始化成功后，Context 才成为可用对象。
        owner->closed = false;
    }
    catch (const std::exception &exception)
    {
        // C++ exception 不跨越 Lua C ABI；已挂 __gc 的 userdata 在错误返回后仍可回收。
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
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
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!lua_istable(L, 2))
    {
        return push_error(L, kInvalidArgument, "request must be a table");
    }

    std::uint32_t profile_id = 0;
    std::uint32_t unit_id = 0;
    std::uint32_t distance_mm = 0;
    if (!uint32_request_field(L, 2, "profile_id", false, &profile_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_request_field(L, 2, "unit_id", false, &unit_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_request_field(L, 2, "distance_mm", true, &distance_mm, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    const auto         *profile     = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInvalidAgent),
                          "profile_id not found");
    }

    // [self, request] -> [self, request, path]；检查的是新栈顶 -1。
    raw_get_field(L, 2, "path");
    LuaPath *path_owner = check_path(L, -1, &error);
    if (path_owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    // lua_pop(L, 1)：弹出临时 path 引用；request.path 仍持有 userdata，path_owner 在本次同步调用中有效。
    lua_pop(L, 1);

    // [self, request] -> [self, request, from_world]；坐标 parser 正常返回栈不变。
    raw_get_field(L, 2, "from_world");
    flywow_navigation::WorldPosition from_world;
    if (!world_position(L, -1, &from_world, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    // lua_pop(L, 1)：弹出 from_world table；毫米坐标已复制到 C++ 的 from_world。
    lua_pop(L, 1);

    // 核心计算：调用 Native 同步推进路径。
    try
    {
        const NavigationAgent         agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        // Native 推进失败仍使用相同的 nil,error 合同；成功的 blocked 状态是 result 字段。
        auto                          advanced = flywow_navigation::GridPathfinder::AdvancePath(
            *owner->context, agent, path_owner->path, path_owner->cursor, from_world, distance_mm,
            dynamic_policy);
        if (!advanced.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(advanced.error), advanced.detail);
        }

        const char *status = path_advance_status_name(advanced.value.status);
        if (status == nullptr)
        {
            return push_error(L, flywow_navigation::NavErrorName(
                                   flywow_navigation::NavError::kInternalError),
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
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
    }
}

// Lua context:find_path：读取毫米世界坐标并同步查询；成功返回 Path userdata，失败 nil,error。
int l_context_find_path(lua_State *L)
{
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    std::uint32_t profile_id = 0;
    if (!uint32_arg(L, 2, "profile_id", &profile_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInvalidAgent),
                          "profile_id not found");
    }
    flywow_navigation::WorldPosition start;
    flywow_navigation::WorldPosition end;
    std::uint32_t self_id = 0;
    if (!world_position(L, 3, &start, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!world_position(L, 4, &end, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_arg(L, 5, "self_unit_id", &self_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }

    try
    {
        const NavigationAgent         agent{NavigationAgentHandle{self_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        // Native 查询失败将稳定错误码和诊断详情原样转换为 nil,error。
        auto result = flywow_navigation::GridPathfinder::FindPath(*owner->context, agent, start,
                                                                  end, dynamic_policy);
        if (!result.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(result.error), result.detail);
        }
        push_path(L, std::move(result.value));
        // 返回值数量为 1：Lua 收到栈顶的Path userdata，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
    }
}

// Lua context:find_path_to_range：搜索合法攻击位置；不忽略 target 占位，不 yield。
int l_context_find_path_to_range(lua_State *L)
{
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    std::uint32_t profile_id = 0;
    if (!uint32_arg(L, 2, "profile_id", &profile_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInvalidAgent),
                          "profile_id not found");
    }
    flywow_navigation::WorldPosition start;
    flywow_navigation::WorldPosition target;
    lua_Integer raw_range = 0;
    std::uint32_t self_id = 0;
    if (!world_position(L, 3, &start, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!world_position(L, 4, &target, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!read_integer(L, 5, "attack_range_mm", &raw_range, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_arg(L, 6, "self_unit_id", &self_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (raw_range < 0 || static_cast<std::uint64_t>(raw_range) > std::numeric_limits<std::uint32_t>::max())
    {
        return push_error(L, kInvalidArgument, "attack_range_mm outside uint32 range");
    }

    try
    {
        const NavigationAgent         agent{NavigationAgentHandle{self_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        // Native 查询失败将稳定错误码和诊断详情原样转换为 nil,error。
        auto                          result = flywow_navigation::GridPathfinder::FindPathToRange(
            *owner->context, agent, start, target, static_cast<std::uint32_t>(raw_range),
            dynamic_policy);
        if (!result.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(result.error), result.detail);
        }
        push_path(L, std::move(result.value));
        // 返回值数量为 1：Lua 收到栈顶的Path userdata，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
    }
}

// Lua context:place_unit：出生场景的薄包装；用同一个 MoveUnit 规则提交首个 footprint。
// 成功返回 Server 地表 Y 归一化的 WorldPosition；失败不改变原有动态事实。
int l_context_place_unit(lua_State *L)
{
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    std::uint32_t profile_id = 0;
    std::uint32_t unit_id = 0;
    if (!uint32_arg(L, 2, "profile_id", &profile_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_arg(L, 3, "unit_id", &unit_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInvalidAgent),
                          "profile_id not found");
    }
    flywow_navigation::WorldPosition world;
    if (!world_position(L, 4, &world, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    const auto grid  = owner->context->map()->WorldToGrid(world);
    if (!grid.ok())
    {
        // 归格失败使用 Native 稳定错误码返回；此时还没有写入 Occupancy。
        return push_error(L, flywow_navigation::NavErrorName(grid.error), grid.detail);
    }

    try
    {
        // 先准备返回位置；失败时尚未写入 Occupancy，不需要回滚已有 footprint。
        auto normalized = owner->context->map()->GridToWorldCenter(grid.value);
        if (!normalized.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(normalized.error), normalized.detail);
        }

        // 出生也是一次 from==to 的 MoveUnit：使用与真实移动相同的静态、
        // Grid/Cell 动态配置和业务回调，不能直接写 DynamicOccupancy 绕过冲突规则。
        const NavigationAgent         agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        const auto                    placed = flywow_navigation::GridPathfinder::MoveUnit(
            *owner->context, agent, world, world, dynamic_policy);
        if (!placed.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(placed.error), placed.detail);
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
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
    }
}

// Lua context:move_unit：复验当前子步并提交占位；成功返回 Server 地表 Y 归一的世界位置。
// from/to 为毫米世界坐标，to 的 X/Z 保留，Y 由目标 Cell 的 BMAP 高度决定。
// 失败返回 nil,error 且不写入新的动态事实；同步调用，不 I/O、不 yield。
int l_context_move_unit(lua_State *L)
{
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    std::uint32_t profile_id = 0;
    std::uint32_t unit_id = 0;
    if (!uint32_arg(L, 2, "profile_id", &profile_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!uint32_arg(L, 3, "unit_id", &unit_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    const auto *profile    = find_profile(*owner, profile_id);
    if (profile == nullptr)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInvalidAgent),
                          "profile_id not found");
    }
    flywow_navigation::WorldPosition from_world;
    flywow_navigation::WorldPosition to_world;
    if (!world_position(L, 4, &from_world, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (!world_position(L, 5, &to_world, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    // 缓存路径生成后动态占位仍会变化。正式提交必须重新验证本次跨格，
    // 包括对角侧格；只检查终点 footprint 会允许动态 corner cutting。
    try
    {
        // 先准备权威返回位置；若归格失败，尚未提交 Occupancy。
        const auto to_grid = owner->context->map()->WorldToGrid(to_world);
        if (!to_grid.ok())
        {
            // 归格或后续移动失败均不提交新的动态事实，错误码直接沿用 Native 合同。
            return push_error(L, flywow_navigation::NavErrorName(to_grid.error), to_grid.detail);
        }
        auto normalized = owner->context->map()->GridToWorldCenter(to_grid.value);
        if (!normalized.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(normalized.error), normalized.detail);
        }

        const NavigationAgent         agent{NavigationAgentHandle{unit_id}, profile};
        const DynamicNavigationPolicy dynamic_policy{nullptr, &ExclusiveDynamicRule};
        const auto                    moved = flywow_navigation::GridPathfinder::MoveUnit(
            *owner->context, agent, from_world, to_world, dynamic_policy);
        if (!moved.ok())
            return push_error(L, flywow_navigation::NavErrorName(moved.error), moved.detail);
        // 成功提交后，Battle 保存与静态地图一致的 Y，不使用折线端点的 Y 插值。
        normalized.value.x_mm = to_world.x_mm;
        normalized.value.z_mm = to_world.z_mm;
        push_world_position(L, normalized.value);
        // 返回值数量为 1：Lua 收到栈顶的权威毫米世界位置 table，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
    }
}

// 返回当前 Context 静态地图 Cell 边长，单位毫米；只读、零分配、不 yield。
int l_context_cell_size_mm(lua_State *L)
{
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    lua_pushinteger(L, owner->context->map()->metadata().cell_size_mm);
    // 返回值数量为 1：Lua 收到栈顶的Cell 边长整数（毫米），不是数字 1。
    return 1;
}

// Lua context:release_unit：释放该 handle 当前记录的 footprint；成功返回 true。
int l_context_release_unit(lua_State *L)
{
    BindingError error;
    LuaNavigationContext *owner = check_context(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    std::uint32_t unit_id = 0;
    if (!uint32_arg(L, 2, "unit_id", &unit_id, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    try
    {
        const NavigationAgentHandle handle{unit_id};
        const auto                  released = owner->context->occupancy().Release(handle);
        if (!released.ok())
        {
            return push_error(L, flywow_navigation::NavErrorName(released.error), released.detail);
        }
        // 将 C 的非零值转成 Lua true 并压栈；这里的 1 是布尔输入。
        lua_pushboolean(L, 1);
        // 返回值数量为 1：Lua 收到栈顶的布尔值 true，不是数字 1。
        return 1;
    }
    catch (const std::exception &exception)
    {
        return push_error(L, flywow_navigation::NavErrorName(
                               flywow_navigation::NavError::kInternalError), exception.what());
    }
}

// ---- Path 方法：只读路线与独占跟随进度 ----

// 返回 Path 世界点数量；不分配、不修改 Path。
int l_path_count(lua_State *L)
{
    BindingError error;
    auto *value = check_path(L, 1, &error);
    if (value == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.count()));
    // 返回值数量为 1：Lua 收到栈顶的路径点数整数，不是数字 1。
    return 1;
}

// 返回 Lua 1-based index 对应的毫米 WorldPosition table；参数错误返回 nil,error。
int l_path_world_point(lua_State *L)
{
    BindingError error;
    auto *value = check_path(L, 1, &error);
    if (value == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    lua_Integer lua_index = 0;
    if (!read_integer(L, 2, "index", &lua_index, &error))
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    if (lua_index <= 0 || static_cast<std::size_t>(lua_index) > value->path.count())
    {
        return push_error(L, kInvalidArgument, "path index out of range");
    }
    push_world_position(L, value->path.WorldPoint(static_cast<std::size_t>(lua_index - 1)));
    // 返回值数量为 1：Lua 收到栈顶的路径点的毫米世界位置 table，不是数字 1。
    return 1;
}

// 返回 XZ 折线总长度，单位毫米。
int l_path_length_mm(lua_State *L)
{
    BindingError error;
    auto *value = check_path(L, 1, &error);
    if (value == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
    lua_pushinteger(L, static_cast<lua_Integer>(value->path.length_mm()));
    // 返回值数量为 1：Lua 收到栈顶的路径长度整数（毫米），不是数字 1。
    return 1;
}

// 析构 placement-new LuaPath；仅由 Lua __gc 调用一次。
int l_path_gc(lua_State *L)
{
    if (lua_type(L, 1) != LUA_TUSERDATA || lua_rawlen(L, 1) != sizeof(LuaPath) ||
        !has_metatable(L, 1, kPathMeta)) return 0;
    auto *value = static_cast<LuaPath *>(lua_touserdata(L, 1));
    value->~LuaPath();
    // 不向 Lua 返回任何值；0 是返回值数量，不是布尔 false 或业务错误码。
    return 0;
}

// ---- Context 生命周期 ----

// 幂等关闭 Context 的大块 Native 内存；userdata 本体保留到 __gc。
int l_context_close(lua_State *L)
{
    BindingError error;
    auto *owner = check_context_userdata(L, 1, &error);
    if (owner == nullptr)
    {
        return push_error(L, error.code.c_str(), error.message);
    }
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
    if (lua_type(L, 1) != LUA_TUSERDATA ||
        lua_rawlen(L, 1) != sizeof(LuaNavigationContext) ||
        !has_metatable(L, 1, kContextMeta)) return 0;
    auto *owner = static_cast<LuaNavigationContext *>(lua_touserdata(L, 1));
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
