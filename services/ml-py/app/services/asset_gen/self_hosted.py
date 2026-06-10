"""Self-hosted open-model fallback provider for asset-gen (T-ML-050).

The self-hosted provider is the fallback in the routing chain. It does
not call any external paid API, so it is safe in dev / CI / offline
scenarios.

In T-ML-050 this is also a stub: ``generate()`` returns a minimal
well-formed GLB placeholder (the 12-byte GLB header with version=2)
rather than calling a real TripoSR / InstantMesh server. The real
gRPC/HTTP call to a self-hosted model server lands with T-ML-051.

The placeholder GLB is accepted by three.js / model-viewer in error mode
(they see a valid header but no BIN chunk) so it does not crash clients.

``provider_id`` is ``"self-hosted"`` matching the ``Provider.SELF_HOSTED``
enum in ``asset_gen.proto`` and the ``"self-hosted"`` value in
``asset_manifest.schema.json``.
"""

from __future__ import annotations

from app.services.asset_gen.content_address import compute_content_address
from app.services.asset_gen.types import AssetGenRequest, AssetGenResult

# Minimal valid GLB 2.0 header (no JSON chunk, no BIN chunk).
# magic=0x46546C67 ("glTF"), version=2, length=12 (header only).
_PLACEHOLDER_GLB: bytes = b"glTF\x02\x00\x00\x00\x0c\x00\x00\x00"


class SelfHostedProvider:
    """Self-hosted open-model fallback provider.

    **Stub**: returns :data:`_PLACEHOLDER_GLB` for all non-dry-run
    requests. The real TripoSR / InstantMesh integration lands with
    T-ML-051.

    Attribute:
        provider_id: ``"self-hosted"``
    """

    provider_id: str = "self-hosted"

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        """Return the content-address + placeholder GLB bytes.

        The content-address is computed deterministically from the
        request inputs regardless of ``dry_run``, so callers always get
        a stable identity for deduplication.
        """
        addr = compute_content_address(request.inputs)

        glb: bytes | None = None if request.dry_run else _PLACEHOLDER_GLB

        return AssetGenResult(
            content_address=addr,
            provider_used=self.provider_id,
            glb_bytes=glb,
            is_stub=True,
        )

    def close(self) -> None:
        pass
