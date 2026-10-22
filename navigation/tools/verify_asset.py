# 职责：发布/启动前验证 Navigation 包身份、空间合同、SHA-256 和 BMAP V1。
# 边界：离线 Asset Gate；只读文件，不加载 Unity，不注册 Native 地图。
# 输入：BMAP、Manifest、期望身份；输出：明确成功或异常，资源上限为 128 MiB。
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib


def verify(bmap, manifest, map_id=None, map_version=None, airnav=None):
    """校验完整发布包；输入路径归宿主，只读；返回 Manifest，失败抛 ValueError。

    检查文件大小后分配，最多 128 MiB；CRC 校验损坏，SHA-256 校验内容身份。
    同一个文件缓冲用于全部检查，不用第二次打开的字节参与本次结果。
    """
    if bmap.stat().st_size > 128 * 1024 * 1024 or manifest.stat().st_size > 65536:
        raise ValueError('NAVIGATION_ASSET_SIZE_LIMIT')

    # 同时限制实际读取，防止 stat 后文件增长使一次分配绕过上限。
    with bmap.open('rb') as stream:
        data = stream.read(128 * 1024 * 1024 + 1)
    if len(data) > 128 * 1024 * 1024:
        raise ValueError('NAVIGATION_ASSET_SIZE_LIMIT')

    with manifest.open('rb') as stream:
        text = stream.read(65537)
    if len(text) > 65536:
        raise ValueError('NAVIGATION_ASSET_SIZE_LIMIT')

    metadata = json.loads(text.decode('utf-8-sig'))
    if not isinstance(metadata, dict):
        raise ValueError('NAVIGATION_MANIFEST_INVALID')

    if len(data) < 64 or data[:4] != b'BMAP':
        raise ValueError('BMAP_HEADER_INVALID')
    fmt, header_size = struct.unpack_from('<HH', data, 4)
    identity, version, width, height, cell_size = struct.unpack_from('<IIIII', data, 8)
    stride = struct.unpack_from('<H', data, 40)[0]
    payload_size, payload_crc, header_crc = struct.unpack_from('<III', data, 44)
    if fmt != 1 or header_size != 64 or stride != 8:
        raise ValueError('BMAP_UNSUPPORTED_FORMAT')

    if not identity or not version or not width or not height or not cell_size:
        raise ValueError('BMAP_METADATA_INVALID')
    if len(data) != 64 + width * height * 8 or payload_size != len(data) - 64:
        raise ValueError('BMAP_SIZE_MISMATCH')

    header = bytearray(data[:64])
    header[52:56] = bytes(4)
    if zlib.crc32(header) != header_crc or zlib.crc32(data[64:]) != payload_crc:
        raise ValueError('BMAP_CRC_MISMATCH')

    if metadata.get('space_type') != 'ground_2_5d' or metadata.get('coordinate_axes') != 'x,y_height,z':
        raise ValueError('NAVIGATION_SPACE_UNSUPPORTED')

    expected = dict(format_version=fmt, map_id=identity, map_version=version,
                    width=width, height=height, cell_size_mm=cell_size,
                    origin_mm=list(struct.unpack_from('<ii', data, 28)),
                    payload_crc32=f'{payload_crc:08X}',
                    content_sha256=hashlib.sha256(data).hexdigest())
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError('NAVIGATION_MANIFEST_MISMATCH: ' + key)
    if map_id is not None and identity != map_id:
        raise ValueError('NAVIGATION_MAP_ID_MISMATCH')
    if map_version is not None and version != map_version:
        raise ValueError('NAVIGATION_MAP_VERSION_MISMATCH')
    declared = metadata.get('capabilities', [])
    if airnav is not None:
        if declared != ['air_2_5d']:
            raise ValueError('AIRNAV_MANIFEST_CAPABILITY')
        if airnav.stat().st_size > 32 * 1024 * 1024:
            raise ValueError('AIRNAV_SIZE_LIMIT')

        with airnav.open('rb') as stream:
            air = stream.read(32 * 1024 * 1024 + 1)
        verify_air(air, data)
        if metadata.get('airnav_sha256') != hashlib.sha256(air).hexdigest():
            raise ValueError('AIRNAV_HASH_MISMATCH')
        package_hash = hashlib.sha256(b'FlyWow.Navigation.Package.V1\0' +
            hashlib.sha256(data).digest() + b'\1' + hashlib.sha256(air).digest()).hexdigest()
        if metadata.get('package_hash') != package_hash:
            raise ValueError('NAVIGATION_PACKAGE_HASH_MISMATCH')
    elif declared or 'airnav_sha256' in metadata or 'package_hash' in metadata:
        raise ValueError('AIRNAV_EXPLICIT_PATH_REQUIRED')
    return metadata


def verify_air(air, bmap):
    """显式 little-endian 验证可选组件；不从地面高度猜障碍。"""
    if len(air) < 96 or len(air) > 32 * 1024 * 1024 or air[:4] != b'AIRN':
        raise ValueError('AIRNAV_HEADER')
    if struct.unpack_from('<HH', air, 4) != (1, 96) or air[8:36] != bmap[8:36]:
        raise ValueError('AIRNAV_METADATA')
    if air[36:40] != bytes(4) or air[80:96] != bytes(16):
        raise ValueError('AIRNAV_RESERVED')
    if air[40:72] != hashlib.sha256(bmap).digest():
        raise ValueError('AIRNAV_BMAP_PAIR')
    width, height = struct.unpack_from('<II', bmap, 16)
    records, count = struct.unpack_from('<II', air, 72)
    if records > width * height or count > 1048576 or len(air) != 96 + records*12 + count*16:
        raise ValueError('AIRNAV_LENGTH')
    expected, previous = 0, -1

    for i in range(records):
        cell, offset, length = struct.unpack_from('<III', air, 96+i*12)
        if cell <= previous or cell >= width*height or offset != expected or not 1 <= length <= 64 or offset+length > count:
            raise ValueError('AIRNAV_RECORD')
        last = None
        for j in range(length):
            low, high = struct.unpack_from('<qq', air, 96+records*12+(offset+j)*16)
            if low > high or (last is not None and low <= last):
                raise ValueError('AIRNAV_INTERVAL')
            last = high
        expected += length
        previous = cell

    if expected != count:
        raise ValueError('AIRNAV_UNREFERENCED_INTERVAL')


def main():
    """CLI 资产门禁；成功返回 0，校验或 I/O 失败由异常提供非零退出码。"""
    parser = argparse.ArgumentParser(description='验证 Navigation 发布包')
    parser.add_argument('--bmap', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--airnav', type=Path)
    parser.add_argument('--map-id', type=int)
    parser.add_argument('--map-version', type=int)
    args = parser.parse_args()
    result = verify(args.bmap, args.manifest, args.map_id, args.map_version, args.airnav)
    print('NAVIGATION_ASSET_OK map=' + str(result['map_id']) + ' hash=' + result['content_sha256'])


if __name__ == '__main__':
    main()
