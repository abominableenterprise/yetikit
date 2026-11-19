"""Execute the documented Bash recipes against real Git history and a stub auditor."""
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest

from fixtures.make_fixtures import TRIS, VERTS, glb

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
        auditor.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = Tools/quality/mesh/check_meshes.py ]; then\n'
            '    printf "%s\\0" "$@" >> "$AUDIT_ARGS"\n'
            '    exit "${AUDIT_EXIT:-0}"\n'
            'fi\n'
            'exec "$REAL_PYTHON" "$@"\n'
        )
        auditor.chmod(0o755)
        tools = self.root / "Tools/quality"
        tools.mkdir(parents=True)
        (tools / "mesh").symlink_to(README.parent / "mesh", target_is_directory=True)
        self.args = self.root / "audit-args"
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        AUDIT_ARGS=str(self.args), REAL_PYTHON=sys.executable)
        section = README.read_text().split("## Changed-file CI\n")[1].split("## Scope and tests\n")[0]
        self.recipes = re.findall(r"```sh\n(.*?)```", section, re.S)
        self.assertEqual(len(self.recipes), 2)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env, check=True,
                              capture_output=True, text=True)

    def run_recipes(self, success, *, assets=None):
        for recipe in self.recipes:
            with self.subTest(recipe=recipe):
                self.args.unlink(missing_ok=True)
                result = subprocess.run(["bash", "-c", recipe], cwd=self.root, env=self.env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                if assets is not None:
                    args = self.args.read_bytes().split(b"\0")[:-1] if self.args.exists() else []
                    selected = [os.fsdecode(arg) for arg in args
                                if arg.lower().endswith((b".gltf", b".glb", b".fbx"))]
                    self.assertCountEqual(selected, assets)
                    if not assets:
                        self.assertFalse(self.args.exists(), "empty selection invoked the auditor")

    def commit_split_mesh(self):
        asset = self.root / "meshes/cube model.gltf"
        asset.parent.mkdir()
        buffer = asset.parent / "shared/vertices data.bin"
        buffer.parent.mkdir()
        raw = glb(VERTS, TRIS)
        json_size = struct.unpack_from("<I", raw, 12)[0]
        doc = json.loads(raw[20:20 + json_size])
        doc["buffers"][0]["uri"] = "shared/vertices%20data.bin"
        asset.write_text(json.dumps(doc))
        buffer.write_bytes(raw[28 + json_size:])
        self.git("add", "meshes")
        self.git("commit", "-qm", "split mesh")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        return asset.relative_to(self.root).as_posix(), buffer

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
        self.run_recipes(success=True, assets=["model.glb"])
        self.env["AUDIT_EXIT"] = "1"
        self.run_recipes(success=False, assets=["model.glb"])

    def test_buffer_only_edit_audits_unchanged_owner(self):
        asset, buffer = self.commit_split_mesh()
        buffer.write_bytes(buffer.read_bytes()[:-4])  # Truncate the index data.
        self.git("add", "meshes")
        self.git("commit", "-qm", "truncate buffer only")
        self.env["AUDIT_EXIT"] = "1"
        self.run_recipes(success=False, assets=[asset])

    def test_buffer_only_deletion_audits_unchanged_owner(self):
        asset, buffer = self.commit_split_mesh()
        self.git("rm", str(buffer.relative_to(self.root)))
        self.git("commit", "-qm", "delete buffer only")
        self.run_recipes(success=True, assets=[asset])

    def test_buffer_rename_selects_gltf_and_glb_once(self):
        asset, buffer = self.commit_split_mesh()
        container = self.root / "container.glb"
        container.write_bytes(glb(VERTS, TRIS))
        self.git("add", container.name)
        self.git("commit", "-qm", "add container")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        old_buffer = buffer.relative_to(self.root)
        self.git("mv", str(old_buffer), str(old_buffer.with_suffix(".dat")))
        model = self.root / asset
        model.write_bytes(model.read_bytes() + b"\n")
        self.git("add", asset)
        self.git("commit", "-qm", "move buffer and edit model")
        self.run_recipes(success=True, assets=[asset, container.name])

    def test_changed_models_keep_literal_names_and_deleted_models_are_skipped(self):
        deleted = self.root / "removed.glb"
        deleted.touch()
        self.git("add", deleted.name)
        self.git("commit", "-qm", "original model")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("rm", deleted.name)
        changed = "-new\tmodel\nname.GLTF"
        (self.root / changed).touch()
        self.git("add", "--", changed)
        self.git("commit", "-qm", "replace model")
        self.run_recipes(success=True, assets=[changed])

    def test_unrelated_change_does_not_audit_unchanged_models(self):
        self.commit_split_mesh()
        (self.root / "unrelated.txt").touch()
        self.git("add", "unrelated.txt")
        self.git("commit", "-qm", "unrelated")
        self.run_recipes(success=True, assets=[])


if __name__ == "__main__":
    unittest.main()
