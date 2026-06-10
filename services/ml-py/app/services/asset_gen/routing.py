"""Multi-provider routing for the asset-gen abstraction (T-ML-050).

:class:`RoutingAssetGenProvider` wraps a primary
:class:`~app.services.asset_gen.base.AssetGenProvider` plus an ordered
list of fallback providers and exposes the same protocol shape. Callers
receive a single provider; the routing is invisible to them.

This satisfies T-ML-050's acceptance criterion:
  *"a forced failure on the primary provider routes to the fallback
  with no caller change."*

Design mirrors :mod:`app.services.llm.routing` exactly:

- **Ordered fallbacks.** The fallback list is tried in order.
- **Single attempt per provider.** The router does not retry the same
  provider on failure; the per-provider client is responsible for its
  own retry policy.
- **Errors carry the chain.** When every provider fails, the router
  raises :class:`~app.services.asset_gen.errors.AllAssetGenProvidersFailedError`
  with the per-provider failures attached.
- **Synchronous.** The background worker (T-ML-051) runs providers in a
  thread pool so the interface is sync (unlike the async LLM client).
"""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass

from app.services.asset_gen.base import AssetGenProvider
from app.services.asset_gen.errors import (
    AllAssetGenProvidersFailedError,
    AssetGenProviderError,
)
from app.services.asset_gen.types import AssetGenRequest, AssetGenResult

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class RoutingResult:
    """Telemetry about which provider served a routed call.

    Returned alongside :class:`~app.services.asset_gen.types.AssetGenResult`
    from :meth:`RoutingAssetGenProvider.generate_with_route` for callers
    (e.g. the background worker) that want to record routing decisions.
    Plain :meth:`RoutingAssetGenProvider.generate` returns just the result.
    """

    result: AssetGenResult
    served_by_provider: str
    attempted_providers: tuple[str, ...]
    """Providers tried in order, including the successful one (last)."""


class RoutingAssetGenProvider:
    """Primary + ordered-fallbacks router for 3D asset generation.

    The router itself satisfies the :class:`AssetGenProvider` protocol
    so it can be nested if multi-tier routing is ever needed. In practice
    we expect one level (Meshy → trellis).
    """

    provider_id: str = "routing"

    def __init__(
        self,
        *,
        primary: AssetGenProvider,
        fallbacks: Sequence[AssetGenProvider] = (),
    ) -> None:
        if primary is None:
            raise ValueError("primary is required")
        self._primary = primary
        self._fallbacks: tuple[AssetGenProvider, ...] = tuple(fallbacks)
        self._chain: tuple[AssetGenProvider, ...] = (primary, *self._fallbacks)

    @property
    def primary(self) -> AssetGenProvider:
        return self._primary

    @property
    def fallbacks(self) -> tuple[AssetGenProvider, ...]:
        return self._fallbacks

    @property
    def chain_provider_ids(self) -> tuple[str, ...]:
        """All provider ids in order, for telemetry / debugging."""
        return tuple(p.provider_id for p in self._chain)

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        """Try the chain; return the first successful result."""
        return self.generate_with_route(request).result

    def generate_with_route(self, request: AssetGenRequest) -> RoutingResult:
        """Same as :meth:`generate` but also returns routing telemetry."""
        attempted: list[str] = []
        failures: list[AssetGenProviderError] = []

        for provider in self._chain:
            attempted.append(provider.provider_id)
            try:
                result = provider.generate(request)
            except AssetGenProviderError as exc:
                logger.warning(
                    "asset-gen provider %s failed; trying next",
                    provider.provider_id,
                    extra={
                        "provider": provider.provider_id,
                        "error_type": type(exc).__name__,
                        "error_message": str(exc),
                    },
                )
                failures.append(exc)
                continue

            return RoutingResult(
                result=result,
                served_by_provider=provider.provider_id,
                attempted_providers=tuple(attempted),
            )

        raise AllAssetGenProvidersFailedError(failures)

    def close(self) -> None:
        """Close every provider in the chain.

        Failures on individual closes are logged and suppressed so a
        broken primary does not prevent the fallback from being closed.
        """
        for provider in self._chain:
            try:
                provider.close()
            except Exception:
                logger.exception(
                    "error while closing asset-gen provider %s",
                    provider.provider_id,
                )
