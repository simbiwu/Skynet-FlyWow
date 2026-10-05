# 职责：按宿主选择的模块生成 Skynet 启动搜索路径，避免手工维护重复路径。
# 边界：Build 配置生成器；只写指定输出，不启动 Service，不读取业务配置。
# 输入：框架根、模块名、Native 产物目录；输出：可被 Skynet include 的 Lua 配置。
# 生命周期：启动前调用；未知模块、缺失目录、非法路径立即失败。
import argparse
import json
from pathlib import Path


def generate(root, modules, native):
    """验证模块并返回路径配置文本；路径只读，不执行运行时 I/O 或 yield。

    root 为框架根目录；modules 为不重复的启用模块列表；native 为宿主 Native 输出。
    返回新文本；未知模块、重复模块或缺失目录抛 ValueError，不猜测部署路径。
    """
    if len(set(modules)) != len(modules):
        raise ValueError('不能重复启用模块')
    lua, services = [], []
    for module in modules:
        if module not in ('gateway', 'navigation'):
            raise ValueError('未知模块: ' + module)
        directory = root / module
        if not directory.is_dir():
            raise ValueError('模块目录不存在: ' + str(directory))
        if (directory / 'lualib').is_dir():
            lua += [str(directory / 'lualib/?.lua'), str(directory / 'lualib/?/init.lua')]
        if (directory / 'service').is_dir():
            services.append(str(directory / 'service/?.lua'))
    values = [('lua_path', lua), ('luaservice', services)]
    if native:
        values.append(('lua_cpath', [str(native / '?.so')]))
    lines = ['--- 构建生成：追加宿主显式启用的 FlyWow 路径；不启动 Service。']
    for key, paths in values:
        if paths:
            value = ';' + ';'.join(paths)
            # Skynet 配置会替换 $NAME；不能让路径被意外展开。
            if any(c in value for c in ('$', '\n', '\r')):
                raise ValueError('路径含不支持的配置字符')
            lines.append(key + ' = ' + key + ' .. ' + json.dumps(value, ensure_ascii=False))
    return '\n'.join(lines) + '\n'


def main():
    """命令行生成入口；输出目录归宿主，参数失败返回非零，不修改其他配置。

    执行少量文件 I/O；模块选择只影响搜索路径，不自动启动模块或加载资产。
    """
    parser = argparse.ArgumentParser(description='生成 FlyWow 模块搜索路径')
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--modules', nargs='+', required=True)
    parser.add_argument('--native', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    content = generate(args.root.resolve(), args.modules, args.native.resolve() if args.native else None)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content, encoding='utf-8')


if __name__ == '__main__':
    main()
