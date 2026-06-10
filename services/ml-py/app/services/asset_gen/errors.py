"""Exception hierarchy for the asset-gen provider abstraction (T-ML-050).

Mirrors the structure of :mod:`app.services.llm.errors` so the routing
layer stays consistent across the two provider families.
"""

from __future__ import annotations


class AssetGenError(Exception):
    """Base class for every error raised by the asset-gen abstraction."""


class AssetGenConfigurationError(AssetGenError):
    """A provider could not be constructed.

    Examples: missing API key, unknown provider id. The factory raises
    this at startup so we fail loud rather than produce a half-configured
    provider that fails per-request.
    """


class AssetGenProviderError(AssetGenError):
    """A specific provider failed to serve a request.

    :class:`RoutingAssetGenProvider` catches this from the primary and
    tries each fallback in order. If *all* providers raise this, the
    router raises :class:`AllAssetGenProvidersFailedError`.

    Concrete subclasses carry the precise failure mode; tests rely on
    them to assert correct routing behaviour. Production code should
    usually catch the base class.
    """

    def __init__(self, message: str, *, provider: str) -> None:
        super().__init__(message)
        self.provider = provider


class AssetGenProviderTimeoutError(AssetGenProviderError):
    """The provider did not respond within the configured deadline."""


class AssetGenProviderHTTPError(AssetGenProviderError):
    """The provider returned an HTTP error response.

    Carries the HTTP status code so callers / telemetry can distinguish
    retryable failures (5xx) from configuration / quota issues (4xx).
    """

    def __init__(self, message: str, *, provider: str, status_code: int) -> None:
        super().__init__(message, provider=provider)
        self.status_code = status_code


class AllAssetGenProvidersFailedError(AssetGenError):
    """Every provider in the chain raised :class:`AssetGenProviderError`.

    Carries the list of individual provider failures so callers can
    log / surface them all.
    """

    def __init__(self, failures: list[AssetGenProviderError]) -> None:
        providers = ", ".join(f.provider for f in failures) or "(none)"
        super().__init__(f"all asset-gen providers failed: {providers}")
        self.failures = tuple(failures)
