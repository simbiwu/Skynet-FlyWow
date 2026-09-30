# 职责：在本地和 CI 中检查 Skynet-FlyWow 的最小仓库、文本与 Skill 合同。
# 边界：Build/Test Tooling；只读扫描仓库，不修改源码、不连接网络、不启动 Skynet。
# 输入/输出：仓库根目录 -> 中文诊断与 0（通过）/1（失败）进程退出码。
# 生命周期：开发者提交前或 GitHub CI 中按次执行；不保存跨运行状态。
# 不负责：不替代语言编译、静态分析、模块测试、性能测试或安全审计。

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable


# 这些文件构成初始化仓库对接入者和自动化工具承诺的最小工程合同。
REQUIRED_FILES = (
    ".editorconfig",
    ".gitattributes",
    ".agents/skills/skynet-flywow-coding-standard/SKILL.md",
    "AGENTS.md",
    "README.md",
    "docs/ADOPTION.md",
    "docs/ARCHITECTURE.md",
    "docs/ENGINEERING_DECISIONS.md",
    "docs/MODULE_STANDARD.md",
    "docs/QUALITY_GATES.md",
    "docs/ROADMAP.md",
    "docs/VERSIONING.md",
)

# 只扫描应当保持 UTF-8/LF 的人类可读文件；未来二进制资产不会被误解码。
TEXT_SUFFIXES = {
    ".c", ".cc", ".cmake", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx",
    ".lua", ".md", ".proto", ".py", ".sh", ".txt", ".yaml", ".yml",
}
TEXT_NAMES = {".editorconfig", ".gitattributes", ".gitignore", "CMakeLists.txt", "Makefile"}
CHINESE_PATTERN = re.compile(r"[\u3400-\u9fff]")


# 只扫描维护者可读的源码和工程说明；排除 .git 与二进制资产。
def iter_text_files(root: Path) -> Iterable[Path]:
    """枚举仓库内受文本合同约束的文件。

    参数：root 是已解析的仓库根目录，由当前进程只读访问。
    返回：按路径排序的文件迭代器；每个 Path 仍归调用方和文件系统所有。
    失败：目录遍历错误直接传播；本函数不执行 I/O 写入、分配大型缓冲区或并发操作。
    """

    for path in sorted(root.rglob("*")):
        if ".git" in path.parts or not path.is_file():
            continue
        if path.suffix.lower() in TEXT_SUFFIXES or path.name in TEXT_NAMES:
            yield path


def check_text_content(path: Path, content: bytes) -> list[str]:
    """验证单个文本文件采用 UTF-8、LF、末尾换行且没有 NUL。

    参数：path 只用于可读诊断；content 是调用方拥有的完整文件字节。
    返回：新分配的中文错误列表；空列表表示通过。
    失败：不抛出解码异常；非法 UTF-8 转换为一条显式错误。本函数不执行 I/O 或 yield。
    """

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
    """检查中文 Markdown 与代码围栏的最低结构合同。

    参数：path 是诊断路径；text 是已经通过 UTF-8 解码的完整 Markdown。
    返回：新分配的错误列表；不修改输入，不执行 I/O 或 yield。
    限制：这里只检测独占一行的三反引号或三波浪号围栏是否成对，不替代 Markdown parser。
    """

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


def check_skill(root: Path) -> list[str]:
    """验证 P0 编码规范 Skill 的身份与中文描述。

    参数：root 是仓库根目录；Skill 路径由稳定仓库合同确定。
    返回：新分配的错误列表；缺失或不合法 frontmatter 都显式报告。
    I/O：只读取一个小型 UTF-8 文件，不分配无界数据、不修改共享状态、不 yield。
    """

    path = root / ".agents/skills/skynet-flywow-coding-standard/SKILL.md"
    if not path.is_file():
        return [f"{path}: 缺少 P0 编码规范 Skill"]
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return [f"{path}: 缺少 YAML frontmatter 起始标记"]
    frontmatter = text.split("---\n", 2)[1]
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


def check_repository(root: Path) -> list[str]:
    """汇总执行不会启动业务运行时的仓库级静态检查。

    参数：root 必须是待检查仓库的现存目录。
    返回：按检查顺序生成的全部错误；调用方负责打印和决定退出码。
    I/O：读取受控文本文件；复杂度 O(文本总字节数)，不联网、不加锁、不 yield。
    """

    errors: list[str] = []
    for relative in REQUIRED_FILES:
        if not (root / relative).is_file():
            errors.append(f"{relative}: 缺少必要文件")

    for path in iter_text_files(root):
        content = path.read_bytes()
        errors.extend(check_text_content(path.relative_to(root), content))
        if path.suffix.lower() == ".md":
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError:
                continue
            errors.extend(check_markdown(path.relative_to(root), text))

    errors.extend(check_skill(root))
    return errors


def parse_args() -> argparse.Namespace:
    """解析仓库级检查的命令行参数。

    --root 可指定待检查仓库目录；缺省值由脚本路径定位，不依赖当前工作目录。
    返回 argparse.Namespace；参数错误由 argparse 打印并以非零退出。本函数不读写文件、不 yield。
    """

    parser = argparse.ArgumentParser(description="检查 Skynet-FlyWow 仓库基础合同")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="仓库根目录；默认由当前脚本位置推导",
    )
    return parser.parse_args()


def main() -> int:
    """执行命令行检查并把所有失败一次性报告给开发者。

    无位置参数；--root 指定仓库根目录，未指定时使用脚本所在仓库。返回 0 表示通过、1 表示失败。
    读取受控文本文件并写 stdout/stderr；不修改文件、不联网、不 yield。
    """

    root = parse_args().root.resolve()
    if not root.is_dir():
        print(f"仓库根目录不存在：{root}", file=sys.stderr)
        return 1
    errors = check_repository(root)
    if errors:
        print("SKYNET_FLYWOW_REPOSITORY_CHECK_FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("SKYNET_FLYWOW_REPOSITORY_CHECK_OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
