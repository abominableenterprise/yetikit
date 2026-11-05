import base64
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_meshes import DEFAULTS, check, configuration, main
from gltf_reader import load_meshes
from mesh_metrics import measure
from fixtures.make_fixtures import VERTS, TRIS, make

FIXTURES = Path(__file__).parent / "fixtures"


class QualityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.results = {p.stem: check(str(p), DEFAULTS, {}, None, False)
                       for p in FIXTURES.glob("*.glb")}

    def test_required_verdicts(self):
        self.assertEqual(len(self.results), 5)
        for name, result in self.results.items():
            self.assertEqual(result["status"], "PASS" if name == "closed_cube" else "FAIL", result)
        self.assertGreater(self.results["missing_face"]["meshes"][0]["open_edges"], 0)
        self.assertGreater(self.results["flipped_faces"]["meshes"][0]["inward_share"], .01)
        self.assertEqual(self.results["inside_out"]["meshes"][0]["inside_out"], 12)

    def test_open_exception_does_not_waive_closed_inside_out(self):
        from check_meshes import failures
        tube = self.results["open_tube"]["meshes"][0]
        self.assertEqual(failures(tube, DEFAULTS, True), [])
        self.assertIn("inside_out", failures(self.results["inside_out"]["meshes"][0], DEFAULTS, True))
        self.assertIn("same_way_edges", failures(self.results["flipped_faces"]["meshes"][0], DEFAULTS, True))

    def test_fixture_script_is_reproducible(self):
        with tempfile.TemporaryDirectory() as tmp:
            make(tmp)
            for path in FIXTURES.glob("*.glb"):
                self.assertEqual(path.read_bytes(), (Path(tmp) / path.name).read_bytes())

    def test_report_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()) as output:
            report = Path(tmp) / "out.json"
            args = ["--json", str(report), str(FIXTURES / "closed_cube.glb"), str(FIXTURES / "missing_face.glb")]
            self.assertEqual(main(args), 1)
            self.assertEqual([r["status"] for r in json.loads(report.read_text())["files"]], ["PASS", "FAIL"])
            self.assertEqual(len(output.getvalue().splitlines()), 2)
            self.assertEqual(main([]), 0)
            self.assertEqual(main(["--config", str(FIXTURES / "exceptions.json"),
                                   str(FIXTURES / "open_tube.glb")]), 0)

    def test_blender_absent_skip_or_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "model.fbx"
            path.touch()
            skipped = check(str(path), DEFAULTS, {}, None, False)
            self.assertEqual((skipped["status"], skipped["message"]), ("SKIP", "needs Blender"))
            self.assertEqual(check(str(path), DEFAULTS, {}, None, True)["status"], "FAIL")
            self.assertEqual(check(str(path) + ".missing", DEFAULTS, {}, None, False)["status"], "FAIL")

    def test_bad_config_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            for doc in ({"exceptions": {"a.glb": {"allowOpen": True}}},
                        {"exceptions": {"a.glb": {"reason": " "}}},
                        {"thresholds": {"holeRayShare": 2}}, {"thresholds": {"typo": 0}},
                        {"thresholds": {"maxOpenEdges": -1}}, {"thresholds": {"inwardShare": True}}):
                path.write_text(json.dumps(doc))
                with self.assertRaises(ValueError):
                    configuration(path)

    def test_gltf_external_and_data_buffers(self):
        raw = (FIXTURES / "closed_cube.glb").read_bytes()
        length = struct.unpack_from("<I", raw, 12)[0]
        doc = json.loads(raw[20:20 + length])
        binary = raw[28 + length:]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cube.gltf"
            (Path(tmp) / "cube.bin").write_bytes(binary)
            for uri in ("cube.bin", "data:application/octet-stream;base64," + base64.b64encode(binary).decode()):
                doc["buffers"][0]["uri"] = uri
                path.write_text(json.dumps(doc))
                self.assertEqual(load_meshes(path)[0][2], [list(t) for t in TRIS])
            doc["buffers"][0]["uri"] = "../escape.bin"
            path.write_text(json.dumps(doc))
            with self.assertRaisesRegex(ValueError, "escapes"):
                load_meshes(path)

    def test_seams_and_translated_volume(self):
        verts = [tuple(c + 1000 for c in VERTS[i]) for face in TRIS for i in face]
        tris = [list(range(i, i + 3)) for i in range(0, len(verts), 3)]
        row = measure(verts, tris)
        self.assertEqual((row["open_edges"], row["same_way_edges"], row["inside_out"]), (0, 0, 0))
        self.assertEqual(measure(verts, [t[::-1] for t in tris])["inside_out"], 12)

    def test_bad_file_does_not_abort_remaining_files(self):
        with tempfile.TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()) as output:
            path = Path(tmp) / "bad.glb"
            path.write_bytes(b"broken")
            self.assertEqual(main([str(path), str(FIXTURES / "closed_cube.glb")]), 1)
            self.assertEqual([line.split()[0] for line in output.getvalue().splitlines()], ["FAIL", "PASS"])

    def test_invalid_document_and_negative_references_fail(self):
        raw = (FIXTURES / "closed_cube.glb").read_bytes()
        length = struct.unpack_from("<I", raw, 12)[0]
        doc = json.loads(raw[20:20 + length])
        doc["buffers"][0]["uri"] = "data:application/octet-stream;base64," + base64.b64encode(raw[28 + length:]).decode()
        doc["meshes"][0]["primitives"][0]["indices"] = -1
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.gltf"
            for data in ([], doc):
                path.write_text(json.dumps(data))
                self.assertEqual(check(str(path), DEFAULTS, {}, None, False)["status"], "FAIL")

    def test_unsupported_and_interleaved_nonindexed_accessors(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "tri.gltf"
            binary = b"".join(struct.pack("<4f", *v, 99) for v in VERTS[:3])
            doc = {"asset": {"version": "2.0"},
                   "buffers": [{"byteLength": len(binary), "uri": "tri.bin"}],
                   "bufferViews": [{"buffer": 0, "byteLength": len(binary), "byteStride": 16}],
                   "accessors": [{"bufferView": 0, "type": "VEC3", "componentType": 5126, "count": 3}],
                   "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}]}
            (Path(tmp) / "tri.bin").write_bytes(binary)
            path.write_text(json.dumps(doc))
            _, verts, tris = load_meshes(path)[0]
            self.assertEqual((verts, tris), ([list(v) for v in VERTS[:3]], [[0, 1, 2]]))
            for key, value in (("sparse", {}), ("normalized", True)):
                doc["accessors"][0][key] = value
                path.write_text(json.dumps(doc))
                with self.assertRaises(ValueError):
                    load_meshes(path)
                del doc["accessors"][0][key]
            doc["extensionsRequired"] = ["unsupported"]
            path.write_text(json.dumps(doc))
            with self.assertRaises(ValueError):
                load_meshes(path)

    def test_degenerate_and_disconnected_inside_out_shell(self):
        self.assertEqual(measure([(0, 0, 0)] * 3, [(0, 1, 2)])["degenerate"], 1)
        shifted = [(x + 4, y, z) for x, y, z in VERTS]
        row = measure(VERTS + shifted, TRIS + [tuple(i + 8 for i in t[::-1]) for t in TRIS])
        self.assertEqual(row["inside_out"], 12)

    def test_thresholds_are_applied(self):
        from check_meshes import failures
        row = self.results["missing_face"]["meshes"][0]
        thresholds = dict(DEFAULTS, maxOpenEdges=4, inwardShare=1, holeRayShare=1)
        self.assertEqual(failures(row, thresholds), [])


# Optional real import/export round trip, in addition to source repair regressions.
BLENDER = os.environ.get("BLENDER") or shutil.which("blender")


@unittest.skipUnless(BLENDER, "no Blender (set BLENDER=path/to/blender)")
class BlenderCLITest(unittest.TestCase):
    def test_fbx_verdicts_match_glb(self):
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "export.py"
            script.write_text('''import bpy, sys
from pathlib import Path
source, target = map(Path, sys.argv[-2:])
for name in ("closed_cube", "missing_face", "flipped_faces", "inside_out"):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(source / (name + ".glb")))
    bpy.ops.export_scene.fbx(filepath=str(target / (name + ".fbx")))
    if name == "closed_cube":
        for obj in bpy.data.objects:
            if obj.type == "MESH":
                obj.scale.x = -1
        bpy.ops.export_scene.fbx(filepath=str(target / "mirrored_cube.fbx"))
''')
            result = subprocess.run([BLENDER, "-b", "--factory-startup", "--python-exit-code", "1",
                                     "--python", str(script), "--", str(FIXTURES.resolve()), tmp],
                                    capture_output=True, text=True, timeout=300)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path in Path(tmp).glob("*.fbx"):
                row = check(str(path), DEFAULTS, {}, BLENDER, True)
                self.assertEqual(row["status"], "PASS" if path.stem in ("closed_cube", "mirrored_cube") else "FAIL", row)


if __name__ == "__main__":
    unittest.main()
