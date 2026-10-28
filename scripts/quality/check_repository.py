# 职责：由开发者在本地检查 Skynet-FlyWow 的最小仓库、文本、Skill 与变更函数注释合同。
# 边界：Build/Test Tooling；只读扫描仓库，不修改源码、不连接网络、不启动 Skynet。
# 输入/输出：仓库根目录 -> 中文诊断与 0（通过）/1（失败）进程退出码。
# 生命周期：由开发者按需执行；不保存跨运行状态。
# 不负责：不替代语言编译、模块测试、注释语义审查、性能测试或安全审计。

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable


# 这些文件构成初始化仓库对接入者和自动化工具承诺的最小工程合同。
REQUIRED_FILES = (
    ".editorconfig",
    ".gitattributes",
    ".agents/skills/skynet-flywow-coding-standard/SKILL.md",
    ".github/workflows/quality.yml",
    "AGENTS.md",
    "README.md",
    "docs/采用指南.md",
    "docs/架构说明.md",
    "docs/工程决策.md",
    "docs/模块标准.md",
    "docs/质量门禁.md",
    "docs/路线图.md",
    "docs/版本管理.md",
)
TEXT_SUFFIXES = {
    ".c", ".cc", ".cmake", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx",
    ".lua", ".md", ".proto", ".py", ".sh", ".txt", ".yaml", ".yml",
}
TEXT_NAMES = {".editorconfig", ".gitattributes", ".gitignore", "CMakeLists.txt", "Makefile"}
CHINESE_PATTERN = re.compile(r"[\u3400-\u9fff]")
LUA_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z_]\w*$")
LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}


def iter_text_files(root: Path) -> Iterable[Path]:
    """枚举仓库内受文本合同约束的文件；只读遍历，不修改文件。"""

    for path in sorted(root.rglob("*")):
        relative_parts = path.relative_to(root).parts
        if ".git" in relative_parts or (relative_parts and relative_parts[0] == "build") or not path.is_file():
            continue
        if path.suffix.lower() in TEXT_SUFFIXES or path.name in TEXT_NAMES:
            yield path


def check_text_content(path: Path, content: bytes) -> list[str]:
    """验证单个文本文件采用 UTF-8、LF、末尾换行且没有 NUL。"""

    errors: list[str] = []
    if b"\x00" in content:
        errors.append(f"{path}: 文本文件包含 NUL byte")
    if b"\r" in content:
        errors.append(f"{path}: 必须使用 LF，不能包含 CR/CRLF")
    if content and not content.endswith(b"\n"):
        errors.append(f"{path}: 文件末尾缺少换行")
    if content.endswith(b"\n\n"):
        errors.append(f"{path}: 文件末尾存在多余空白行")
    try:
        content.decode("utf-8")
    except UnicodeDecodeError as exception:
        errors.append(f"{path}: 不是合法 UTF-8：{exception}")
    return errors


def check_markdown(path: Path, text: str) -> list[str]:
    """检查中文 Markdown 与代码围栏的最低结构合同，不替代 Markdown parser。"""

    errors: list[str] = []
    if not CHINESE_PATTERN.search(text):
        errors.append(f"{path}: 工程文档或 Skill 缺少中文正文")
    for marker in ("```", "~~~"):
        count = sum(1 for line in text.splitlines() if line.startswith(marker))
        if count % 2 != 0:
            errors.append(f"{path}: {marker} 代码围栏数量为 {count}，没有成对闭合")
    if "[TODO" in text or "[TBD" in text:
        errors.append(f"{path}: 保留了初始化占位符")
    return errors


def check_quality_workflow(root: Path) -> list[str]:
    """确认 CI 会运行门禁单测，并按提交基线扫描变更 Lua 函数。"""

    path = root / ".github/workflows/quality.yml"
    if not path.is_file():
        return [f"{path}: 缺少自动质量门禁工作流"]
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exception:
        return [f"{path}: 无法读取质量门禁工作流：{exception}"]

    errors: list[str] = []
    required_fragments = {
        "pull_request:": "必须在 Pull Request 上运行",
        "push:": "必须在推送提交时运行",
        "fetch-depth: 0": "必须获取基线历史以扫描提交差异",
        "python -m unittest discover -s scripts/quality -p 'test_*.py'": "必须运行门禁单测",
        "python scripts/quality/check_repository.py --base-ref": "必须按提交基线扫描变更函数",
    }
    for fragment, message in required_fragments.items():
        if fragment not in text:
            errors.append(f"{path}: {message}")
    return errors


