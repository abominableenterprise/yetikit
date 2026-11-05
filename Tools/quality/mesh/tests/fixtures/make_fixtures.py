"""Generate tiny deterministic synthetic glTF 2 binary meshes; no art inputs."""
import json
from pathlib import Path
import struct

VERTS = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
         (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
TRIS = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
        (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
        (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]


def glb(verts, tris):
    positions = b"".join(struct.pack("<3f", *v) for v in verts)
    indices = b"".join(struct.pack("<3H", *t) for t in tris)
    binary = positions + indices
    doc = {"asset": {"version": "2.0"}, "scene": 0,
           "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
           "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
           "buffers": [{"byteLength": len(binary)}],
           "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(positions)},
                           {"buffer": 0, "byteOffset": len(positions), "byteLength": len(indices)}],
           "accessors": [{"bufferView": 0, "componentType": 5126, "count": len(verts),
                          "type": "VEC3", "min": [-1, -1, -1], "max": [1, 1, 1]},
                         {"bufferView": 1, "componentType": 5123, "count": len(tris) * 3,
                          "type": "SCALAR"}]}
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    binary += b"\0" * (-len(binary) % 4)
    return (struct.pack("<4sII", b"glTF", 2, 28 + len(text) + len(binary))
            + struct.pack("<II", len(text), 0x4E4F534A) + text
            + struct.pack("<II", len(binary), 0x004E4942) + binary)


def make(directory):
    cases = {"closed_cube": TRIS, "missing_face": TRIS[2:],
             "flipped_faces": [tuple(reversed(t)) if i < 4 else t for i, t in enumerate(TRIS)],
             "open_tube": TRIS[4:], "inside_out": [tuple(reversed(t)) for t in TRIS]}
    for name, tris in cases.items():
        (Path(directory) / (name + ".glb")).write_bytes(glb(VERTS, tris))


if __name__ == "__main__":
    make(Path(__file__).parent)
