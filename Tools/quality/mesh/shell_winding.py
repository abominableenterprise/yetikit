"""Winding of closed, consistently oriented, non-intersecting triangle shells."""
import numpy as np


class Shell:
    def __init__(self, triangles):
        self.points = np.asarray(triangles, dtype=float)
        self.lo = self.points.min(axis=(0, 1))
        self.hi = self.points.max(axis=(0, 1))
        a, b, c = (self.points - self.points[0, 0]).transpose(1, 0, 2)
        self.volume6 = np.einsum("ij,ij->i", a, np.cross(b, c)).sum()

    def contains(self, other):
        # For disjoint connected surfaces, any point on the candidate shell has
        # the same containment. Sum oriented solid angles rather than counting
        # ray hits (which need special handling on shared edges and vertices).
        rays = self.points - other.points[0, 0]
        lengths = np.linalg.norm(rays, axis=2)
        if np.any(lengths == 0):
            return False
        a, b, c = (rays / lengths[:, :, None]).transpose(1, 0, 2)
        numerator = np.einsum("ij,ij->i", a, np.cross(b, c))
        denominator = (1 + np.einsum("ij,ij->i", a, b) + np.einsum("ij,ij->i", b, c)
                       + np.einsum("ij,ij->i", c, a))
        # The sum of the half-angles is +/- 2*pi inside and zero outside;
        # ignore its sign so an inverted container still contributes to depth.
        return abs(np.arctan2(numerator, denominator).sum()) > np.pi


def wrong_winding(shells):
    """Yield indices with the wrong volume sign: + solid, - cavity, + island, ..."""
    if not shells:
        return
    lo, hi = np.array([s.lo for s in shells]), np.array([s.hi for s in shells])
    nonzero = np.array([s.volume6 != 0 for s in shells])
    for i, shell in enumerate(shells):
        if not nonzero[i]:
            continue
        candidates = np.flatnonzero(nonzero & np.all((lo < shell.lo) & (hi > shell.hi), axis=1))
        depth = sum(shells[j].contains(shell) for j in candidates)
        if shell.volume6 * (-1 if depth % 2 else 1) < 0:
            yield i
