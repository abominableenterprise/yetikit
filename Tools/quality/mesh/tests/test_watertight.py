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

# Remove the top of a cube, leaving a four-edge rim but no fins and no UV layer.
UNTEXTURED_HOLE = """
import sys, bpy, bmesh
sys.path.insert(0, sys.argv[-1])
from watertight import close_holes, unclosed
bm = bmesh.new()
bmesh.ops.create_cube(bm, size=1.0)
bm.normal_update()
bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.z > 0.9], context="FACES_ONLY")
me = bpy.data.meshes.new("open_cube")
bm.to_mesh(me)
bm.free()
obj = bpy.data.objects.new("open_cube", me)
bpy.context.scene.collection.objects.link(obj)
r = close_holes(obj)
assert unclosed(r) is None, r
assert r["open"] == (4, 0) and r["tris"] == (10, 12), r
assert r["fill_tris"] == 2 and r["flat_uv"] == 0, r
assert not me.uv_layers, "repair must not add a UV layer"
cap = [p for p in me.polygons if all(me.vertices[i].co.z > 0 for i in p.vertices)]
assert len(cap) == 2 and all(p.use_smooth for p in cap), "fill faces must still be smoothed"
assert all(p.normal.z > 0 for p in cap), "cap winding must face outward"
print("RESULT untextured hole filled")
"""

# Both sheets disappear during fin removal; even shared mesh data must stay intact on failure.
EMPTY_REPAIR = """
import sys, bpy
sys.path.insert(0, sys.argv[-1])
from watertight import close_holes

def snapshot(me):
    return ([tuple(v.co) for v in me.vertices], [tuple(e.vertices) for e in me.edges],
            [tuple(p.vertices) for p in me.polygons], [tuple(n.vector) for n in me.corner_normals],
            [a.name for a in me.attributes], [tuple(uv.vector) for uv in me.uv_layers.active.uv])

verts, faces = GEOMETRY
me = bpy.data.meshes.new("sheet")
me.from_pydata(verts, [], faces)
me.update()
uv_layer = me.uv_layers.new()
for i, uv in enumerate(uv_layer.uv):
    uv.vector = (i / len(me.loops), 0.5)
me.normals_split_custom_set([(0.6, 0, 0.8)] * len(me.loops))
obj = bpy.data.objects.new("sheet", me)
other = bpy.data.objects.new("shared_sheet", me)
before = snapshot(me)
try:
    close_holes(obj)
except ValueError as exc:
    assert "no triangles" in str(exc), str(exc)
else:
    raise AssertionError("repair accepted a result with no triangles")
assert obj.data == me and other.data == me, "repair replaced the shared mesh data"
assert snapshot(me) == before, "empty repair modified the source mesh"
print("RESULT empty repair rejected")
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
    def report(self, open_=(9, 0), over=(3, 0), same=(5, 0), tris=(10, 12)):
        return {"open": open_, "over": over, "same_way": same, "tris": tris}

    def test_a_closed_mesh_passes(self):
        self.assertIsNone(unclosed(self.report()))

    def test_empty_result_fails_even_with_no_bad_edges(self):
        self.assertIn("no triangles", unclosed(self.report(tris=(1, 0))))

    def test_over_used_edges_left_fail(self):
        self.assertIn("'over': 1", unclosed(self.report(over=(1, 1))))

    def test_open_or_same_way_edges_left_fail(self):
        self.assertIn("'open': 4", unclosed(self.report(open_=(133, 4))))
        self.assertIn("'same_way': 2", unclosed(self.report(same=(0, 2))))


@unittest.skipUnless(BLENDER, "no Blender (set BLENDER=path/to/blender)")
class CloseHolesBlenderTest(unittest.TestCase):
    def test_fills_a_hole_without_a_uv_layer(self):
        r, line = run_blender(UNTEXTURED_HOLE)
        self.assertEqual(r.returncode, 0, r.stdout[-2000:] + r.stderr[-2000:])
        self.assertEqual(line, "RESULT untextured hole filled")

    def test_empty_repair_does_not_modify_the_source(self):
        triangle = ([(0, 0, 0), (1, 0, 0), (0, 1, 0)], [(0, 1, 2)])
        grid = ([(x, y, 0) for y in range(4) for x in range(4)],
                [(i, i + 1, i + 5, i + 4) for i in (4 * y + x for y in range(3) for x in range(3))])
        for name, geometry in (("triangle", triangle), ("plane_grid", grid)):
            with self.subTest(name=name):
                r, line = run_blender(EMPTY_REPAIR.replace("GEOMETRY", repr(geometry)))
                self.assertEqual(r.returncode, 0, r.stdout[-2000:] + r.stderr[-2000:])
                self.assertEqual(line, "RESULT empty repair rejected")

    def test_shells_split_at_a_shared_edge_stay_apart(self):
        r, line = run_blender(TWO_SHELLS)
        self.assertIsNotNone(line, r.stdout[-2000:] + r.stderr[-2000:])
        over_before, over_after, open_after, shards, tris_before, tris_after = map(int, line.split()[1:])
        self.assertEqual(over_before, 3, "the shared edge's three segments have four faces each")
        self.assertEqual((over_after, open_after, shards), (0, 0, 0), "split apart, nothing dropped, nothing reopened")
        self.assertEqual(tris_after, tris_before)

    def test_small_independent_closed_part_survives_an_unrelated_split(self):
        script = TWO_SHELLS.replace('me = bpy.data.meshes.new("shells")',
                                    'bmesh.ops.create_cube(bm, size=1.0, matrix=Matrix.Translation((4, 0, 0)))\n'
                                    'me = bpy.data.meshes.new("shells")')
        r, line = run_blender(script)
        self.assertEqual(r.returncode, 0, r.stdout[-2000:] + r.stderr[-2000:])
        self.assertIsNotNone(line, r.stdout[-2000:] + r.stderr[-2000:])
        over_before, over_after, open_after, shards, tris_before, tris_after = map(int, line.split()[1:])
        self.assertEqual((over_before, over_after, open_after), (3, 0, 0))
        self.assertEqual(tris_before, 228, "two subdivided shells plus a separate six-face cube")
        self.assertEqual((shards, tris_after), (0, tris_before), "the unrelated small closed part must survive")

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