def check_skill(root: Path) -> list[str]:
    """验证 P0 编码规范 Skill 的身份与中文描述。"""

    path = root / ".agents/skills/skynet-flywow-coding-standard/SKILL.md"
    if not path.is_file():
        return [f"{path}: 缺少 P0 编码规范 Skill"]
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exception:
        return [f"{path}: 无法读取 Skill：{exception}"]
    if not text.startswith("---\n"):
        return [f"{path}: 缺少 YAML frontmatter 起始标记"]
    parts = text.split("---\n", 2)
    if len(parts) < 3:
        return [f"{path}: YAML frontmatter 没有闭合"]
    frontmatter = parts[1]
    errors: list[str] = []
    if "name: skynet-flywow-coding-standard\n" not in frontmatter:
        errors.append(f"{path}: Skill name 不符合稳定标识")
    description = next(
        (line.removeprefix("description:").strip() for line in frontmatter.splitlines()
         if line.startswith("description:")),
        "",
    )
    if not description or not CHINESE_PATTERN.search(description):
        errors.append(f"{path}: Skill description 必须提供中文触发说明")
    return errors


def _long_bracket_end(source: str, start: int) -> tuple[int, int] | None:
    """返回 Lua 长字符串/长注释的结束偏移与结束行；未闭合时视为到文件末尾。"""

    match = re.match(r"\[(=*)\[", source[start:])
    if not match:
        return None
    opener = match.group(0)
    closer = "]" + match.group(1) + "]"
    content_start = start + len(opener)
    closing_start = source.find(closer, content_start)
    end = len(source) if closing_start < 0 else closing_start + len(closer)
    return end, source[start:end].count("\n")


def _tokenize_lua(source: str) -> list[tuple[str, int]]:
    """跳过注释和字符串，保留 Lua 关键字与行号供函数范围识别使用。"""

    tokens: list[tuple[str, int]] = []
    index = 0
    line = 1
    length = len(source)

    while index < length:
        char = source[index]

        if char.isspace():
            if char == "\n":
                line += 1
            index += 1
            continue

        if source.startswith("--", index):
            long_comment = _long_bracket_end(source, index + 2)
            if long_comment:
                end, line_delta = long_comment
                index = end
                line += line_delta
            else:
                newline = source.find("\n", index)
                index = length if newline < 0 else newline
            continue

        if char in ("'", '"'):
            quote = char
            index += 1
            while index < length:
                if source[index] == "\\":
                    if index + 1 < length and source[index + 1] == "\n":
                        line += 1
                    index += 2
                    continue
                if source[index] == quote:
                    index += 1
                    break
                if source[index] == "\n":
                    line += 1
                index += 1
            continue

        long_string = _long_bracket_end(source, index) if char == "[" else None
        if long_string:
            end, line_delta = long_string
            index = end
            line += line_delta
            continue

        if char.isalpha() or char == "_":
            start = index
            index += 1
            while index < length and (source[index].isalnum() or source[index] == "_"):
                index += 1
            tokens.append((source[start:index], line))
            continue

        tokens.append((char, line))
        index += 1

    return tokens


def find_lua_named_function_spans(source: str) -> list[tuple[int, int]]:
    """识别具名 Lua 函数的起止行；不尝试判断匿名回调的语义质量。"""

    tokens = _tokenize_lua(source)
    blocks: list[dict[str, object]] = []
    spans: list[tuple[int, int]] = []

    for index, (value, token_line) in enumerate(tokens):
        if value == "function":
            next_value = tokens[index + 1][0] if index + 1 < len(tokens) else ""
            named = bool(LUA_IDENTIFIER_PATTERN.match(next_value)) and next_value not in LUA_KEYWORDS
            blocks.append({"kind": "function", "start": token_line, "named": named})
        elif value == "if":
            blocks.append({"kind": "if"})
        elif value in ("for", "while"):
            blocks.append({"kind": value, "awaiting_do": True})
        elif value == "do":
            if blocks and blocks[-1].get("kind") in ("for", "while") and blocks[-1].get("awaiting_do"):
                blocks[-1]["awaiting_do"] = False
            else:
                blocks.append({"kind": "do"})
        elif value == "repeat":
            blocks.append({"kind": "repeat"})
        elif value == "end":
            if not blocks:
                continue
            block = blocks.pop()
            if block.get("kind") == "function" and block.get("named"):
                spans.append((int(block["start"]), token_line))
        elif value == "until":
            if blocks and blocks[-1].get("kind") == "repeat":
                blocks.pop()

    return sorted(spans)


