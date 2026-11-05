"""Headless Blender audit. Usage: blender -b --python winding_audit.py -- out.json files..."""
import json
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mesh_metrics import measure  # noqa: E402
from outside_rays import level_view, ray_counts  # noqa: E402


def audit(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if path.lower().endswith((".glb", ".gltf")):
        bpy.ops.import_scene.gltf(filepath=os.path.abspath(path))
    else:
        bpy.ops.import_scene.fbx(filepath=os.path.abspath(path))
    rows = []
    for obj in [o for o in bpy.data.objects if o.type == "MESH"]:
        me = obj.data
        me.calc_loop_triangles()
        # Match the pure reader: audit mesh-local bind geometry, not instances.
        # A mirrored object transform is not itself an inside-out mesh.
        verts = [v.co.copy() for v in me.vertices]
        cn = [c.vector.copy() for c in me.corner_normals]
        tris = list(me.loop_triangles)
        normals = 0
        for tri in tris:
            a, b, c = (verts[i] for i in tri.vertices)
            n = (b - a).cross(c - a)
            if n.length >= 2e-10 and all(n.dot(cn[i]) < 0 for i in tri.loops):
                normals += 1
        indices = [tuple(t.vertices) for t in tris]
        row = measure([tuple(v) for v in verts], indices)
        lt, _, level_hit = ray_counts(verts, indices, level_view())
        row.update(file=path, mesh=obj.name, normals=normals,
                   share=round(100 * row["inward_share"], 3),
                   ray_share=round(100 * row["hole_ray_share"], 3),
                   level_share=round(100 * sum(lt) / max(1, level_hit), 3))
        rows.append(row)
        print("AUDIT", os.path.basename(path), obj.name, row)
    if not rows:
        raise ValueError("no meshes")
    return rows


if __name__ == "__main__":
    out, *files = sys.argv[sys.argv.index("--") + 1:]
    rows = [row for path in files for row in audit(path)]
    with open(out, "w") as fh:
        json.dump(rows, fh, indent=2)
    print("WROTE", out, len(rows))
