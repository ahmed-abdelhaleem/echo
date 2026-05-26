"""LLM client abstraction (T-ML-041).

The reflection pipeline (T-ML-042, PR D) talks to large language models
through the :class:`LLMClient` protocol declared in :mod:`.base`. Concrete
implementations live in their own modules:

- :mod:`.mock`     — deterministic in-memory client used by tests and the
  CI environment, which does not carry API keys.
- :mod:`.anthropic`— Claude 3.5 Sonnet primary provider. **Stub** in this
  PR; the real wire implementation (and the ``anthropic`` SDK dependency)
  lands with the reflection pipeline.
- :mod:`.openai`   — GPT-4o fallback provider. **Stub** in this PR; same
  rationale as Anthropic.
- :mod:`.routing`  — :class:`RoutingLLMClient` chains a primary client
  with an ordered list of fallbacks. T-ML-041's acceptance criterion
  ("forced failure on primary routes to fallback with no caller change")
  is implemented and tested here.
- :mod:`.factory`  — :func:`build_client_from_env` returns the configured
  routing client based on ``ECHO_LLM_PRIMARY`` / ``ECHO_LLM_FALLBACKS``.

This package deliberately ships *zero* new top-level dependencies. The
real provider HTTP calls + their official SDKs land with the pipeline
PR, where they will be guarded by the ``human-review-required`` label
per AGENTS.md §10.1.
"""

from app.services.llm.base import LLMClient
from app.services.llm.errors import (
    AllProvidersFailedError,
    LLMConfigurationError,
    LLMProviderError,
    LLMProviderTimeoutError,
)
from app.services.llm.factory import (
    DEFAULT_PRIMARY,
    KNOWN_PROVIDERS,
    build_client,
    build_client_from_env,
)
from app.services.llm.mock import MockLLMClient
from app.services.llm.routing import RoutingLLMClient, RoutingResult
from app.services.llm.types import (
    Completion,
    CompletionRequest,
    Message,
    Role,
)

__all__ = [
    "DEFAULT_PRIMARY",
    "KNOWN_PROVIDERS",
    "AllProvidersFailedError",
    "Completion",
    "CompletionRequest",
    "LLMClient",
    "LLMConfigurationError",
    "LLMProviderError",
    "LLMProviderTimeoutError",
    "Message",
    "MockLLMClient",
    "Role",
    "RoutingLLMClient",
    "RoutingResult",
    "build_client",
    "build_client_from_env",
]
