# 职责：从唯一 UPM 源目录生成可复现离线安装包，支持 Windows 安装 WSL 开发包。
# 边界：Build Tool；归档是派生产物，不建立第二份可编辑源码。
# 输入：unity 源与显式产物目录；输出：内容标识 tgz，可选更新显式宿主 manifest。
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import tarfile
import tempfile


def package(source, output):
    """归档完整 Package，返回路径；执行离线 I/O，失败删除未完成临时文件。

    source 为只读 UPM 源码，output 为宿主拥有的产物目录。
    固定 tar/gzip 时间及用户字段，避免相同源码重复构建产生不同内容身份。
    """
    assets = sorted(item for item in source.rglob('*') if item.name != '.clang-format')
    for item in assets:
        if not item.name.endswith('.meta') and not Path(str(item) + '.meta').is_file():
            raise ValueError('UPM_META_MISSING: ' + str(item))
    output.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.navigation-', suffix='.tgz', dir=output)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        with temporary.open('wb') as stream:
            with gzip.GzipFile(fileobj=stream, mode='wb', filename='', mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w') as archive:
                    for item in [source] + assets:
                        name = 'package' if item == source else 'package/' + item.relative_to(source).as_posix()
                        info = archive.gettarinfo(str(item), arcname=name)
                        info.mtime = 0
                        info.uid = info.gid = 0
                        info.uname = info.gname = ''
                        if item.is_file():
                            with item.open('rb') as content:
                                archive.addfile(info, content)
                        else:
                            archive.addfile(info)
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        result = output / ('flywow-navigation-' + digest + '.tgz')
        if result.exists():
            if hashlib.sha256(result.read_bytes()).hexdigest() != digest:
                raise ValueError('UPM_ARTIFACT_CONFLICT')
        else:
            temporary.rename(result)
        return result
    finally:
        temporary.unlink(missing_ok=True)


def main():
    """生成安装产物；仅 --manifest 显式指定时更新宿主依赖，失败退出非零。"""
    parser = argparse.ArgumentParser(description='生成 FlyWow Navigation 离线 UPM 包')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--manifest', type=Path,
                        help='开发接入：显式更新宿主 manifest 的相对包依赖')
    args = parser.parse_args()
    artifact = package(Path(__file__).resolve().parents[1] / 'unity', args.output)
    if args.manifest:
        # 源码仍只有 framework/unity；这里只更新调用方明确选择的工程依赖。
        definition = json.loads(args.manifest.read_text(encoding='utf-8-sig'))
        relative = os.path.relpath(artifact.resolve(), args.manifest.parent.resolve())
        definition['dependencies']['com.flywow.navigation'] = 'file:' + relative.replace(os.sep, '/')
        definition['testables'] = sorted(set(definition.get('testables', []) + ['com.flywow.navigation']))
        content = json.dumps(definition, ensure_ascii=False, indent=2) + '\n'
        # 保留标准两空格排版，并在完整写盘后替换，避免留下半份 manifest。
        descriptor, staging = tempfile.mkstemp(prefix='.navigation-manifest-', dir=args.manifest.parent)
        os.close(descriptor)
        staging = Path(staging)
        try:
            staging.write_text(content, encoding='utf-8')
            staging.replace(args.manifest)
        finally:
            staging.unlink(missing_ok=True)
    print(artifact)


if __name__ == '__main__':
    main()
