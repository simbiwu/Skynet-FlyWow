-- 职责：验证 common 对 Skynet tick 回绕和毫秒差值的计算合同。
-- 边界：Unit Test；传入确定的 32 位 tick 数，不启动 Skynet 或等待真实时间。
-- 生命周期：单一 Lua State；不创建连接、Socket 或 Native 资源。
-- 不负责：skynet.now() 的宿主时钟实现由 Skynet 提供，本测试验证模块的纯整数算法。
local root = assert(arg[1])
package.path = root .. "/common/lualib/?.lua;" .. package.path

local flywow_common = require "flywow_common"

-- elapsed_ticks 独立返回 tick 差；同一周期内检查普通差值和相同时间点。
assert(flywow_common.elapsed_ticks(100, 109) == 9)
assert(flywow_common.elapsed_ticks(100, 100) == 0)

-- 起点接近 32 位最大值、当前值回到低位时，仍得到正确的正向 tick 差。
local wrapped_ticks = flywow_common.elapsed_ticks(0xfffffff0, 0x20)
assert(wrapped_ticks == 48)

-- elapsed_ms 直接返回同一时间段的毫秒差；普通与回绕场景都应与 tick 接口对应。
assert(flywow_common.elapsed_ms(100, 109) == 90)
assert(flywow_common.elapsed_ms(0xfffffff0, 0x20) == 480)
assert(flywow_common.elapsed_ms(100, 110) == 100)

print("FLYWOW_COMMON_TIME_OK")
