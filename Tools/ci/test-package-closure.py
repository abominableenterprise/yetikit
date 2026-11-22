#!/usr/bin/env python3
"""Offline regressions for the module dependency checker."""

import json
from pathlib import Path
import runpy
import tempfile
import unittest

lint = runpy.run_path(Path(__file__).with_name("check-package-closure.py"))["lint"]
PREFIX = "com.abominable.yetikit."
IMAGE = "com.unity.modules.imageconversion"


class ClosureTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def write(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text, encoding="utf-8")

    def fixture(self, playtest_deps, core_deps, locked):
        self.write("Host/Packages/packages-lock.json", json.dumps({"dependencies": locked}))
        for package, deps in (("playtest", playtest_deps), ("core", core_deps)):
            self.write(f"Packages/{PREFIX}{package}/package.json", json.dumps({"dependencies": deps}))
        self.write(f"Packages/{PREFIX}playtest/Runtime/Nested/Frames.cs", '''
// EncodeToPNG();
var title = @"LoadImage";
var jpg = texture.EncodeToJPG(90);
''')
        self.write(f"Packages/{PREFIX}playtest/Editor/Other.cs", '''
/* texture.EncodeToPNG(); */
var copy = "texture.EncodeToJPG(90);";
void PreloadImage() {}
''')
        return lint(self.root)

    def test_unrelated_host_module_and_stale_kit_lock_do_not_supply_api(self):
        count, errors = self.fixture({PREFIX + "core": "0.3.0"}, {}, {
            IMAGE: {"dependencies": {}},
            PREFIX + "playtest": {"dependencies": {IMAGE: "1.0.0"}},
        })
        self.assertEqual(count, 2)
        self.assertEqual(len(errors), 1)
        self.assertIn(f"Frames.cs:4: EncodeToJPG requires {IMAGE}", errors[0])

    def test_direct_and_transitive_dependencies_supply_api(self):
        self.assertEqual(self.fixture({IMAGE: "1.0.0"}, {}, {}), (2, []))
        self.assertEqual(self.fixture({PREFIX + "core": "0.3.0"}, {IMAGE: "1.0.0"}, {}), (2, []))
        self.assertEqual(self.fixture({"com.unity.fixture": "1.2.3"}, {}, {
            "com.unity.fixture": {"dependencies": {IMAGE: "1.0.0"}},
        }), (2, []))


if __name__ == "__main__":
    unittest.main()
