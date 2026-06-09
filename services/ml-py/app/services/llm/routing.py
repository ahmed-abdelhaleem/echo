"""Multi-provider routing for the LLM client abstraction (T-ML-041).

The :class:`RoutingLLMClient` is the meat of this PR. It wraps a
primary :class:`LLMClient` plus an ordered list of fallback clients
and exposes the same :class:`LLMClient` shape. Callers receive a
single client; the routing is invisible to them. This satisfies
T-ML-041's acceptance criterion: a forced failure on the primary
routes to the fallback with no caller-visible change.

Design choices worth noting:

- **Ordered fallbacks.** The fallback list is tried in order so we
  can express "Anthropic primary, then OpenAI, then mock" as a single
  config. The router does NOT load-balance across fallbacks; in
  production we expect to have one or two fallbacks at most.
- **Single attempt per provider.** The router does not retry the same
  provider on failure; the per-provider client is responsible for its
  own retry policy. This keeps the routing layer simple and predictable.
- **Errors carry the chain.** When every provider fails, the router
  raises :class:`AllProvidersFailedError` with the per-provider
  failures attached so telemetry can record the full chain.
- **Async-safe.** ``complete`` is async and can be called from many
  coroutines concurrently; the underlying clients are responsible for
  their own concurrency control.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence
from dataclasses import dataclass

from app.services.llm.base import LLMClient
from app.services.llm.errors import (
    AllProvidersFailedError,
    LLMProviderError,
)
from app.services.llm.types import Completion, CompletionRequest

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class RoutingResult:
    """Telemetry about which provider served a routed call.

    Returned alongside :class:`Completion` from
    :meth:`RoutingLLMClient.complete_with_route` for callers (eg the
    reflection pipeline) that want to record routing decisions in
    their audit log. Plain ``complete`` returns just the completion.
    """

    completion: Completion
    served_by_provider: str
    attempted_providers: tuple[str, ...]
    """Providers tried in order, including the successful one (last)."""


class RoutingLLMClient:
    """Primary + ordered-fallbacks router.

    The router is itself an :class:`LLMClient` so it can be nested
    inside another router if multi-tier routing is ever needed (e.g.
    "premium pool routes to free pool on quota error"). In practice
    we expect one level.
    """

    provider_id: str = "routing"

    def __init__(
        self,
        *,
        primary: LLMClient,
        fallbacks: Sequence[LLMClient] = (),
    ) -> None:
        if primary is None:
            raise ValueError("primary is required")
        self._primary = primary
        self._fallbacks: tuple[LLMClient, ...] = tuple(fallbacks)
        # Cache the chain for logging / introspection.
        self._chain: tuple[LLMClient, ...] = (primary, *self._fallbacks)

    @property
    def primary(self) -> LLMClient:
        return self._primary

    @property
    def fallbacks(self) -> tuple[LLMClient, ...]:
        return self._fallbacks

    @property
    def chain_provider_ids(self) -> tuple[str, ...]:
        """All provider ids in order, for telemetry / debugging."""
        return tuple(c.provider_id for c in self._chain)

    async def complete(self, request: CompletionRequest) -> Completion:
        """Try the chain; return the first successful completion."""
        result = await self.complete_with_route(request)
        return result.completion

    async def complete_with_route(
        self,
        request: CompletionRequest,
    ) -> RoutingResult:
        """Same as :meth:`complete` but also returns routing telemetry."""
        attempted: list[str] = []
        failures: list[LLMProviderError] = []
        for client in self._chain:
            attempted.append(client.provider_id)
            try:
                completion = await client.complete(request)
            except LLMProviderError as exc:
                logger.warning(
                    "LLM provider %s failed; trying next",
                    client.provider_id,
                    extra={
                        "provider": client.provider_id,
                        "error_type": type(exc).__name__,
                        "error_message": str(exc),
                    },
                )
                failures.append(exc)
                continue
            return RoutingResult(
                completion=completion,
                served_by_provider=client.provider_id,
                attempted_providers=tuple(attempted),
            )
        raise AllProvidersFailedError(failures)

    async def aclose(self) -> None:
        """Close every client in the chain.

        We call ``aclose`` on every client even if one raises so a
        failing close on the primary does not leak the fallback's
        connection pool. Any close-time exception is logged and
        suppressed.
        """
        for client in self._chain:
            try:
                await client.aclose()
            except Exception:
                logger.exception(
                    "error while closing LLM client %s",
                    client.provider_id,
                )
