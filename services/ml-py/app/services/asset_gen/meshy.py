"""Meshy provider stub (primary) for asset-gen routing (T-ML-050).

This is the **M1 stub** — the constructor validates the API key so the
server fails loudly on misconfiguration, but ``generate()`` always raises
:class:`~app.services.asset_gen.errors.AssetGenProviderError` to
demonstrate the routing fallback path without making real API calls.

The real Meshy HTTP implementation lands with T-ML-051. At that point
this file is replaced; the ``AssetGenProvider`` protocol and router are
untouched.

.. note:: Per AGENTS.md §11, triggering paid Meshy API calls at scale or
   changing generation budget caps requires a ``human-review-required``
   PR. This stub safely satisfies T-ML-050 without any spend.
"""

from __future__ import annotations

from app.services.asset_gen.content_address import compute_content_address
from app.services.asset_gen.errors import (
    AssetGenConfigurationError,
    AssetGenProviderError,
)
from app.services.asset_gen.types import AssetGenRequest, AssetGenResult


class MeshyProvider:
    """Primary asset-gen provider backed by the Meshy API.

    **Stub**: in T-ML-050, ``generate()`` always raises
    :class:`AssetGenProviderError` so the router's fallback path is
    exercised. Replace the raise with a real HTTP call in T-ML-051.

    Constructor:
        api_key: Meshy API key. Required; raises
            :class:`AssetGenConfigurationError` when empty.

    Attribute:
        provider_id: ``"meshy"``
    """

    provider_id: str = "meshy"

    def __init__(self, *, api_key: str) -> None:
        if not api_key:
            raise AssetGenConfigurationError(
                "MESHY_API_KEY required when meshy is in the chain",
            )
        # Stored but not used in the stub. T-ML-051 uses it for HTTP auth.
        self._api_key = api_key

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        """Compute the content-address then simulate a provider failure.

        The content-address computation runs first so dry-runs work even
        on a forced-fail stub: callers that need just the address (e.g.
        the reconciler's dedup logic) can set ``dry_run=True``.

        Raises:
            AssetGenProviderError: always (stub behaviour; see class docs).
        """
        addr = compute_content_address(request.inputs)

        if request.dry_run:
            return AssetGenResult(
                content_address=addr,
                provider_used=self.provider_id,
                glb_bytes=None,
                is_stub=True,
            )

        # CHOICE: raise instead of calling Meshy. The real HTTP call lands
        # in T-ML-051. Raising here proves the router routes to fallback.
        # Alternative considered: return a placeholder GLB.
        # We chose raise so that the primary is *visibly* non-functional and
        # tests can assert routing happened.
        raise AssetGenProviderError(
            "MeshyProvider is a stub in T-ML-050; real HTTP call lands in T-ML-051",
            provider=self.provider_id,
        )

    def close(self) -> None:
        pass
