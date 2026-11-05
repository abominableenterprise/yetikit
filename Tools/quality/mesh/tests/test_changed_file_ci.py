"""Execute the documented Bash recipes against real Git history and a stub auditor."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

README = Path(__file__).resolve().parents[2] / "README.md"


class ChangedFileCITest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Synthetic Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("commit", "-qm", "base", "--allow-empty")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        auditor = self.bin / "python3"
        auditor.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$AUDIT_ARGS"\nexit "${AUDIT_EXIT:-0}"\n')
        auditor.chmod(0o755)
        self.args = self.root / "audit-args"
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"], AUDIT_ARGS=str(self.args))
        section = README.read_text().split("## Changed-file CI\n")[1].split("## Scope and tests\n")[0]
        self.recipes = re.findall(r"```sh\n(.*?)```", section, re.S)
        self.assertEqual(len(self.recipes), 2)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True)

    def run_recipes(self, success):
        for recipe in self.recipes:
            with self.subTest(recipe=recipe):
                result = subprocess.run(["bash", "-c", recipe], cwd=self.root, env=self.env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                if success:
                    self.assertIn("model.glb", self.args.read_text().splitlines())

    def test_missing_base_ref_fails(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")
        self.run_recipes(success=False)

    def test_missing_merge_base_fails(self):
        self.git("checkout", "--orphan", "disconnected")
        self.git("commit", "-qm", "unrelated", "--allow-empty")
        self.run_recipes(success=False)

    def test_changed_model_is_audited_and_audit_failure_propagates(self):
        (self.root / "model.glb").touch()
        self.git("add", "model.glb")
        self.git("commit", "-qm", "model")
        self.run_recipes(success=True)
        self.env["AUDIT_EXIT"] = "1"
        self.run_recipes(success=False)


if __name__ == "__main__":
    unittest.main()