def _is_nontrivial_lua_function(source_lines: list[str], start_line: int, end_line: int) -> bool:
    """用保守的结构启发式排除单步函数；复杂判断和状态操作必须有说明。"""

    body_lines = [
        line.strip()
        for line_number, line in enumerate(source_lines, start=1)
        if start_line < line_number < end_line
        and line.strip()
        and not line.strip().startswith("--")
        and line.strip() not in {"end", "end,"}
    ]
    if len(body_lines) >= 3:
        return True

    body = "\n".join(body_lines)
    if re.search(r"\b(if|for|while|repeat|pcall|xpcall)\b", body):
        return True
    if re.search(r"\b(skynet\.(call|send|wait)|coroutine\.yield|hotupgrade_native\.|load\s*\()", body):
        return True
    if re.search(r"\b(self|batch|module_state)\.[A-Za-z_]\w*\s*=", body):
        return True
    return False


def _has_lua_function_summary(source_lines: list[str], start_line: int) -> bool:
    """要求函数声明前存在紧邻的职责说明；单独的 @param/@return 标签不算职责说明。"""

    index = start_line - 2
    while index >= 0:
        stripped = source_lines[index].strip()
        if not stripped:
            break
        if not stripped.startswith("--"):
            break
        comment_body = stripped.lstrip("-").strip()
        if comment_body and not comment_body.startswith("@"):
            return True
        index -= 1
    return False


def _lua_doc_block(source_lines: list[str], start_line: int) -> list[str]:
    """读取函数声明前紧邻的 LuaDoc 行；普通注释摘要也包含在同一块中。"""

    index = start_line - 2
    block: list[str] = []
    while index >= 0 and source_lines[index].strip().startswith("---"):
        block.append(source_lines[index].strip())
        index -= 1
    return block


def _lua_function_parameters(source_lines: list[str], start_line: int) -> list[str]:
    """从具名函数声明读取显式参数名；Lua 参数列表不支持嵌套表达式。"""

    signature = " ".join(source_lines[start_line - 1:start_line + 3])
    match = re.search(r"\bfunction\s+(?:[A-Za-z_]\w*(?:[.:][A-Za-z_]\w*)*)?\s*\(([^)]*)\)", signature)
    if not match:
        return []
    return [parameter.strip() for parameter in match.group(1).split(",") if parameter.strip()]


def _missing_lua_param_annotations(source_lines: list[str], start_line: int) -> list[str]:
    """返回缺少 LuaDoc 的业务参数；self 和丢弃参数不要求重复说明。"""

    documented: dict[str, bool] = {}
    for line in _lua_doc_block(source_lines, start_line):
        match = re.match(r"---@param\s+(\S+)\s+\S+(?:\s+(.+))?$", line)
        if match:
            parameter_name = match.group(1).rstrip("?")
            description = match.group(2) or ""
            documented[parameter_name] = bool(description and CHINESE_PATTERN.search(description))

    return [
        parameter for parameter in _lua_function_parameters(source_lines, start_line)
        if parameter not in {"self", "_"} and not documented.get(parameter, False)
    ]


def _has_lua_return_annotation(source_lines: list[str], start_line: int) -> bool:
    """检查函数声明前紧邻的 LuaDoc 是否描述返回类型和中文合同。"""

    return_lines = [
        line for line in _lua_doc_block(source_lines, start_line)
        if line.startswith("---@return")
    ]
    annotations = [
        match.groups()
        for line in return_lines
        if (match := re.match(r"---@return\s+(\S+)(?:\s+(.+))?$", line))
    ]
    if not annotations or len(annotations) != len(return_lines):
        return False
    return all(
        type_name == "nil" or (description is not None and CHINESE_PATTERN.search(description))
        for type_name, description in annotations
    )


