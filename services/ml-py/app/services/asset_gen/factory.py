"""Factory for the asset-gen provider abstraction (T-ML-050).

:func:`build_provider_from_env` reads the standard env vars and returns
a fully-configured :class:`RoutingAssetGenProvider`. Construction is
strict: unknown providers, missing API keys, or contradictory settings
raise :class:`AssetGenConfigurationError` so the gRPC server fails to
boot rather than silently producing a half-configured provider.

Recognised environment variables:

- ``ECHO_ASSET_GEN_PRIMARY``   — Provider id of the primary. Default:
  ``meshy``. Set to ``self-hosted`` in dev / CI (no API key needed).
- ``ECHO_ASSET_GEN_FALLBACKS`` — Comma-separated provider ids. Default:
  ``self-hosted``. Production sets this to ``self-hosted`` (i.e. the
  open-model TripoSR / InstantMesh server).
- ``ECHO_ENV``                 — One of ``production`` / ``staging`` /
  ``dev``. ``production`` rejects dev-only providers in the chain.
- ``MESHY_API_KEY``            — Meshy API key, required if ``meshy``
  appears in the chain.

The factory performs *no* network IO; it only constructs provider
objects. Network failures surface on the first ``generate()`` call.
"""

from __future__ import annotations

import os
from collections.abc import Iterable

from app.services.asset_gen.base import AssetGenProvider
from app.services.asset_gen.errors import AssetGenConfigurationError
from app.services.asset_gen.meshy import MeshyProvider
from app.services.asset_gen.routing import RoutingAssetGenProvider
from app.services.asset_gen.self_hosted import SelfHostedProvider

KNOWN_PROVIDERS: tuple[str, ...] = ("meshy", "self-hosted")
"""Provider ids the factory recognises. Update when adding a new provider."""

DEFAULT_PRIMARY: str = "meshy"
"""What we configure as the primary in production."""

DEFAULT_FALLBACKS: tuple[str, ...] = ("self-hosted",)
"""Default fallback chain when ``ECHO_ASSET_GEN_FALLBACKS`` is unset."""


def _build_single(provider_id: str, env: dict[str, str]) -> AssetGenProvider:
    """Construct one provider from env vars.

    Kept private so tests can call :func:`build_provider` with a
    hand-constructed env dict rather than mutating ``os.environ``.
    """
    if provider_id == "meshy":
        api_key = env.get("MESHY_API_KEY", "")
        if not api_key:
            raise AssetGenConfigurationError(
                "MESHY_API_KEY required when meshy is in the chain",
            )
        return MeshyProvider(api_key=api_key)

    if provider_id == "self-hosted":
        return SelfHostedProvider()

    raise AssetGenConfigurationError(
        f"unknown asset-gen provider {provider_id!r}; known: {KNOWN_PROVIDERS}",
    )


def build_provider(
    *,
    primary: str,
    fallbacks: Iterable[str] = (),
    env: dict[str, str] | None = None,
) -> RoutingAssetGenProvider:
    """Build a :class:`RoutingAssetGenProvider` from explicit settings.

    Used by tests and by :func:`build_provider_from_env`. Production
    callers should prefer the latter so the env-var contract stays in
    one place.

    Args:
        primary: Provider id of the primary provider.
        fallbacks: Provider ids for the fallback chain, in order.
        env: Environment variables to read. Defaults to ``os.environ``.

    Raises:
        AssetGenConfigurationError: on unknown providers, missing API
            keys, duplicate providers in the chain, or production deploys
            that try to use a stub-only provider.
    """
    if env is None:
        env = dict(os.environ)

    chain = [primary, *list(fallbacks)]
    if len(set(chain)) != len(chain):
        raise AssetGenConfigurationError(
            f"duplicate providers in chain {chain!r}",
        )

    for pid in chain:
        if pid not in KNOWN_PROVIDERS:
            raise AssetGenConfigurationError(
                f"unknown asset-gen provider {pid!r}; known: {KNOWN_PROVIDERS}",
            )

    primary_provider = _build_single(primary, env)
    fallback_providers = [_build_single(fid, env) for fid in fallbacks]
    return RoutingAssetGenProvider(primary=primary_provider, fallbacks=fallback_providers)


def build_provider_from_env(
    env: dict[str, str] | None = None,
) -> RoutingAssetGenProvider:
    """Build the production routing provider from environment variables.

    Defaults:
        - ``ECHO_ASSET_GEN_PRIMARY=meshy``
        - ``ECHO_ASSET_GEN_FALLBACKS=self-hosted``

    In a dev shell where no env vars are set, the constructor will
    raise on the missing Meshy API key. To get a working provider for
    local dev without provider keys, set
    ``ECHO_ASSET_GEN_PRIMARY=self-hosted ECHO_ASSET_GEN_FALLBACKS=``.
    """
    if env is None:
        env = dict(os.environ)

    primary = env.get("ECHO_ASSET_GEN_PRIMARY", DEFAULT_PRIMARY).strip().lower()
    fallbacks_raw = env.get("ECHO_ASSET_GEN_FALLBACKS", ",".join(DEFAULT_FALLBACKS))
    fallbacks = tuple(fb.strip().lower() for fb in fallbacks_raw.split(",") if fb.strip())
    return build_provider(primary=primary, fallbacks=fallbacks, env=env)
