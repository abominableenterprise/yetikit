# Outside-ray visibility test shared by winding_audit.py and winding.py's turn_outward().
# Parallel rays come at the mesh from DIRS directions (a Fibonacci sphere), one through the centre of each cell of a
# GRID x GRID grid across its bounding sphere. Along a ray, the first triangle is what a double-sided render shows; the
# first FRONT-facing one is what a back-face-culled render shows. A ray whose first triangle faces away from it and
# that meets no front face at all looks through the model: it counts as a hole and a see-through vote for that first
# triangle. (A back face with a front face behind it, such as a sleeve over an arm or two coincident layers of opposite
# winding on thin parts, is not a hole.)
# Rays are cast by rasterising each triangle into the grid (cell centres inside it), no BVH needed.
import math

DIRS = 64
GRID = 64
# The audit's evidence bar: a triangle counts as inward when at least MIN_VOTES rays look through it.
# One or two stray rays are sampling noise (a crack between two triangles, a sliver); they move with the grid under
# axis conversion. The fix pass (winding.turn_outward) keeps turning on any majority.
MIN_VOTES = 3


def sphere(n=DIRS):
    g = math.pi * (3 - math.sqrt(5))
    out = []
    for i in range(n):
        y = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(1 - y * y)
        out.append((math.cos(g * i) * r, y, math.sin(g * i) * r))
    return out


def _sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def _dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def _cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _norm(a):
    l = math.sqrt(_dot(a, a))
    return (a[0] / l, a[1] / l, a[2] / l) if l > 0 else (0.0, 0.0, 0.0)


def basis(d):
    """Two unit vectors across d."""
    a = (1.0, 0.0, 0.0) if abs(d[0]) < 0.9 else (0.0, 1.0, 0.0)
    u = _norm(_cross(d, a))
    return u, _cross(d, u)


def votes(verts, tris, dirs=None):
    """Per triangle: (see-through votes, front-first votes). verts: xyz triples; tris: vertex index triples; dirs: the
    ray directions (default: sphere())."""
    through, front, _ = ray_counts(verts, tris, dirs)
    return through, front


def ray_counts(verts, tris, dirs=None):
    """votes() plus the number of rays that hit the mesh at all: the share denominator. It also counts the rays that
    meet a back face first and a front face behind it, which vote for no triangle."""
    verts = [tuple(v) for v in verts]
    lo = [min(v[i] for v in verts) for i in range(3)]
    hi = [max(v[i] for v in verts) for i in range(3)]
    c = tuple((lo[i] + hi[i]) / 2 for i in range(3))
    radius = math.sqrt(sum((hi[i] - lo[i]) ** 2 for i in range(3))) / 2 + 1e-9
    fn = []
    for a, b, cc in tris:
        n = _cross(_sub(verts[b], verts[a]), _sub(verts[cc], verts[a]))
        fn.append(n)
    through = [0] * len(tris)
    front = [0] * len(tris)
    hit = 0
    cell = 2 * radius / GRID
    for d in (dirs if dirs is not None else sphere()):
        u, w = basis(d)
        p = [(_dot(_sub(v, c), u), _dot(_sub(v, c), w), _dot(_sub(v, c), d)) for v in verts]
        cells = {}
        for k, (ia, ib, ic) in enumerate(tris):
            facing = _dot(fn[k], d)
            if facing == 0:
                continue
            A, B, C = p[ia], p[ib], p[ic]
            area = (B[0] - A[0]) * (C[1] - A[1]) - (B[1] - A[1]) * (C[0] - A[0])
            if area == 0:
                continue
            x0 = max(0, int(math.ceil((min(A[0], B[0], C[0]) + radius) / cell - 0.5)))
            x1 = min(GRID - 1, int(math.floor((max(A[0], B[0], C[0]) + radius) / cell - 0.5)))
            y0 = max(0, int(math.ceil((min(A[1], B[1], C[1]) + radius) / cell - 0.5)))
            y1 = min(GRID - 1, int(math.floor((max(A[1], B[1], C[1]) + radius) / cell - 0.5)))
            for i in range(x0, x1 + 1):
                x = (i + 0.5) * cell - radius
                for j in range(y0, y1 + 1):
                    y = (j + 0.5) * cell - radius
                    l0 = ((B[0] - x) * (C[1] - y) - (B[1] - y) * (C[0] - x)) / area
                    l1 = ((C[0] - x) * (A[1] - y) - (C[1] - y) * (A[0] - x)) / area
                    l2 = 1.0 - l0 - l1
                    if l0 < 0 or l1 < 0 or l2 < 0:
                        continue
                    cells.setdefault(i * GRID + j, []).append((l0 * A[2] + l1 * B[2] + l2 * C[2], k, facing > 0))
        hit += len(cells)
        for hits in cells.values():
            hits.sort()
            _, first, back = hits[0]
            if not back:
                front[first] += 1
                continue
            if all(b for _, _, b in hits):
                through[first] += 1
    return through, front, hit


def inward(verts, tris, min_votes=1):
    """Indices of the triangles seen through more often than seen front first (and by at least min_votes rays), the
    see-through rays, and all the rays that hit (ray_counts())."""
    through, front, hit = ray_counts(verts, tris)
    return [k for k in range(len(tris)) if through[k] > front[k] and through[k] >= min_votes], sum(through), hit


def level_view(z_up=2):
    """The directions of sphere() a standing or crouching viewer looks along: level or down (z_up: the up axis)."""
    return [d for d in sphere() if d[z_up] <= 0.1]
