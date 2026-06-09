"""OpenAI GPT client (T-ML-041 fallback provider).

**Wire-implementation stub.** Same rationale as
:mod:`app.services.llm.anthropic`: this PR delivers the routing
abstraction; the wire implementation + the ``openai`` Python SDK
dependency land with the pipeline PR.
"""

from __future__ import annotations

from app.services.llm.errors import LLMConfigurationError
from app.services.llm.types import Completion, CompletionRequest

_ALLOWED_MODELS: frozenset[str] = frozenset(
    {
        "gpt-4o-2024-08-06",
        "gpt-4o-mini-2024-07-18",
    },
)

DEFAULT_MODEL: str = "gpt-4o-2024-08-06"
"""Default fallback model. We do not run a smaller model as the
fallback because the fallback path only fires on primary failure, so
the cost amortises across the (rare) failure mode."""


class OpenAIClient:
    """OpenAI GPT client (fallback path)."""

    provider_id: str = "openai"

    def __init__(
        self,
        *,
        api_key: str,
        model: str = DEFAULT_MODEL,
        timeout_seconds: float = 30.0,
        base_url: str = "https://api.openai.com/v1",
        organization: str | None = None,
    ) -> None:
        if not api_key:
            raise LLMConfigurationError("OpenAI API key is required")
        if model not in _ALLOWED_MODELS:
            raise LLMConfigurationError(
                f"unknown OpenAI model {model!r}; allowed: {sorted(_ALLOWED_MODELS)}",
            )
        if timeout_seconds <= 0:
            raise LLMConfigurationError(
                f"timeout_seconds must be positive, got {timeout_seconds}",
            )
        self._api_key = api_key
        self._model = model
        self._timeout_seconds = timeout_seconds
        self._base_url = base_url.rstrip("/")
        self._organization = organization

    @property
    def model(self) -> str:
        return self._model

    async def complete(self, request: CompletionRequest) -> Completion:
        raise NotImplementedError(
            "OpenAIClient.complete: real wire implementation lands in PR D"
            " (T-ML-042). Use MockLLMClient for tests until then.",
        )

    async def aclose(self) -> None:
        return
