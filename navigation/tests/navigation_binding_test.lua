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

--- Navigation 配置与 UnitProfile 分离；稀疏 ID 排序后可查，重复 ID 拒绝替换。
local profiles =
{
    {
        unit_id = 10000,
        radius_mm = 300,
        max_step_mm = 1000,
        max_slope_permille = 1000,
    },
    {
        unit_id = 1,
        radius_mm = 0,
        max_step_mm = 1000,
        max_slope_permille = 1000,
        area_cost_permille = { [0] = 2000 },
        area_allowed = { [0] = 0 }, -- 数字 0 按原 Lua 真值规则为允许。
    },
}
profiles.source = false -- 命名字段不属于稠密 NavigationProfile 数组。
local empty_profiles, empty_error = navigation.load_navigation_profiles({})
assert(empty_profiles == nil and empty_error.code == "INVALID_ARGUMENT")
local sparse_profiles, sparse_error = navigation.load_navigation_profiles({
    [1] = profiles[1],
    [3] = profiles[2],
})
assert(sparse_profiles == nil and sparse_error.code == "INVALID_ARGUMENT")
local duplicate_profiles, duplicate_error =
    navigation.load_navigation_profiles({ profiles[2], profiles[2] })
assert(duplicate_profiles == nil and duplicate_error.code == "INVALID_AGENT")
local invalid_profiles, invalid_profile_error = navigation.load_navigation_profiles({
    { unit_id = 1, radius_mm = "invalid", max_step_mm = 1000, max_slope_permille = 1000 },
})
assert(invalid_profiles == nil and invalid_profile_error.code == "INVALID_ARGUMENT")
assert(navigation.load_navigation_profiles(profiles))
local first = assert(navigation.new_context(17))
local second = assert(navigation.new_context(17))
assert(first:unit_radius_mm(1) == 0)
assert(first:unit_radius_mm(10000) == 300)

local updated_profiles = {
    {
        unit_id = 1,
        radius_mm = 100,
        max_step_mm = 1000,
        max_slope_permille = 1000,
        area_cost_permille = { [0] = 2000 },
        area_allowed = { [0] = 0 },
    },
    profiles[1],
}
assert(navigation.load_navigation_profiles(updated_profiles))
assert(first:unit_radius_mm(1) == 100) -- 已有 Context 的后续调用读取新 Registry 表。
local updated_context = assert(navigation.new_context(17))
assert(updated_context:unit_radius_mm(1) == 100)
updated_context:close()
assert(navigation.load_navigation_profiles(profiles)) -- 恢复本测试的当前导航配置。
assert(first:map_version() == 2)
local start = { x_mm = 750, y_mm = 0, z_mm = 750 }
local goal = { x_mm = 1750, y_mm = 0, z_mm = 1750 }
assert(first:place_unit(1, 1, start))
assert(first:set_cell_rule(1, 1, "block"))
local blocked_start, blocked_start_error = first:place_unit(1, 2, start)
assert(blocked_start == nil and blocked_start_error.code == "MOVE_BLOCKED")
assert(second:place_unit(1, 1, start))
assert(second:place_unit(1, 2, start)) -- 未设置规则时沿用默认允许重叠。
assert(first:set_cell_rule(1, 1, "allow"))
assert(first:place_unit(1, 3, start))
assert(first:set_cell_rule(1, 1, "default"))
assert(first:place_unit(1, 4, start))
assert(first:set_cell_rule(3, 3, "block"))
assert(first:place_unit(1, 5, goal))
local blocked, block_error = first:place_unit(1, 6, goal)
assert(blocked == nil and block_error.code == "MOVE_BLOCKED")
assert(first:release_unit(5))
local bad_rule, bad_rule_error = first:set_cell_rule(3, 3, "invalid")
assert(bad_rule == nil and bad_rule_error.code == "INVALID_ARGUMENT")
local outside, outside_error = first:set_cell_rule(5, 5, "block")
assert(outside == nil and outside_error.code == "OUT_OF_BOUNDS")
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

local id_ok, invalid_map_id, map_id_error = pcall(function()
    return navigation.new_context(0)
end)
assert(id_ok)
assert(invalid_map_id == nil)
assert(map_id_error.code == "INVALID_ARGUMENT")
local replacement_map, replacement_error = navigation.load_map(arg[5])
assert(replacement_map, replacement_error and replacement_error.message)
assert(replacement_map.map_id == 17 and replacement_map.map_version == 3)
assert(first:map_version() == 2) -- 已有 Context 固定旧地图。
local old_map_query, old_map_error = navigation.query_cell(17, 2, start)
assert(old_map_query == nil and old_map_error.code == "MAP_VERSION_MISMATCH")
assert(navigation.query_cell(17, 3, start).walkable)

first:close()
first:close()
local closed, closed_error = first:find_path(1, start, goal, 1)
assert(closed == nil and closed_error.code == "CONTEXT_CLOSED")
assert(second:release_unit(1))
second:close()
-- 真实调用覆盖 record 中的 Path userdata、推进结果和 Range 查询，确保迁移保持合同。
local third = assert(navigation.new_context(17))
assert(third:map_version() == 3)
assert(third:cell_size_mm() == 500)
assert(third:place_unit(1, 7, start))
local third_path = assert(third:find_path(1, start, goal, 7))
local paused = assert(third:advance_path({
    unit_id          = 1,
    unit_instance_id = 7,
    distance_mm = 0,
    path        = third_path,
    from_world  = start,
}))
assert(paused.status == "moving" and not paused.moved and paused.consumed_mm == 0)
local advanced = assert(third:advance_path({
    unit_id          = 1,
    unit_instance_id = 7,
    distance_mm = 5000,
    path        = third_path,
    from_world  = start,
}))
assert(advanced.status == "reached" and advanced.moved)
assert(advanced.position.x_mm == goal.x_mm and advanced.position.y_mm == 0)
assert(third:move_unit(1, 7, goal, goal))
assert(third:find_path_to_range(1, goal, start, 500, 7):count() > 0)
local wrong_path, wrong_path_error = third:advance_path({
    unit_id          = 1,
    unit_instance_id = 7,
    distance_mm = 10,
    path        = third,
    from_world  = goal,
})
assert(wrong_path == nil and wrong_path_error.code == "INVALID_ARGUMENT")
assert(third:release_unit(7))
third:close()
assert(third_path:count() > 0) -- immutable Path 不依赖 Context 的动态内存。
local path_meta = getmetatable(third_path)
path_meta.__gc(third_path)
path_meta.__gc(third_path) -- 重复 GC 不允许二次析构 Native Path。
local dead_path, dead_path_error = third_path:count()
assert(dead_path == nil and dead_path_error.code == "INVALID_ARGUMENT")
collectgarbage("collect")
print("FLYWOW_NAVIGATION_BINDING_OK")
