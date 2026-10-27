# 职责：锁定仓库自检工具对合法文本、Markdown 与 Lua 注释门禁的判断。
# 边界：Build/Test Tooling；只测试纯检查函数，不启动 Skynet、不连接网络。
# 输入/输出：内存文本与临时 Lua 片段 -> unittest 断言和进程退出状态。
# 生命周期：由开发者按需本地运行；临时目录由 unittest 生命周期回收。
# 不负责：不验证注释的业务语义、未来业务模块、编译器、性能或安全。

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


# 测试通过文件路径加载工具，避免为了一个仓库自检脚本提前建立 Python package 层级。
CHECKER_PATH = Path(__file__).resolve().parent / "check_repository.py"
SPEC = importlib.util.spec_from_file_location("check_repository", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载仓库自检工具：{CHECKER_PATH}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class CheckTextContentTests(unittest.TestCase):
    """验证 UTF-8/LF 文本合同的成功和失败状态。"""

    def test_accepts_utf8_lf_with_final_newline(self) -> None:
        errors = CHECKER.check_text_content(Path("demo.md"), "中文\n".encode("utf-8"))
        self.assertEqual([], errors)

    def test_rejects_crlf_and_missing_final_newline(self) -> None:
        errors = CHECKER.check_text_content(Path("demo.md"), b"line\r\nlast")
        self.assertEqual(2, len(errors))
        self.assertTrue(any("LF" in error for error in errors))
        self.assertTrue(any("末尾" in error for error in errors))

    def test_rejects_invalid_utf8(self) -> None:
        errors = CHECKER.check_text_content(Path("demo.md"), b"\xff\n")
        self.assertTrue(any("UTF-8" in error for error in errors))

    def test_rejects_extra_blank_line_at_eof(self) -> None:
        errors = CHECKER.check_text_content(Path("demo.md"), "中文\n\n".encode("utf-8"))
        self.assertTrue(any("多余空白行" in error for error in errors))


class CheckMarkdownTests(unittest.TestCase):
    """验证中文文档和代码围栏的最低结构合同。"""

    def test_accepts_chinese_with_closed_fence(self) -> None:
        text = "# 示例\n\n```text\nvalue\n```\n"
        self.assertEqual([], CHECKER.check_markdown(Path("demo.md"), text))

    def test_rejects_unclosed_fence(self) -> None:
        errors = CHECKER.check_markdown(Path("demo.md"), "# 示例\n\n```text\nvalue\n")
        self.assertTrue(any("没有成对闭合" in error for error in errors))

    def test_rejects_initializer_placeholder(self) -> None:
        errors = CHECKER.check_markdown(Path("demo.md"), "# 示例\n\n[TODO: 补充]\n")
        self.assertTrue(any("占位符" in error for error in errors))


class LuaCommentGateTests(unittest.TestCase):
    """验证变更行定位、非平凡函数识别及紧邻职责注释门禁。"""

    def test_rejects_changed_nontrivial_function_without_summary(self) -> None:
        source = (
            "local function update_batch(batch)\n"
            "    local paths = find_paths(batch)\n"
            "    if not paths then\n"
            "        return nil\n"
            "    end\n"
            "    batch.files = {}\n"
            "    return true\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {2, 3, 4, 5})
        self.assertEqual(1, len(errors))
        self.assertIn("缺少紧邻的职责说明", errors[0])
        self.assertIn("demo.lua:1", errors[0])

    def test_accepts_changed_nontrivial_function_with_summary(self) -> None:
        source = (
            "-- 根据本批发布包生成文件记录，并在发现无效输入时返回诊断。\n"
            "local function update_batch(batch)\n"
            "    local paths = find_paths(batch)\n"
            "    if not paths then\n"
            "        return nil\n"
            "    end\n"
            "    batch.files = {}\n"
            "    return true\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {3, 4, 5, 6})
        self.assertEqual([], errors)

    def test_simple_getter_does_not_require_comment(self) -> None:
        source = (
            "function M:get_id()\n"
            "    return self.id\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {2})
        self.assertEqual([], errors)

    def test_ignores_unchanged_function(self) -> None:
        source = (
            "local function update_batch(batch)\n"
            "    local paths = find_paths(batch)\n"
            "    if not paths then\n"
            "        return nil\n"
            "    end\n"
            "    batch.files = {}\n"
            "    return true\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {10})
        self.assertEqual([], errors)

    def test_handles_nested_blocks_and_strings(self) -> None:
        source = (
            "-- 处理候选批次并保留失败边界。\n"
            "local function update_batch(batch)\n"
            "    local text = 'end function fake()'\n"
            "    if batch then\n"
            "        for _, item in ipairs(batch.items) do\n"
            "            consume(item)\n"
            "        end\n"
            "    end\n"
            "    return text\n"
            "end\n"
        )
        spans = CHECKER.find_lua_named_function_spans(source)
        self.assertEqual([(2, 10)], spans)
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {5})
        self.assertEqual([], errors)


if __name__ == "__main__":
    unittest.main()
