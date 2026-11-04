--- FlyWow 模块间复用的通用基础操作。
--- elapsed_ticks 返回两个 skynet.now() 读数的 tick 差，elapsed_ms 将这个差值换算为毫秒。
local M = {}

local MILLISECONDS_PER_TICK = 10 -- Skynet 时钟每递增一个 tick 经过 10ms；换算精度因此为 10ms。

--- 计算同一 Skynet 时钟先后两次读数之间经过的 tick 数。
---@param started_tick integer 操作开始时保存的 skynet.now() 读数，单位为 10ms tick。
---@param current_tick integer 本次检查读取的 skynet.now() 读数，单位为 10ms tick。
---@return integer 两次读数相减得到的 tick 数。
function M.elapsed_ticks(started_tick, current_tick)
    return current_tick - started_tick
end

--- 将同一 Skynet 时钟先后两次读数的 tick 差换算成毫秒；每 tick 为 10ms。
---@param started_tick integer 操作开始时保存的 skynet.now() 读数，单位为 10ms tick。
---@param current_tick integer 本次检查读取的 skynet.now() 读数，单位为 10ms tick。
---@return integer 两次读数之间的毫秒数，以 10ms 为步长。
function M.elapsed_ms(started_tick, current_tick)
    local elapsed_ticks = M.elapsed_ticks(started_tick, current_tick) -- 两次时钟读数之间经过的 tick 数。
    return elapsed_ticks * MILLISECONDS_PER_TICK
end

return M
