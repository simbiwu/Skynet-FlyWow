#!/usr/bin/env python3
"""生成 FlyWow Gateway 的 command registry。

本工具只在构建阶段读取 .proto，不参与 Server 运行时；输出是可审查、可提交的 Lua registry。
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path


RPC_RE = re.compile(
    r"(?P<comments>(?:(?:\s*//[^\n]*\n)+))?\s*"
    r"rpc\s+(?P<name>[A-Za-z_]\w*)\s*\(\s*(?P<request>[A-Za-z_]\w*)\s*\)"
    r"\s*returns\s*\(\s*(?P<response>[A-Za-z_]\w*)\s*\)\s*;"
)


def parse_proto(source: str) -> tuple[str, list[dict[str, str | int]]]:
    """解析一个 service 的 RPC 合同；缺失 command_id 或重复 id 时失败。"""
    package_match = re.search(r"^\s*package\s+([\w.]+)\s*;", source, re.MULTILINE)
    if not package_match:
        raise ValueError("proto package is required")
    package = package_match.group(1)
    commands: list[dict[str, str | int]] = []
    seen: set[int] = set()
    for match in RPC_RE.finditer(source):
        comments = match.group("comments") or ""
        command_match = re.search(r"command_id\s*=\s*(\d+)", comments)
        if not command_match:
            raise ValueError(f"rpc {match.group('name')} is missing // command_id=<uint32>")
        command_id = int(command_match.group(1))
        if not 1 <= command_id <= 0xFFFFFFFF or command_id in seen:
            raise ValueError(f"invalid or duplicate command_id: {command_id}")
        seen.add(command_id)
        commands.append(
            {
                "id": command_id,
                "name": match.group("name"),
                "request": f".{package}.{match.group('request')}",
                "response": f".{package}.{match.group('response')}",
            }
        )
    if not commands:
        raise ValueError("proto must declare at least one rpc")
    return package, commands


def render(package: str, commands: list[dict[str, str | int]]) -> str:
    """将已验证的 command 定义渲染为确定性 Lua table。"""
    lines = [
        "-- 职责：由 proto service/rpc 结构生成的 FlyWow Gateway command registry。",
        "-- 边界：Build Artifact；运行时只读加载，不手工注册 command。",
        "-- 输入/输出：.proto -> Envelope command 到 request/response 类型的映射。",
        "-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。",
        "-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。",
        "return {",
        f'    envelope_type = ".{package}.Envelope",',
        "    commands = {",
    ]
    for command in sorted(commands, key=lambda item: int(item["id"])):
        lines.extend(
            [
                f'        [{command["id"]}] = {{',
                f'            name = "{command["name"]}",',
                f'            request_type = "{command["request"]}",',
                f'            response_type = "{command["response"]}",',
                "        },",
            ]
        )
    lines.extend(["    },", "}", ""])
    return "\n".join(lines)


def main() -> int:
    """执行 CLI；错误写到 stderr 并返回非零状态，不修改不完整输出。"""
    parser = argparse.ArgumentParser(description="Generate FlyWow Gateway Lua registry")
    parser.add_argument("--proto", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    package, commands = parse_proto(args.proto.read_text(encoding="utf-8"))
    output = render(package, commands)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.output.exists() or args.output.read_text(encoding="utf-8") != output:
        args.output.write_text(output, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
