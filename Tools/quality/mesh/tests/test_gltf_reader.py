"""Reader regressions for multi-primitive index concatenation."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gltf_reader import load_meshes


class PrimitiveIndexTest(unittest.TestCase):
    def test_unsigned_indices_are_widened_before_offsets(self):
        for component, dtype in ((5121, "u1"), (5123, "<u2")):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as tmp:
                # Primitive two crosses the index range during addition; primitive
                # three starts beyond it. The accessor itself stays in range.
                count = int(np.iinfo(np.dtype(dtype)).max)
                positions = np.zeros((count, 3), dtype="<f4")
                positions[-3:] = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                indices = np.array([count - 3, count - 2, count - 1], dtype=dtype)
                binary = positions.tobytes() + indices.tobytes()
                primitive = {"attributes": {"POSITION": 0}, "indices": 1}
                doc = {
                    "asset": {"version": "2.0"},
                    "buffers": [{"byteLength": len(binary), "uri": "mesh.bin"}],
                    "bufferViews": [
                        {"buffer": 0, "byteLength": positions.nbytes},
                        {"buffer": 0, "byteOffset": positions.nbytes,
                         "byteLength": indices.nbytes},
                    ],
                    "accessors": [
                        {"bufferView": 0, "type": "VEC3", "componentType": 5126,
                         "count": count},
                        {"bufferView": 1, "type": "SCALAR", "componentType": component,
                         "count": 3},
                    ],
                    "meshes": [{"primitives": [primitive] * 3}],
                }
                path = Path(tmp) / "mesh.gltf"
                path.write_text(json.dumps(doc))
                path.with_suffix(".bin").write_bytes(binary)
                _, verts, tris = load_meshes(path)[0]
                self.assertEqual(len(verts), count * 3)
                self.assertEqual(tris, [[i + count * p for i in indices.tolist()]
                                        for p in range(3)])
                for tri in tris:
                    self.assertEqual([verts[i] for i in tri], positions[-3:].tolist())


if __name__ == "__main__":
    unittest.main()
