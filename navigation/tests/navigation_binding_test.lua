--- 职责：对真实 Native/Lua ABI 验证加载、路径、Context 隔离及关闭失败。
--- 边界：独立测试；只读取调用方生成的测试 BMAP，不需要业务或 Skynet Service。
--- 输入：框架根、Native 目录、BMAP 路径；输出：断言通过标记，失败退出非零。
package.path = arg[1] .. "/navigation/lualib/?.lua;" .. package.path
package.cpath = arg[2] .. "/?.so;" .. package.cpath
local navigation = require "flywow_navigation"
--- 超限文件在分配文件缓冲前拒绝；这里只读 sparse 文件的长度，不消费 128 MiB。
local oversized, size_error = navigation.load_map(arg[4])
assert(oversized == nil and size_error.code == "BMAP_SIZE_OVERFLOW")
local loaded, load_error = navigation.load_map(arg[3])
assert(loaded, load_error and load_error.message)
assert(loaded.map_id == 17 and loaded.map_version == 2)

--- 本测试 profiles 归各 Context 复制；0 半径只占一个格，不影响其它测试前提。
local profiles =
{
    {
        id                 = 1,
        radius_mm          = 0,
        max_step_mm        = 1000,
        max_slope_permille = 1000,
    },
}
-- 稠密性校验只统计正整数下标；命名字段不应被当作 profile 或拒绝。
profiles.source = false
local first = assert(navigation.new_context(17, 2, profiles))
local second = assert(navigation.new_context(17, 2, profiles))
local start = { x_mm = 750, y_mm = 0, z_mm = 750 }
local goal = { x_mm = 1750, y_mm = 0, z_mm = 1750 }
assert(first:place_unit(1, 1, start))
assert(second:place_unit(1, 1, start))
local rejected, conflict = first:place_unit(1, 2, start)
assert(rejected == nil and conflict.code == "MOVE_BLOCKED")
local path, path_error = first:find_path(1, start, goal, 1)
assert(path, path_error and path_error.message)
assert(path:count() >= 2 and path:length_mm() > 0)
assert(path:world_point(1).x_mm == start.x_mm)
local invalid_point, point_error = path:world_point(0)
assert(invalid_point == nil)
assert(point_error.code == "INVALID_ARGUMENT")

local ok, invalid_map, map_error = pcall(function() return navigation.load_map(123) end)
assert(ok)
assert(invalid_map == nil)
assert(map_error.code == "INVALID_ARGUMENT")

local invalid_context, context_error = navigation.new_context(17, 2, {})
assert(invalid_context == nil)
assert(context_error.code == "INVALID_ARGUMENT")

local sparse_ok, sparse_context, sparse_error = pcall(function()
    return navigation.new_context(17, 2, { [1] = profiles[1], [3] = profiles[1] })
end)
assert(sparse_ok)
assert(sparse_context == nil)
assert(sparse_error.code == "INVALID_ARGUMENT")

local id_ok, invalid_map_id, map_id_error = pcall(function()
    return navigation.new_context(0, 2, profiles)
end)
assert(id_ok)
assert(invalid_map_id == nil)
assert(map_id_error.code == "INVALID_ARGUMENT")

local profile_ok, invalid_profile, profile_error = pcall(function()
    return navigation.new_context(17, 2, {
        { id = 1, radius_mm = "invalid", max_step_mm = 1000, max_slope_permille = 1000 },
    })
end)
assert(profile_ok)
assert(invalid_profile == nil)
assert(profile_error.code == "INVALID_ARGUMENT")
first:close()
first:close()
local closed, closed_error = first:find_path(1, start, goal, 1)
assert(closed == nil and closed_error.code == "CONTEXT_CLOSED")
assert(second:release_unit(1))
second:close()
print("FLYWOW_NAVIGATION_BINDING_OK")
