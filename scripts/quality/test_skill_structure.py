from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

import check_skill_structure as checker


class SkillStructureTests(unittest.TestCase):
    def test_upgrade_overlay_structure(self) -> None:
        """在临时工程中补入两个保持不变的旧入口，验证本次替换包结构。"""
        package_root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                package_root / ".agents/skills/flywow-engineering-workflow",
                root / ".agents/skills/flywow-engineering-workflow",
            )
            shutil.copytree(
                package_root / ".agents/skills/skynet-flywow-coding-standard/references",
                root / ".agents/skills/skynet-flywow-coding-standard/references",
            )
            # 这两个入口在真实仓库中保持原样，不属于本次覆盖文件。
            base_skills = {
                "skynet-flywow-coding-standard": "实现或评审 FlyWow 代码时遵守编码规范。",
                "source-based-practical-teaching": "编写源码实战教程时遵守教学规范。",
            }
            for name, description in base_skills.items():
                path = root / f".agents/skills/{name}/SKILL.md"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(
                    f"---\nname: {name}\ndescription: {description}\n---\n\n# 保持不变\n",
                    encoding="utf-8",
                )
            errors = checker.run_checks(root)
            self.assertEqual([], errors)

    def test_frontmatter_requires_expected_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".agents/skills/example/SKILL.md"
            path.parent.mkdir(parents=True)
            path.write_text(
                "---\nname: wrong\ndescription: 中文触发说明\n---\n正文\n",
                encoding="utf-8",
            )
            original_root = checker.ROOT
            checker.ROOT = root
            try:
                errors = checker.check_skill_file(
                    ".agents/skills/example/SKILL.md", "expected"
                )
            finally:
                checker.ROOT = original_root
            self.assertTrue(any("name 必须是 expected" in item for item in errors))

    def test_frontmatter_rejects_unclosed_block(self) -> None:
        fields, problem = checker.parse_frontmatter(
            "---\nname: sample\ndescription: 中文说明\n"
        )
        self.assertIsNone(fields)
        self.assertEqual("YAML frontmatter 未闭合", problem)

    def test_reference_list_has_no_duplicate_paths(self) -> None:
        self.assertEqual(
            len(checker.REQUIRED_REFERENCES),
            len(set(checker.REQUIRED_REFERENCES)),
        )

    def test_all_three_skill_entries_are_declared(self) -> None:
        self.assertEqual(3, len(checker.SKILLS))
        self.assertIn(
            ".agents/skills/flywow-engineering-workflow/SKILL.md",
            checker.SKILLS,
        )


if __name__ == "__main__":
    unittest.main()
