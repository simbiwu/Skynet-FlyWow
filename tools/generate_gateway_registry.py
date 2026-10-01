#!/usr/bin/env python3
"""生成 FlyWow Gateway command registry。

边界：FlyWow Build Tool；只在构建阶段读取宿主 .proto。
输入/输出：proto3 package、Envelope、service/rpc -> 确定性 Lua registry。
生命周期/所有权：每次构建独立运行；原子替换输出，不保存跨运行状态。
不负责：不参与 Server Runtime，不替代 protoc，不生成业务 handler。
"""
from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


# 仅提取 Gateway 使用的单层 rpc 声明；command_id 必须紧邻声明前的行注释中。
# 命名组供 parse_proto 构造稳定 registry；完整 Proto 语义仍由 protoc 校验。
RPC_RE = re.compile(
    r"(?P<comments>(?:(?:\s*//[^\n]*\n)+))?\s*"
    r"rpc\s+(?P<name>[A-Za-z_]\w*)\s*\(\s*(?P<request>[A-Za-z_]\w*)\s*\)"
    r"\s*returns\s*\(\s*(?P<response>[A-Za-z_]\w*)\s*\)\s*;"
)


def _structural_source(source: str) -> str:
    """移除注释和字符串，仅供花括号与声明结构检查。

    source 是调用方拥有的完整 Proto 文本；返回新字符串，仅保留结构检查所需内容。
    不执行 I/O，时间/空间复杂度 O(n)；本处理不代替 protoc 的完整语法和类型检查。
    """
    without_blocks = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    without_lines = re.sub(r"//[^\n]*", "", without_blocks)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', without_lines)


def parse_proto(source: str) -> tuple[str, list[dict[str, str | int]]]:
    """解析宿主 Proto 的 Gateway RPC 合同。

    source 是调用方拥有的完整 proto3 文本；返回 package 字符串及按源顺序生成的 command record 列表。
    每条 record 含 uint32 id、方法名和带 package 的 request/response 类型名。
    缺少 package/Envelope/rpc/消息、结构失衡、command_id 缺失/重复/越界时抛 ValueError；不执行 I/O。
    此轻量解析器只接受约定的单层消息和 rpc 形态，完整语法由 protoc 负责。
    """
    structural = _structural_source(source)
    if not re.search(r'^\s*syntax\s*=\s*"proto3"\s*;', source, re.MULTILINE):
        raise ValueError('syntax = "proto3" is required')
    if structural.count("{") != structural.count("}"):
        raise ValueError("proto braces are unbalanced")
    package_match = re.search(r"^\s*package\s+([\w.]+)\s*;", source, re.MULTILINE)
    if not package_match:
        raise ValueError("proto package is required")
    package = package_match.group(1)
    messages = set(re.findall(r"\bmessage\s+([A-Za-z_]\w*)\s*\{", structural))
    if "Envelope" not in messages:
        raise ValueError("proto must declare message Envelope")
    commands: list[dict[str, str | int]] = []
    seen: set[int] = set()
    for match in RPC_RE.finditer(source):
        comments = match.group("comments") or ""
        # command_id 是线上 Envelope 的稳定路由值；重复或越界会造成歧义，因此在生成期拒绝。
        command_match = re.search(r"command_id\s*=\s*(\d+)", comments)
        if not command_match:
            raise ValueError(f"rpc {match.group('name')} is missing // command_id=<uint32>")
        command_id = int(command_match.group(1))
        if not 1 <= command_id <= 0xFFFFFFFF or command_id in seen:
            raise ValueError(f"invalid or duplicate command_id: {command_id}")
        seen.add(command_id)
        request_name = match.group("request")
        response_name = match.group("response")
        if request_name not in messages or response_name not in messages:
            raise ValueError(
                f"rpc {match.group('name')} request/response must be messages declared in the same proto"
            )
        commands.append(
            {
                "id"      : command_id,
                "name"    : match.group("name"),
                "request" : f".{package}.{request_name}",
                "response": f".{package}.{response_name}",
            }
        )
    if not commands:
        raise ValueError("proto must declare at least one rpc")
    return package, commands


def render(package: str, commands: list[dict[str, str | int]]) -> str:
    """将已验证 command definitions 渲染为确定性 Lua table。

    package 是 Proto package 名；commands 是 parse_proto 返回的 record 列表，函数只读输入。
    返回 UTF-8/LF Lua 源文本；按数值 command id 排序以避免输入顺序改变生成物。
    输入须符合 parse_proto 的输出合同；不执行 I/O。
    """
    lines = [
        "-- 职责：由 proto service/rpc 结构生成的 FlyWow Gateway command registry。",
        "-- 边界：Build Artifact；运行时只读加载，不手工注册 command。",
        "-- 输入/输出：.proto -> Envelope command 到 request/response 类型的映射。",
        "-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。",
        "-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。",
        "return",
        "{",
        f'    envelope_type = ".{package}.Envelope",',
        "    commands      =",
        "    {",
    ]
    # 生成物按数值 id 排序，保证相同协议无论 rpc 声明顺序如何都得到稳定 diff。
    for command in sorted(commands, key=lambda item: int(item["id"])):
        lines.extend(
            [
                f'        [{command["id"]}] =',
                "        {",
                f'            name          = "{command["name"]}",',
                f'            request_type  = "{command["request"]}",',
                f'            response_type = "{command["response"]}",',
                "        },",
            ]
        )
    lines.extend(["    },", "}", ""])
    return "\n".join(lines)


def write_if_changed(path: Path, content: str) -> None:
    """仅在内容变化时原子替换生成物。

    path 是构建输出目标，content 是已完整渲染的 UTF-8/LF Lua 文本；调用方拥有输入字符串。
    相同内容不触碰文件或 mtime；变化时先在目标目录写入并 fsync，再用 os.replace 原子发布完整文件。
    读写失败向上传播 OSError；finally 尽力删除尚未发布的临时文件，不留下半个 registry。
    写入需要目标目录权限并会修改 path 指向的生成物；不执行网络 I/O。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_name = temporary.name
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            Path(temporary_name).unlink(missing_ok=True)


def main() -> int:
    """执行构建期 CLI；读取 --proto/--output，成功返回 0。

    成功返回 0；协议合同或文件操作失败时异常使进程以非零状态退出。
    只在协议内容变化时原子更新生成文件；不启动 Skynet、不读取运行时配置。
    """
    parser = argparse.ArgumentParser(description="Generate FlyWow Gateway Lua registry")
    parser.add_argument("--proto", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    package, commands = parse_proto(args.proto.read_text(encoding="utf-8"))
    output = render(package, commands)
    write_if_changed(args.output, output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
