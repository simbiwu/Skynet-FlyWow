--- 职责：真实固定 Lua ABI 下验证可选加载、空中完整调用链、错误返回与释放。
local root, native_dir, bmap_path, airnav_path = ...
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

---@param value any
---@param err FlyWowNavigationError?
---@param code string
local function error_code(value, err, code)
    assert(value == nil and err.code == code, err and err.code or "unexpected success")
end

assert(navigation.load_map(bmap_path, airnav_path))
local context = assert(navigation.new_context(17))
local ground_value, ground_error = context:find_path(1, position(250, 0, 250), position(750, 0, 250), 1)
error_code(ground_value, ground_error, "INVALID_AGENT")

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
assert(path:count() > 2)
local reached = false
for _ = 1, 100 do
    local result = assert(context:advance_air_path { handle = 1, path = path, distance_mm = 100 })
    if result.status == "reached" then
        reached = true
        break
    end
    assert(result.status == "moving")
end

assert(reached)

local result = assert(context:sweep_air
{
    from           = position(250, 10100, 1750),
    to             = position(2750, 10100, 1750),
    body           = { radius_mm = 50, half_height_mm = 200 },
    exclude_handle = 1,
})
assert(result.kind == "static" and result.time_numerator and result.time_denominator)

local value, err = context:move_air { handle = 1, target = position(250, 1000, 1750) }
error_code(value, err, "BLOCKED")
assert(context:remove_air_obstacle { handle = 1 })
assert(context:remove_air_obstacle { handle = 1 })
value, err = context:set_air_obstacle { handle = 0, min = position(0, 0, 0), max = position(1, 1, 1) }
error_code(value, err, "INVALID_ARGUMENT")
value, err = navigation.load_map(bmap_path, airnav_path .. ".missing")
error_code(value, err, "IO_ERROR")
value, err = navigation.load_map(bmap_path, "")
error_code(value, err, "INVALID_ARGUMENT")

assert(navigation.load_map(bmap_path))
local old = assert(context:sweep_air
{
    from = position(250, 1000, 1750),
    to   = position(2750, 1000, 1750),
    body = { radius_mm = 0, half_height_mm = 0 },
})
assert(old.kind == "static")

local fresh = assert(navigation.new_context(17, { buckets = 2 }))
value, err = fresh:sweep_air
{
    from = position(250, 1000, 1750),
    to   = position(2750, 1000, 1750),
    body = { radius_mm = 0, half_height_mm = 0 },
}
error_code(value, err, "QUERY_BUDGET_EXCEEDED")

context:close()
context:close()
value, err = context:remove_air_obstacle { handle = 1 }
error_code(value, err, "CONTEXT_CLOSED")
fresh:close()
collectgarbage("collect")
print("FLYWOW_AIR_BINDING_OK")
