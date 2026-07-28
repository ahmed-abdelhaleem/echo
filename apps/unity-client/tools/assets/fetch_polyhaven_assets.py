#!/usr/bin/env python3
"""Fetch the vetted 1K Poly Haven FBX set used by the Bedroom vertical slice."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import urllib.request


USER_AGENT = "EchoGameAssetFetcher/1.0 (github.com/ahmed-abdelhaleem/echo)"
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parents[1]
CONFIG_PATH = SCRIPT_DIR / "polyhaven_bedroom_assets.json"
OUTPUT_ROOT = PROJECT_ROOT / "Assets" / "Resources" / "Art" / "PolyHaven"


def read_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download(url: str, destination: pathlib.Path, expected_md5: str) -> None:
    if destination.exists():
        digest = hashlib.md5(destination.read_bytes(), usedforsecurity=False).hexdigest()
        if digest == expected_md5:
            print(f"ready  {destination.relative_to(PROJECT_ROOT)}")
            return

    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = response.read()

    digest = hashlib.md5(payload, usedforsecurity=False).hexdigest()
    if digest != expected_md5:
        raise RuntimeError(
            f"checksum mismatch for {destination.name}: {digest} != {expected_md5}"
        )
    destination.write_bytes(payload)
    print(f"fetched {destination.relative_to(PROJECT_ROOT)} ({len(payload):,} bytes)")


def fetch_asset(asset_id: str, resolution: str) -> None:
    file_index = read_json(f"https://api.polyhaven.com/files/{asset_id}")
    package = file_index["fbx"][resolution]["fbx"]
    asset_root = OUTPUT_ROOT / asset_id
    download(
        package["url"],
        asset_root / f"{asset_id}_{resolution}.fbx",
        package["md5"],
    )
    for relative_path, file_info in package.get("include", {}).items():
        download(
            file_info["url"],
            asset_root / relative_path,
            file_info["md5"],
        )


def main() -> int:
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if config["license"] != "CC0-1.0":
        raise RuntimeError("asset download blocked: expected a CC0-only manifest")
    for asset_id in config["assets"]:
        fetch_asset(asset_id, config["resolution"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
