# 职责：锁定仓库自检工具对合法文本、Markdown 与 Lua 注释门禁的判断。
# 边界：Build/Test Tooling；只测试纯检查函数，不启动 Skynet、不连接网络。
# 输入/输出：内存文本与临时 Lua 片段 -> unittest 断言和进程退出状态。
# 生命周期：由开发者按需本地运行；临时目录由 unittest 生命周期回收。
# 不负责：不验证注释的业务语义、未来业务模块、编译器、性能或安全。

from __future__ import annotations

import importlib.util
import unittest
from tempfile import TemporaryDirectory
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


class CheckWorkflowTests(unittest.TestCase):
    """确认仓库自检会阻止移除 CI 质量门禁。"""

    def test_accepts_workflow_that_runs_tests_and_commit_diff_scan(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflow = root / ".github/workflows/quality.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(
                "pull_request:\npush:\nfetch-depth: 0\n"
                "python -m unittest discover -s scripts/quality -p 'test_*.py'\n"
                "python scripts/quality/check_repository.py --base-ref origin/main\n",
                encoding="utf-8",
            )
            self.assertEqual([], CHECKER.check_quality_workflow(root))

    def test_rejects_workflow_without_commit_diff_scan(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflow = root / ".github/workflows/quality.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("pull_request:\n", encoding="utf-8")
            errors = CHECKER.check_quality_workflow(root)
            self.assertEqual(4, len(errors))
            self.assertTrue(any("基线" in error or "提交差异" in error for error in errors))

class HotUpgradeControllerTypeGateTests(unittest.TestCase):
    """防止 Controller 模块类型与 controller 参数的方法声明脱节。"""

    def test_requires_load_patch_on_the_controller_module_type(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_path = root / "hotupgrade/lualib/flywow_hotupgrade_controller.lua"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "---@class FlyWowHotUpgradeController\n"
                "---@field handle_command fun(self: FlyWowHotUpgradeController)\n"
                "local M = {}\n",
                encoding="utf-8",
            )

            errors = CHECKER.check_hotupgrade_controller_type_contract(root)

            self.assertTrue(any("未声明 load_patch" in error for error in errors))


class HotUpgradeFullSourceGateTests(unittest.TestCase):
    """确保 HotUpgrade 生产模块即使未改动也执行函数合同和阶段门禁。"""

    def test_scans_short_multiphase_production_function_without_git_diff(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_path = root / "hotupgrade/lualib/controller.lua"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "--- 准备本批发布状态。\n"
                "---@param batch table 本批记录。\n"
                "---@return table 阶段结果。\n"
                "local function prepare(batch)\n"
                "    local result = load_patch(batch)\n"
                "    if not result.ok then\n"
                "        return result\n"
                "    end\n"
                "    for _, file in ipairs(batch.files) do\n"
                "        snapshot(file)\n"
                "    end\n"
                "    return success()\n"
                "end\n",
                encoding="utf-8",
            )

            errors = CHECKER.check_hotupgrade_lua_function_contracts(root)

            self.assertTrue(any("阶段边界没有空行" in error for error in errors))
            self.assertTrue(any("缺少紧邻该阶段的中文目的说明" in error for error in errors))


class LuaCommentGateTests(unittest.TestCase):
    """验证变更函数的合同注释、逻辑排版和范围定位门禁。"""

    def test_rejects_changed_nontrivial_function_without_summary(self) -> None:
        source = (
            "---@param batch table 当前发布批次记录。\n"
            "---@return boolean 是否完成。\n"
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
        self.assertTrue(any("缺少紧邻的职责说明" in error for error in errors))
        self.assertTrue(any("demo.lua:3" in error for error in errors))

    def test_accepts_changed_nontrivial_function_with_summary(self) -> None:
        source = (
            "-- 根据本批发布包生成文件记录，并在发现无效输入时返回诊断。\n"
            "---@param batch table 当前发布批次记录。\n"
            "---@return boolean 是否完成。\n"
            "local function update_batch(batch)\n"
            "    local paths = find_paths(batch)\n"
            "    if not paths then\n"
            "        return nil\n"
            "    end\n"
            "\n"
            "    -- 保存后续阶段要填充的文件记录。\n"
            "    batch.files = {}\n"
            "    return true\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {4, 5, 6, 7})
        self.assertEqual([], errors)

    def test_checks_function_when_only_doc_comment_changed(self) -> None:
        source = (
            "--- 准备候选状态并保留统一失败合同。\n"
            "---@param state table 当前候选状态记录。\n"
            "---@return table 已构建的候选状态。\n"
            "local function build_state(state)\n"
            "    return state\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {1})
        self.assertEqual([], errors)

    def test_rejects_changed_function_without_return_contract(self) -> None:
        source = "local function has_value(value)\n    return value ~= nil\nend\n"
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {2})
        self.assertTrue(any("缺少紧邻的 @return" in error for error in errors))

    def test_rejects_changed_function_without_param_documentation(self) -> None:
        source = (
            "---@return table 状态记录。\n"
            "local function build_record(request)\n"
            "    return request\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {3})
        self.assertTrue(any("缺少参数说明：request" in error for error in errors))

    def test_rejects_param_annotation_without_chinese_description(self) -> None:
        source = (
            "---@param request table\n"
            "---@return table 状态记录。\n"
            "local function build_record(request)\n"
            "    return request\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {3})
        self.assertTrue(any("缺少参数说明：request" in error for error in errors))

    def test_rejects_return_annotation_without_contract_description(self) -> None:
        source = (
            "---@return table\n"
            "local function build_record()\n"
            "    return {}\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {2})
        self.assertTrue(any("缺少紧邻的 @return" in error for error in errors))

    def test_rejects_short_multiphase_function_without_spacing_or_phase_comment(self) -> None:
        source = (
            "--- 固定本批文件后保存部署前快照。\n"
            "---@param batch table 本批发布记录。\n"
            "---@return table 本阶段结果。\n"
            "local function prepare_batch(batch)\n"
            "    local result = load_patch(batch)\n"
            "    if not result.ok then\n"
            "        return result\n"
            "    end\n"
            "    for _, file in ipairs(batch.files) do\n"
            "        snapshot(file)\n"
            "    end\n"
            "    return success()\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {8})
        self.assertTrue(any("阶段边界没有空行" in error for error in errors))
        self.assertTrue(any("缺少紧邻该阶段的中文目的说明" in error for error in errors))

    def test_accepts_short_multiphase_function_with_spacing_and_phase_comment(self) -> None:
        source = (
            "--- 固定本批文件后保存部署前快照。\n"
            "---@param batch table 本批发布记录。\n"
            "---@return table 本阶段结果。\n"
            "local function prepare_batch(batch)\n"
            "    local result = load_patch(batch)\n"
            "    if not result.ok then\n"
            "        return result\n"
            "    end\n"
            "\n"
            "    -- 逐个保存正式文件内容，供后续部署失败时恢复。\n"
            "    for _, file in ipairs(batch.files) do\n"
            "        snapshot(file)\n"
            "    end\n"
            "    return success()\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {10})
        self.assertEqual([], errors)

    def test_does_not_skip_business_if_as_a_new_phase(self) -> None:
        source = (
            "--- 执行候选模块更新。\n"
            "---@return table 更新结果。\n"
            "local function update_module()\n"
            "    prepare()\n"
            "    if candidate.enabled then\n"
            "        activate()\n"
            "    end\n"
            "    persist()\n"
            "    return success()\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {5})
        self.assertTrue(any("阶段边界没有空行" in error for error in errors))
        self.assertTrue(any("缺少紧邻该阶段的中文目的说明" in error for error in errors))

    def test_skips_immediate_return_guard_between_phases(self) -> None:
        source = (
            "--- 准备并构造结果。\n"
            "---@return table 结果。\n"
            "local function build_result()\n"
            "    prepare()\n"
            "    if not ready() then\n"
            "        return failure()\n"
            "    end\n"
            "    return success()\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {5})
        self.assertEqual([], errors)

    def test_phase_comment_can_precede_lua_type_annotation(self) -> None:
        source_lines = [
            "    if not valid then",
            "        return failure()",
            "    end",
            "",
            "    -- 校验通过后构造并登记本地记录。",
            "    ---@type table",
            "    local record = {}",
        ]
        self.assertTrue(CHECKER._has_lua_phase_comment(source_lines, 2, 6))

    def test_checks_repeat_loop_as_a_phase_boundary(self) -> None:
        source = (
            "--- 等待状态稳定后生成结果。\n"
            "---@return table 稳定结果。\n"
            "local function wait_until_ready()\n"
            "    repeat\n"
            "        poll()\n"
            "    until ready()\n"
            "    local result = build_result()\n"
            "    return result\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {5})
        self.assertTrue(any("阶段边界没有空行" in error for error in errors))
        self.assertTrue(any("缺少紧邻该阶段的中文目的说明" in error for error in errors))

    def test_ignores_end_and_phase_text_inside_long_string(self) -> None:
        source = (
            "--- 返回固定的多行文本。\\n"
            "---@return string 示例文本。\\n"
            "local function get_text()\\n"
            "    local text = [[\\n"
            "    end\\n"
            "    local hidden = true\\n"
            "    ]]\\n"
            "    return text\\n"
            "end\\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {5})
        self.assertEqual([], errors)

    def test_accepts_long_single_phase_function_without_artificial_comment(self) -> None:
        statements = "".join(f"    local value_{index} = {index}\n" for index in range(20))
        source = (
            "--- 生成一组连续计算结果。\n"
            "---@return table 结果列表。\n"
            "local function build_values()\n"
            + statements
            + "    return {}\nend\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {4})
        self.assertEqual([], errors)

    def test_rejects_inline_control_body(self) -> None:
        source = (
            "--- 复制状态并保留失败合同。\n"
            "---@param state table 当前业务状态表。\n"
            "---@return table 复制后的业务状态。\n"
            "local function copy_state(state)\n"
            "    if not state then return {} end\n"
            "    return state\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {5})
        self.assertTrue(any("不能与 if/loop 头部挤在同一行" in error for error in errors))

    def test_rejects_compressed_control_body_in_anonymous_callback(self) -> None:
        source = (
            "local callbacks = { function()\n"
            "    while pending do wait_for_result() end\n"
            "end }\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {2})
        self.assertTrue(any("不能与 if/loop 头部挤在同一行" in error for error in errors))

    def test_ignores_control_words_inside_strings(self) -> None:
        source = (
            "-- 返回固定字符串，覆盖控制关键字文本的门禁误报。\n"
            "---@return string 测试字符串。\n"
            "local function get_text()\n"
            "    return 'if ready then return true end'\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {3})
        self.assertEqual([], errors)

    def test_simple_getter_requires_return_but_not_summary(self) -> None:
        source = (
            "---@return integer ID 标识。\n"
            "function M:get_id()\n"
            "    return self.id\n"
            "end\n"
        )
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {3})
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
            "---@param batch table 当前候选批次记录。\n"
            "---@return string 交给调用方的文本。\n"
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
        self.assertEqual([(4, 12)], spans)
        errors = CHECKER.check_lua_function_comments(Path("demo.lua"), source, {6})
        self.assertEqual([], errors)


if __name__ == "__main__":
    unittest.main()
