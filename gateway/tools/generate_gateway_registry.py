#!/usr/bin/env python3
"""生成 FlyWow Gateway command registry。

边界：FlyWow Build Tool；只在构建阶段读取宿主 .proto。
输入/输出：proto3 package、CommandId、Request/可选 Response -> 确定性 Lua registry。
命令规则：
1. .proto 必须声明 enum CommandId；每个非零枚举项是一个业务命令。
2. 枚举名按 QUERY_CELL -> QueryCell 转换为消息前缀。
3. XxxRequest 和 XxxResponse 都可选；两者都有是请求-响应，只有 Request 是单向请求，只有 Response 是主动下发。
4. 不读取 service/rpc，不解析注释，不引入自定义 Protobuf option。
生命周期/所有权：每次构建独立运行；原子替换输出，不保存跨运行状态。
不负责：不参与 Server Runtime，不替代 protoc，不生成业务 handler。
"""
from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path


ENUM_RE = re.compile(
    r"\benum\s+CommandId\s*\{(?P<body>.*?)\}",
    re.DOTALL,
)
ENUM_VALUE_RE = re.compile(
    r"\b(?P<name>[A-Z][A-Z0-9_]+)\s*=\s*(?P<id>\d+)\s*;"
)
MESSAGE_RE = re.compile(r"\bmessage\s+(?P<name>[A-Za-z_]\w*)\s*\{")


def _without_comments(source: str) -> str:
    """移除注释，避免注释中的伪声明被当成协议结构。"""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def _pascal_name(enum_name: str) -> str:
    """把 QUERY_CELL 转换为 QueryCell；命令枚举使用全大写下划线形式。"""
    return "".join(part[:1] + part[1:].lower() for part in enum_name.split("_") if part)


def parse_proto(source: str) -> tuple[str, list[dict[str, str | int | None]]]:
    """解析 CommandId 和消息命名合同，返回可生成的命令记录。"""
    structural = _without_comments(source)

    if not re.search(r'^\s*syntax\s*=\s*"proto3"\s*;', source, re.MULTILINE):
        raise ValueError('syntax = "proto3" is required')

    package_match = re.search(
        r"^\s*package\s+([\w.]+)\s*;",
        structural,
        re.MULTILINE,
    )
    if not package_match:
        raise ValueError("proto package is required")
    package = package_match.group(1)

    if "Envelope" not in {
        match.group("name") for match in MESSAGE_RE.finditer(structural)
    }:
        raise ValueError("proto must declare message Envelope")

    message_names = {
        match.group("name")
        for match in MESSAGE_RE.finditer(structural)
    }

    enum_match = ENUM_RE.search(structural)
    if not enum_match:
        raise ValueError("proto must declare enum CommandId")

    commands: list[dict[str, str | int | None]] = []
    seen_ids: set[int] = set()
    seen_names: set[str] = set()

    for match in ENUM_VALUE_RE.finditer(enum_match.group("body")):
        enum_name = match.group("name")
        command_id = int(match.group("id"))

        if enum_name == "COMMAND_UNSPECIFIED":
            if command_id != 0:
                raise ValueError("COMMAND_UNSPECIFIED must be zero")
            continue

        if not 1 <= command_id <= 0xFFFFFFFF:
            raise ValueError(f"invalid command id: {command_id}")
        if command_id in seen_ids:
            raise ValueError(f"duplicate command id: {command_id}")
        seen_ids.add(command_id)

        method_name = _pascal_name(enum_name)
        request_name = f"{method_name}Request"
        response_name = f"{method_name}Response"

        request_type = (
            f".{package}.{request_name}"
            if request_name in message_names
            else None
        )
        response_type = (
            f".{package}.{response_name}"
            if response_name in message_names
            else None
        )
        if method_name in seen_names:
            raise ValueError(f"duplicate command method name: {method_name}")
        seen_names.add(method_name)

        commands.append(
            {
                "id": command_id,
                "enum_name": enum_name,
                "name": method_name,
                "request": request_type,
                "response": response_type,
            }
        )

    if not commands:
        raise ValueError("CommandId must declare at least one command")

    return package, commands


def render(
    package: str,
    commands: list[dict[str, str | int | None]],
) -> str:
    """将命令记录渲染为确定性 Lua table。"""
    lines = [
        "-- 职责：由 proto CommandId 和 Request/Response 消息生成的 FlyWow Gateway command registry。",
        "-- 边界：Build Artifact；运行时只读加载，不手工注册 command。",
        "-- 输入/输出：CommandId + 可选 XxxRequest/XxxResponse -> Envelope command 映射。",
        "-- 生命周期：协议生成后随 Server 产物发布；Gateway 启动时加载并校验。",
        "-- 不负责：不实现业务 handler、不读取 Socket、不动态解析 .proto。",
        "local command_ids =",
        "    {",
    ]

    for command in sorted(commands, key=lambda item: str(item["enum_name"])):
        lines.append(
            f'        {command["enum_name"]} = {command["id"]},'
        )

    lines.extend(
        [
            "    }",
            "return",
            "{",
            f'    envelope_type = ".{package}.Envelope",',
            "    command_ids   = command_ids,",
            "    commands      =",
            "    {",
        ]
    )

    for command in sorted(commands, key=lambda item: int(item["id"])):
        request = (
            f'"{command["request"]}"'
            if command["request"] is not None
            else "nil"
        )
        response = (
            f'"{command["response"]}"'
            if command["response"] is not None
            else "nil"
        )
        lines.extend(
            [
                f'        [command_ids.{command["enum_name"]}] =',
                "        {",
                f'            name          = "{command["name"]}",',
                f"            request_type  = {request},",
                f"            response_type = {response},",
                "        },",
            ]
        )

    lines.extend(["    },", "}", ""])
    return "\n".join(lines)


def write_if_changed(path: Path, content: str) -> None:
    """仅在内容变化时原子替换生成物。"""
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
    """执行构建期 CLI。"""
    parser = argparse.ArgumentParser(
        description="Generate FlyWow Gateway Lua registry",
    )
    parser.add_argument("--proto", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    package, commands = parse_proto(
        args.proto.read_text(encoding="utf-8"),
    )
    write_if_changed(
        args.output,
        render(package, commands),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
