"""Small static glTF 2 reader: triangle primitives, embedded or local buffers.

Audit every mesh in mesh-local space, including unused meshes. Animation, skin
poses and morph deformation are not evaluated. Unsupported encodings fail closed.
"""
import base64
import json
from pathlib import Path
import struct
from urllib.parse import unquote, urlsplit

import numpy as np


def load_meshes(path):
    path = Path(path)
    blob = path.read_bytes()
    binary = None
    if path.suffix.lower() == ".glb":
        magic, version, size = struct.unpack_from("<4sII", blob)
        if magic != b"glTF" or version != 2 or size != len(blob):
            raise ValueError("invalid GLB header")
        chunks, offset = {}, 12
        while offset < size:
            length, kind = struct.unpack_from("<II", blob, offset)
            offset += 8
            if offset + length > size or length % 4:
                raise ValueError("invalid GLB chunk")
            chunks[kind] = blob[offset:offset + length]
            offset += length
        doc = json.loads(chunks[0x4E4F534A])
        binary = chunks.get(0x004E4942)
    else:
        doc = json.loads(blob)
    if not isinstance(doc, dict) or not isinstance(doc.get("asset"), dict):
        raise ValueError("invalid glTF document")
    if doc.get("asset", {}).get("version") != "2.0":
        raise ValueError("requires glTF 2.0")
    if doc.get("extensionsRequired"):
        raise ValueError("required glTF extensions are not supported")
    buffers = []
    for spec in doc.get("buffers", []):
        uri = spec.get("uri")
        if uri is None:
            data = binary
        elif uri.startswith("data:") and ";base64," in uri:
            data = base64.b64decode(uri.split(",", 1)[1], validate=True)
        else:
            parts = urlsplit(uri)
            if parts.scheme or parts.netloc or parts.query or parts.fragment:
                raise ValueError("buffer must be a local relative URI")
            target = (path.parent / unquote(parts.path)).resolve()
            if not target.is_relative_to(path.parent.resolve()):
                raise ValueError("buffer URI escapes asset directory")
            data = target.read_bytes()
        if data is None or len(data) < spec["byteLength"]:
            raise ValueError("missing or truncated buffer")
        buffers.append(data[:spec["byteLength"]])

    def reference(items, index):
        if type(index) is not int or not 0 <= index < len(items):
            raise ValueError("invalid glTF reference")
        return items[index]

    def accessor(index, position=False):
        a = reference(doc["accessors"], index)
        if "sparse" in a or a.get("normalized"):
            raise ValueError("sparse/normalized accessors are not supported")
        expected = (5126,) if position else (5121, 5123, 5125)
        if a["componentType"] not in expected or a["type"] != ("VEC3" if position else "SCALAR"):
            raise ValueError("invalid position/index accessor")
        dtype = np.dtype({5126: "<f4", 5121: "u1", 5123: "<u2", 5125: "<u4"}[a["componentType"]])
        view = reference(doc["bufferViews"], a["bufferView"])
        width = 3 if position else 1
        stride = view.get("byteStride", dtype.itemsize * width)
        start = view.get("byteOffset", 0)
        offset = a.get("byteOffset", 0)
        count = a["count"]
        end = offset + (count - 1) * stride + dtype.itemsize * width
        data = reference(buffers, view["buffer"])
        if (count <= 0 or start < 0 or offset < 0 or stride < dtype.itemsize * width
                or end > view["byteLength"] or start + view["byteLength"] > len(data)):
            raise ValueError("accessor outside buffer view")
        return np.ndarray((count, width), dtype=dtype, buffer=data,
                          offset=start + offset, strides=(stride, dtype.itemsize)).copy()

    meshes = []
    for index, mesh in enumerate(doc.get("meshes", [])):
        verts, tris = [], []
        for primitive in mesh["primitives"]:
            if primitive.get("mode", 4) != 4 or primitive.get("extensions"):
                raise ValueError("only uncompressed TRIANGLES primitives are supported")
            positions = accessor(primitive["attributes"]["POSITION"], True)
            indices = accessor(primitive["indices"]).ravel() if "indices" in primitive else np.arange(len(positions))
            if len(indices) % 3 or not len(indices) or np.max(indices) >= len(positions):
                raise ValueError("invalid triangle indices")
            # Primitive offsets can exceed the accessor's unsigned index range.
            tris.extend((indices.astype(np.int64).reshape(-1, 3) + len(verts)).tolist())
            verts.extend(positions.tolist())
        meshes.append((mesh.get("name", str(index)), verts, tris))
    if not meshes:
        raise ValueError("no meshes")
    return meshes
