-- 职责：验证 common 对 64 位 Skynet tick 直接求差并换算毫秒。
-- 边界：Unit Test；传入确定的 tick 读数，不启动 Skynet 或等待真实时间。
-- 生命周期：单一 Lua State；不创建连接、Socket 或 Native 资源。
-- 不负责：skynet.now() 的宿主时钟实现由 Skynet 提供，本测试验证模块的纯整数算法。
local root = assert(arg[1])
package.path = root .. "/common/lualib/?.lua;" .. package.path

local flywow_common = require "flywow_common"

-- 检查普通 tick 差和两个相同读数。
assert(flywow_common.elapsed_ticks(100, 109) == 9)
assert(flywow_common.elapsed_ticks(100, 100) == 0)

-- 读数超过 32 位后继续递增，差值仍是普通减法结果。
assert(flywow_common.elapsed_ticks(0xfffffff0, 0x100000020) == 48)
assert(flywow_common.elapsed_ticks(0x100000000, 0x100000009) == 9)

-- elapsed_ms 直接返回同一时间段的毫秒差；普通及超过 32 位的读数都应与 tick 接口对应。
assert(flywow_common.elapsed_ms(100, 109) == 90)
assert(flywow_common.elapsed_ms(0xfffffff0, 0x100000020) == 480)
assert(flywow_common.elapsed_ms(100, 110) == 100)

print("FLYWOW_COMMON_TIME_OK")
