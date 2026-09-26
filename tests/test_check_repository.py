# 职责：锁定仓库自检工具对合法文本和典型破坏的判断，防止质量门禁静默失效。
# 边界：Build/Test Tooling；只测试纯检查函数，不启动 Skynet、不连接网络。
# 输入/输出：内存字节与临时 Markdown -> unittest 断言和进程退出状态。
# 生命周期：本地提交前及 GitHub CI 中按次运行；临时目录由 unittest 生命周期回收。
# 不负责：不验证未来业务模块、编译器、性能、安全或 GitHub Runner 行为。

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


# 测试通过文件路径加载工具，避免为了一个 CI 脚本提前建立 Python package 层级。
CHECKER_PATH = Path(__file__).resolve().parents[1] / "scripts/ci/check_repository.py"
SPEC = importlib.util.spec_from_file_location("check_repository", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载仓库自检工具：{CHECKER_PATH}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class CheckTextContentTests(unittest.TestCase):
    """验证 UTF-8/LF 文本合同的成功和失败状态。"""

    def test_accepts_utf8_lf_with_final_newline(self) -> None:
        """合法中文 UTF-8 与 LF 输入应返回空错误列表；不执行 I/O。"""

        errors = CHECKER.check_text_content(Path("demo.md"), "中文\n".encode("utf-8"))
        self.assertEqual([], errors)

    def test_rejects_crlf_and_missing_final_newline(self) -> None:
        """CRLF 且无末尾换行的输入应同时报告两个独立错误；不执行 I/O。"""

        errors = CHECKER.check_text_content(Path("demo.md"), b"line\r\nlast")
        self.assertEqual(2, len(errors))
        self.assertTrue(any("LF" in error for error in errors))
        self.assertTrue(any("末尾" in error for error in errors))

    def test_rejects_invalid_utf8(self) -> None:
        """非法 UTF-8 必须成为显式诊断，不能让解码异常逃逸或被忽略。"""

        errors = CHECKER.check_text_content(Path("demo.md"), b"\xff\n")
        self.assertTrue(any("UTF-8" in error for error in errors))

    def test_rejects_extra_blank_line_at_eof(self) -> None:
        """末尾两个换行表示多余空白行，必须失败以保持稳定 diff。"""

        errors = CHECKER.check_text_content(Path("demo.md"), "中文\n\n".encode("utf-8"))
        self.assertTrue(any("多余空白行" in error for error in errors))


class CheckMarkdownTests(unittest.TestCase):
    """验证中文文档和代码围栏的最低结构合同。"""

    def test_accepts_chinese_with_closed_fence(self) -> None:
        """含中文且代码围栏成对的 Markdown 应通过；不执行 I/O。"""

        text = "# 示例\n\n```text\nvalue\n```\n"
        self.assertEqual([], CHECKER.check_markdown(Path("demo.md"), text))

    def test_rejects_unclosed_fence(self) -> None:
        """未闭合代码围栏必须失败，避免发布后吞掉后续正文排版。"""

        errors = CHECKER.check_markdown(Path("demo.md"), "# 示例\n\n```text\nvalue\n")
        self.assertTrue(any("没有成对闭合" in error for error in errors))

    def test_rejects_initializer_placeholder(self) -> None:
        """Skill 初始化器遗留占位符必须失败，不能进入主分支。"""

        errors = CHECKER.check_markdown(Path("demo.md"), "# 示例\n\n[TODO: 补充]\n")
        self.assertTrue(any("占位符" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