def _inline_lua_control_body_lines(source_lines: list[str], start_line: int, end_line: int) -> list[int]:
    """用 Lua token 定位把 if/loop 主体与控制头挤在同一行的代码。"""

    function_source = "\n".join(source_lines[start_line - 1:end_line])
    tokens = _tokenize_lua(function_source)
    violations: set[int] = set()

    for index, (value, token_line) in enumerate(tokens):
        next_line = tokens[index + 1][1] if index + 1 < len(tokens) else -1
        if value in {"then", "do", "else"} and next_line == token_line:
            violations.add(start_line + token_line - 1)
        if value == "repeat":
            for next_value, next_token_line in tokens[index + 1:]:
                if next_value == "until":
                    if next_token_line == token_line:
                        violations.add(start_line + token_line - 1)
                    break
                if next_value == "repeat":
                    break

    return sorted(violations)


def _lua_phase_boundaries(source_lines: list[str], start_line: int, end_line: int) -> list[tuple[int, int]]:
    """定位同级控制块结束后继续执行的阶段边界，不依赖函数行数。"""

    body_indent = None
    for line_number in range(start_line, end_line - 1):
        line = source_lines[line_number]
        if line.strip() and not line.lstrip().startswith("--"):
            body_indent = len(line) - len(line.lstrip())
            break
    if body_indent is None:
        return []

    function_source = "\n".join(source_lines[start_line - 1:end_line])
    closing_control_lines = {
        start_line + token_line - 1
        for value, token_line in _tokenize_lua(function_source)
        if value in {"end", "until"}
    }

    boundaries: list[tuple[int, int]] = []
    for index in range(start_line, end_line - 1):
        line = source_lines[index]
        line_number = index + 1
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        closes_block = stripped == "end" or stripped.startswith("until ")
        if indent != body_indent or not closes_block or line_number not in closing_control_lines:
            continue

        next_statement = None
        for next_index in range(index + 1, end_line - 1):
            next_line = source_lines[next_index]
            next_stripped = next_line.strip()
            if not next_stripped or next_line.lstrip().startswith("--"):
                continue
            next_indent = len(next_line) - len(next_line.lstrip())
            if next_indent < body_indent:
                break
            if next_indent == body_indent:
                next_statement = next_index
                break
        if next_statement is None:
            continue

        next_text = source_lines[next_statement].strip()
        if next_text.startswith("return"):
            continue
        if next_text.startswith(("elseif ", "else")):
            continue
        if _is_lua_guard_statement(source_lines, next_statement, body_indent):
            # 只有立即返回的顶层 guard 属于连续校验；业务 if 仍是独立处理阶段。
            continue

        boundaries.append((index, next_statement))

    return boundaries


def _is_lua_guard_statement(source_lines: list[str], statement_index: int, body_indent: int) -> bool:
    """只识别 if 主体首句立即 return 的校验 guard，不把业务分支当作 guard 跳过。"""

    statement_line = source_lines[statement_index]
    statement_indent = len(statement_line) - len(statement_line.lstrip())
    if statement_indent != body_indent or not statement_line.strip().startswith("if "):
        return False

    condition_ended = False
    for line in source_lines[statement_index:]:
        stripped = line.strip()
        if not stripped or line.lstrip().startswith("--"):
            continue
        if not condition_ended:
            if re.search(r"\bthen\b", stripped):
                condition_ended = True
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= statement_indent:
            return False
        return indent == statement_indent + 4 and stripped.startswith("return")
    return False


def _has_lua_phase_spacing(source_lines: list[str], previous_line: int, next_line: int) -> bool:
    """要求阶段结束与下一段代码之间存在空行。"""

    return any(not source_lines[index].strip() for index in range(previous_line + 1, next_line))


def _has_lua_phase_comment(source_lines: list[str], previous_line: int, next_line: int) -> bool:
    """只接受紧邻下一阶段、且能被中文读者理解的阶段说明。"""

    for index in range(next_line - 1, previous_line, -1):
        line = source_lines[index].strip()
        if not line:
            continue
        if line.startswith("---@"):
            continue
        if not line.startswith("--"):
            return False
        return bool(CHINESE_PATTERN.search(line))
    return False


def _lua_function_comment_start_line(source_lines: list[str], start_line: int) -> int:
    """找到函数前紧邻的摘要和 LuaDoc 起始行，用于识别只改注释的函数。"""

    index = start_line - 2
    while index >= 0 and source_lines[index].strip().startswith("--"):
        index -= 1
    return index + 2


