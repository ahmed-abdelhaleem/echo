"""Print bounds and triangle counts for the downloaded Bedroom FBX set."""

from __future__ import annotations

import json
import pathlib

import bpy


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
ASSET_ROOT = PROJECT_ROOT / "Assets" / "Resources" / "Art" / "PolyHaven"
MANIFEST_PATH = PROJECT_ROOT / "tools" / "assets" / "polyhaven_bedroom_assets.json"
SCALE_PROFILE_PATH = (
    PROJECT_ROOT
    / "Assets"
    / "Resources"
    / "Config"
    / "real_world_scale_profiles.json"
)


def inspect_asset(asset_id: str) -> dict:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    fbx_path = ASSET_ROOT / asset_id / f"{asset_id}_1k.fbx"
    bpy.ops.import_scene.fbx(filepath=str(fbx_path))
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    corners = [
        obj.matrix_world @ mathutils.Vector(corner)
        for obj in meshes
        for corner in obj.bound_box
    ]
    minimum = [min(corner[index] for corner in corners) for index in range(3)]
    maximum = [max(corner[index] for corner in corners) for index in range(3)]
    dimensions = [maximum[index] - minimum[index] for index in range(3)]
    triangles = sum(
        len(polygon.vertices) - 2
        for obj in meshes
        for polygon in obj.data.polygons
    )
    return {
        "asset": asset_id,
        "dimensionsMeters": [round(value, 4) for value in dimensions],
        "meshes": len(meshes),
        "triangles": triangles,
    }


import mathutils  # noqa: E402  (available only after Blender initializes)


manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
scale_catalog = json.loads(SCALE_PROFILE_PATH.read_text(encoding="utf-8"))
scale_profiles = {
    profile["assetId"]: profile for profile in scale_catalog["assets"]
}
for slug in manifest["assets"]:
    if slug not in scale_profiles:
        raise SystemExit(f"missing real-world scale profile for {slug}")
    profile = scale_profiles[slug]
    if profile["targetLongestMeters"] <= 0:
        raise SystemExit(f"invalid real-world target for {slug}")
    if profile["minimumHeightMeters"] >= profile["maximumHeightMeters"]:
        raise SystemExit(f"invalid height range for {slug}")
    summary = inspect_asset(slug)
    summary["category"] = profile["category"]
    summary["blocksPlayer"] = profile["blocksPlayer"]
    summary["targetLongestMeters"] = profile["targetLongestMeters"]
    summary["targetHeightRangeMeters"] = [
        profile["minimumHeightMeters"],
        profile["maximumHeightMeters"],
    ]
    print("ECHO_POLYHAVEN_ASSET=" + json.dumps(summary, sort_keys=True))

undeclared = sorted(set(scale_profiles) - set(manifest["assets"]))
if undeclared:
    raise SystemExit(
        "scale profiles reference assets outside the vetted manifest: "
        + ", ".join(undeclared)
    )
