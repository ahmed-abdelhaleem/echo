"""HTTP client for Echo's self-hosted Microsoft TRELLIS service."""

from __future__ import annotations

import base64
import hashlib
import json
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from app.services.asset_gen.content_address import compute_content_address
from app.services.asset_gen.errors import (
    AssetGenConfigurationError,
    AssetGenProviderError,
    AssetGenProviderHTTPError,
    AssetGenProviderTimeoutError,
)
from app.services.asset_gen.types import AssetGenRequest, AssetGenResult

KNOWN_API_STYLES: tuple[str, ...] = ("echo", "trellis2-apple")
MAX_REFERENCE_BYTES = 20_000_000


class TrellisProvider:
    """Generate GLBs through a separately deployed TRELLIS process."""

    provider_id: str = "trellis"

    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: float = 900.0,
        api_style: str = "echo",
    ) -> None:
        normalized_url = base_url.strip().rstrip("/")
        if not normalized_url.startswith(("http://", "https://")):
            raise AssetGenConfigurationError(
                "TRELLIS_BASE_URL must be an http:// or https:// URL",
            )
        if timeout_seconds <= 0:
            raise AssetGenConfigurationError("TRELLIS_TIMEOUT_SECONDS must be positive")
        if api_style not in KNOWN_API_STYLES:
            raise AssetGenConfigurationError(
                f"TRELLIS_API_STYLE must be one of {KNOWN_API_STYLES}",
            )
        endpoint = "/v1/generate" if api_style == "echo" else "/generate"
        self._generate_url = f"{normalized_url}{endpoint}"
        self._timeout_seconds = timeout_seconds
        self._api_style = api_style

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        """Return a generated GLB, mapping transport failures to provider errors."""
        addr = compute_content_address(request.inputs)
        if request.dry_run:
            return AssetGenResult(
                content_address=addr,
                provider_used=self.provider_id,
                glb_bytes=None,
            )

        payload = self._build_payload(request)
        http_request = Request(
            self._generate_url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urlopen(http_request, timeout=self._timeout_seconds) as response:
                response_body = response.read()
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise AssetGenProviderHTTPError(
                f"TRELLIS returned HTTP {exc.code}: {detail}",
                provider=self.provider_id,
                status_code=exc.code,
            ) from exc
        except TimeoutError as exc:
            raise AssetGenProviderTimeoutError(
                "TRELLIS generation timed out",
                provider=self.provider_id,
            ) from exc
        except URLError as exc:
            if isinstance(exc.reason, TimeoutError):
                raise AssetGenProviderTimeoutError(
                    "TRELLIS generation timed out",
                    provider=self.provider_id,
                ) from exc
            raise AssetGenProviderError(
                f"TRELLIS request failed: {exc.reason}",
                provider=self.provider_id,
            ) from exc

        glb = self._decode_response(response_body)
        if len(glb) < 12 or glb[:4] != b"glTF":
            raise AssetGenProviderError(
                "TRELLIS returned an invalid GLB payload",
                provider=self.provider_id,
            )
        return AssetGenResult(
            content_address=addr,
            provider_used=self.provider_id,
            glb_bytes=glb,
            is_stub=False,
        )

    def _build_payload(self, request: AssetGenRequest) -> bytes:
        body: dict[str, object]
        if self._api_style == "echo":
            body = {
                "asset_id": request.asset_id,
                "mode": request.inputs.mode,
                "prompt": request.inputs.prompt,
                "negative_prompt": request.inputs.negative_prompt,
                "references": [
                    {"uri": ref.uri, "sha256": ref.sha256} for ref in request.inputs.references
                ],
                "params": request.inputs.params,
            }
        else:
            if request.inputs.mode != "image-to-3d":
                raise AssetGenProviderError(
                    "trellis2-apple supports image-to-3d requests only",
                    provider=self.provider_id,
                )
            if len(request.inputs.references) != 1:
                raise AssetGenProviderError(
                    "trellis2-apple requires exactly one reference image",
                    provider=self.provider_id,
                )
            params = request.inputs.params
            reference = request.inputs.references[0]
            body = {
                "image": base64.b64encode(
                    _download_reference(reference.uri, reference.sha256)
                ).decode("ascii"),
                "seed": params.get("seed", 42),
                "pipeline_type": params.get("pipeline_type", "512"),
                "decimation_target": params.get("target_polycount", 1_000_000),
                "texture_size": params.get("texture_size", 1024),
                "remesh": params.get("remesh", False),
                "steps": params.get("steps"),
                "guidance_strength": params.get("guidance_strength"),
                "texture_guidance": params.get("texture_guidance"),
            }
        return json.dumps(body, separators=(",", ":")).encode("utf-8")

    def _decode_response(self, response_body: bytes) -> bytes:
        if self._api_style == "echo":
            return response_body
        try:
            body = json.loads(response_body)
            encoded_glb = body["glb"]
            if not isinstance(encoded_glb, str):
                raise TypeError
            return base64.b64decode(encoded_glb, validate=True)
        except (KeyError, TypeError, ValueError) as exc:
            raise AssetGenProviderError(
                "trellis2-apple returned an invalid JSON response",
                provider=self.provider_id,
            ) from exc

    def close(self) -> None:
        pass


def _download_reference(uri: str, expected_sha256: str) -> bytes:
    if not uri.startswith(("http://", "https://")):
        raise AssetGenProviderError(
            "TRELLIS reference URI must use http:// or https://",
            provider="trellis",
        )
    try:
        with urlopen(uri, timeout=30) as response:
            data = bytes(response.read(MAX_REFERENCE_BYTES + 1))
    except (HTTPError, URLError, TimeoutError) as exc:
        raise AssetGenProviderError(
            f"failed to download TRELLIS reference: {exc}",
            provider="trellis",
        ) from exc
    if len(data) > MAX_REFERENCE_BYTES:
        raise AssetGenProviderError(
            "TRELLIS reference image exceeds 20 MB",
            provider="trellis",
        )
    if expected_sha256 and hashlib.sha256(data).hexdigest() != expected_sha256:
        raise AssetGenProviderError(
            "TRELLIS reference image sha256 mismatch",
            provider="trellis",
        )
    return data
