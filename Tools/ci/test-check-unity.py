#!/usr/bin/env python3
"""Offline regressions for the cheap Unity CI checks."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("check_unity", Path(__file__).with_name("check-unity.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class UnityChecksTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", self.temp.name], check=True)

    def put(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def test_valid_untracked_package(self):
        self.put("Packages/core/A.cs", "// synthetic\n")
        self.put("Packages/core/A.cs.meta", "guid: " + "a" * 32 + "\n")
        self.put("Packages/core/A.asmdef", '{"autoReferenced": false}')
        self.assertEqual([], checker.validate(self.root))

    def test_missing_script_metadata(self):
        self.put("Packages/core/A.cs", "// synthetic\n")
        self.assertIn("missing .cs.meta", checker.validate(self.root)[0])

    def test_duplicate_guid_across_repo(self):
        self.put("Packages/core/A.cs.meta", "guid: " + "a" * 32 + "\n")
        self.put("Host/Assets/B.cs.meta", "guid: " + "A" * 32 + "\n")
        self.assertTrue(any("duplicate GUID" in error for error in checker.validate(self.root)))

    def test_malformed_guid(self):
        self.put("Host/Assets/A.meta", "guid: invalid\n")
        self.assertIn("expected one", checker.validate(self.root)[0])

    def test_invalid_assembly_json(self):
        for invalid in ("", "[]", "{bad", '{}\n{}'):
            with self.subTest(invalid=invalid):
                self.put("Packages/core/A.asmdef", invalid)
                self.assertTrue(checker.validate(self.root))

    def test_auto_reference_must_be_explicit_boolean_false(self):
        for invalid in ('{}', '{"autoReferenced": true}', '{"autoReferenced": 0}'):
            with self.subTest(invalid=invalid):
                self.put("Packages/core/A.asmdef", invalid)
                self.assertIn("autoReferenced must be false", checker.validate(self.root)[0])

    def test_ignored_editor_cache_is_not_scanned(self):
        self.put(".gitignore", "Library/\n")
        self.put("Host/Library/A.asmdef", "invalid")
        self.assertEqual([], checker.validate(self.root))


if __name__ == "__main__":
    unittest.main()
