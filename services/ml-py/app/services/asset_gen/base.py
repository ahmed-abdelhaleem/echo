"""The :class:`AssetGenProvider` protocol (T-ML-050).

Every provider implementation — Meshy, self-hosted, mock — satisfies
this contract. The routing layer depends only on this protocol, not on
any concrete class.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from app.services.asset_gen.types import AssetGenRequest, AssetGenResult


@runtime_checkable
class AssetGenProvider(Protocol):
    """A typed contract every 3D asset-generation provider satisfies.

    Implementations are synchronous (the background worker runs them in
    a thread pool) and stateless: a single provider instance is shared
    across the process.

    Failures are signalled by raising a subclass of
    :class:`~app.services.asset_gen.errors.AssetGenProviderError`. The
    router relies on those errors to decide whether to fall back.
    """

    provider_id: str
    """Stable short identifier used in :class:`AssetGenResult.provider_used`
    and recognised by the factory (``"meshy"``, ``"self-hosted"``)."""

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        """Generate (or dry-run) an asset.

        On ``dry_run=True``, implementations compute the content-address
        and return immediately without calling any external API.

        Raises:
            AssetGenProviderError: on provider-side failures.
        """
        ...

    def close(self) -> None:
        """Release any resources held by the provider (HTTP pools, etc.).

        Idempotent. The factory calls this on shutdown. Implementations
        that hold no resources may make this a no-op.
        """
        ...
