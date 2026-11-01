# 职责：用显式提供的 pinned Lua 验证 common 的 tick/ms 时长计算。
# 边界：Test Runner；不下载解释器、不连接网络、不启动宿主服务。
# 输入/输出：SKYNET_LUA 与当前 FlyWow 根路径 -> unittest 结果。
# 生命周期：每次测试启动一个短命 Lua 子进程，超时后由 subprocess 终止。
# 不负责：缺少解释器时明确跳过，不把跳过描述为通过。
import os
from pathlib import Path
import subprocess
import unittest


class SkynetTimeTests(unittest.TestCase):
    # 同时验证普通 tick 差和 32 位回绕后的毫秒差。
    def test_tick_wrap_and_millisecond_elapsed_time(self):
        lua = os.environ.get("SKYNET_LUA")
        if not lua:
            self.skipTest("需要显式设置 SKYNET_LUA 为 pinned Skynet 的 Lua")
        root = Path(__file__).resolve().parents[2]
        result = subprocess.run([lua, str(root / "gateway/tests/gateway_time_test.lua"), str(root)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FLYWOW_COMMON_TIME_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
