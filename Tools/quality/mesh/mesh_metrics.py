"""Read-only mesh metrics; source ray voting plus seam-aware topology/volume."""
from collections import defaultdict

import numpy as np

from outside_rays import MIN_VOTES, inward
from shell_winding import Shell, wrong_winding


def measure(verts, tris):
    v, t = np.asarray(verts, dtype=float), np.asarray(tris, dtype=int)
    if v.ndim != 2 or v.shape[1] != 3 or t.ndim != 2 or t.shape[1] != 3 or not len(t):
        raise ValueError("empty or invalid triangle mesh")
    if not np.isfinite(v).all() or t.min() < 0 or t.max() >= len(v):
        raise ValueError("invalid vertices or indices")
    # Exact position welding joins UV/normal seams without closing narrow real cracks.
    _, remap = np.unique(v, axis=0, return_inverse=True)
    edges, neighbors = defaultdict(list), defaultdict(set)
    for i, face in enumerate(remap[t]):
        for a, b in zip(face, np.roll(face, -1)):
            edges[tuple(sorted((a, b)))].append((i, a < b))
    open_n = sum(len(e) == 1 for e in edges.values())
    over = sum(len(e) > 2 for e in edges.values())
    same = sum(int(len(e) == 2 and e[0][1] == e[1][1]) for e in edges.values())
    for uses in edges.values():
        for i, _ in uses:
            neighbors[i].update(j for j, _ in uses if j != i)
    # Rays alone cannot identify a wholly inside-out closed shell: its far wall
    # still presents a front face. Signed volume supplies that missing evidence.
    unseen = set(range(len(t)))
    shells, shell_faces = [], []
    while unseen:
        seed = unseen.pop()
        piece, stack = {seed}, [seed]
        while stack:
            for j in neighbors[stack.pop()] & unseen:
                unseen.remove(j)
                piece.add(j)
                stack.append(j)
        indices = list(piece)
        local = remap[t[indices]]
        uses = (edges[tuple(sorted((a, b)))] for face in local for a, b in zip(face, np.roll(face, -1)))
        if all(len(e) == 2 and e[0][1] != e[1][1] for e in uses):
            shells.append(Shell(v[t[indices]]))
            shell_faces.append(piece)
    wrong = {face for i in wrong_winding(shells) for face in shell_faces[i]}
    bad, holes, hit = inward(verts, tris, MIN_VOTES)
    area = np.linalg.norm(np.cross(v[t[:, 1]] - v[t[:, 0]], v[t[:, 2]] - v[t[:, 0]]), axis=1)
    inward_count = len(set(bad) | wrong)
    return {"tris": len(t), "inward": inward_count, "inside_out": len(wrong),
            "inward_share": inward_count / len(t), "hole_ray_share": holes / max(1, hit),
            "holes": holes, "hit_rays": hit, "open_edges": open_n, "over_edges": over,
            "same_way_edges": same, "degenerate": int(np.count_nonzero(area == 0))}
