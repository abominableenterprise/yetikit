# Run: python3 -m unittest discover -s Tools/quality/mesh/tests -p "test_*.py"
# winding.py runs inside Blender; only its pure flip loop (settle) is tested here, with bpy/bmesh/mathutils stubbed.
import os
import sys
import types
import unittest
from unittest.mock import patch

MESH_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_stubs = {name: types.ModuleType(name) for name in ("bpy", "bmesh", "mathutils", "mathutils.bvhtree")}
_stubs["mathutils"].Vector = object
_stubs["mathutils.bvhtree"].BVHTree = object

# Restore both the import path and module cache, including modules imported with these stubs.
with patch.object(sys, "path", [MESH_DIR, *sys.path]), patch.dict(sys.modules, _stubs):
    from winding import settle


class SettleTest(unittest.TestCase):
    def run_rounds(self, answers):
        """settle() over bad_faces answering from `answers` (one set per vote), recording votes and reversals."""
        calls, reversed_ = [], []

        def bad_faces(rnd):
            calls.append(rnd)
            return set(answers[len(calls) - 1])

        flipped, left = settle(bad_faces, reversed_.append)
        return flipped, left, calls, reversed_

    def test_converges_with_left_zero(self):
        flipped, left, calls, reversed_ = self.run_rounds([{1, 2}, {3}, set()])
        self.assertEqual((flipped, left), ({1, 2, 3}, 0))
        self.assertEqual(calls, [0, 1, 2])
        self.assertEqual(reversed_, [{1, 2}, {3}])

    def test_a_face_turned_twice_is_not_flipped(self):
        flipped, left, _, _ = self.run_rounds([{1, 2}, {2}, set()])
        self.assertEqual((flipped, left), ({1}, 0))

    def test_unconverged_after_the_last_round_reports_the_faces_left(self):
        # Every round still flips faces. Re-check after the fourth reversal so an unconverged result reports
        # remaining faces instead of incorrectly passing a caller's `if left:` guard.
        flipped, left, calls, reversed_ = self.run_rounds([{1}, {2}, {3}, {4}, {5, 6}])
        self.assertEqual(left, 2)
        self.assertEqual(calls, [0, 1, 2, 3, 4])  # one more vote after the last reversal
        self.assertEqual(len(reversed_), 4)  # but no fifth reversal
        self.assertEqual(flipped, {1, 2, 3, 4})

    def test_converging_exactly_on_the_last_round_reports_zero(self):
        flipped, left, calls, _ = self.run_rounds([{1}, {2}, {3}, {4}, set()])
        self.assertEqual((flipped, left), ({1, 2, 3, 4}, 0))
        self.assertEqual(calls, [0, 1, 2, 3, 4])


if __name__ == "__main__":
    unittest.main()
