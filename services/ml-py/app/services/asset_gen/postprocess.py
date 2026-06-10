"""GLB post-processing and the proposed automated QA gate for T-ML-051.

The gate in this module is intentionally limited to objective checks: valid
GLB structure, embedded assets, size/poly budgets, LOD presence, and thumbnail
integrity. Visual safety and brand policy still require human review before
this change can merge, per AGENTS.md.
"""

from __future__ import annotations

import io
import json
import struct
import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from PIL import Image, ImageDraw

from app.services.asset_gen.models import AssetSpec

GLB_JSON_CHUNK = 0x4E4F534A


class AssetPostProcessingError(RuntimeError):
    pass


@dataclass(frozen=True, slots=True)
class GlbInspection:
    polycount: int
    vertex_count: int
    external_uris: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ProcessedAsset:
    glb_bytes: bytes
    thumbnail_png: bytes
    lod_glbs: tuple[bytes, ...]
    polycount: int
    size_bytes: int
    processor_version: str


class AssetPostProcessor(Protocol):
    def process(
        self,
        source_glb: bytes,
        spec: AssetSpec,
        *,
        max_size_bytes: int,
    ) -> ProcessedAsset: ...


@dataclass(frozen=True, slots=True)
class GateResult:
    passed: bool
    reasons: tuple[str, ...] = ()


class AssetQualityGate(Protocol):
    def evaluate(
        self,
        asset: ProcessedAsset,
        spec: AssetSpec,
        *,
        max_size_bytes: int,
    ) -> GateResult: ...


class AutomatedAssetQualityGate:
    """Objective pre-publication checks; visual brand review remains human."""

    def __init__(self, *, required_lod_count: int = 2) -> None:
        self._required_lod_count = required_lod_count

    def evaluate(
        self,
        asset: ProcessedAsset,
        spec: AssetSpec,
        *,
        max_size_bytes: int,
    ) -> GateResult:
        reasons: list[str] = []
        try:
            inspection = inspect_glb(asset.glb_bytes)
        except AssetPostProcessingError as exc:
            return GateResult(False, (str(exc),))

        if asset.size_bytes != len(asset.glb_bytes):
            reasons.append("reported size does not match GLB bytes")
        if asset.size_bytes > max_size_bytes:
            reasons.append("GLB exceeds configured size budget")
        target_polycount = _target_polycount(spec)
        if target_polycount is not None and inspection.polycount > target_polycount:
            reasons.append("GLB exceeds target_polycount")
        if inspection.external_uris:
            reasons.append("GLB contains external resource URIs")
        if not asset.thumbnail_png.startswith(b"\x89PNG\r\n\x1a\n"):
            reasons.append("thumbnail is not a PNG")
        if len(asset.lod_glbs) < self._required_lod_count:
            reasons.append("required LOD variants are missing")
        previous_polycount = inspection.polycount
        for lod in asset.lod_glbs:
            try:
                lod_inspection = inspect_glb(lod)
            except AssetPostProcessingError:
                reasons.append("LOD variant is not a valid GLB")
                break
            if lod_inspection.external_uris:
                reasons.append("LOD variant contains external resource URIs")
                break
            if previous_polycount > 0 and lod_inspection.polycount >= previous_polycount:
                reasons.append("LOD variants must reduce polygon count")
                break
            previous_polycount = lod_inspection.polycount
        return GateResult(not reasons, tuple(reasons))


class GltfpackPostProcessor:
    """Optimize, meshopt-compress, simplify, and create two LOD GLBs."""

    def __init__(
        self,
        *,
        binary: str = "gltfpack",
        runner: Callable[[list[str]], None] | None = None,
    ) -> None:
        self._binary = binary
        self._runner = runner or _run_command

    def process(
        self,
        source_glb: bytes,
        spec: AssetSpec,
        *,
        max_size_bytes: int,
    ) -> ProcessedAsset:
        source_inspection = inspect_glb(source_glb)
        target = _target_polycount(spec)
        primary_ratio = _simplification_ratio(source_inspection.polycount, target)

        with tempfile.TemporaryDirectory(prefix="echo-asset-") as directory:
            root = Path(directory)
            source = root / "source.glb"
            primary = root / "asset.glb"
            source.write_bytes(source_glb)

            primary_command = [
                self._binary,
                "-i",
                str(source),
                "-o",
                str(primary),
                "-cc",
                "-kn",
                "-km",
            ]
            if primary_ratio < 1.0:
                primary_command.extend(["-si", f"{primary_ratio:.6f}"])
            self._runner(primary_command)

            lod_paths = (root / "lod-1.glb", root / "lod-2.glb")
            for path, ratio in zip(lod_paths, (0.5, 0.2), strict=True):
                self._runner(
                    [
                        self._binary,
                        "-i",
                        str(primary),
                        "-o",
                        str(path),
                        "-cc",
                        "-kn",
                        "-km",
                        "-si",
                        str(ratio),
                    ]
                )

            optimized = _required_output(primary)
            lods = tuple(_required_output(path) for path in lod_paths)

        inspection = inspect_glb(optimized)
        if len(optimized) > max_size_bytes:
            raise AssetPostProcessingError(
                f"optimized GLB is {len(optimized)} bytes; budget is {max_size_bytes}"
            )
        return ProcessedAsset(
            glb_bytes=optimized,
            thumbnail_png=_metadata_thumbnail(spec, inspection),
            lod_glbs=lods,
            polycount=inspection.polycount,
            size_bytes=len(optimized),
            processor_version="gltfpack-v1",
        )


