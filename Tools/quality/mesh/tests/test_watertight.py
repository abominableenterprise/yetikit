# Run: python3 -m unittest discover -s Tools/quality/mesh/tests -p "test_*.py"
# watertight.py runs inside Blender. unclosed() (the refusal to export a non-watertight mesh) is tested here
# with bmesh/numpy/mathutils stubbed; close_holes() itself runs in Blender (BLENDER=path, or blender on PATH),
# skipped without one.
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

MESH_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_stubs = {name: types.ModuleType(name) for name in ("bmesh", "numpy", "mathutils")}
_stubs["mathutils"].Vector = object

# Do not leave fake dependencies or the module imported with them in the process-wide cache.
with patch.object(sys, "path", [MESH_DIR, *sys.path]), patch.dict(sys.modules, _stubs):
    from watertight import unclosed

HERE = MESH_DIR
BLENDER = os.environ.get("BLENDER") or shutil.which("blender")

# Two subdivided cubes (54 quads each, well over SHARD) touching along one edge: after the weld that edge (three
# segments) has four faces. close_holes() must split it and keep the two shells apart, not weld them back.
TWO_SHELLS = """
import sys, bpy, bmesh
sys.path.insert(0, sys.argv[-1])
from watertight import close_holes
from mathutils import Matrix
bm = bmesh.new()
for x in (0.5, 1.5):
    cube = bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation((x, x, 0.5)))
    bmesh.ops.subdivide_edges(bm, edges=list({e for v in cube["verts"] for e in v.link_edges}), cuts=2, use_grid_fill=True)
me = bpy.data.meshes.new("shells")
bm.to_mesh(me)
bm.free()
me.uv_layers.new()
obj = bpy.data.objects.new("shells", me)
bpy.context.scene.collection.objects.link(obj)
r = close_holes(obj)
print("RESULT", r["over"][0], r["over"][1], r["open"][1], r["shards"], r["tris"][0], r["tris"][1])
"""

# A closed subdivided cube with one face wound inward but outward corner normals: close_holes() turns the
# face and must keep its normals outward (negate only the ones that followed the old winding).
INWARD_FACE = """
import sys, bpy, bmesh
sys.path.insert(0, sys.argv[-1])
from watertight import close_holes
bm = bmesh.new()
cube = bmesh.ops.create_cube(bm, size=1.0)
bmesh.ops.subdivide_edges(bm, edges=list(bm.edges), cuts=2, use_grid_fill=True)
bm.faces.ensure_lookup_table()
bmesh.ops.reverse_faces(bm, faces=[bm.faces[0]])
me = bpy.data.meshes.new("cube")
bm.to_mesh(me)
bm.free()
me.uv_layers.new()
me.normals_split_custom_set([tuple(me.vertices[l.vertex_index].co.normalized()) for l in me.loops])
obj = bpy.data.objects.new("cube", me)
bpy.context.scene.collection.objects.link(obj)
r = close_holes(obj)
inward = sum(1 for l in me.loops if me.corner_normals[l.index].vector.dot(me.vertices[l.vertex_index].co) < 0)
print("RESULT", r["same_way"][0], r["same_way"][1], inward)
"""

# A closed cube wound wholly inside out: wind_outward() reverses it, and leaves an outward one alone.
INSIDE_OUT = """
import sys, bmesh
sys.path.insert(0, sys.argv[-1])
from watertight import wind_outward, signed_volume
bm = bmesh.new()
bmesh.ops.create_cube(bm, size=1.0)
bmesh.ops.reverse_faces(bm, faces=list(bm.faces))
before = signed_volume(bm.faces)
n = wind_outward(bm)
again = wind_outward(bm)
print("RESULT", round(before, 3), n, round(signed_volume(bm.faces), 3), again)
"""


def run_blender(script):
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(script)
    try:
        r = subprocess.run([BLENDER, "-b", "--factory-startup", "--python-exit-code", "1", "--python", f.name, "--", HERE],
                           capture_output=True, text=True, timeout=300)
    finally:
        os.unlink(f.name)
    return r, next((l for l in r.stdout.splitlines() if l.startswith("RESULT")), None)


class UnclosedTest(unittest.TestCase):
    def report(self, open_=(9, 0), over=(3, 0), same=(5, 0)):
        return {"open": open_, "over": over, "same_way": same}

    def test_a_closed_mesh_passes(self):
        self.assertIsNone(unclosed(self.report()))

    def test_over_used_edges_left_fail(self):
        self.assertIn("'over': 1", unclosed(self.report(over=(1, 1))))

    def test_open_or_same_way_edges_left_fail(self):
        self.assertIn("'open': 4", unclosed(self.report(open_=(133, 4))))
        self.assertIn("'same_way': 2", unclosed(self.report(same=(0, 2))))


@unittest.skipUnless(BLENDER, "no Blender (set BLENDER=path/to/blender)")
class CloseHolesBlenderTest(unittest.TestCase):
    def test_shells_split_at_a_shared_edge_stay_apart(self):
        r, line = run_blender(TWO_SHELLS)
        self.assertIsNotNone(line, r.stdout[-2000:] + r.stderr[-2000:])
        over_before, over_after, open_after, shards, tris_before, tris_after = map(int, line.split()[1:])
        self.assertEqual(over_before, 3, "the shared edge's three segments have four faces each")
        self.assertEqual((over_after, open_after, shards), (0, 0, 0), "split apart, nothing dropped, nothing reopened")
        self.assertEqual(tris_after, tris_before)

    def test_a_turned_face_keeps_its_outward_corner_normals(self):
        r, line = run_blender(INWARD_FACE)
        self.assertIsNotNone(line, r.stdout[-2000:] + r.stderr[-2000:])
        same_before, same_after, inward = map(int, line.split()[1:])
        self.assertGreater(same_before, 0, "the reversed face runs the same way as its neighbours")
        self.assertEqual(same_after, 0, "close_holes turned it")
        self.assertEqual(inward, 0, "its outward source normals stay outward")

    def test_an_inside_out_piece_is_reversed(self):
        r, line = run_blender(INSIDE_OUT)
        self.assertIsNotNone(line, r.stdout[-2000:] + r.stderr[-2000:])
        before, n, after, again = line.split()[1:]
        self.assertEqual((float(before), int(n), float(after), int(again)), (-1.0, 1, 1.0, 0))


if __name__ == "__main__":
    unittest.main()
