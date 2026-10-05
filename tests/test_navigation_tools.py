# 职责：验证独立模块路径选择和资产发布门禁的拒绝行为。
# 边界：Python 单元测试；所有输入使用临时目录，不依赖宿主工程。
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    """加载待测工具；只执行模块定义，CLI main 不会运行。"""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


asset = load('verify_navigation_asset', ROOT / 'navigation/tools/verify_asset.py')
paths = load('flywow_module_paths', ROOT / 'tools/module_paths.py')


class NavigationToolsTests(unittest.TestCase):
    """锁定资产损坏、身份错误以及错误模块配置的早期拒绝。"""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        payload = struct.pack('<iBBBB', 0, 1, 0, 1, 0)
        header = bytearray(64)
        header[:4] = b'BMAP'
        struct.pack_into('<HHIIIII', header, 4, 1, 64, 17, 2, 1, 1, 500)
        struct.pack_into('<H', header, 40, 8)
        struct.pack_into('<III', header, 44, len(payload), zlib.crc32(payload), 0)
        struct.pack_into('<I', header, 52, zlib.crc32(header))
        self.bmap = self.root / 'map.bmap'
        self.manifest = self.root / 'map.manifest.json'
        self.bmap.write_bytes(header + payload)
        self.metadata = dict(format_version=1, map_id=17, map_version=2,
                             width=1, height=1, cell_size_mm=500, origin_mm=[0, 0],
                             payload_crc32=f'{zlib.crc32(payload):08X}',
                             space_type='ground_2_5d', coordinate_axes='x,y_height,z',
                             content_sha256=hashlib.sha256(header + payload).hexdigest())
        self.write_manifest()

    def write_manifest(self):
        """将当前测试元数据写到独占临时文件；不修改真实资产。"""
        self.manifest.write_text(json.dumps(self.metadata))

    def test_valid_asset_and_expected_identity(self):
        self.assertEqual(asset.verify(self.bmap, self.manifest, 17, 2), self.metadata)
        with self.assertRaisesRegex(ValueError, 'MAP_ID_MISMATCH'):
            asset.verify(self.bmap, self.manifest, 18, 2)
        with self.assertRaisesRegex(ValueError, 'MAP_VERSION_MISMATCH'):
            asset.verify(self.bmap, self.manifest, 17, 3)

    def test_payload_damage_and_truncation_are_rejected(self):
        original = self.bmap.read_bytes()
        damaged = bytearray(original)
        damaged[-1] ^= 1
        self.bmap.write_bytes(damaged)
        with self.assertRaisesRegex(ValueError, 'CRC_MISMATCH'):
            asset.verify(self.bmap, self.manifest)
        self.bmap.write_bytes(original[:-1])
        with self.assertRaisesRegex(ValueError, 'SIZE_MISMATCH'):
            asset.verify(self.bmap, self.manifest)

    def test_wrong_manifest_hash_and_space_are_rejected(self):
        self.metadata['content_sha256'] = '0' * 64
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'MANIFEST_MISMATCH: content_sha256'):
            asset.verify(self.bmap, self.manifest)
        self.metadata['space_type'] = 'volume_3d'
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'SPACE_UNSUPPORTED'):
            asset.verify(self.bmap, self.manifest)

    def test_oversized_asset_is_rejected_before_read(self):
        with self.bmap.open('wb') as stream:
            stream.truncate(128 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(ValueError, 'SIZE_LIMIT'):
            asset.verify(self.bmap, self.manifest)

    def test_wrong_origin_is_rejected(self):
        self.metadata['origin_mm'] = [500, 0]
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'MANIFEST_MISMATCH: origin_mm'):
            asset.verify(self.bmap, self.manifest)

    def test_navigation_only_does_not_load_gateway_paths(self):
        (self.root / 'navigation/lualib').mkdir(parents=True)
        text = paths.generate(self.root, ['navigation'], self.root / 'build')
        self.assertIn('navigation/lualib/?.lua', text)
        self.assertNotIn('gateway', text)
        self.assertNotIn('luaservice =', text)
        self.assertIn('lua_cpath =', text)

    def test_invalid_module_selection_fails_before_output(self):
        for selection in [['unknown'], ['navigation', 'navigation'], ['gateway']]:
            with self.assertRaises(ValueError):
                paths.generate(self.root, selection, None)


if __name__ == '__main__':
    unittest.main()
