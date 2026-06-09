"""Deterministic in-memory LLM client.

Used by:

- The reflection pipeline test suite (T-ML-042) so end-to-end pipeline
  tests don't need network access or live API keys.
- CI, via the factory's default routing (when ``ECHO_LLM_PRIMARY`` is
  unset, the factory builds a mock primary so the gRPC server boots).
- The forced-failure tests in this module that prove the router
  honours T-ML-041's acceptance criterion.

The mock is *not* used in production. The factory refuses to construct
a mock primary if ``ECHO_ENV=production``.
"""

from __future__ import annotations

from collections.abc import Callable

from app.services.llm.errors import (
    LLMProviderContentFilterError,
    LLMProviderError,
    LLMProviderHTTPError,
    LLMProviderTimeoutError,
)
from app.services.llm.types import Completion, CompletionRequest

CompletionFn = Callable[[CompletionRequest], Completion]
"""Callable that turns a request into a completion. Tests pass this in
to script the mock's behaviour for individual calls."""


def default_completion_fn(provider_id: str, model: str) -> CompletionFn:
    """Build a default ``fn`` that echoes the last user message.

    Useful for "happy path" tests where the test only cares that the
    routing returns *something* from a working provider, not what.
    """

    def _fn(request: CompletionRequest) -> Completion:
        last_user = next(
            (m for m in reversed(request.messages) if m.role == "user"),
            None,
        )
        text = (last_user.content if last_user else "").strip()
        # Truncate to roughly the requested length so length-honouring
        # behaviour is testable.
        approx_chars = max(1, request.max_output_tokens * 4)
        truncated = text[:approx_chars]
        return Completion(
            text=truncated,
            provider=provider_id,
            model=model,
            finish_reason="stop",
            input_tokens=sum(len(m.content) for m in request.messages) // 4,
            output_tokens=len(truncated) // 4,
            metadata=dict(request.metadata),
        )

    return _fn


class MockLLMClient:
    """A configurable, deterministic LLM client.

    The mock dispatches on a per-call callable rather than capturing a
    fixed return value because router tests need to interleave success
    and failure responses to prove fallback works on the *forced*
    failure of the primary.
    """

    provider_id: str

    def __init__(
        self,
        *,
        provider_id: str = "mock",
        model: str = "mock-1",
        fn: CompletionFn | None = None,
        raises: type[LLMProviderError] | LLMProviderError | None = None,
    ) -> None:
        """Construct a mock client.

        Args:
            provider_id: Identifier echoed in :attr:`Completion.provider`.
                Tests use distinct ids ("mock-primary", "mock-fallback")
                so they can assert which provider served a routed call.
            model: Identifier echoed in :attr:`Completion.model`.
            fn: Per-call generator. Defaults to one that echoes the
                last user message.
            raises: Force the client to raise on every call. Used by
                router tests. May be an exception *class* (the client
                will instantiate it with a default message) or an
                already-constructed instance.
        """
        self.provider_id = provider_id
        self._model = model
        self._fn = fn or default_completion_fn(provider_id, model)
        self._raises = raises
        self.call_count = 0
        """Test affordance: number of times ``complete`` was called.
        Lets routing tests assert "primary was tried, then fallback"."""

    async def complete(self, request: CompletionRequest) -> Completion:
        self.call_count += 1
        if self._raises is not None:
            if isinstance(self._raises, LLMProviderError):
                raise self._raises
            # Class: instantiate with a default message based on type.
            if issubclass(self._raises, LLMProviderTimeoutError):
                raise self._raises("forced timeout", provider=self.provider_id)
            if issubclass(self._raises, LLMProviderHTTPError):
                raise self._raises(
                    "forced HTTP error",
                    provider=self.provider_id,
                    status_code=500,
                )
            if issubclass(self._raises, LLMProviderContentFilterError):
                raise self._raises(
                    "forced content filter",
                    provider=self.provider_id,
                )
            raise self._raises("forced failure", provider=self.provider_id)
        return self._fn(request)

    async def aclose(self) -> None:
        """No-op; the mock holds no resources."""
        return
