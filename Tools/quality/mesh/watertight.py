# Close an imported mesh into a watertight, consistently wound solid in Blender.
# Outside-ray voting alone can miss reversed faces on open meshes: a ray entering a hole may see an inward face
# front first. close_holes() repairs the topology before orienting the resulting closed pieces:
#  1. Weld UV-seam splits by position, keeping UVs and normals per corner.
#  2. Split edges shared by three or more faces and drop affected pieces under SHARD faces. Re-weld only within each kept
#     piece so separated sheets stay apart. Drop fins (faces with two or more open edges), then fill every open
#     boundary loop with triangulated faces and no new vertices. Each fill corner takes its vertex's UV from a rim
#     face. If a fill face would span a texture seam, use the rim UV closest to the loop's median colour instead.
#  3. Wind each connected piece consistently, then reverse any piece whose signed volume is still negative.
#  4. Preserve source corner normals, which may intentionally lean past a face at recessed rims. On turned faces,
#     negate only normals that followed the old inward winding. Fill corners receive the vertex's mean normal,
#     oriented to their face's side.
# turn_outward() can follow as an outside-ray check. unclosed() reports remaining open, over-used or same-way edges.
import bmesh
import numpy as np
from mathutils import Vector

SHARD = 20  # a piece (faces joined by two-face edges) this small, cut loose at a three-face edge, is a shard: dropped
SEAM_UV = 0.05  # a fill face whose UV triangle is wider than this (in UV units) would smear across the atlas
TMP = "close_holes_n"


def edge_use(bm):
    """(open edges, edges with more than two faces, shared edges whose two faces run the same way)."""
    open_n = sum(1 for e in bm.edges if len(e.link_faces) < 2)
    over = sum(1 for e in bm.edges if len(e.link_faces) > 2)
    same = sum(1 for e in bm.edges if len(e.link_loops) == 2 and e.link_loops[0].vert is e.link_loops[1].vert)
    return open_n, over, same


def _texel(pixels, uv):
    h, w = pixels.shape[:2]
    return pixels[int(np.clip(uv[1] % 1.0 * h, 0, h - 1)), int(np.clip(uv[0] % 1.0 * w, 0, w - 1)), :3]


def _rim_uv(vert, rim_faces, uv_layer):
    """The UV this vertex has in a rim face (the old faces beside the hole), or None."""
    for l in vert.link_loops:
        if l.face in rim_faces:
            return l[uv_layer].uv.copy()
    return None


def _flat_uv(corners, pixels):
    if pixels is None or not corners:
        return corners[0] if corners else Vector((0.5, 0.5))
    cols = np.array([_texel(pixels, uv) for uv in corners])
    return corners[int(np.argmin(np.linalg.norm(cols - np.median(cols, axis=0), axis=1)))]


def _uv_span(uvs):
    return max((a - b).length for a in uvs for b in uvs)


def pieces(bm):
    """The connected pieces (faces joined across shared edges), as lists of faces."""
    seen, out = set(), []
    for f in bm.faces:
        if f in seen:
            continue
        seen.add(f)
        stack, piece = [f], []
        while stack:
            g = stack.pop()
            piece.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h not in seen:
                        seen.add(h)
                        stack.append(h)
        out.append(piece)
    return out


def signed_volume(faces):
    """The volume a closed piece encloses: negative when it is wound inside out."""
    v = 0.0
    for f in faces:
        c = [l.vert.co for l in f.loops]
        v += sum(c[0].dot(c[k].cross(c[k + 1])) for k in range(1, len(c) - 1))
    return v / 6.0


def wind_outward(bm):
    """Reverse every closed piece wound inside out (negative volume); returns how many. recalc_face_normals winds a
    piece consistently but can pick the inward side. turn_outward() cannot detect this when a ray into a recessed
    piece still meets the far wall front face first."""
    bad = [p for p in pieces(bm) if signed_volume(p) < 0]
    for p in bad:
        bmesh.ops.reverse_faces(bm, faces=p)
    return len(bad)


