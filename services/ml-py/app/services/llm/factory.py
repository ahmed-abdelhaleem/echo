"""Factory for the LLM client abstraction (T-ML-041).

:func:`build_client_from_env` reads the standard env vars and returns a
fully-configured :class:`RoutingLLMClient`. Construction is strict:
unknown providers, missing API keys, or contradictory settings raise
:class:`LLMConfigurationError` so the gRPC server fails to boot rather
than silently producing a half-configured client.

Recognised environment variables:

- ``ECHO_LLM_PRIMARY``    — Provider id of the primary. Default:
  ``anthropic``. Set to ``mock`` in dev / CI.
- ``ECHO_LLM_FALLBACKS``  — Comma-separated provider ids. Default:
  empty (no fallback). Production sets this to ``openai``.
- ``ECHO_ENV``            — One of ``production`` / ``staging`` /
  ``dev``. ``production`` rejects mock providers in the chain.
- ``ANTHROPIC_API_KEY``   — Anthropic API key, required if Anthropic
  appears in the chain.
- ``ANTHROPIC_MODEL``     — Optional override for the Anthropic model.
- ``OPENAI_API_KEY``      — OpenAI API key.
- ``OPENAI_MODEL``        — Optional override for the OpenAI model.

The factory does *not* perform any network IO; it only constructs the
client objects. Network failures surface on the first ``complete``
call.
"""

from __future__ import annotations

import os
from collections.abc import Iterable

from app.services.llm.anthropic import AnthropicClient
from app.services.llm.base import LLMClient
from app.services.llm.errors import LLMConfigurationError
from app.services.llm.mock import MockLLMClient
from app.services.llm.openai import OpenAIClient
from app.services.llm.routing import RoutingLLMClient

KNOWN_PROVIDERS: tuple[str, ...] = ("anthropic", "openai", "mock")
"""Provider ids the factory recognises. Update when adding a new
provider implementation."""

DEFAULT_PRIMARY: str = "anthropic"
"""What we configure as the primary in production."""


def _build_single(provider_id: str, env: dict[str, str]) -> LLMClient:
    """Construct one provider client from env vars.

    Kept private so tests can call :func:`build_client` with a hand-
    constructed env dict rather than mutating ``os.environ``.
    """
    if provider_id == "anthropic":
        api_key = env.get("ANTHROPIC_API_KEY", "")
        if not api_key:
            raise LLMConfigurationError(
                "ANTHROPIC_API_KEY required when anthropic is in the chain",
            )
        kwargs: dict[str, object] = {"api_key": api_key}
        model = env.get("ANTHROPIC_MODEL")
        if model:
            kwargs["model"] = model
        return AnthropicClient(**kwargs)  # type: ignore[arg-type]
    if provider_id == "openai":
        api_key = env.get("OPENAI_API_KEY", "")
        if not api_key:
            raise LLMConfigurationError(
                "OPENAI_API_KEY required when openai is in the chain",
            )
        kwargs2: dict[str, object] = {"api_key": api_key}
        model = env.get("OPENAI_MODEL")
        if model:
            kwargs2["model"] = model
        organization = env.get("OPENAI_ORGANIZATION")
        if organization:
            kwargs2["organization"] = organization
        return OpenAIClient(**kwargs2)  # type: ignore[arg-type]
    if provider_id == "mock":
        return MockLLMClient()
    raise LLMConfigurationError(
        f"unknown LLM provider {provider_id!r}; known: {KNOWN_PROVIDERS}",
    )


def build_client(
    *,
    primary: str,
    fallbacks: Iterable[str] = (),
    env: dict[str, str] | None = None,
) -> RoutingLLMClient:
    """Build a :class:`RoutingLLMClient` from explicit settings.

    Used by tests and by :func:`build_client_from_env`. Production
    callers should prefer the latter so the env-var contract stays
    in one place.

    Args:
        primary: Provider id of the primary client.
        fallbacks: Provider ids for the fallback chain, in order.
        env: Environment variables to read. Defaults to ``os.environ``.

    Raises:
        LLMConfigurationError: on unknown providers, missing API keys,
            duplicate providers in the chain, or production deploys
            that try to use ``mock``.
    """
    if env is None:
        env = dict(os.environ)

    chain = [primary, *list(fallbacks)]
    if len(set(chain)) != len(chain):
        raise LLMConfigurationError(
            f"duplicate providers in chain {chain!r}",
        )

    echo_env = env.get("ECHO_ENV", "dev")
    if echo_env == "production" and "mock" in chain:
        raise LLMConfigurationError(
            "mock provider is forbidden in production (ECHO_ENV=production)",
        )

    primary_client = _build_single(primary, env)
    fallback_clients = [_build_single(fid, env) for fid in fallbacks]
    return RoutingLLMClient(primary=primary_client, fallbacks=fallback_clients)


def build_client_from_env(
    env: dict[str, str] | None = None,
) -> RoutingLLMClient:
    """Build the production routing client from environment variables.

    Defaults:
        - ``ECHO_LLM_PRIMARY=anthropic``
        - ``ECHO_LLM_FALLBACKS=`` (no fallback)

    In a dev shell where no env vars are set, the constructor will
    raise on the missing Anthropic API key. To get a working client
    for local dev without provider keys, set ``ECHO_LLM_PRIMARY=mock``.
    """
    if env is None:
        env = dict(os.environ)
    primary = env.get("ECHO_LLM_PRIMARY", DEFAULT_PRIMARY).strip().lower()
    fallbacks_raw = env.get("ECHO_LLM_FALLBACKS", "")
    fallbacks = tuple(fb.strip().lower() for fb in fallbacks_raw.split(",") if fb.strip())
    return build_client(primary=primary, fallbacks=fallbacks, env=env)
