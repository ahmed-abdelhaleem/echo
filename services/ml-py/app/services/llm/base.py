"""The :class:`LLMClient` protocol."""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from app.services.llm.types import Completion, CompletionRequest


@runtime_checkable
class LLMClient(Protocol):
    """A typed contract every LLM provider implementation satisfies.

    Implementations are async and stateless: a single client instance
    is shared across the process and called concurrently. State that
    must persist across calls (rate limiters, connection pools) lives
    inside the implementation, not in the protocol.

    The protocol returns a :class:`Completion`. Failures are signalled
    by raising one of the subclasses of
    :class:`app.services.llm.errors.LLMProviderError`. The router
    relies on those errors to decide whether to fall back.
    """

    provider_id: str
    """Stable short identifier used in :class:`Completion.provider`
    and recognised by the factory ("anthropic", "openai", "mock")."""

    async def complete(self, request: CompletionRequest) -> Completion:
        """Send the request to the provider, await the response."""
        ...

    async def aclose(self) -> None:
        """Release any resources held by the client (HTTP pools, etc.).

        Idempotent. The factory calls this on shutdown. Implementations
        that hold no resources may make this a no-op.
        """
        ...
