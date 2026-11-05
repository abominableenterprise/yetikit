# Run: python3 -m unittest discover -s Tools/quality/mesh/tests -p "test_*.py"
import os
import sys
import unittest
from unittest.mock import patch

MESH_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with patch.object(sys, "path", [MESH_DIR, *sys.path]):
    from outside_rays import inward, ray_counts, votes

DOWN = [(0.0, 0.0, 1.0)]  # one ray direction: along +z, so a triangle whose normal points +z is a back face to it


def square(z, up, x0=-1.0, x1=1.0):
    """Two triangles covering [x0, x1] x [-1, 1] at height z, wound to face +z (up) or -z."""
    a, b, c, d = (x0, -1.0, z), (x1, -1.0, z), (x1, 1.0, z), (x0, 1.0, z)
    return [(a, b, c), (a, c, d)] if up else [(a, c, b), (a, d, c)]


def mesh(*squares):
    verts, tris = [], []
    for sq in squares:
        for t in sq:
            tris.append(tuple(range(len(verts), len(verts) + 3)))
            verts.extend(t)
    return verts, tris


class RayCountsTest(unittest.TestCase):
    def test_back_first_with_front_behind_votes_for_nobody_but_counts_as_hit(self):
        # A sleeve over an arm: the ray meets a back face (z -1, facing +z) and then a front face (z +1, facing -z).
        sleeve = mesh(square(-1, up=True), square(1, up=False))
        through, front, hit = ray_counts(*sleeve, DOWN)
        self.assertEqual((sum(through), sum(front)), (0, 0))  # the per-triangle vote is unchanged: no vote
        self.assertGreater(hit, 0)
        self.assertEqual((through, front), votes(*sleeve, DOWN))
        # The same rays, front face first: every one of them is a front vote, so hit counts exactly those rays.
        solid = mesh(square(-1, up=False), square(1, up=True))
        self.assertEqual(sum(ray_counts(*solid, DOWN)[1]), hit)

    def test_share_denominator_includes_back_first_front_behind_rays(self):
        # Left half: a lone back face (a hole). Right half: back face first, front face behind (not a hole).
        verts, tris = mesh(square(-1, up=True, x0=-1, x1=0), square(-1, up=True, x0=0, x1=1),
                           square(1, up=False, x0=0, x1=1))
        through, front, hit = ray_counts(verts, tris, DOWN)
        holes = sum(through)
        self.assertGreater(holes, 0)
        self.assertEqual(sum(front), 0)
        # holes / (holes + front) would incorrectly report 100% silhouette loss; really about half is lost.
        self.assertGreater(hit, holes)
        self.assertAlmostEqual(holes / hit, 0.5, delta=0.1)

    def test_inward_returns_all_hit_rays_as_the_denominator(self):
        verts, tris = mesh(square(-1, up=True), square(1, up=False))
        bad, holes, hit = inward(verts, tris)
        self.assertEqual(hit, ray_counts(verts, tris)[2])
        self.assertGreaterEqual(hit, holes + sum(votes(verts, tris)[1]))


if __name__ == "__main__":
    unittest.main()
