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

from audit_paths import resolve

JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942
STATIC_PRIMITIVE_METADATA = {"KHR_materials_variants"}


def _local_buffer_path(parent, uri):
    parts = urlsplit(uri)
    if parts.scheme or parts.netloc or parts.query or parts.fragment:
        raise ValueError("buffer must be a local relative URI")
    path = unquote(parts.path)
    if "\0" in path:
        raise ValueError("buffer URI contains a null byte")
    return parent / path


def _protect_buffer_paths(doc, parent, inputs):
    specs = doc.get("buffers") if isinstance(doc, dict) else None
    if not isinstance(specs, list):
        return
    # Collect paths without reading buffers or depending on validation order.
    # A malformed entry must not hide local paths in subsequent entries.
    for spec in specs:
        uri = spec.get("uri") if isinstance(spec, dict) else None
        if isinstance(uri, str):
            try:
                inputs.add(_local_buffer_path(parent, uri))
            except ValueError:
                continue  # Nonlocal or invalid URI; the audit handles validation.


def load_meshes(path, *, inputs=None):
    path = Path(path)
    blob = path.read_bytes()
    binary = None
    if path.suffix.lower() == ".glb":
        magic, version, size = struct.unpack_from("<4sII", blob)
        if magic != b"glTF" or version != 2 or size != len(blob):
            raise ValueError("invalid GLB header")
        text, offset, chunk = None, 12, 0
        while offset < size:
            if size - offset < 8:
                raise ValueError("truncated GLB chunk header")
            length, kind = struct.unpack_from("<II", blob, offset)
            offset += 8
            if offset + length > size or length % 4:
                raise ValueError("invalid GLB chunk")
            if chunk == 0 and kind != JSON_CHUNK:
                raise ValueError("GLB JSON chunk must be first")
            if kind == JSON_CHUNK:
                if chunk != 0:
                    raise ValueError("duplicate GLB JSON chunk")
                text = blob[offset:offset + length]
            elif kind == BIN_CHUNK:
                if chunk != 1:
                    raise ValueError("GLB BIN chunk must occur at most once, immediately after JSON")
                binary = blob[offset:offset + length]
            # glTF requires clients to ignore unknown chunk types.
            offset += length
            chunk += 1
        if text is None:
            raise ValueError("missing GLB JSON chunk")
        doc = json.loads(text)
    else:
        doc = json.loads(blob)
    if inputs is not None:
        _protect_buffer_paths(doc, path.parent, inputs)
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
            target = resolve(_local_buffer_path(path.parent, uri))
            if not target.is_relative_to(resolve(path.parent)):
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
        if offset % dtype.itemsize or (start + offset) % dtype.itemsize:
            raise ValueError("misaligned accessor or buffer view offset")
        if "byteStride" in view and (not position or type(stride) is not int or not 4 <= stride <= 252 or stride % 4):
            raise ValueError("invalid vertex stride or stride on an index buffer view")
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
            extensions = primitive.get("extensions", {})
            if primitive.get("mode", 4) != 4:
                raise ValueError("only TRIANGLES primitives are supported")
            if not isinstance(extensions, dict) or extensions.keys() - STATIC_PRIMITIVE_METADATA:
                raise ValueError("unsupported glTF primitive extensions")
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
