--- FlyWow 模块间复用的通用基础操作。
--- elapsed_ticks 与 elapsed_ms 分别返回 Skynet 时钟差值的 tick 数和毫秒数，并统一处理回绕。
local M = {}

local TICK_COUNT_PER_CYCLE = 0x100000000 -- skynet.now() 的 32 位计数完整回绕周期。
local MILLISECONDS_PER_TICK = 10 -- Skynet 时钟每递增一个 tick 经过 10ms；换算精度因此为 10ms。

--- 计算两个同一 Skynet 时钟读数之间经过的 tick 数，并处理 32 位回绕。
--- 两个值须为同一时钟的 skynet.now() 读数，范围 0..0xffffffff；两次读取间隔须小于完整计数周期。
---@param started_tick integer 操作开始时保存的 skynet.now() 值；必须是 32 位无符号 tick。
---@param current_tick integer 本次检查读取的同一 Skynet 时钟值；必须是 32 位无符号 tick。
---@return integer 回绕安全的经过 tick 数，范围为 0..0xffffffff。
function M.elapsed_ticks(started_tick, current_tick)
    -- 未回绕时取模不改变正差值；回绕后直接相减为负，取模会恢复正向差值。
    -- 例如 started_tick=0xfffffff0、current_tick=0x20，结果为 48 tick，而不是负数。
    return (current_tick - started_tick) % TICK_COUNT_PER_CYCLE
end

--- 计算两个同一 Skynet 时钟读数之间经过的毫秒数，并处理 32 位回绕。
--- 读取间隔限制与 elapsed_ticks() 相同；时间分辨率为 10ms，不包含小于一个 tick 的精度。
---@param started_tick integer 操作开始时保存的 skynet.now() 值；必须是 32 位无符号 tick。
---@param current_tick integer 本次检查读取的同一 Skynet 时钟值；必须是 32 位无符号 tick。
---@return integer 回绕安全的经过毫秒数，结果以 10ms 为步长。
function M.elapsed_ms(started_tick, current_tick)
    -- elapsed_ticks 负责唯一的回绕规则；这里仅将经过时长换成毫秒。
    local elapsed_ticks = M.elapsed_ticks(started_tick, current_tick) -- 同一时间段的回绕安全 tick 差。
    return elapsed_ticks * MILLISECONDS_PER_TICK
end

return M
