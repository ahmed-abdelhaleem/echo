"""HTTP inference server for the Apple Silicon TRELLIS.2 port."""

from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import urlopen

MAX_REQUEST_BYTES = 1_000_000
MAX_REFERENCE_BYTES = 20_000_000
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8090

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("ATTN_BACKEND", "sdpa")
os.environ.setdefault("SPARSE_ATTN_BACKEND", "sdpa")
os.environ.setdefault("SPARSE_CONV_BACKEND", "none")


class ModelAccessError(RuntimeError):
    pass


class AppleTrellisRuntime:
    """Lazily load TRELLIS.2 once and serialize MPS generation."""

    def __init__(self) -> None:
        default_root = Path.home() / "Documents" / "GitHub" / "trellis-mac"
        root = Path(os.environ.get("TRELLIS_MAC_ROOT", str(default_root))).expanduser()
        self._root = root
        self._pipeline: Any | None = None
        self._lock = threading.Lock()

    @property
    def model_loaded(self) -> bool:
        return self._pipeline is not None

    def _load_pipeline(self) -> Any:
        if self._pipeline is not None:
            return self._pipeline

        from huggingface_hub import get_token

        if not get_token():
            raise ModelAccessError(
                "Hugging Face login required for gated DINOv3 and RMBG-2.0 models"
            )

        trellis_root = self._root / "TRELLIS.2"
        stubs_root = self._root / "stubs"
        if not trellis_root.is_dir():
            raise RuntimeError(f"TRELLIS.2 checkout not found at {trellis_root}")
        sys.path.insert(0, str(trellis_root))
        sys.path.append(str(stubs_root))

        import torch
        from trellis2.pipelines.trellis2_image_to_3d import (
            Trellis2ImageTo3DPipeline,
        )

        if not torch.backends.mps.is_available():
            raise RuntimeError("PyTorch MPS is unavailable")
        # The upstream pipeline eagerly loads both 512 and 1024 flow models.
        # Local development only needs the 512 path; omitting 1024 saves about
        # 5.2 GB of disk and model-loading traffic.
        Trellis2ImageTo3DPipeline.model_names_to_load = [
            "sparse_structure_flow_model",
            "sparse_structure_decoder",
            "shape_slat_flow_model_512",
            "shape_slat_decoder",
            "tex_slat_flow_model_512",
            "tex_slat_decoder",
        ]
        pipeline = Trellis2ImageTo3DPipeline.from_pretrained("microsoft/TRELLIS.2-4B")
        pipeline.to(torch.device("mps"))
        self._pipeline = pipeline
        return pipeline

    def generate(self, payload: dict[str, Any]) -> bytes:
        if payload.get("mode") != "image-to-3d":
            raise ValueError("Apple TRELLIS.2 supports image-to-3d requests only")
        if payload.get("negative_prompt"):
            raise ValueError("Apple TRELLIS.2 does not support negative_prompt")
        params = payload.get("params") or {}
        if not isinstance(params, dict):
            raise ValueError("params must be an object")

        image = _load_reference_image(payload.get("references"))
        seed = _bounded_int(params.get("seed", 42), "seed", minimum=0)
        steps = params.get("steps")
        if steps is not None:
            steps = _bounded_int(steps, "steps", minimum=1, maximum=50)
        pipeline_type = params.get("pipeline_type", "512")
        if pipeline_type != "512":
            raise ValueError("Apple TRELLIS.2 adapter supports pipeline_type 512 only")
        target_polycount = _bounded_int(
            params.get("target_polycount", 200_000),
            "target_polycount",
            minimum=100,
            maximum=1_000_000,
        )

        sampler_params = {"steps": steps} if steps is not None else {}
        with self._lock:
            pipeline = self._load_pipeline()
            outputs = pipeline.run(
                image,
                seed=seed,
                pipeline_type=pipeline_type,
                sparse_structure_sampler_params=sampler_params,
                shape_slat_sampler_params=sampler_params,
                tex_slat_sampler_params=sampler_params,
            )
            mesh = outputs[0] if isinstance(outputs, list) else outputs
            vertices = mesh.vertices.cpu().numpy()
            faces = mesh.faces.cpu().numpy()

        if len(vertices) == 0 or len(faces) == 0:
            raise RuntimeError("TRELLIS.2 produced an empty mesh")
        if len(faces) > target_polycount:
            import fast_simplification

            vertices, faces = fast_simplification.simplify(
                vertices,
                faces,
                target_count=target_polycount,
            )

        import trimesh

        exported = trimesh.Trimesh(
            vertices=vertices,
            faces=faces,
            process=False,
        ).export(file_type="glb")
        if not isinstance(exported, bytes):
            raise RuntimeError("TRELLIS.2 GLB export did not return bytes")
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


def _load_reference_image(references: object) -> Any:
    from PIL import Image

    if not isinstance(references, list) or len(references) != 1:
        raise ValueError("image-to-3d requires exactly one reference")
    reference = references[0]
    if not isinstance(reference, dict) or not isinstance(reference.get("uri"), str):
        raise ValueError("reference uri must be a string")
    uri = reference["uri"]
    if urlparse(uri).scheme not in {"http", "https"}:
        raise ValueError("reference uri must use http:// or https://")

    with urlopen(uri, timeout=30) as response:
        data = response.read(MAX_REFERENCE_BYTES + 1)
    if len(data) > MAX_REFERENCE_BYTES:
        raise ValueError("reference image exceeds 20 MB")
    expected_sha256 = reference.get("sha256")
    if expected_sha256 and hashlib.sha256(data).hexdigest() != expected_sha256:
        raise ValueError("reference image sha256 mismatch")
    return Image.open(io.BytesIO(data)).convert("RGBA")


class AppleTrellisHandler(BaseHTTPRequestHandler):
    runtime = AppleTrellisRuntime()

    def do_GET(self) -> None:
        if self.path != "/healthz":
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        from huggingface_hub import get_token

        self._write_json(
            HTTPStatus.OK,
            {
                "status": "ok",
                "backend": "mps",
                "model_loaded": self.runtime.model_loaded,
                "hf_token_present": bool(get_token()),
            },
        )

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
        except ModelAccessError as exc:
            self._write_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": str(exc)})
            return
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

    def _write_json(self, status: HTTPStatus, body: dict[str, object]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def main() -> None:
    bind = os.environ.get("TRELLIS_BIND", DEFAULT_BIND)
    port = int(os.environ.get("TRELLIS_PORT", str(DEFAULT_PORT)))
    server = ThreadingHTTPServer((bind, port), AppleTrellisHandler)
    print(f"Apple TRELLIS.2 server listening on http://{bind}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
