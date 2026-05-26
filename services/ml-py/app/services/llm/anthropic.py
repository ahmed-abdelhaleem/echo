"""Anthropic Claude client (T-ML-041 primary provider).

**Wire-implementation stub.** This module exists in PR C to:

1. Reserve the ``provider_id="anthropic"`` slot in the factory so PR D
   (the reflection pipeline) can swap in the real wire implementation
   without touching any caller.
2. Carry the configuration-validation logic (API key required, model
   id allowlist) at construction time, so the factory fails loud on a
   misconfigured production deploy even before any traffic arrives.
3. Provide a clear seam in the test suite: the routing tests use
   :class:`MockLLMClient` to exercise routing; this client raises
   :class:`NotImplementedError` from ``complete`` so the test suite
   accidentally calling it would surface immediately.

The real wire implementation (HTTP + the ``anthropic`` Python SDK) is
held back to PR D because it adds a new top-level dependency — that
gates on ``human-review-required`` per AGENTS.md §10.1. Splitting the
abstraction PR from the dep-bumping PR keeps the review surface
honest.
"""

from __future__ import annotations

from app.services.llm.errors import LLMConfigurationError
from app.services.llm.types import Completion, CompletionRequest

# Models we are willing to route to. Off-list models are rejected at
# construction time. Pinned to dated snapshots for reproducibility.
_ALLOWED_MODELS: frozenset[str] = frozenset(
    {
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022",
    },
)

DEFAULT_MODEL: str = "claude-3-5-sonnet-20241022"
"""Default reflection model. Tuned for instruction-following and the
tone-sensitive prose Echo writes; documented in docs/06 §"LLM"."""


class AnthropicClient:
    """Anthropic Claude client.

    Args:
        api_key: API key from the Anthropic console. Required;
            constructor raises if missing or empty.
        model: Model identifier. Must appear in :data:`_ALLOWED_MODELS`.
        timeout_seconds: Per-request timeout. Applied by the real
            HTTP impl in PR D.
        base_url: Override for the API endpoint (used by tests / VPCs).
    """

    provider_id: str = "anthropic"

    def __init__(
        self,
        *,
        api_key: str,
        model: str = DEFAULT_MODEL,
        timeout_seconds: float = 30.0,
        base_url: str = "https://api.anthropic.com",
    ) -> None:
        if not api_key:
            raise LLMConfigurationError("Anthropic API key is required")
        if model not in _ALLOWED_MODELS:
            raise LLMConfigurationError(
                f"unknown Anthropic model {model!r}; allowed: {sorted(_ALLOWED_MODELS)}",
            )
        if timeout_seconds <= 0:
            raise LLMConfigurationError(
                f"timeout_seconds must be positive, got {timeout_seconds}",
            )
        self._api_key = api_key
        self._model = model
        self._timeout_seconds = timeout_seconds
        self._base_url = base_url.rstrip("/")

    @property
    def model(self) -> str:
        return self._model

    async def complete(self, request: CompletionRequest) -> Completion:
        """Send the completion request to Anthropic.

        **Not yet implemented.** The real wire implementation lands in
        PR D. Calling this method today raises :class:`NotImplementedError`
        so test runs accidentally routing here surface immediately
        rather than silently producing a placeholder.
        """
        raise NotImplementedError(
            "AnthropicClient.complete: real wire implementation lands in PR D"
            " (T-ML-042). Use MockLLMClient for tests until then.",
        )

    async def aclose(self) -> None:
        """No-op until PR D introduces an HTTP connection pool."""
        return
