# 职责：用真实固定 Lua 解释器加载真实 Native 模块，独立验证 ABI 与状态边界。
# 边界：集成测试；临时 BMAP 由测试生成，不读取商业或课程资产。
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib


class NavigationBindingTests(unittest.TestCase):
    """显式指定已构建 Native 和固定 Lua，避免替身测试被当成 ABI 验证。"""

    @unittest.skipUnless(os.environ.get('SKYNET_LUA') and os.environ.get('NAVIGATION_NATIVE_DIR'),
                         '需要 SKYNET_LUA 和 NAVIGATION_NATIVE_DIR 运行真实绑定测试')
    def test_real_binding_context_isolation_and_close(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            bmap = Path(directory) / 'map.bmap'
            oversized = Path(directory) / 'oversized.bmap'
            with oversized.open('wb') as stream:
                stream.truncate(128 * 1024 * 1024 + 1)
            # 5×5 平地；每格完整 V1 record 为 i32 高度、u16 flags、u8 Area、u8 Clearance。
            payload = struct.pack('<iHBB', 0, 1, 0, 1) * 25
            header = bytearray(64)
            header[:4] = b'BMAP'
            struct.pack_into('<HHIIIII', header, 4, 1, 64, 17, 2, 5, 5, 500)
            struct.pack_into('<H', header, 40, 8)
            struct.pack_into('<III', header, 44, len(payload), zlib.crc32(payload), 0)
            struct.pack_into('<I', header, 52, zlib.crc32(header))
            bmap.write_bytes(header + payload)
            result = subprocess.run([os.environ['SKYNET_LUA'],
                                     str(root / 'navigation/tests/navigation_binding_test.lua'), str(root),
                                     os.environ['NAVIGATION_NATIVE_DIR'], str(bmap), str(oversized)],
                                    text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('FLYWOW_NAVIGATION_BINDING_OK', result.stdout)