def check_lua_function_comments(path: Path, source: str, changed_lines: set[int]) -> list[str]:
    """检查变更函数的 LuaDoc、职责说明和长逻辑块排版。"""

    if not changed_lines:
        return []

    source_lines = source.splitlines()
    errors: list[str] = []
    inline_control_lines = _inline_lua_control_body_lines(source_lines, 1, len(source_lines))
    for line_number in sorted(set(inline_control_lines) & changed_lines):
        errors.append(
            f"{path}:{line_number}: Lua 控制结构的主体不能与 if/loop 头部挤在同一行"
        )

    for start_line, end_line in find_lua_named_function_spans(source):
        comment_start = _lua_function_comment_start_line(source_lines, start_line)
        if not any(
            comment_start <= changed_line <= end_line
            for changed_line in changed_lines
        ):
            continue

        if not _has_lua_return_annotation(source_lines, start_line):
            errors.append(f"{path}:{start_line}: 变更的具名 Lua 函数缺少紧邻的 @return 固定返回合同")

        missing_params = _missing_lua_param_annotations(source_lines, start_line)
        if missing_params:
            errors.append(
                f"{path}:{start_line}: LuaDoc 缺少参数说明：{', '.join(missing_params)}"
            )

        if _is_nontrivial_lua_function(source_lines, start_line, end_line):
            if not _has_lua_function_summary(source_lines, start_line):
                errors.append(
                    f"{path}:{start_line}: 非平凡 Lua 函数缺少紧邻的职责说明；"
                    "请说明函数职责及关键约束"
                )
            for previous_line, next_line in _lua_phase_boundaries(source_lines, start_line, end_line):
                if not _has_lua_phase_spacing(source_lines, previous_line, next_line):
                    errors.append(
                        f"{path}:{previous_line + 1}: 多阶段 Lua 函数的阶段边界没有空行；"
                        "请按真实流程分段，不要把连续步骤机械拆开"
                    )
                if not _has_lua_phase_comment(source_lines, previous_line, next_line):
                    errors.append(
                        f"{path}:{next_line + 1}: 多阶段 Lua 函数缺少紧邻该阶段的中文目的说明；"
                        "请解释阶段目标或约束，不要逐行翻译代码"
                    )
    return errors


def _parse_changed_lines(diff_text: str) -> dict[str, set[int]]:
    """从 git diff --unified=0 中提取新文件侧的变更行范围。"""

    changed: dict[str, set[int]] = {}
    current_path: str | None = None

    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            marker_path = line[4:]
            current_path = marker_path[2:] if marker_path.startswith("b/") else None
            if current_path and not current_path.endswith(".lua"):
                current_path = None
            continue

        if not line.startswith("@@") or not current_path:
            continue

        match = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        changed.setdefault(current_path, set())
        if count == 0:
            # 纯删除没有新行；用删除点定位仍然存在的外层函数。
            changed[current_path].add(start)
        else:
            changed[current_path].update(range(start, start + count))

    return changed


