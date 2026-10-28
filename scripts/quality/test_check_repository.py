# 职责：锁定仓库自检工具对合法文本、Markdown 与 Lua 注释门禁的判断。
# 边界：Build/Test Tooling；只测试纯检查函数，不启动 Skynet、不连接网络。
# 输入/输出：内存文本与临时 Lua 片段 -> unittest 断言和进程退出状态。
# 生命周期：由开发者按需本地运行；临时目录由 unittest 生命周期回收。
# 不负责：不验证注释的业务语义、未来业务模块、编译器、性能或安全。

from __future__ import annotations

import importlib.util
import unittest
from unittest.mock import patch
from tempfile import TemporaryDirectory
from pathlib import Path


# 测试通过文件路径加载工具，避免为了一个仓库自检脚本提前建立 Python package 层级。
CHECKER_PATH = Path(__file__).resolve().parent / "check_repository.py"
SPEC = importlib.util.spec_from_file_location("check_repository", CHECKER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"无法加载仓库自检工具：{CHECKER_PATH}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class FlyWowCodingSkillGateTests(unittest.TestCase):
    """确保给 AI 的合同变更约束仍保留在编码 Skill 中。"""

    def test_requires_pre_and_post_contract_audit_rules(self) -> None:
        with TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            skill_path = root / ".agents/skills/skynet-flywow-coding-standard/SKILL.md"
            skill_path.parent.mkdir(parents=True)
            skill_path.write_text(
                "---\n"
                "name: skynet-flywow-coding-standard\n"
                "description: FlyWow 编码规范。\n"
                "---\n"
                "### AI 实施前后合同门禁（强制）\n"
                "不得擅自改变上述合同。\n"
                "逐项对照基线与工作区差异。\n",
                encoding="utf-8",
            )

            errors = CHECKER.check_skill(root)

            self.assertEqual([], errors)

            skill_path.write_text(
                "---\n"
                "name: skynet-flywow-coding-standard\n"
                "description: FlyWow 编码规范。\n"
                "---\n",
                encoding="utf-8",
            )

            errors = CHECKER.check_skill(root)

            self.assertEqual(3, len(errors))


class QualityGateCompositionTests(unittest.TestCase):
    """仓库入口必须同时执行全仓通用门禁与模块专项门禁。"""

    def test_runs_general_and_module_specific_gates(self) -> None:
        with TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            with (
                patch.object(CHECKER, "check_changed_lua_function_comments", return_value=[]) as general_gate,
                patch.object(CHECKER, "check_module_specific_quality_gates", return_value=[]) as module_gates,
            ):
                CHECKER.check_repository(root)

            general_gate.assert_called_once_with(root, None)
            module_gates.assert_called_once_with(root)


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


class CommentClarityGateTests(unittest.TestCase):
    """拒绝已知含糊的异常边界和错误传播套话。"""

    def test_rejects_boundary_and_result_contract_jargon(self) -> None:
        source = (
            "-- 仅在候选模块顶层和状态钩子边界捕获异常；其余内部错误由明确结果合同传播。\n"
        )

        errors = CHECKER.check_hotupgrade_comment_clarity(Path("hotupgrade.lua"), source)

        self.assertEqual(3, len(errors))
        self.assertTrue(any("边界捕获异常" in error for error in errors))
        self.assertTrue(any("状态钩子边界" in error for error in errors))
        self.assertTrue(any("结果合同传播" in error for error in errors))

    def test_accepts_specific_operation_and_error_result(self) -> None:
        source = "-- 执行 export_state；回调抛错时停止 Stage 并返回 HU_MODULE_STAGE_FAILED。\n"

        errors = CHECKER.check_hotupgrade_comment_clarity(Path("hotupgrade.lua"), source)

        self.assertEqual([], errors)

    def test_generic_comment_gate_rejects_phrases_in_any_flywow_module(self) -> None:
        source = "-- 内部错误由明确结果合同传播。\n"

        errors = CHECKER.check_flywow_comment_clarity(Path("navigation/lualib/route.lua"), source)

        self.assertEqual(1, len(errors))
        self.assertIn("navigation/lualib/route.lua", errors[0])

    def test_generic_gate_rejects_abstract_stage_headings(self) -> None:
        source = (
            "-- 参数/状态检查：先处理输入。\n"
            "-- 数据准备：继续处理。\n"
            "-- 状态修改：更新状态。\n"
            "-- 持久化/消息发送：发送数据。\n"
            "-- 核心计算：完成计算。\n"
            "-- 收尾：返回。\n"
        )

        errors = CHECKER.check_flywow_comment_clarity(Path("gateway.lua"), source)

        self.assertEqual(6, len(errors))

    def test_hotupgrade_gate_adds_module_specific_comment_phrases(self) -> None:
        source = (
            "-- 当前 register 协程；身份集合核验完成后继续。\n"
            "-- 保存执行状态和结果到结果槽。\n"
        )

        errors = CHECKER.check_hotupgrade_comment_clarity(Path("hotupgrade.lua"), source)

        self.assertEqual(4, len(errors))

    def test_markdown_scans_comment_clarity_without_treating_snippets_as_full_records(self) -> None:
        with TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            controller_path = root / "hotupgrade/lualib/flywow_hotupgrade_controller.lua"
            controller_path.parent.mkdir(parents=True)
            controller_path.write_text(
                "---@class FlyWowHotUpgradeController\n"
                "---@field load_patch fun(self: FlyWowHotUpgradeController, batch: any)\n"
                "local M = {}\n",
                encoding="utf-8",
            )
            markdown_path = root / "hotupgrade/sample/readme.md"
            markdown_path.parent.mkdir(parents=True)
            markdown_path.write_text(
                "~~~lua\n"
                "local record = {\n"
                "    first = 1,\n"
                "}\n"
                "~~~\n",
                encoding="utf-8",
            )

            errors = CHECKER.check_hotupgrade_lua_function_contracts(root)

            self.assertEqual([], errors)

            markdown_path.write_text(
                "~~~lua\n"
                "-- 保存执行状态和结果到结果槽。\n"
                "local record = {\n"
                "    first = 1,\n"
                "}\n"
                "~~~\n",
                encoding="utf-8",
            )

            errors = CHECKER.check_hotupgrade_lua_function_contracts(root)

            self.assertEqual(2, len(errors))

    def test_extracts_lua_comments_from_tutorial_fences(self) -> None:
        fence = chr(96) * 3
        markdown = (
            "# 教程\n"
            "\n"
            + fence + "lua\n"
            + "-- 当前 register 协程；等待结果。\n"
            + "local value = 1\n"
            + fence + "\n"
        )

        blocks = list(CHECKER.iter_lua_markdown_blocks(markdown))

        self.assertEqual([(4, "-- 当前 register 协程；等待结果。\nlocal value = 1")], blocks)


class LuaRecordFieldGateTests(unittest.TestCase):
    """确保多行 FlyWow record 的每个具名字段都有就近说明。"""

    def test_rejects_uncommented_record_field(self) -> None:
        source = "local record = {\n    first = 1, -- 已说明。\n    second = 2,\n}\n"

        errors = CHECKER.check_lua_multiline_record_field_comments(Path("sample.lua"), source)

        self.assertEqual(1, len(errors))
        self.assertIn(":3:", errors[0])

    def test_generic_changed_field_gate_only_reports_changed_fields(self) -> None:
        source = "local record = {\n    first = 1,\n    second = 2,\n}\n"

        errors = CHECKER.check_lua_multiline_record_field_comments(
            Path("navigation/lualib/route.lua"), source, {3}
        )

        self.assertEqual(1, len(errors))
        self.assertIn(":3:", errors[0])

    def test_rejects_multiple_record_fields_on_one_line(self) -> None:
        source = "local record = {\n    first = 1, second = 2, -- 一条注释不能代替逐字段说明。\n}\n"

        errors = CHECKER.check_lua_multiline_record_field_comments(Path("sample.lua"), source)

        self.assertTrue(any("不能挤在同一行" in error for error in errors))

    def test_does_not_treat_comment_marker_inside_string_as_comment(self) -> None:
        source = 'local record = {\n    message = "-- not a comment",\n}\n'

        errors = CHECKER.check_lua_multiline_record_field_comments(Path("sample.lua"), source)

        self.assertEqual(1, len(errors))

    def test_accepts_inline_and_preceding_field_comments(self) -> None:
        source = (
            "local record = {\n"
            "    first = 1, -- 行尾字段说明。\n"
            "    -- 第二个字段的独立说明。\n"
            "    second = { nested = true },\n"
            "}\n"
        )

        errors = CHECKER.check_lua_multiline_record_field_comments(Path("sample.lua"), source)

        self.assertEqual([], errors)

    def test_does_not_treat_nested_function_locals_as_record_fields(self) -> None:
        source = (
            "local record = {\n"
            "    callback = function() -- record 内负责执行的业务检查回调。\n"
            "        local result = true\n"
            "        return result\n"
            "    end, -- 完成该回调的业务检查。\n"
            "}\n"
        )

        errors = CHECKER.check_lua_multiline_record_field_comments(Path("sample.lua"), source)

        self.assertEqual([], errors)


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
