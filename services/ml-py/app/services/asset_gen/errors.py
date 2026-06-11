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
        # Include each provider's failure reason in the message itself, not
        # just the provider ids. Loggers (and the worker's traceback) print
        # the exception string but drop structured `extra=` fields under the
        # default formatter, so the reason has to live in the message to be
        # visible at all. Alternative considered: keep the terse id-only
        # message and rely on callers reading `.failures` — rejected because
        # the common case (a flat log line) then shows no actionable cause.
        if failures:
            detail = "; ".join(
                f"{failure.provider} ({type(failure).__name__}: {failure})"
                for failure in failures
            )
        else:
            detail = "(none)"
        super().__init__(f"all asset-gen providers failed: {detail}")
        self.failures = tuple(failures)
