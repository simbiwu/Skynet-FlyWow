-- 通过公开 Lua API 加载地图、规划并提交一次单位移动，然后释放 Context。
local skynet = require "skynet"
local function run_navigation_sample()
    local bmap_path = assert(os.getenv("FLYWOW_NAVIGATION_SAMPLE_MAP"))
    local navigation = require "flywow_navigation"
    local map = assert(navigation.load_map(bmap_path))
    assert(map.map_id == 17)
    assert(navigation.load_navigation_profiles({
        {unit_id = 1, radius_mm = 0, max_step_mm = 1000, max_slope_permille = 1000},
    }))
    local context = assert(navigation.new_context(map.map_id))
    local start = {x_mm = 750, y_mm = 0, z_mm = 750}
    local target = {x_mm = 1750, y_mm = 0, z_mm = 1750}
    assert(context:place_unit(1, 7, start))
    local path, path_error = context:find_path(1, start, target, 7)
    assert(path and path_error == nil and path:count() > 1 and path:status() == "reached")
    local movement, movement_error = context:advance_path({
        unit_id = 1, unit_instance_id = 7, distance_mm = 10000,
        path = path, from_world = start,
    })
    assert(movement and movement_error == nil)
    assert(movement.status == "reached" and movement.moved)
    assert(movement.position.x_mm == target.x_mm and movement.position.z_mm == target.z_mm)
    print(string.format("map_id=%d map_version=%d path_points=%d movement=%s",
        map.map_id, map.map_version, path:count(), movement.status))
    assert(context:release_unit(7))
    context:close()
end
skynet.start(function()
    local ok, message = xpcall(run_navigation_sample, debug.traceback)
    if ok then print("FLYWOW_NAVIGATION_SAMPLE_OK")
    else skynet.error("FLYWOW_NAVIGATION_SAMPLE_FAILED: " .. tostring(message)) end
    io.stdout:flush()
    io.stderr:flush()
    os.exit(ok and 0 or 1)
end)
