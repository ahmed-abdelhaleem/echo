"""Minimal HTTP inference server for the original Microsoft TRELLIS runtime.

Run this file from the official TRELLIS checkout's Python environment on a
CUDA-capable host. For Apple Silicon, use a TRELLIS.2 MPS/MLX port and set
``TRELLIS_API_STYLE=trellis2-apple`` in Echo instead.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.request import urlopen

from PIL import Image
from trellis.pipelines import TrellisImageTo3DPipeline, TrellisTextTo3DPipeline
from trellis.utils import postprocessing_utils

MAX_REQUEST_BYTES = 1_000_000
MAX_REFERENCE_BYTES = 20_000_000
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8090


class TrellisRuntime:
    """Own lazily loaded TRELLIS pipelines and serialize GPU generation."""

    def __init__(self) -> None:
        self._text_pipeline: Any | None = None
        self._image_pipeline: Any | None = None
        self._lock = threading.Lock()

    def _get_text_pipeline(self) -> Any:
        if self._text_pipeline is None:
            model = os.environ.get("TRELLIS_TEXT_MODEL", "microsoft/TRELLIS-text-xlarge")
            self._text_pipeline = TrellisTextTo3DPipeline.from_pretrained(model)
            self._text_pipeline.cuda()
        return self._text_pipeline

    def _get_image_pipeline(self) -> Any:
        if self._image_pipeline is None:
            model = os.environ.get("TRELLIS_IMAGE_MODEL", "microsoft/TRELLIS-image-large")
            self._image_pipeline = TrellisImageTo3DPipeline.from_pretrained(model)
            self._image_pipeline.cuda()
        return self._image_pipeline

    def generate(self, payload: dict[str, Any]) -> bytes:
        mode = payload.get("mode")
        prompt = payload.get("prompt")
        params = payload.get("params") or {}
        if mode not in {"text-to-3d", "image-to-3d"}:
            raise ValueError("mode must be text-to-3d or image-to-3d")
        if not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("prompt must be a non-empty string")
        if not isinstance(params, dict):
            raise ValueError("params must be an object")
        if payload.get("negative_prompt"):
            raise ValueError("TRELLIS does not support negative_prompt")

        seed = _bounded_int(params.get("seed", 42), "seed", minimum=0)
        simplify = _bounded_float(params.get("simplify", 0.95), "simplify", 0.0, 1.0)
        texture_size = _bounded_int(
            params.get("texture_size", 1024),
            "texture_size",
            minimum=256,
            maximum=2048,
        )
        sparse_params = _dict_param(params, "sparse_structure_sampler_params")
        slat_params = _dict_param(params, "slat_sampler_params")

        with self._lock:
            if mode == "text-to-3d":
                outputs = self._get_text_pipeline().run(
                    prompt,
                    seed=seed,
                    sparse_structure_sampler_params=sparse_params,
                    slat_sampler_params=slat_params,
                    formats=["mesh", "gaussian"],
                )
            else:
                image = _load_reference_image(payload.get("references"))
                outputs = self._get_image_pipeline().run(
                    image,
                    seed=seed,
                    sparse_structure_sampler_params=sparse_params,
                    slat_sampler_params=slat_params,
                    formats=["mesh", "gaussian"],
                )

            glb = postprocessing_utils.to_glb(
                outputs["gaussian"][0],
                outputs["mesh"][0],
                simplify=simplify,
                texture_size=texture_size,
                verbose=False,
            )
            exported = glb.export(file_type="glb")
        if not isinstance(exported, bytes):
            raise RuntimeError("TRELLIS GLB export did not return bytes")
        return exported


def _bounded_int(
    value: object,
    name: str,
    *,
    minimum: int,
    maximum: int | None = None,
) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{name} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f"{name} is outside the supported range")
    return value


def _bounded_float(value: object, name: str, minimum: float, maximum: float) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    result = float(value)
    if not minimum <= result <= maximum:
        raise ValueError(f"{name} is outside the supported range")
    return result


def _dict_param(params: dict[str, Any], name: str) -> dict[str, Any]:
    value = params.get(name, {})
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    return value


def _load_reference_image(references: object) -> Image.Image:
    if not isinstance(references, list) or len(references) != 1:
        raise ValueError("image-to-3d requires exactly one reference")
    reference = references[0]
    if not isinstance(reference, dict) or not isinstance(reference.get("uri"), str):
        raise ValueError("reference uri must be a string")

    with urlopen(reference["uri"], timeout=30) as response:
        data = response.read(MAX_REFERENCE_BYTES + 1)
    if len(data) > MAX_REFERENCE_BYTES:
        raise ValueError("reference image exceeds 20 MB")

    expected_sha256 = reference.get("sha256")
    if expected_sha256 and hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError("reference image sha256 mismatch")
    return Image.open(io.BytesIO(data)).convert("RGBA")


class TrellisHandler(BaseHTTPRequestHandler):
    runtime = TrellisRuntime()

    def do_GET(self) -> None:
        if self.path != "/healthz":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self._write_json(HTTPStatus.OK, {"status": "ok"})

    def do_POST(self) -> None:
        if self.path != "/v1/generate":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > MAX_REQUEST_BYTES:
                raise ValueError("invalid Content-Length")
            payload = json.loads(self.rfile.read(content_length))
            if not isinstance(payload, dict):
                raise ValueError("request body must be an object")
            glb = self.runtime.generate(payload)
        except ValueError as exc:
            self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except Exception as exc:
            self.log_error("generation failed: %s", exc)
            self._write_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "generation failed"})
            return

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "model/gltf-binary")
        self.send_header("Content-Length", str(len(glb)))
        self.end_headers()
        self.wfile.write(glb)

    def _write_json(self, status: HTTPStatus, body: dict[str, str]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def main() -> None:
    os.environ.setdefault("SPCONV_ALGO", "native")
    bind = os.environ.get("TRELLIS_BIND", DEFAULT_BIND)
    port = int(os.environ.get("TRELLIS_PORT", str(DEFAULT_PORT)))
    server = ThreadingHTTPServer((bind, port), TrellisHandler)
    print(f"TRELLIS server listening on http://{bind}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
