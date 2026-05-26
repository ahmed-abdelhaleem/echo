"""Exception hierarchy for the LLM client abstraction."""

from __future__ import annotations


class LLMError(Exception):
    """Base class for every error raised by the LLM abstraction.

    Callers typically only handle :class:`AllProvidersFailedError` (the
    routing client's terminal error) and let the rest bubble up. The
    pipeline's safety classifier sees these as a 500 and either retries
    with a different prompt or falls back to a curated string per
    docs/04 §"Generation pipeline".
    """


class LLMConfigurationError(LLMError):
    """A client could not be constructed.

    Examples: missing API key, unknown provider id, conflicting routing
    config. The factory raises this at startup so we fail loud instead
    of producing a half-configured client that then fails per-request.
    """


class LLMProviderError(LLMError):
    """A specific provider failed to serve a request.

    The :class:`RoutingLLMClient` catches this from the primary and
    tries each fallback in order. If *all* providers raise this, the
    router raises :class:`AllProvidersFailedError`.

    Concrete subclasses below carry the precise failure mode; tests
    rely on them to assert correct routing behaviour. Production code
    should usually catch the base class.
    """

    def __init__(self, message: str, *, provider: str) -> None:
        super().__init__(message)
        self.provider = provider


class LLMProviderTimeoutError(LLMProviderError):
    """The provider did not respond within the configured deadline."""


class LLMProviderHTTPError(LLMProviderError):
    """The provider returned an HTTP error response.

    Carries the HTTP status code so callers / telemetry can distinguish
    retryable failures (5xx) from configuration / quota issues (4xx).
    """

    def __init__(self, message: str, *, provider: str, status_code: int) -> None:
        super().__init__(message, provider=provider)
        self.status_code = status_code


class LLMProviderContentFilterError(LLMProviderError):
    """The provider's own safety stack refused to complete the request.

    Treated as a routable failure: the router will try the fallback.
    The pipeline (T-ML-042) treats *post-classifier* safety failures
    differently — they bypass the router and fall back to a curated
    string.
    """


class AllProvidersFailedError(LLMError):
    """Every provider in the chain raised :class:`LLMProviderError`.

    Carries the list of individual provider failures so callers can
    log / surface them all.
    """

    def __init__(self, failures: list[LLMProviderError]) -> None:
        providers = ", ".join(f.provider for f in failures) or "(none)"
        super().__init__(f"all LLM providers failed: {providers}")
        self.failures = tuple(failures)