def close_holes(obj, image=None):
    """Weld, fill every open loop and wind every piece outward (see the header). Returns a dict of the counts."""
    me = obj.data
    pixels = None
    if image is not None and image.size[0] > 0:
        pixels = np.array(image.pixels[:], dtype=np.float32).reshape(image.size[1], image.size[0], image.channels)
    attr = me.attributes.new(TMP, "FLOAT_VECTOR", "CORNER")
    for i, cn in enumerate(me.corner_normals):
        attr.data[i].vector = cn.vector
    bm = bmesh.new()
    bm.from_mesh(me)
    uv_layer = bm.loops.layers.uv.active
    nl = bm.loops.layers.float_vector[TMP]
    welded = len(bm.verts)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    welded -= len(bm.verts)
    before = edge_use(bm)
    tris_before = sum(len(f.verts) - 2 for f in bm.faces)

    shards = 0
    over_edges = [e for e in bm.edges if len(e.link_faces) > 2]
    if over_edges:
        affected = {f for e in over_edges for f in e.link_faces}
        bmesh.ops.split_edges(bm, edges=over_edges)
        seen, kept = set(), []
        for f in list(bm.faces):
            if f in seen:
                continue
            piece, stack = {f}, [f]
            while stack:
                for e in stack.pop().edges:
                    if len(e.link_faces) == 2:
                        for g in e.link_faces:
                            if g not in piece:
                                piece.add(g)
                                stack.append(g)
            seen |= piece
            if piece & affected and len(piece) < SHARD:
                bmesh.ops.delete(bm, geom=list(piece), context="FACES_ONLY")
                shards += len(piece)
            else:
                kept.append({v for g in piece for v in g.verts})
        # Re-weld within each kept piece only: welding across pieces would join the sheets the split separated again.
        for verts in kept:
            bmesh.ops.remove_doubles(bm, verts=[v for v in verts if v.is_valid], dist=1e-5)
    fins = 0
    while True:
        fin = [f for f in bm.faces if sum(e.is_boundary for e in f.edges) >= 2]
        if not fin:
            break
        bmesh.ops.delete(bm, geom=fin, context="FACES_ONLY")
        fins += len(fin)
    bmesh.ops.delete(bm, geom=[e for e in bm.edges if not e.link_faces], context="EDGES")  # a deleted shard's wire edges
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    boundary = [e for e in bm.edges if e.is_boundary]
    rim_faces = {f for e in boundary for f in e.link_faces}
    filled = bmesh.ops.holes_fill(bm, edges=boundary, sides=0)["faces"]
    loops = len(filled)
    new = bmesh.ops.triangulate(bm, faces=filled, quad_method="BEAUTY", ngon_method="BEAUTY")["faces"]
    flat = 0
    for f in new:
        f.smooth = True
        uvs = [_rim_uv(l.vert, rim_faces, uv_layer) for l in f.loops]
        if any(u is None for u in uvs) or _uv_span(uvs) > SEAM_UV:
            uv = _flat_uv([u for u in uvs if u is not None], pixels)
            uvs = [uv] * 3
            flat += 1
        for l, uv in zip(f.loops, uvs):
            l[uv_layer].uv = uv
            l[nl] = Vector()

    # Wind each connected piece consistently and outward (the pieces are closed now).
    flip = bm.faces.layers.int.new(TMP + "_flip")
    bm.normal_update()
    was = [f.normal.copy() for f in bm.faces]  # by position in bm.faces (recalc rebuilds the face wrappers, not the order)
    bm.faces.index_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    inside_out = wind_outward(bm)
    bm.normal_update()
    for i, f in enumerate(bm.faces):
        f[flip] = int(f.normal.dot(was[i]) < 0)
    after = edge_use(bm)
    tris_after = sum(len(f.verts) - 2 for f in bm.faces)
    bm.to_mesh(me)
    bm.free()

    # Corner normals (step 4).
    attr = me.attributes[TMP]
    stored = [Vector(d.vector) for d in attr.data]
    flipped = [d.value for d in me.attributes[TMP + "_flip"].data]
    mean = [Vector() for _ in me.vertices]
    for li, l in enumerate(me.loops):
        mean[l.vertex_index] += stored[li]
    normals = []
    for p in me.polygons:
        for li in p.loop_indices:
            n = stored[li]
            if n.length > 1e-6:  # source corner: negate only if its face was turned and it followed the old winding
                n = n.normalized()
                n = -n if flipped[p.index] and n.dot(p.normal) < 0 else n
            else:  # a fill corner
                n = mean[me.loops[li].vertex_index]
                n = n.normalized() if n.length > 1e-6 else p.normal.copy()
                n = -n if n.dot(p.normal) < 0 else n
            normals.append(tuple(n))
    me.attributes.remove(attr)
    me.attributes.remove(me.attributes[TMP + "_flip"])
    me.normals_split_custom_set(normals)
    me.update()
    report = {"welded": welded, "shards": shards, "fins": fins, "loops": loops, "fill_tris": len(new), "flat_uv": flat, "tris": (tris_before, tris_after),
              "inside_out": inside_out,
              "open": (before[0], after[0]), "over": (before[1], after[1]), "same_way": (before[2], after[2])}
    print("HOLES", obj.name, report)
    return report


def unclosed(report):
    """Why close_holes() left the mesh not watertight (open, over-used or same-way edges after it), or None."""
    left = {k: report[k][1] for k in ("open", "over", "same_way") if report[k][1]}
    return f"not watertight after --close-holes: {left}" if left else None
