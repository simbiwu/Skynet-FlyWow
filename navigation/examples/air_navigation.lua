--- 职责：独立演示加载、障碍、寻路、推进、升降及扫掠；不接 Battle 或弹丸效果。
--- 调用：固定 Skynet Lua 执行本文件，四个位置参数为 FlyWow 根、Native 目录、BMAP、airnav。
--- 示例坐标来自共享 17/v2 golden 地图；失败立即终止，不隐式重试或自动重规划。
local root, native_dir, bmap_path, airnav_path = ...
assert(root and native_dir and bmap_path and airnav_path, "需要四个显式路径参数")
package.path = root .. "/navigation/lualib/?.lua;" .. package.path
package.cpath = native_dir .. "/?.so;" .. package.cpath
local navigation = require "flywow_navigation"

---@param x integer
---@param y integer
---@param z integer
---@return FlyWowNavigationPosition
local function position(x, y, z)
    return { x_mm = x, y_mm = y, z_mm = z }
end

assert(navigation.load_map(bmap_path, airnav_path))
local context = assert(navigation.new_context(17))
assert(context:set_air_obstacle
{
    handle = 1,
    min    = position(200, 800, 1700),
    max    = position(300, 1200, 1800),
})
local path = assert(context:find_air_path
{
    start          = position(250, 1000, 1750),
    target         = position(2750, 1000, 1750),
    flight_y_mm    = 1000,
    body           = { radius_mm = 50, half_height_mm = 200 },
    exclude_handle = 1,
})
for _ = 1, 100 do
    local result, err = context:advance_air_path { handle = 1, path = path, distance_mm = 100 }
    assert(result, err and err.code)
    assert(result.status ~= "blocked", "动态阻挡需由调用者决定重规划")
    if result.status == "reached" then
        break
    end
end

--- 已到建筑另一侧，调用者决定上升；move 全段通过才提交。
local raised = assert(context:move_air { handle = 1, target = position(2750, 14000, 1750) })
local sweep = assert(context:sweep_air
{
    from           = raised,
    to             = position(250, 14000, 1750),
    body           = { radius_mm = 50, half_height_mm = 200 },
    exclude_handle = 1,
})
assert(sweep.kind == "clear")
assert(context:remove_air_obstacle { handle = 1 })
context:close()
print("FLYWOW_AIR_EXAMPLE_OK")
