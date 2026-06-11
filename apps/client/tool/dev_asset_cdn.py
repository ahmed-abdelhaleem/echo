#!/usr/bin/env python3
"""Dev-only CORS static server for content-addressed 3D assets.

The Flutter client builds GLB URLs as:

    {ECHO_ASSET_CDN_URL}/assets/sha256/{digest}/asset.glb

In production that origin is the Cloudflare R2 / asset CDN. In local dev there
is no CDN, so this tiny server stands in for it. It serves any request shaped
like ``/assets/sha256/<64-hex>/asset.glb`` by returning, in order:

    1. a real GLB you dropped at ``<--root>/assets/sha256/<digest>/asset.glb``
       (use this to preview an actual generated mesh), else
    2. the bundled dev placeholder cube
       (``apps/client/assets/3d/dev/placeholder.glb``).

Every response carries permissive CORS headers so a browser ``<model-viewer>``
(and the client's dio downloader) can fetch cross-origin from localhost.

Usage:
    python3 apps/client/tool/dev_asset_cdn.py            # :8099, placeholder
    python3 apps/client/tool/dev_asset_cdn.py --port 8099 --root /tmp/echo-cdn

Then launch the client pointing at it:
    cd apps/client && flutter run -d chrome --web-port=8082 \
        --dart-define=ECHO_ASSET_CDN_URL=http://localhost:8099

NB: on a *debug* web build the client also hydrates the placeholder from its
own bundle, so the viewport should render even without this server. This server
matters for release builds and for previewing real generated GLBs.
"""

from __future__ import annotations

import argparse
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

_ASSET_RE = re.compile(r"^/assets/sha256/(?P<digest>[0-9a-f]{64})/asset\.glb$")
_REPO_ROOT = Path(__file__).resolve().parents[3]
_PLACEHOLDER = _REPO_ROOT / "apps/client/assets/3d/dev/placeholder.glb"


def _serve_root() -> Path:
    return _HANDLER_ROOT


_HANDLER_ROOT = Path.cwd()


class AssetCdnHandler(BaseHTTPRequestHandler):
    def _cors(self) -> None:
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")

    def do_OPTIONS(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        self.send_response(HTTPStatus.NO_CONTENT)
        self._cors()
        self.end_headers()

    def do_HEAD(self) -> None:  # noqa: N802
        self._respond(write_body=False)

    def do_GET(self) -> None:  # noqa: N802
        self._respond(write_body=True)

    def _respond(self, *, write_body: bool) -> None:
        if self.path == "/healthz":
            body = b'{"status":"ok"}'
            self.send_response(HTTPStatus.OK)
            self._cors()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if write_body:
                self.wfile.write(body)
            return

        match = _ASSET_RE.match(self.path)
        if match is None:
            self.send_response(HTTPStatus.NOT_FOUND)
            self._cors()
            self.end_headers()
            return

        digest = match.group("digest")
        candidate = _serve_root() / "assets" / "sha256" / digest / "asset.glb"
        override = _serve_root() / "override.glb"
        if candidate.is_file():
            glb_path, served = candidate, "real"
        elif override.is_file():
            # Drop any .glb at <root>/override.glb to preview it for *every*
            # asset without computing content-address digests.
            glb_path, served = override, "override"
        else:
            glb_path, served = _PLACEHOLDER, "placeholder"
        if not glb_path.is_file():
            self.send_response(HTTPStatus.NOT_FOUND)
            self._cors()
            self.end_headers()
            return

        data = glb_path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self._cors()
        self.send_header("Content-Type", "model/gltf-binary")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if write_body:
            self.wfile.write(data)
        self.log_message("served %s GLB (%d bytes) for %s", served, len(data), digest)


def main() -> None:
    global _HANDLER_ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument(
        "--root",
        default=str(Path.cwd()),
        help="dir holding real assets/sha256/<digest>/asset.glb files",
    )
    args = parser.parse_args()
    _HANDLER_ROOT = Path(args.root).expanduser().resolve()

    if not _PLACEHOLDER.is_file():
        raise SystemExit(
            f"placeholder GLB missing at {_PLACEHOLDER}; "
            "run apps/client/assets/3d/dev/gen_placeholder.py"
        )

    server = ThreadingHTTPServer((args.bind, args.port), AssetCdnHandler)
    print(
        f"dev asset CDN on http://{args.bind}:{args.port} "
        f"(real-asset root: {_HANDLER_ROOT}, fallback: placeholder cube)",
        flush=True,
    )
    print(
        "launch client with: "
        f"flutter run -d chrome --web-port=8082 "
        f"--dart-define=ECHO_ASSET_CDN_URL=http://{args.bind}:{args.port}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()

