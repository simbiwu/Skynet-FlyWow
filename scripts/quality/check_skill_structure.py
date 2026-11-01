#!/usr/bin/env python3
"""检查 FlyWow 三个 Skill 入口及其 references 的结构合同。"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKILLS = {
    ".agents/skills/skynet-flywow-coding-standard/SKILL.md":
        ("skynet-flywow-coding-standard", True),
    ".agents/skills/source-based-practical-teaching/SKILL.md":
        ("source-based-practical-teaching", False),
    ".agents/skills/flywow-engineering-workflow/SKILL.md":
        ("flywow-engineering-workflow", True),
}
REQUIRED_REFERENCES = (
    ".agents/skills/skynet-flywow-coding-standard/references/工程合同与最小设计.md",
    ".agents/skills/skynet-flywow-coding-standard/references/注释与可读性.md",
    ".agents/skills/skynet-flywow-coding-standard/references/Lua与Skynet.md",
    ".agents/skills/skynet-flywow-coding-standard/references/C++与Native.md",
    ".agents/skills/skynet-flywow-coding-standard/references/Shell与验证.md",
    ".agents/skills/flywow-engineering-workflow/references/需求分析与方案设计.md",
    ".agents/skills/flywow-engineering-workflow/references/分阶段实施.md",
    ".agents/skills/flywow-engineering-workflow/references/代码审计与复杂度审计.md",
    ".agents/skills/flywow-engineering-workflow/references/调试与根因分析.md",
    ".agents/skills/flywow-engineering-workflow/references/反模式与架构重置.md",
)


def read_utf8(path: Path) -> tuple[str | None, list[str]]:
    try:
        raw = path.read_bytes()
        errors = []
        if b"\x00" in raw:
            errors.append(f"{path.relative_to(ROOT)}: 包含 NUL byte")
        if b"\r" in raw:
            errors.append(f"{path.relative_to(ROOT)}: 必须使用 LF")
        if raw and not raw.endswith(b"\n"):
            errors.append(f"{path.relative_to(ROOT)}: 缺少末尾换行")
        try:
            return raw.decode("utf-8"), errors
        except UnicodeDecodeError as exc:
            errors.append(f"{path.relative_to(ROOT)}: 不是合法 UTF-8：{exc}")
            return None, errors
    except OSError as exc:
        return None, [f"{path.relative_to(ROOT)}: 无法读取：{exc}"]


def parse_frontmatter(text: str) -> tuple[dict[str, str] | None, str | None]:
    if not text.startswith("---\n"):
        return None, "缺少 YAML frontmatter 起始标记"
    end = text.find("\n---\n", 4)
    if end < 0:
        return None, "YAML frontmatter 未闭合"
    fields = {}
    for line in text[4:end].splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields[key.strip()] = value.strip().strip('"').strip("'")
    return fields, None


def check_skill_file(relative: str, expected_name: str) -> list[str]:
    path = ROOT / relative
    text, errors = read_utf8(path)
    if text is None:
        return errors
    fields, problem = parse_frontmatter(text)
    if problem:
        errors.append(f"{relative}: {problem}")
        return errors
    if fields.get("name") != expected_name:
        errors.append(f"{relative}: name 必须是 {expected_name}")
    description = fields.get("description", "")
    if not description or not re.search(r"[\u3400-\u9fff]", description):
        errors.append(f"{relative}: description 必须包含中文触发说明")
    if len(description) > 1024:
        errors.append(f"{relative}: description 超过 1024 字符")
    return errors


def check_references() -> list[str]:
    errors = []
    for relative in REQUIRED_REFERENCES:
        path = ROOT / relative
        if not path.is_file():
            errors.append(f"{relative}: 缺少必需 reference")
            continue
        text, read_errors = read_utf8(path)
        errors.extend(read_errors)
        if text is not None and not re.search(r"[\u3400-\u9fff]", text):
            errors.append(f"{relative}: reference 缺少中文正文")

    # 检查两个主 Skill 中显式写出的 references 相对链接。
    for skill_relative in (list(SKILLS)[0], list(SKILLS)[2]):
        skill_path = ROOT / skill_relative
        text, read_errors = read_utf8(skill_path)
        errors.extend(read_errors)
        if text is None:
            continue
        for target in re.findall(r"`(references/[^`]+\.md)`", text):
            resolved = (skill_path.parent / target).resolve()
            if not resolved.is_file():
                errors.append(f"{skill_relative}: reference 路径无效：{target}")
    return errors


def check_acceptance_cases() -> list[str]:
    path = ROOT / ".agents/skills/flywow-engineering-workflow/references/反模式与架构重置.md"
    text, errors = read_utf8(path)
    if text is None:
        return errors
    required = (
        "有调用者但可被更直接调用替代",
        "业务行为测试",
        "公开合同与内部文档",
        "重复传递、检查或转换",
        "保护机制",
        "完整替代设计",
    )
    for phrase in required:
        if phrase not in text:
            errors.append(f"{path.relative_to(ROOT)}: 缺少复杂度验收主题：{phrase}")
    return errors


def run_checks(root: Path = ROOT) -> list[str]:
    global ROOT
    original_root = ROOT
    ROOT = root.resolve()
    errors = []
    for relative, (name, _) in SKILLS.items():
        errors.extend(check_skill_file(relative, name))
    errors.extend(check_references())
    errors.extend(check_acceptance_cases())
    ROOT = original_root
    return errors


def main() -> int:
    errors = run_checks()
    if errors:
        print("\n".join(f"ERROR: {item}" for item in errors))
        return 1
    print("FlyWow Skill 入口、Frontmatter 与 references 检查通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
