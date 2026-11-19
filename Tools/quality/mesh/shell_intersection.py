"""Surface contact test for candidate nested triangle shells."""
import numpy as np


def _contacts(triangle, candidates, tolerance):
    # Separating-axis test for triangles. The in-plane edge normals are
    # additionally needed for coplanar triangles, where edge crosses alone
    # only give axes normal to the plane.
    a = triangle - triangle[0]
    b = candidates - triangle[0]
    ea = np.roll(a, -1, axis=0) - a
    eb = np.roll(b, -1, axis=1) - b
    na = np.cross(ea[0], ea[1])
    nb = np.cross(eb[:, 0], eb[:, 1])
    axes = np.concatenate((np.broadcast_to(na, (len(b), 1, 3)), nb[:, None],
                           np.cross(ea[None, :, None], eb[:, None]).reshape(-1, 9, 3),
                           np.broadcast_to(np.cross(na, ea), eb.shape),
                           np.cross(nb[:, None], eb)), axis=1)
    ap = np.einsum("vc,nkc->nvk", a, axes)
    bp = np.einsum("nvc,nkc->nvk", b, axes)
    margin = tolerance * np.linalg.norm(axes, axis=2)
    separated = (ap.max(axis=1) + margin < bp.min(axis=1)) | (bp.max(axis=1) + margin < ap.min(axis=1))
    return bool(np.any(~np.any(separated, axis=1)))


class _BoundsNode:
    def __init__(self, tris):
        self.lo = tris.min(axis=(0, 1))
        self.hi = tris.max(axis=(0, 1))
        self.count = len(tris)
        self.tris = tris
        self.children = ()

    def split(self):
        if not self.children:
            axis = np.argmax(self.hi - self.lo)
            mid = self.count // 2
            order = np.argpartition(self.tris[:, :, axis].mean(axis=1), mid)
            self.children = (_BoundsNode(self.tris[order[:mid]]), _BoundsNode(self.tris[order[mid:]]))
            self.tris = None
        return self.children


def surfaces_touch(first, second, tolerance):
    stack = [(_BoundsNode(first), _BoundsNode(second))]
    while stack:
        a, b = stack.pop()
        if np.any(a.hi + tolerance < b.lo) or np.any(b.hi + tolerance < a.lo):
            continue
        if a.count > 8 and a.count >= b.count:
            stack.extend((child, b) for child in a.split())
        elif b.count > 8:
            stack.extend((a, child) for child in b.split())
        elif any(_contacts(tri, b.tris, tolerance) for tri in a.tris):
            return True
    return False
