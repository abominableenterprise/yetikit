# Imported meshes can have triangles wound against their own vertex normals, producing see-through holes when
# back faces are culled. fix_winding() welds UV-seam splits, aligns faces with source normals and clears custom normals.
# Recalculating face normals alone is unreliable on open meshes. turn_outward() instead uses outside rays to find
# back faces visible through the mesh, including thin layers whose source normals also point inward.
import os
import sys

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import outside_rays  # noqa: E402


def reference_normals(m):
    """Source direction per face (the sum of its corner normals) and a BVH of the source faces."""
    me = m.data
    ref = [sum((me.corner_normals[i].vector for i in p.loop_indices), Vector()) for p in me.polygons]
    bm = bmesh.new()
    bm.from_mesh(me)
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    return ref, tree


def against(bm, ref, tree):
    """Faces wound against the source normal nearest to them."""
    bm.normal_update()
    return [f for f in bm.faces if f.normal.dot(ref[tree.find_nearest(f.calc_center_median())[2]]) < 0]


def agree(bm, ref, tree):
    """Reverse every face wound against the source normal nearest to it; returns how many."""
    flip = against(bm, ref, tree)
    bmesh.ops.reverse_faces(bm, faces=flip)
    return len(flip)


def weld(bm):
    """Merge the importer's UV-seam splits; returns how many vertices went."""
    n = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    return n - len(bm.verts)


def seam_weld(m):
    """weld() on an object's mesh in place before decimation; returns how many vertices went."""
    bm = bmesh.new()
    bm.from_mesh(m.data)
    welded = weld(bm)
    bm.to_mesh(m.data)
    bm.free()
    m.data.update()
    print("SEAMS", m.name, "welded", welded)
    return welded


def fix_winding(m, ref, tree):
    bm = bmesh.new()
    bm.from_mesh(m.data)
    welded = weld(bm)
    flipped = agree(bm, ref, tree)
    bm.to_mesh(m.data)
    bm.free()
    clear_custom_normals(m)
    print("WINDING", m.name, "welded", welded, "flipped", flipped)
    return flipped


def clear_custom_normals(m):
    if m.data.has_custom_normals:
        bpy.context.view_layer.objects.active = m
        bpy.ops.mesh.customdata_custom_splitnormals_clear()


def settle(bad_faces, reverse, rounds=4):
    """Reverse bad_faces(round) with reverse(faces) until none is left, at most `rounds` times; after the last reversal
    vote once more (bad_faces(rounds)). Returns (flipped, left): the face indices reversed an odd number of times
    (bmesh face references do not survive reverse_faces) and the faces still bad at the end, 0 only when converged."""
    flipped = set()
    for rnd in range(rounds):
        bad = bad_faces(rnd)
        if not bad:
            return flipped, 0
        reverse(bad)
        flipped ^= bad
    return flipped, len(bad_faces(rounds))


def turn_outward(m, unseen=True):
    """Reverse faces of mesh object m that rays from outside see back face first (outside_rays.py; repeat because a
    turned face can uncover another), and unseen faces wound against all three of their source corner normals.
    No weld, vertex or UV change: custom normals stay, except on a turned face whose normals pointed along its old
    winding, where they turn with it.
    unseen=False skips the unseen faces' corner-normal rule: on a mesh watertight.close_holes() already closed and wound
    consistently, a recessed face whose source normals lean past it is not necessarily inside out.
    Returns (turned, left): faces reversed, and the faces still seen through after the last round."""
    me = m.data
    old = [[(me.loops[i].vertex_index, me.corner_normals[i].vector.copy()) for i in p.loop_indices] for p in me.polygons]
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    bm.normal_update()
    unseen_against = set()

    def bad_faces(rnd):
        bm.verts.ensure_lookup_table()
        bm.faces.ensure_lookup_table()
        loops = bm.calc_loop_triangles()
        tris = [tuple(l.vert.index for l in t) for t in loops]
        through, front = outside_rays.votes([tuple(v.co) for v in bm.verts], tris)
        bad = {loops[k][0].face.index for k in range(len(tris)) if through[k] > front[k]}
        if rnd == 0 and unseen:
            seen = {loops[k][0].face.index for k in range(len(tris)) if through[k] or front[k]}
            for f in bm.faces:
                if f.index not in seen and f.calc_area() > 1e-10 and all(f.normal.dot(n) < 0 for _, n in old[f.index]):
                    unseen_against.add(f.index)
            bad |= unseen_against
        return bad

    def reverse(bad):
        bmesh.ops.reverse_faces(bm, faces=[bm.faces[i] for i in bad])
        bm.normal_update()

    flipped, left = settle(bad_faces, reverse)
    bm.to_mesh(me)
    bm.free()
    normals = []
    for p in me.polygons:
        by_vert = dict(old[p.index])
        if p.index in flipped:
            was = -p.normal  # the old winding's normal
            normals += [(-by_vert[me.loops[i].vertex_index] if by_vert[me.loops[i].vertex_index].dot(was) > 0
                         else by_vert[me.loops[i].vertex_index]) for i in p.loop_indices]
        else:
            normals += [by_vert[me.loops[i].vertex_index] for i in p.loop_indices]
    me.normals_split_custom_set([tuple(n) for n in normals])
    print("WINDING", m.name, "turned", len(flipped), "of", len(me.polygons), "unseen against normals", len(unseen_against), "left", left)
    return len(flipped), left
