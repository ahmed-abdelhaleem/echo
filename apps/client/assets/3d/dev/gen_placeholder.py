#!/usr/bin/env python3
"""Generate the dev-only placeholder GLB shipped with the Flutter client.

T-CLIENT-040 fallback (see asset_file_store_io.dart). A real Echo
deployment streams generated GLBs from R2 via the asset CDN. In local
dev there is no CDN and no on-disk cache, so the 3D viewport would
otherwise render nothing. This script writes a deterministic, minimal
unit cube GLB into `placeholder.glb`; the file store's debug-only
bundle fallback hands those bytes to Thermion / model_viewer so the
wiring is visibly correct.

Reproducibility: run this script and the output is byte-identical.

GLB layout (https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification):

    +-- 12-byte header  (magic="glTF" + version + total length)
    +-- JSON chunk      (header + minified glTF document)
    +-- BIN chunk       (header + indices + positions)
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

_GLB_MAGIC = 0x46546C67  # "glTF"
_GLB_VERSION = 2
_JSON_CHUNK_TYPE = 0x4E4F534A  # "JSON"
_BIN_CHUNK_TYPE = 0x004E4942  # "BIN\0"


def _build_cube_bytes() -> bytes:
    # 8 unit-cube corners centered at the origin.
    positions: list[float] = [
        -1.0, -1.0, -1.0,
         1.0, -1.0, -1.0,
         1.0,  1.0, -1.0,
        -1.0,  1.0, -1.0,
        -1.0, -1.0,  1.0,
         1.0, -1.0,  1.0,
         1.0,  1.0,  1.0,
        -1.0,  1.0,  1.0,
    ]
    # 36 indices = 12 triangles = 6 cube faces.
    indices: list[int] = [
        0, 1, 2, 0, 2, 3,  # -Z
        4, 6, 5, 4, 7, 6,  # +Z
        0, 3, 7, 0, 7, 4,  # -X
        1, 5, 6, 1, 6, 2,  # +X
        3, 2, 6, 3, 6, 7,  # +Y
        0, 4, 5, 0, 5, 1,  # -Y
    ]
    idx_bytes = struct.pack(f"<{len(indices)}H", *indices)  # 72 bytes (uint16)
    pos_bytes = struct.pack(f"<{len(positions)}f", *positions)  # 96 bytes (float32)
    buf = idx_bytes + pos_bytes  # 168 bytes
    while len(buf) % 4 != 0:
        buf += b"\x00"
    return buf


def _gltf_document(buffer_length: int) -> bytes:
    doc = {
        "asset": {"version": "2.0", "generator": "echo dev placeholder"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 1}, "indices": 0}]}],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5123,  # uint16
                "count": 36,
                "type": "SCALAR",
            },
            {
                "bufferView": 1,
                "componentType": 5126,  # float
                "count": 8,
                "type": "VEC3",
                "max": [1.0, 1.0, 1.0],
                "min": [-1.0, -1.0, -1.0],
            },
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": 72, "target": 34963},
            {"buffer": 0, "byteOffset": 72, "byteLength": 96, "target": 34962},
        ],
        "buffers": [{"byteLength": buffer_length}],
    }
    out = json.dumps(doc, separators=(",", ":"), sort_keys=True).encode("utf-8")
    while len(out) % 4 != 0:
        out += b" "
    return out


def build_placeholder_glb() -> bytes:
    binary_chunk = _build_cube_bytes()
    json_chunk = _gltf_document(len(binary_chunk))
    total_length = 12 + 8 + len(json_chunk) + 8 + len(binary_chunk)
    header = struct.pack("<III", _GLB_MAGIC, _GLB_VERSION, total_length)
    json_header = struct.pack("<II", len(json_chunk), _JSON_CHUNK_TYPE)
    bin_header = struct.pack("<II", len(binary_chunk), _BIN_CHUNK_TYPE)
    return header + json_header + json_chunk + bin_header + binary_chunk


if __name__ == "__main__":
    glb = build_placeholder_glb()
    out_path = Path(__file__).resolve().parent / "placeholder.glb"
    out_path.write_bytes(glb)
    print(f"wrote {out_path} ({len(glb)} bytes)")
