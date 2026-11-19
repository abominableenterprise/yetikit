"""Synthetic cavity, solid island, and non-containing bounding box fixtures."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_meshes import DEFAULTS, check
from fixtures.make_fixtures import TRIS, VERTS, glb
from mesh_metrics import measure
from test_watertight import BLENDER, run_blender


def cube(verts, tris, scale, reverse, center=(0, 0, 0)):
    offset = len(verts)
    verts.extend(tuple(scale * c + origin for c, origin in zip(v, center)) for v in VERTS)
    tris.extend(tuple(i + offset for i in (t[::-1] if reverse else t)) for t in TRIS)


class NestedShellTest(unittest.TestCase):
    def test_audit_accepts_cavity_and_rejects_reversed_cavity(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "nested.glb"
            for reverse, expected in ((True, "PASS"), (False, "FAIL")):
                with self.subTest(cavity_winds_inward=reverse):
                    verts, tris = [], []
                    cube(verts, tris, 1, False)
                    cube(verts, tris, .5, reverse)
                    cube(verts, tris, .25, False)  # solid at depth two
                    path.write_bytes(glb(verts, tris))
                    result = check(str(path), DEFAULTS, {}, None, False)
                    self.assertEqual(result["status"], expected, result)
                    self.assertEqual(result["meshes"][0]["inside_out"], 0 if reverse else 12)

    def test_bounds_alone_do_not_make_a_cavity(self):
        # The little cube is strictly within the tetrahedron's bounds, but beyond its sloped face.
        verts = [(0, 0, 0), (4, 0, 0), (0, 4, 0), (0, 0, 4)]
        tris = [(0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)]
        cube(verts, tris, .25, False, center=(3, 3, 3))
        self.assertEqual(measure(verts, tris)["inside_out"], 0)
        tris[4:] = [t[::-1] for t in tris[4:]]
        self.assertEqual(measure(verts, tris)["inside_out"], 12)

    def test_intersecting_shell_is_not_a_cavity(self):
        # The cube crosses the tetrahedron's sloped face, although its first
        # vertex is inside and its bounds are strictly nested.
        verts = [(0, 0, 0), (4, 0, 0), (0, 4, 0), (0, 0, 4)]
        tris = [(0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)]
        for center in ((1.3, 1.3, 1.3), (1, 1, 1.25)):
            with self.subTest(center=center):
                v, t = list(verts), list(tris)
                cube(v, t, .25, False, center=center)
                self.assertEqual(measure(v, t)["inside_out"], 0)

    @unittest.skipUnless(BLENDER, "no Blender (set BLENDER=path/to/blender)")
    def test_repair_preserves_correct_cavity_and_reverses_wrong_one(self):
        script = """
import sys, bmesh
sys.path.insert(0, sys.argv[-1])
from watertight import pieces, signed_volume, wind_outward
from mathutils import Matrix
for inward in (True, False):
    bm = bmesh.new()
    for size in (2, 1, .5):
        bmesh.ops.create_cube(bm, size=size)
    shells = sorted(pieces(bm), key=signed_volume, reverse=True)
    if inward:
        bmesh.ops.reverse_faces(bm, faces=shells[1])
    assert wind_outward(bm) == (0 if inward else 1), inward
    assert [signed_volume(s) > 0 for s in shells] == [True, False, True]
    assert wind_outward(bm) == 0
    bm.free()
bm = bmesh.new()
verts = [bm.verts.new(v) for v in ((0, 0, 0), (4, 0, 0), (0, 4, 0), (0, 0, 4))]
for face in ((0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)):
    bm.faces.new([verts[i] for i in face])
bmesh.ops.create_cube(bm, size=.5, matrix=Matrix.Translation((1.3, 1.3, 1.3)))
assert wind_outward(bm) == 0
assert all(signed_volume(s) > 0 for s in pieces(bm))
bm.free()
print('RESULT OK')
"""
        result, line = run_blender(script)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(line, "RESULT OK")
