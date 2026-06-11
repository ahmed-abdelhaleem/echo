#!/usr/bin/env python3
"""Generate a distinct dev GLB per asset declared in a season manifest.

Local dev has no GPU and no paid 3D provider, and the Apple TRELLIS server is
image-to-3d only — so the real asset-gen worker can't produce season-001's
text-to-3d meshes. This tool stands in for that worker on the *serving* side:
it reads each season's `content/assets-3d/<season>/assets.manifest.json` (the
authored desired state, already stamped with a `content_address`) and writes a
deterministic, visually distinct, **uncompressed** GLB for every asset at the
exact content-addressed path the client fetches:

    <out>/assets/sha256/<digest>/asset.glb

Run it, then serve `<out>` with `make dev-asset-cdn` and point the client at it
(`make client-3d` / `make dev-3d`). Each vignette then shows its own model.

Why not the real worker here? The production post-processor meshopt-compresses
GLBs (`gltfpack -cc`), which `<model-viewer>` can only decode with a
network-loaded decoder — unavailable offline. These GLBs are uncompressed so
they render with no network. The production path (worker + a real provider such
as Meshy/TRELLIS-GPU) is unchanged; this only fills the local-dev gap.

The meshes are intentionally simple (a colored box per environment, a colored
sphere per prop/character/ambient, hue seeded by the asset id) — enough to tell
vignettes apart, not to look final.
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import math
import struct
from pathlib import Path

_GLB_MAGIC = 0x46546C67  # "glTF"
_GLB_VERSION = 2
_JSON_CHUNK = 0x4E4F534A  # "JSON"
_BIN_CHUNK = 0x004E4942  # "BIN\0"
_REPO_ROOT = Path(__file__).resolve().parents[3]


def _color_for(asset_id: str) -> tuple[float, float, float]:
    seed = int(hashlib.sha256(asset_id.encode("utf-8")).hexdigest()[:8], 16)
    hue = (seed % 360) / 360.0
    return colorsys.hsv_to_rgb(hue, 0.55, 0.85)


def _sphere(
    radius: float,
    rings: int,
    sectors: int,
    scale: tuple[float, float, float],
) -> tuple[list[float], list[float], list[int]]:
    positions: list[float] = []
    normals: list[float] = []
    indices: list[int] = []
    for i in range(rings + 1):
        phi = (i / rings) * math.pi
        for j in range(sectors + 1):
            theta = (j / sectors) * 2.0 * math.pi
            nx = math.sin(phi) * math.cos(theta)
            ny = math.cos(phi)
            nz = math.sin(phi) * math.sin(theta)
            positions += [
                nx * radius * scale[0],
                ny * radius * scale[1],
                nz * radius * scale[2],
            ]
            normals += [nx, ny, nz]
    row = sectors + 1
    for i in range(rings):
        for j in range(sectors):
            a = i * row + j
            b = a + row
            indices += [a, b, a + 1, a + 1, b, b + 1]
    return positions, normals, indices


def _box(sx: float, sy: float, sz: float) -> tuple[list[float], list[float], list[int]]:
    hx, hy, hz = sx / 2, sy / 2, sz / 2
    # (corner, normal) per face — 4 verts/face so each face has a flat normal.
    faces = [
        ([(-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)], (0, 0, 1)),
        ([(hx, -hy, -hz), (-hx, -hy, -hz), (-hx, hy, -hz), (hx, hy, -hz)], (0, 0, -1)),
        ([(hx, -hy, hz), (hx, -hy, -hz), (hx, hy, -hz), (hx, hy, hz)], (1, 0, 0)),
        ([(-hx, -hy, -hz), (-hx, -hy, hz), (-hx, hy, hz), (-hx, hy, -hz)], (-1, 0, 0)),
        ([(-hx, hy, hz), (hx, hy, hz), (hx, hy, -hz), (-hx, hy, -hz)], (0, 1, 0)),
        ([(-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz), (-hx, -hy, hz)], (0, -1, 0)),
    ]
    positions: list[float] = []
    normals: list[float] = []
    indices: list[int] = []
    for corners, normal in faces:
        base = len(positions) // 3
        for corner in corners:
            positions += list(corner)
            normals += list(normal)
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    return positions, normals, indices


def _cylinder(
    radius_bottom: float,
    radius_top: float,
    height: float,
    sectors: int,
) -> tuple[list[float], list[float], list[int]]:
    """A cylinder/cone/frustum with caps. radius_top == 0 yields a cone."""
    positions: list[float] = []
    normals: list[float] = []
    indices: list[int] = []
    hy = height / 2
    slope = (radius_bottom - radius_top) / height
    # Side wall.
    for j in range(sectors + 1):
        theta = (j / sectors) * 2.0 * math.pi
        cx, cz = math.cos(theta), math.sin(theta)
        length = math.sqrt(cx * cx + slope * slope + cz * cz)
        nx, ny, nz = cx / length, slope / length, cz / length
        positions += [radius_bottom * cx, -hy, radius_bottom * cz]
        normals += [nx, ny, nz]
        positions += [radius_top * cx, hy, radius_top * cz]
        normals += [nx, ny, nz]
    for j in range(sectors):
        b0 = j * 2
        indices += [b0, b0 + 2, b0 + 1, b0 + 1, b0 + 2, b0 + 3]
    # End caps.
    for radius, y, ny, flip in ((radius_bottom, -hy, -1.0, True), (radius_top, hy, 1.0, False)):
        if radius <= 1e-6:
            continue
        center = len(positions) // 3
        positions += [0.0, y, 0.0]
        normals += [0.0, ny, 0.0]
        ring = len(positions) // 3
        for j in range(sectors + 1):
            theta = (j / sectors) * 2.0 * math.pi
            positions += [radius * math.cos(theta), y, radius * math.sin(theta)]
            normals += [0.0, ny, 0.0]
        for j in range(sectors):
            if flip:
                indices += [center, ring + j + 1, ring + j]
            else:
                indices += [center, ring + j, ring + j + 1]
    return positions, normals, indices


def _torus(
    major: float,
    minor: float,
    ring_segments: int,
    tube_segments: int,
) -> tuple[list[float], list[float], list[int]]:
    positions: list[float] = []
    normals: list[float] = []
    indices: list[int] = []
    for i in range(ring_segments + 1):
        u = (i / ring_segments) * 2.0 * math.pi
        cu, su = math.cos(u), math.sin(u)
        for j in range(tube_segments + 1):
            v = (j / tube_segments) * 2.0 * math.pi
            cv, sv = math.cos(v), math.sin(v)
            positions += [(major + minor * cv) * cu, minor * sv, (major + minor * cv) * su]
            normals += [cv * cu, sv, cv * su]
    stride = tube_segments + 1
    for i in range(ring_segments):
        for j in range(tube_segments):
            a = i * stride + j
            b = a + stride
            indices += [a, b, a + 1, a + 1, b, b + 1]
    return positions, normals, indices


# A small library of distinct primitives. The asset id selects one
# deterministically so every asset reads as a *different* generated model
# (not the same cube), independent of its kind.
_SHAPES: tuple[str, ...] = ("sphere", "box", "cylinder", "cone", "torus")


def _geometry_for(
    kind: str,
    asset_id: str,
) -> tuple[list[float], list[float], list[int]]:
    seed = int(hashlib.sha256(f"shape:{asset_id}".encode("utf-8")).hexdigest()[:8], 16)
    shape = _SHAPES[seed % len(_SHAPES)]
    if shape == "box":
        return _box(1.5, 1.2, 1.5)
    if shape == "cylinder":
        return _cylinder(1.0, 1.0, 1.8, 40)
    if shape == "cone":
        return _cylinder(1.1, 0.0, 1.9, 40)
    if shape == "torus":
        return _torus(0.85, 0.38, 36, 22)
    return _sphere(radius=1.1, rings=24, sectors=40, scale=(1.0, 1.0, 1.0))



def build_asset_glb(asset_id: str, kind: str) -> bytes:
    positions, normals, indices = _geometry_for(kind, asset_id)
    color = _color_for(asset_id)

    idx_bytes = struct.pack(f"<{len(indices)}I", *indices)
    while len(idx_bytes) % 4:
        idx_bytes += b"\x00"
    pos_bytes = struct.pack(f"<{len(positions)}f", *positions)
    nrm_bytes = struct.pack(f"<{len(normals)}f", *normals)
    blob = idx_bytes + pos_bytes + nrm_bytes

    pos_off = len(idx_bytes)
    nrm_off = pos_off + len(pos_bytes)
    xs, ys, zs = positions[0::3], positions[1::3], positions[2::3]
    vtx = len(positions) // 3

    document = {
        "asset": {"version": "2.0", "generator": "echo dev asset generator"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0}],
        "meshes": [
            {
                "primitives": [
                    {
                        "attributes": {"POSITION": 1, "NORMAL": 2},
                        "indices": 0,
                        "material": 0,
                    }
                ]
            }
        ],
        "materials": [
            {
                "pbrMetallicRoughness": {
                    "baseColorFactor": [color[0], color[1], color[2], 1.0],
                    "metallicFactor": 0.05,
                    "roughnessFactor": 0.85,
                },
                "doubleSided": True,
            }
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5125, "count": len(indices), "type": "SCALAR"},
            {
                "bufferView": 1,
                "componentType": 5126,
                "count": vtx,
                "type": "VEC3",
                "min": [min(xs), min(ys), min(zs)],
                "max": [max(xs), max(ys), max(zs)],
            },
            {"bufferView": 2, "componentType": 5126, "count": vtx, "type": "VEC3"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(idx_bytes), "target": 34963},
            {"buffer": 0, "byteOffset": pos_off, "byteLength": len(pos_bytes), "target": 34962},
            {"buffer": 0, "byteOffset": nrm_off, "byteLength": len(nrm_bytes), "target": 34962},
        ],
        "buffers": [{"byteLength": len(blob)}],
    }
    json_bytes = json.dumps(document, separators=(",", ":"), sort_keys=True).encode("utf-8")
    while len(json_bytes) % 4:
        json_bytes += b" "

    total = 12 + 8 + len(json_bytes) + 8 + len(blob)
    header = struct.pack("<III", _GLB_MAGIC, _GLB_VERSION, total)
    json_header = struct.pack("<II", len(json_bytes), _JSON_CHUNK)
    bin_header = struct.pack("<II", len(blob), _BIN_CHUNK)
    glb = header + json_header + json_bytes + bin_header + blob
    assert glb[:4] == b"glTF" and len(glb) == total
    return glb


def _digest_of(content_address: str) -> str:
    algorithm, _, digest = content_address.partition(":")
    if algorithm != "sha256" or len(digest) != 64:
        raise ValueError(f"unexpected content_address {content_address!r}")
    return digest


def generate(manifest_dir: Path, out_root: Path, season: str | None) -> int:
    written = 0
    for manifest_path in sorted(manifest_dir.rglob("*.manifest.json")):
        doc = json.loads(manifest_path.read_text(encoding="utf-8"))
        if season and doc.get("season_id") != season:
            continue
        for asset in doc.get("assets", []):
            digest = _digest_of(str(asset["content_address"]))
            glb = build_asset_glb(str(asset["id"]), str(asset.get("kind", "prop")))
            dest = out_root / "assets" / "sha256" / digest / "asset.glb"
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(glb)
            written += 1
            print(
                f"  {asset['id']:<28} {asset.get('kind', 'prop'):<12} "
                f"{len(glb):>6} B -> {dest.relative_to(out_root)}",
                flush=True,
            )
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest-dir",
        default=str(_REPO_ROOT / "content" / "assets-3d"),
        help="directory tree containing *.manifest.json",
    )
    parser.add_argument(
        "--out",
        default=str(_REPO_ROOT / ".echo-cdn"),
        help="CDN serve root (matches `make dev-asset-cdn` ASSET_CDN_ROOT)",
    )
    parser.add_argument("--season", default=None, help="only this season_id")
    args = parser.parse_args()

    manifest_dir = Path(args.manifest_dir).expanduser().resolve()
    out_root = Path(args.out).expanduser().resolve()
    print(f"generating dev GLBs from {manifest_dir} -> {out_root}", flush=True)
    count = generate(manifest_dir, out_root, args.season)
    if count == 0:
        raise SystemExit("no assets found; check --manifest-dir / --season")
    print(f"done: {count} asset GLB(s) written under {out_root}", flush=True)


if __name__ == "__main__":
    main()

