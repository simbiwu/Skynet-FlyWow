# 职责：使用显式提供的 pinned Lua 运行 Gateway 真实源码合同测试。
# 边界：Test Runner；不下载解释器、不连接网络、不启动宿主服务。
# 输入/输出：SKYNET_LUA 与当前 FlyWow 根路径 -> unittest 结果。
# 生命周期：每次测试启动一个短命 Lua 子进程，超时后由 subprocess 终止。
# 不负责：没有解释器时明确跳过，不把跳过视为 Gateway 已验证。
import os
from pathlib import Path
import subprocess
import unittest


class GatewayAsyncTests(unittest.TestCase):
    # 使用宿主固定版本解释器；必须显式注入，不猜测开发机路径。
    def test_async_contract(self):
        lua = os.environ.get("SKYNET_LUA")
        if not lua:
            self.skipTest("需要显式设置 SKYNET_LUA 为 pinned Skynet 的 Lua")
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run([lua, str(root / "tests/gateway_async_test.lua"), str(root)],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GATEWAY_ASYNC_UNIT_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