def inspect_glb(data: bytes) -> GlbInspection:
    if len(data) < 20 or data[:4] != b"glTF":
        raise AssetPostProcessingError("payload is not a GLB")
    version, declared_length = struct.unpack_from("<II", data, 4)
    if version != 2:
        raise AssetPostProcessingError("GLB version must be 2")
    if declared_length != len(data):
        raise AssetPostProcessingError("GLB declared length does not match payload")

    offset = 12
    document: dict[str, Any] | None = None
    while offset + 8 <= len(data):
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk_end = offset + chunk_length
        if chunk_end > len(data):
            raise AssetPostProcessingError("GLB chunk exceeds payload")
        if chunk_type == GLB_JSON_CHUNK:
            raw_json = data[offset:chunk_end].rstrip(b" \t\r\n\x00")
            parsed = json.loads(raw_json)
            if not isinstance(parsed, dict):
                raise AssetPostProcessingError("GLB JSON chunk must be an object")
            document = parsed
        offset = chunk_end
    if offset != len(data) or document is None:
        raise AssetPostProcessingError("GLB is missing a valid JSON chunk")

    accessors = document.get("accessors", [])
    if not isinstance(accessors, list):
        raise AssetPostProcessingError("GLB accessors must be an array")
    meshes = document.get("meshes", [])
    if not isinstance(meshes, list):
        raise AssetPostProcessingError("GLB meshes must be an array")

    polycount = 0
    vertex_count = 0
    for mesh in meshes:
        if not isinstance(mesh, dict):
            continue
        primitives = mesh.get("primitives", [])
        if not isinstance(primitives, list):
            continue
        for primitive in primitives:
            if not isinstance(primitive, dict) or primitive.get("mode", 4) != 4:
                continue
            attributes = primitive.get("attributes", {})
            if isinstance(attributes, dict) and "POSITION" in attributes:
                vertex_count += _accessor_count(accessors, attributes["POSITION"])
            if "indices" in primitive:
                polycount += _accessor_count(accessors, primitive["indices"]) // 3
            elif isinstance(attributes, dict) and "POSITION" in attributes:
                polycount += _accessor_count(accessors, attributes["POSITION"]) // 3

    external_uris: list[str] = []
    for collection_name in ("buffers", "images"):
        collection = document.get(collection_name, [])
        if not isinstance(collection, list):
            continue
        for entry in collection:
            if not isinstance(entry, dict):
                continue
            uri = entry.get("uri")
            if isinstance(uri, str) and not uri.startswith("data:"):
                external_uris.append(uri)
    return GlbInspection(polycount, vertex_count, tuple(external_uris))


def _accessor_count(accessors: list[object], index: object) -> int:
    if not isinstance(index, int) or isinstance(index, bool):
        raise AssetPostProcessingError("GLB accessor index must be an integer")
    try:
        accessor = accessors[index]
    except IndexError as exc:
        raise AssetPostProcessingError("GLB accessor index is out of range") from exc
    if not isinstance(accessor, dict) or not isinstance(accessor.get("count"), int):
        raise AssetPostProcessingError("GLB accessor count is invalid")
    return int(accessor["count"])


def _target_polycount(spec: AssetSpec) -> int | None:
    value = spec.inputs.params.get("target_polycount")
    if value is None:
        return None
    if not isinstance(value, int) or isinstance(value, bool) or value < 100:
        raise AssetPostProcessingError("target_polycount must be an integer >= 100")
    return value


def _simplification_ratio(polycount: int, target: int | None) -> float:
    if target is None or polycount <= 0 or polycount <= target:
        return 1.0
    return max(0.01, target / polycount)


def _run_command(command: list[str]) -> None:
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise AssetPostProcessingError(
            f"{command[0]} is required for asset post-processing"
        ) from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or exc.stdout.strip() or "unknown error"
        raise AssetPostProcessingError(f"gltfpack failed: {detail}") from exc


def _required_output(path: Path) -> bytes:
    if not path.is_file():
        raise AssetPostProcessingError(f"postprocessor did not create {path.name}")
    return path.read_bytes()


def _metadata_thumbnail(spec: AssetSpec, inspection: GlbInspection) -> bytes:
    image = Image.new("RGB", (512, 512), color=(30, 34, 42))
    draw = ImageDraw.Draw(image)
    draw.rectangle((32, 32, 480, 480), outline=(116, 132, 153), width=3)
    draw.text((56, 64), spec.name or spec.asset_id, fill=(238, 240, 244))
    draw.text((56, 104), f"{inspection.polycount:,} triangles", fill=(174, 184, 198))
    draw.text((56, 136), "Automated pipeline thumbnail", fill=(174, 184, 198))
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()
