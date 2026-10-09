-- 职责：真实 Native ABI 的单位范围与部分路径回归，不启动 Skynet Service。
package.path = arg[1] .. "/navigation/lualib/?.lua;" .. package.path
package.cpath = arg[2] .. "/?.so;" .. package.cpath
local navigation = require "flywow_navigation"
assert(navigation.load_map(arg[3]))
local profiles = {
    { unit_id = 1, radius_mm = 0, max_step_mm = 1000, max_slope_permille = 1000 },
    { unit_id = 2, radius_mm = 600, max_step_mm = 1000, max_slope_permille = 1000 },
}
assert(navigation.load_navigation_profiles(profiles))
-- 可选参数不要求填写；查询状态与推进状态独立。
local range_context = assert(navigation.new_context(17))
local a = { x_mm = 250, y_mm = 0, z_mm = 1250 }
local b = { x_mm = 1750, y_mm = 0, z_mm = 1250 }
assert(range_context:place_unit(1, 80, a))
assert(range_context:place_unit(2, 81, b))
local unit_path = assert(range_context:find_path_to_unit_range(1, a, 2, b, 80))
assert(unit_path:status() == "reached")
local e = unit_path:world_point(unit_path:count())
local d2 = (e.x_mm-b.x_mm)^2 + (e.z_mm-b.z_mm)^2
assert(d2 >= 600^2 and d2 <= (600+708)^2)
local bad, bad_error = range_context:find_path_to_unit_range(1, a, 2, b, 80, 1)
assert(not bad and bad_error.code == "INVALID_ARGUMENT")
local unknown, unknown_error = range_context:find_path_to_unit_range(1, a, 999, b, 80)
assert(not unknown and unknown_error.code == "INVALID_AGENT")
range_context:close()
local partial_context = assert(navigation.new_context(17))
assert(partial_context:place_unit(1, 90, a))
for z = 0, 4 do
    assert(partial_context:set_cell_rule(2, z, "block"))
    assert(partial_context:place_unit(1, 100+z, {x_mm=1250,y_mm=0,z_mm=z*500+250}))
end
local no_path, no_path_error = partial_context:find_path_to_range(1, a, b, 0, 90, nil)
assert(not no_path and no_path_error.code == "NO_PATH")
local p = assert(partial_context:find_path_to_range(1, a, b, 0, 90, true))
assert(p:status() == "partial")
local wall_end = p:world_point(p:count())
assert(wall_end.x_mm == 750 and wall_end.z_mm == 1250)
local exact_partial = assert(partial_context:find_path(1, a, b, 90, true))
assert(exact_partial:status() == "partial")
local invalid, invalid_error = partial_context:find_path_to_range(1, a, b, 0, 90, "true")
assert(not invalid and invalid_error.code == "INVALID_ARGUMENT")
local zero_progress, zero_error = partial_context:find_path_to_range(1, wall_end, b, 0, 90, true)
assert(not zero_progress and zero_error.code == "NO_PATH")
local unit_partial = assert(partial_context:find_path_to_unit_range(1, a, 1, b, 90, true))
assert(unit_partial:status() == "partial")
partial_context:close()
print("FLYWOW_UNIT_RANGE_OK")
