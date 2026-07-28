"""Validate a locally downloaded Mixamo FBX with Blender's importer."""

import json
import sys
from pathlib import Path

import bpy


def _asset_path() -> Path:
    try:
        separator = sys.argv.index("--")
        return Path(sys.argv[separator + 1]).expanduser().resolve()
    except (ValueError, IndexError) as error:
        raise SystemExit("usage: blender --background --python validate_mixamo_asset.py -- asset.fbx") from error


def main() -> None:
    asset_path = _asset_path()
    if not asset_path.is_file():
        raise SystemExit(f"asset does not exist: {asset_path}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(filepath=str(asset_path), use_anim=True)
    if "FINISHED" not in result:
        raise SystemExit(f"Blender could not import {asset_path}")

    meshes = [item for item in bpy.data.objects if item.type == "MESH"]
    armatures = [item for item in bpy.data.objects if item.type == "ARMATURE"]
    actions = list(bpy.data.actions)
    triangles = sum(
        len(loop_triangles)
        for mesh in meshes
        for loop_triangles in [mesh.data.loop_triangles]
    )
    if meshes:
        for mesh in meshes:
            mesh.data.calc_loop_triangles()
        triangles = sum(len(mesh.data.loop_triangles) for mesh in meshes)

    summary = {
        "asset": str(asset_path),
        "meshes": len(meshes),
        "armatures": len(armatures),
        "actions": len(actions),
        "triangles": triangles,
    }
    print(f"ECHO_ASSET_VALIDATION={json.dumps(summary, sort_keys=True)}")

    if not meshes or not armatures or not actions:
        raise SystemExit("asset must contain at least one mesh, armature, and animation action")


if __name__ == "__main__":
    main()
