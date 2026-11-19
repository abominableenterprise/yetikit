"""Synthetic regressions for audit-gate follow-ups from issue #19."""
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import tracemalloc
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_meshes import DEFAULTS, check, main
from fixtures.make_fixtures import TRIS, VERTS, glb
from mesh_metrics import measure

JSON = 0x4E4F534A
BIN = 0x004E4942


def cube_parts(tris=TRIS):
    raw = glb(VERTS, tris)
    length = struct.unpack_from("<I", raw, 12)[0]
    return raw[20:20 + length], raw[28 + length:]


def container(*chunks):
    payload = b"".join(struct.pack("<II", len(data), kind) + data for kind, data in chunks)
    return struct.pack("<4sII", b"glTF", 2, 12 + len(payload)) + payload


class AuditRegressionTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.asset = self.root / "cube.glb"
        self.asset.write_bytes(glb(VERTS, TRIS))

    def audit(self, path):
        return check(str(path), DEFAULTS, {}, None, False)

    def write_split_cube(self, doc, binary, uri="cube.bin"):
        path = self.asset.with_suffix(".gltf")
        doc["buffers"][0].update(uri=uri, byteLength=len(binary))
        path.write_text(json.dumps(doc))
        path.with_suffix(".bin").write_bytes(binary)
        return path

    def test_glb_rejects_duplicate_and_misordered_known_chunks(self):
        closed, binary = cube_parts()
        opened, _ = cube_parts(TRIS[2:])
        unknown = (0x11111111, b"test")
        for label, chunks in {
            "duplicate JSON": ((JSON, opened), (JSON, closed), (BIN, binary)),
            "duplicate BIN": ((JSON, closed), (BIN, binary), (BIN, binary)),
            "BIN first": ((BIN, binary), (JSON, closed)),
            "late BIN": ((JSON, closed), unknown, (BIN, binary)),
            "late JSON": (unknown, (JSON, closed), (BIN, binary)),
        }.items():
            with self.subTest(label=label):
                self.asset.write_bytes(container(*chunks))
                row = self.audit(self.asset)
                self.assertEqual(row["status"], "FAIL", row)
                self.assertIn("GLB", row["message"])
        self.asset.write_bytes(container((JSON, closed), (BIN, binary), unknown, unknown))
        self.assertEqual(self.audit(self.asset)["status"], "PASS")

    def test_rejects_misaligned_views_offsets_and_strides(self):
        text, original = cube_parts()
        for issue in ("shifted views", "relative position offset", "index offset", "position stride",
                      "index stride"):
            with self.subTest(issue=issue):
                doc = json.loads(text)
                pos, idx = doc["bufferViews"]
                binary = original
                if issue == "shifted views":
                    binary = b"\0" + binary
                    for view in (pos, idx):
                        view["byteOffset"] += 1
                elif issue == "relative position offset":
                    # The absolute start is aligned, but the accessor offset isn't.
                    binary = b"\0" * 4 + binary
                    pos.update(byteOffset=1, byteLength=pos["byteLength"] + 3)
                    doc["accessors"][0]["byteOffset"] = 3
                    idx["byteOffset"] += 4
                elif issue == "index offset":
                    start = idx["byteOffset"]
                    binary = binary[:start] + b"\0" + binary[start:]
                    idx["byteLength"] += 1
                    doc["accessors"][1]["byteOffset"] = 1
                elif issue == "position stride":
                    start = idx["byteOffset"]
                    binary = b"".join(binary[i:i + 12] + b"\0" for i in range(0, start, 12)) + binary[start:]
                    pos.update(byteStride=13, byteLength=start + len(VERTS))
                    idx["byteOffset"] = pos["byteLength"]
                else:
                    idx["byteStride"] = 2
                row = self.audit(self.write_split_cube(doc, binary))
                self.assertEqual(row["status"], "FAIL", row)
                self.assertRegex(row["message"], "align|stride")

    def test_indices_need_component_alignment_not_four_byte_alignment(self):
        text, binary = cube_parts()
        doc = json.loads(text)
        idx = doc["bufferViews"][1]
        start = idx["byteOffset"]
        idx["byteOffset"] += 2
        self.assertEqual(self.audit(self.write_split_cube(doc, binary[:start] + b"\0\0" + binary[start:]))["status"], "PASS")

    def test_optional_material_variants_do_not_change_audit(self):
        text, binary = cube_parts()
        doc = json.loads(text)
        extension = "KHR_materials_variants"
        doc.update(extensionsUsed=[extension], extensions={extension: {"variants": [{"name": "alternate"}]}},
                   materials=[{}, {}])
        primitive = doc["meshes"][0]["primitives"][0]
        primitive.update(material=0, extensions={extension: {"mappings": [{"material": 1, "variants": [0]}]}})
        row = self.audit(self.write_split_cube(doc, binary))
        self.assertEqual(row["status"], "PASS", row)
        primitive["extensions"]["KHR_draco_mesh_compression"] = {"bufferView": 0, "attributes": {"POSITION": 0}}
        self.assertEqual(self.audit(self.write_split_cube(doc, binary))["status"], "FAIL")
        del primitive["extensions"]["KHR_draco_mesh_compression"]
        doc["extensionsRequired"] = [extension]
        self.assertEqual(self.audit(self.write_split_cube(doc, binary))["status"], "FAIL")

    def test_report_cannot_overwrite_asset_or_external_buffer(self):
        text, binary = cube_parts()
        split = self.write_split_cube(json.loads(text), binary, uri="cube%2Ebin")
        buffer = split.with_suffix(".bin")
        # A failed audit must still protect buffers that were already read.
        malformed = json.loads(split.read_text())
        malformed["meshes"] = []
        split.write_text(json.dumps(malformed))
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
            for source in (self.asset, buffer):
                original = source.read_bytes()
                symlink = source.with_name(source.name + ".symlink")
                hardlink = source.with_name(source.name + ".hardlink")
                symlink.symlink_to(source)
                hardlink.hardlink_to(source)
                for report in (source, symlink, hardlink):
                    with self.subTest(report=report, source=source):
                        with self.assertRaises(SystemExit) as exit_code:
                            main(["--json", str(report), str(split), str(self.asset)])
                        self.assertEqual(exit_code.exception.code, 2)
                        self.assertIn("aliases", errors.getvalue())
                        self.assertEqual(source.read_bytes(), original)

    def test_report_protects_buffers_even_when_loading_fails_early(self):
        text, binary = cube_parts()
        for failure, message in (
            ({"extensionsRequired": ["EXT_dummy"]}, "required glTF extensions"),
            (None, "missing.bin"),
            ({"asset": {"version": "1.0"}}, "requires glTF 2.0"),
        ):
            with self.subTest(failure=failure):
                doc = json.loads(text)
                split = self.write_split_cube(doc, binary, uri="cube%2Ebin")
                buffer = split.with_suffix(".bin")
                if failure is None:
                    doc["buffers"].insert(0, {"uri": "missing.bin", "byteLength": 4})
                else:
                    doc.update(failure)
                split.write_text(json.dumps(doc))
                report = self.root / "out.json"
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(main(["--json", str(report), str(split)]), 1)
                row, = json.loads(report.read_text())["files"]
                self.assertEqual(row["status"], "FAIL")
                self.assertIn(message, row["message"])
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
                    with self.assertRaises(SystemExit) as exit_code:
                        main(["--json", str(buffer), str(split)])
                self.assertEqual(exit_code.exception.code, 2)
                self.assertIn("aliases an input", errors.getvalue())
                self.assertEqual(buffer.read_bytes(), binary)

    def test_report_protects_external_buffers_in_malformed_glbs(self):
        text, binary = cube_parts()
        doc = json.loads(text)
        doc["buffers"][0]["uri"] = "cube%2Ebin"
        external = json.dumps(doc).encode()
        external += b" " * (-len(external) % 4)
        valid = container((JSON, external))
        buffer = self.asset.with_suffix(".bin")
        self.asset.write_bytes(valid)
        buffer.write_bytes(binary)
        self.assertEqual(self.audit(self.asset)["status"], "PASS")
        for label, malformed in {
            "wrong magic": b"BAD!" + valid[4:],
            "wrong version": valid[:4] + struct.pack("<I", 1) + valid[8:],
            "wrong size": valid + b"extra",
            "duplicate JSON after reference": container((JSON, external), (JSON, text)),
            "duplicate JSON with reference": container((JSON, text), (JSON, external)),
            "unreadable JSON before reference": container((JSON, b"nope"), (JSON, external)),
            "misordered JSON": container((BIN, binary), (JSON, external)),
            "misaligned JSON": container((JSON, external + b" ")),
            "truncated JSON padding": container((JSON, external + b"    "))[:-1],
            "misaligned trailing chunk": container((JSON, external), (BIN, b"x")),
            "truncated trailing chunk header": (valid[:8] + struct.pack("<I", len(valid) + 4)
                                               + valid[12:] + b"test"),
            "truncated trailing chunk payload": container((JSON, external), (BIN, b"1234"))[:-1],
        }.items():
            with self.subTest(label=label):
                self.asset.write_bytes(malformed)
                buffer.write_bytes(binary)
                report = self.root / "out.json"
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(main(["--json", str(report), str(self.asset)]), 1)
                    row, = json.loads(report.read_text())["files"]
                    self.assertEqual(row["status"], "FAIL")
                    self.assertIn("GLB", row["message"])
                    with self.assertRaises(SystemExit) as exit_code:
                        main(["--json", str(buffer), str(self.asset)])
                self.assertEqual(exit_code.exception.code, 2)
                self.assertIn("aliases an input", errors.getvalue())
                self.assertEqual(buffer.read_bytes(), binary)

    def test_looping_buffer_and_asset_are_reported_without_aborting_batch(self):
        text, binary = cube_parts()
        split = self.write_split_cube(json.loads(text), binary, uri="loop")
        loop = self.root / "loop"
        loop.symlink_to(loop.name)
        asset_loop = self.root / "loop.glb"
        asset_loop.symlink_to(asset_loop.name)
        report = self.root / "out.json"
        with redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(["--json", str(report), str(split), str(asset_loop), str(self.asset)]), 1)
        rows = json.loads(report.read_text())["files"]
        self.assertEqual([row["status"] for row in rows], ["FAIL", "FAIL", "PASS"])
        self.assertRegex(rows[0]["message"].lower(), "symlink|symbolic link")
        self.assertEqual([line.split()[0] for line in output.getvalue().splitlines()], ["FAIL", "FAIL", "PASS"])

    def test_high_multiplicity_edge_connectivity_does_not_build_a_clique(self):
        count = 1024
        verts = [(0, 0, 0), (1, 0, 0)] + [(0, 1, i) for i in range(count)]
        tris = [(0, 1, i + 2) for i in range(count)]
        # Isolate topology from the ray rasterizer. A clique of 1024 Python
        # sets takes >32 MiB on CPython; allow ample headroom for linear storage.
        with patch("mesh_metrics.inward", return_value=([], 0, 0)):
            tracemalloc.start()
            try:
                row = measure(verts, tris)
                _, peak = tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
        self.assertEqual((row["over_edges"], row["open_edges"], row["inside_out"]), (1, 2 * count, 0))
        self.assertLess(peak, 12 * 1024 * 1024)