def check_changed_lua_function_comments(root: Path, base_ref: str | None = None) -> list[str]:
    """检查 Git 工作区/暂存区中变更行覆盖的非平凡具名 Lua 函数。

    默认检查相对 HEAD 的工作区变更；给定 base_ref 时检查 base_ref...HEAD，供 CI 验证已提交差异。
    不回溯未变更历史函数；无 Git 元数据的源码快照会跳过此门禁。
    该门禁只验证职责注释是否存在，不判断注释语义是否充分。
    """

    if not (root / ".git").exists():
        return []

    try:
        diff = subprocess.run(
            ["git", "diff", "--unified=0", f"{base_ref}...HEAD" if base_ref else "HEAD", "--"],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if diff.returncode != 0:
            return [f"Lua 注释门禁无法读取 Git diff：{diff.stderr.strip() or diff.returncode}"]

        untracked = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if untracked.returncode != 0:
            return [f"Lua 注释门禁无法读取未跟踪文件：{untracked.stderr.strip() or untracked.returncode}"]
    except OSError as exception:
        return [f"Lua 注释门禁无法执行 Git：{exception}"]

    changed_by_path = _parse_changed_lines(diff.stdout)
    for relative_path in untracked.stdout.splitlines():
        if not relative_path.endswith(".lua"):
            continue
        path = root / relative_path
        if path.is_file():
            try:
                line_count = len(path.read_text(encoding="utf-8").splitlines())
            except (OSError, UnicodeDecodeError) as exception:
                return [f"{relative_path}: 无法读取新增 Lua 文件：{exception}"]
            changed_by_path[relative_path] = set(range(1, line_count + 1))

    errors: list[str] = []
    for relative_path, changed_lines in sorted(changed_by_path.items()):
        path = root / relative_path
        if not path.is_file():
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exception:
            errors.append(f"{relative_path}: 无法读取变更 Lua 文件：{exception}")
            continue
        errors.extend(check_lua_function_comments(Path(relative_path), source, changed_lines))

    return errors


def check_hotupgrade_controller_type_contract(root: Path) -> list[str]:
    """确认 Controller 模块类型公开其方法，避免 helper 参数丢失 IDE 补全。"""

    path = root / "hotupgrade/lualib/flywow_hotupgrade_controller.lua"
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exception:
        return [f"{path.relative_to(root)}: 无法读取 Controller 类型声明：{exception}"]

    class_match = re.search(
        r"---@class FlyWowHotUpgradeController\n(?P<fields>(?:---@field .*\n)+)local M\s*=",
        source,
    )
    if not class_match:
        return [f"{path.relative_to(root)}: Controller 类型没有绑定到模块表 M"]
    if not re.search(
        r"---@field load_patch fun\(self: FlyWowHotUpgradeController,",
        class_match.group("fields"),
    ):
        return [f"{path.relative_to(root)}: Controller 类型未声明 load_patch，helper 无法获得 IDE 成员提示"]
    return []


def check_hotupgrade_lua_function_contracts(root: Path) -> list[str]:
    """全量检查 HotUpgrade 生产 Lua 的函数合同、阶段分段和压缩控制体。"""

    source_paths = sorted(
        list((root / "hotupgrade/lualib").rglob("*.lua"))
        + list((root / "hotupgrade/service").rglob("*.lua"))
    )
    errors = check_hotupgrade_controller_type_contract(root)
    for path in source_paths:
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exception:
            errors.append(f"{path.relative_to(root)}: 无法读取 HotUpgrade Lua 源码：{exception}")
            continue
        changed_lines = set(range(1, len(source.splitlines()) + 1))
        errors.extend(check_lua_function_comments(path.relative_to(root), source, changed_lines))
    return errors


def check_repository(root: Path, base_ref: str | None = None) -> list[str]:
    """汇总执行不会启动业务运行时的仓库级静态检查。"""

    errors: list[str] = []
    for relative in REQUIRED_FILES:
        if not (root / relative).is_file():
            errors.append(f"{relative}: 缺少必要文件")

    for path in iter_text_files(root):
        content = path.read_bytes()
        errors.extend(check_text_content(path.relative_to(root), content))
        if path.suffix.lower() == ".md":
            try:
                markdown_text = content.decode("utf-8")
            except UnicodeDecodeError:
                continue
            errors.extend(check_markdown(path.relative_to(root), markdown_text))

    errors.extend(check_skill(root))
    errors.extend(check_quality_workflow(root))
    errors.extend(check_changed_lua_function_comments(root, base_ref))
    errors.extend(check_hotupgrade_lua_function_contracts(root))
    return errors


def parse_args() -> argparse.Namespace:
    """解析仓库级检查的命令行参数；默认仓库路径由脚本位置推导。"""

    parser = argparse.ArgumentParser(description="检查 Skynet-FlyWow 仓库基础合同")
    parser.add_argument(
        "--base-ref",
        help="可选 Git 基线；检查 base-ref...HEAD，用于 CI 已提交差异扫描",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="仓库根目录；默认由当前脚本位置推导",
    )
    return parser.parse_args()


def main() -> int:
    """执行命令行检查并把所有失败一次性报告给开发者。"""

    arguments = parse_args()
    root = arguments.root.resolve()
    if not root.is_dir():
        print(f"仓库根目录不存在：{root}", file=sys.stderr)
        return 1

    errors = check_repository(root, arguments.base_ref)
    if errors:
        print("SKYNET_FLYWOW_REPOSITORY_CHECK_FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("SKYNET_FLYWOW_REPOSITORY_CHECK_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
