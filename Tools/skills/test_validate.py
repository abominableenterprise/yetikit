"""Synthetic metadata regressions; no Unity or credentials needed."""

from pathlib import Path
import tempfile
import unittest

import yaml

from validate import validate_skill


class SkillMetadataTests(unittest.TestCase):
    def check_text(self, text: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example" / "SKILL.md"
            path.parent.mkdir()
            path.write_text(text, encoding="utf-8")
            validate_skill(path)

    def test_valid_plain_quoted_and_multiline_descriptions(self):
        for description in ("Do work when needed", '"Do work: when needed"', ">\n  Do work\n  when needed"):
            with self.subTest(description=description):
                self.check_text(f"---\nname: example\ndescription: {description}\n---\n# Steps\n")

    def test_invalid_frontmatter_is_rejected(self):
        fixtures = (
            "# No frontmatter\n",
            "---\nname: example\n",
            "---\n[]\n---\n",
            "---\nname: [invalid\n---\n",
            "---\ndescription: Do work\n---\n",
            "---\nname: another\ndescription: Do work\n---\n",
            "---\nname: example\n---\n",
            "---\nname: example\ndescription: ''\n---\n",
            "---\nname: example\ndescription: '   '\n---\n",
            "---\nname: example\ndescription: null\n---\n",
            "---\nname: example\ndescription: 42\n---\n",
        )
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                with self.assertRaises((ValueError, yaml.YAMLError)):
                    self.check_text(fixture)

    def test_line_limit(self):
        header = "---\nname: example\ndescription: Do work\n---\n"
        self.check_text(header + "step\n" * 146)
        with self.assertRaisesRegex(ValueError, "150 lines"):
            self.check_text(header + "step\n" * 147)


if __name__ == "__main__":
    unittest.main()
