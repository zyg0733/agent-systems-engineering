"""Project dual-license completeness checks; no runtime or Git history needed."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("repository_check", PROJECT / "scripts/repository_check.py")
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

NOTICE = """Agent Systems Lab
Copyright 2026 Agent Systems Lab contributors
Code: Apache-2.0. Teaching material: CC-BY-4.0.
"""
SCOPE = """# License scope

原创代码采用 [Apache-2.0](../LICENSE)。教材采用 [CC-BY-4.0](../LICENSE-DOCS)。
项目声明见 [NOTICE](../NOTICE)。

教材中的原创代码示例采用 Apache-2.0。

第三方材料保留原有许可。
"""


class RepositoryLicenseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Use the actual canonical project texts rather than copying legal text
        # into test fixtures. Every mutation below starts from those materials.
        cls.license_texts = {
            name: (PROJECT / name).read_text(encoding="utf-8")
            for name in checker.LICENSE_TEXT_RULES
        }

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asl-license-check-")
        self.root = Path(self.temp.name).resolve()
        (self.root / "docs").mkdir()
        (self.root / ".gitignore").write_text(
            "".join("/" + name + "/\n" for name in checker.REQUIRED_EXCLUSIONS),
            encoding="utf-8",
        )
        (self.root / "mix.lock").write_text("%{}\n", encoding="utf-8")
        self.restore_materials()

    def tearDown(self):
        self.temp.cleanup()

    def restore_materials(self):
        for relative, text in {
            **self.license_texts, "NOTICE": NOTICE, "docs/licensing.md": SCOPE,
        }.items():
            (self.root / relative).write_text(text, encoding="utf-8")

    def findings(self):
        return {(row["path"], row["rule"]) for row in checker.check(self.root)["findings"]}

    def test_complete_project_license_materials_pass(self):
        result = checker.check(self.root)
        self.assertEqual("passed", result["status"], result["findings"])
        self.assertFalse(any("license_pending" in item["rule"] for item in result["warnings"]))

    def test_each_required_project_material_is_required(self):
        for relative in sorted(checker.PROJECT_LICENSE_PATHS):
            with self.subTest(relative=relative):
                (self.root / relative).unlink()
                self.assertIn(
                    (relative, "required_project_license_missing_or_unscanned"), self.findings()
                )
                self.restore_materials()

    def test_third_party_license_does_not_substitute_for_root_license(self):
        (self.root / "vendor").mkdir()
        (self.root / "LICENSE").rename(self.root / "vendor/LICENSE")
        self.assertIn(
            ("LICENSE", "required_project_license_missing_or_unscanned"), self.findings()
        )

    def test_ignored_license_is_not_opened_or_accepted(self):
        with (self.root / ".gitignore").open("a", encoding="utf-8") as stream:
            stream.write("/LICENSE\n")
        original_open = Path.open

        def guarded_open(path, *args, **kwargs):
            if path == self.root / "LICENSE":
                raise AssertionError("ignored license must not be opened")
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", guarded_open):
            self.assertIn(
                ("LICENSE", "required_project_license_missing_or_unscanned"), self.findings()
            )

    def test_symlink_license_is_not_read_as_project_material(self):
        (self.root / "LICENSE").rename(self.root / "real-license.txt")
        (self.root / "LICENSE").symlink_to("real-license.txt")
        findings = self.findings()
        self.assertIn(("LICENSE", "symlink_requires_explicit_source_review"), findings)
        self.assertIn(("LICENSE", "required_project_license_missing_or_unscanned"), findings)

    def test_truncated_legal_text_fails(self):
        for relative, text in self.license_texts.items():
            with self.subTest(relative=relative):
                (self.root / relative).write_text(text[:2000], encoding="utf-8")
                self.assertIn(
                    (relative, "project_license_text_incomplete_or_unexpected"), self.findings()
                )
                self.restore_materials()

    def test_wrong_license_or_spdx_only_placeholder_fails(self):
        for relative, replacement in (
            ("LICENSE-DOCS", self.license_texts["LICENSE"]),
            ("LICENSE", "SPDX-License-Identifier: Apache-2.0\n"),
        ):
            with self.subTest(relative=relative):
                (self.root / relative).write_text(replacement, encoding="utf-8")
                self.assertIn(
                    (relative, "project_license_text_incomplete_or_unexpected"), self.findings()
                )
                self.restore_materials()

    def test_scope_boundaries_and_project_notice_are_required(self):
        for relative, original, removed, rule in (
            ("docs/licensing.md", SCOPE, "教材中的原创代码示例采用 Apache-2.0。",
             "project_license_scope_missing_declaration_or_boundary"),
            ("docs/licensing.md", SCOPE, "第三方材料保留原有许可。",
             "project_license_scope_missing_declaration_or_boundary"),
            ("NOTICE", NOTICE, "Agent Systems Lab",
             "project_notice_missing_identity_or_license_declaration"),
            ("NOTICE", NOTICE, "CC-BY-4.0",
             "project_notice_missing_identity_or_license_declaration"),
        ):
            with self.subTest(relative=relative, removed=removed):
                (self.root / relative).write_text(original.replace(removed, ""), encoding="utf-8")
                self.assertIn((relative, rule), self.findings())
                self.restore_materials()


if __name__ == "__main__":
    unittest.main()
