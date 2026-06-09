"""Tests for the LLM client abstraction (T-ML-041).

Covers:
- :class:`CompletionRequest` validation
- :class:`MockLLMClient` deterministic behaviour
- :class:`RoutingLLMClient` happy-path, primary-fail-fallback-success,
  all-fail, and chain ordering. **The primary-fail-fallback-success
  test is the T-ML-041 acceptance criterion: "a forced failure on the
  primary routes to the fallback with no caller change."**
- Provider stubs (Anthropic, OpenAI) raise NotImplementedError so
  routing never silently uses them.
- :func:`build_client` / :func:`build_client_from_env` factory paths.
"""

from __future__ import annotations

import pytest

from app.services.llm import (
    AllProvidersFailedError,
    Completion,
    CompletionRequest,
    LLMClient,
    LLMConfigurationError,
    LLMProviderTimeoutError,
    Message,
    MockLLMClient,
    RoutingLLMClient,
    build_client,
    build_client_from_env,
)
from app.services.llm.anthropic import AnthropicClient
from app.services.llm.errors import (
    LLMProviderContentFilterError,
    LLMProviderHTTPError,
)
from app.services.llm.openai import OpenAIClient

# ---------------------------------------------------------------------------
# CompletionRequest validation
# ---------------------------------------------------------------------------


def _basic_request(text: str = "hello") -> CompletionRequest:
    return CompletionRequest(
        messages=(Message(role="user", content=text),),
    )


def test_completion_request_requires_messages() -> None:
    with pytest.raises(ValueError):
        CompletionRequest(messages=())


def test_completion_request_requires_user_message() -> None:
    with pytest.raises(ValueError):
        CompletionRequest(
            messages=(Message(role="system", content="x"),),
        )


def test_completion_request_rejects_invalid_temperature() -> None:
    with pytest.raises(ValueError):
        CompletionRequest(
            messages=(Message(role="user", content="hi"),),
            temperature=3.0,
        )


def test_completion_request_rejects_zero_max_output_tokens() -> None:
    with pytest.raises(ValueError):
        CompletionRequest(
            messages=(Message(role="user", content="hi"),),
            max_output_tokens=0,
        )


# ---------------------------------------------------------------------------
# MockLLMClient
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_mock_client_echoes_last_user_message() -> None:
    client = MockLLMClient()
    req = CompletionRequest(
        messages=(
            Message(role="system", content="be terse"),
            Message(role="user", content="hello world"),
        ),
    )
    result = await client.complete(req)
    assert isinstance(result, Completion)
    assert result.provider == "mock"
    assert "hello world" in result.text
    assert result.finish_reason == "stop"


@pytest.mark.asyncio
async def test_mock_client_satisfies_llm_client_protocol() -> None:
    """LLMClient is runtime-checkable; the mock must satisfy it."""
    client: LLMClient = MockLLMClient()
    # Module-level isinstance check on a Protocol just verifies
    # attribute presence; explicit assert proves the typing contract
    # holds at runtime too.
    assert isinstance(client, LLMClient)


@pytest.mark.asyncio
async def test_mock_client_raises_configured_exception() -> None:
    client = MockLLMClient(raises=LLMProviderTimeoutError)
    with pytest.raises(LLMProviderTimeoutError):
        await client.complete(_basic_request())


@pytest.mark.asyncio
async def test_mock_client_call_count_increments_on_each_call() -> None:
    client = MockLLMClient()
    assert client.call_count == 0
    await client.complete(_basic_request("a"))
    await client.complete(_basic_request("b"))
    assert client.call_count == 2


# ---------------------------------------------------------------------------
# RoutingLLMClient — happy path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_router_returns_primary_response_when_primary_succeeds() -> None:
    primary = MockLLMClient(provider_id="primary")
    fallback = MockLLMClient(provider_id="fallback")
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])

    out = await router.complete(_basic_request())

    assert out.provider == "primary"
    assert primary.call_count == 1
    assert fallback.call_count == 0


@pytest.mark.asyncio
async def test_router_complete_with_route_returns_telemetry() -> None:
    primary = MockLLMClient(provider_id="primary")
    fallback = MockLLMClient(provider_id="fallback")
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])

    result = await router.complete_with_route(_basic_request())

    assert result.served_by_provider == "primary"
    assert result.attempted_providers == ("primary",)
    assert result.completion.provider == "primary"


# ---------------------------------------------------------------------------
# RoutingLLMClient — T-ML-041 acceptance criterion
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_router_falls_back_on_primary_failure() -> None:
    """T-ML-041 acceptance: a forced failure on primary routes to
    fallback with no caller change.

    The caller calls ``router.complete(req)`` exactly once and
    receives a Completion from the fallback provider, with no
    awareness that the primary failed.
    """
    primary = MockLLMClient(
        provider_id="primary",
        raises=LLMProviderTimeoutError,
    )
    fallback = MockLLMClient(provider_id="fallback")
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])

    out = await router.complete(_basic_request())

    assert out.provider == "fallback", "router should have returned the fallback's response"
    assert primary.call_count == 1
    assert fallback.call_count == 1


@pytest.mark.asyncio
async def test_router_falls_back_on_http_error() -> None:
    primary = MockLLMClient(
        provider_id="primary",
        raises=LLMProviderHTTPError,
    )
    fallback = MockLLMClient(provider_id="fallback")
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])

    out = await router.complete(_basic_request())

    assert out.provider == "fallback"


@pytest.mark.asyncio
async def test_router_falls_back_on_content_filter() -> None:
    """Content-filter from the primary's safety stack is a routable
    failure — the router tries the fallback. (The pipeline's own
    classifiers handle *post-completion* safety differently.)"""
    primary = MockLLMClient(
        provider_id="primary",
        raises=LLMProviderContentFilterError,
    )
    fallback = MockLLMClient(provider_id="fallback")
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])

    out = await router.complete(_basic_request())
    assert out.provider == "fallback"


@pytest.mark.asyncio
async def test_router_walks_chain_in_order_until_one_succeeds() -> None:
    """The chain is tried in declared order; the first success wins."""
    a = MockLLMClient(provider_id="a", raises=LLMProviderTimeoutError)
    b = MockLLMClient(provider_id="b", raises=LLMProviderTimeoutError)
    c = MockLLMClient(provider_id="c")  # succeeds
    d = MockLLMClient(provider_id="d")  # would succeed too
    router = RoutingLLMClient(primary=a, fallbacks=[b, c, d])

    result = await router.complete_with_route(_basic_request())

    assert result.served_by_provider == "c"
    assert result.attempted_providers == ("a", "b", "c")
    assert d.call_count == 0, "router should stop at first success"


@pytest.mark.asyncio
async def test_router_raises_all_providers_failed_when_chain_exhausted() -> None:
    a = MockLLMClient(provider_id="a", raises=LLMProviderTimeoutError)
    b = MockLLMClient(provider_id="b", raises=LLMProviderHTTPError)
    router = RoutingLLMClient(primary=a, fallbacks=[b])

    with pytest.raises(AllProvidersFailedError) as exc_info:
        await router.complete(_basic_request())

    err = exc_info.value
    assert len(err.failures) == 2
    assert {f.provider for f in err.failures} == {"a", "b"}


@pytest.mark.asyncio
async def test_router_raises_immediately_when_no_fallbacks_and_primary_fails() -> None:
    a = MockLLMClient(provider_id="a", raises=LLMProviderTimeoutError)
    router = RoutingLLMClient(primary=a)

    with pytest.raises(AllProvidersFailedError):
        await router.complete(_basic_request())


@pytest.mark.asyncio
async def test_router_does_not_retry_same_provider_twice() -> None:
    """The router contract is one attempt per provider. Per-provider
    retry policy is the provider client's responsibility."""
    primary = MockLLMClient(provider_id="primary", raises=LLMProviderTimeoutError)
    fallback = MockLLMClient(provider_id="fallback")
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])

    await router.complete(_basic_request())
    assert primary.call_count == 1


def test_router_chain_provider_ids_lists_all_providers_in_order() -> None:
    primary = MockLLMClient(provider_id="primary")
    fallback_a = MockLLMClient(provider_id="fallback-a")
    fallback_b = MockLLMClient(provider_id="fallback-b")
    router = RoutingLLMClient(
        primary=primary,
        fallbacks=[fallback_a, fallback_b],
    )
    assert router.chain_provider_ids == ("primary", "fallback-a", "fallback-b")


def test_router_rejects_none_primary() -> None:
    with pytest.raises(ValueError):
        RoutingLLMClient(primary=None)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Router.aclose
# ---------------------------------------------------------------------------


class _CountingCloseClient(MockLLMClient):
    def __init__(self) -> None:
        super().__init__(provider_id="counting")
        self.close_count = 0

    async def aclose(self) -> None:
        self.close_count += 1


@pytest.mark.asyncio
async def test_router_aclose_closes_every_client_in_chain() -> None:
    primary = _CountingCloseClient()
    fallback = _CountingCloseClient()
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])
    await router.aclose()
    assert primary.close_count == 1
    assert fallback.close_count == 1


class _BrokenCloseClient(MockLLMClient):
    async def aclose(self) -> None:
        raise RuntimeError("close failed")


@pytest.mark.asyncio
async def test_router_aclose_continues_after_broken_close() -> None:
    """A failing close on one client should not skip closing the others."""
    primary = _BrokenCloseClient(provider_id="broken")
    fallback = _CountingCloseClient()
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])
    await router.aclose()  # must not raise
    assert fallback.close_count == 1


# ---------------------------------------------------------------------------
# Anthropic + OpenAI stubs
# ---------------------------------------------------------------------------


def test_anthropic_rejects_empty_api_key() -> None:
    with pytest.raises(LLMConfigurationError):
        AnthropicClient(api_key="")


def test_anthropic_rejects_unknown_model() -> None:
    with pytest.raises(LLMConfigurationError):
        AnthropicClient(api_key="sk-x", model="claude-2.0")


def test_anthropic_accepts_known_model() -> None:
    c = AnthropicClient(api_key="sk-x", model="claude-3-5-sonnet-20241022")
    assert c.model == "claude-3-5-sonnet-20241022"


def test_anthropic_rejects_nonpositive_timeout() -> None:
    with pytest.raises(LLMConfigurationError):
        AnthropicClient(api_key="sk-x", timeout_seconds=0)


@pytest.mark.asyncio
async def test_anthropic_complete_raises_not_implemented() -> None:
    """Routing should never hit the real wire impl in PR C; ensure
    accidental routes surface."""
    c = AnthropicClient(api_key="sk-x")
    with pytest.raises(NotImplementedError):
        await c.complete(_basic_request())


def test_openai_rejects_empty_api_key() -> None:
    with pytest.raises(LLMConfigurationError):
        OpenAIClient(api_key="")


def test_openai_rejects_unknown_model() -> None:
    with pytest.raises(LLMConfigurationError):
        OpenAIClient(api_key="sk-x", model="gpt-3.5-turbo")


def test_openai_accepts_known_model() -> None:
    c = OpenAIClient(api_key="sk-x", model="gpt-4o-mini-2024-07-18")
    assert c.model == "gpt-4o-mini-2024-07-18"


@pytest.mark.asyncio
async def test_openai_complete_raises_not_implemented() -> None:
    c = OpenAIClient(api_key="sk-x")
    with pytest.raises(NotImplementedError):
        await c.complete(_basic_request())


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def test_build_client_with_mock_primary_no_fallback() -> None:
    router = build_client(primary="mock", env={})
    assert router.primary.provider_id == "mock"
    assert router.fallbacks == ()


def test_build_client_rejects_unknown_provider() -> None:
    with pytest.raises(LLMConfigurationError):
        build_client(primary="grok", env={})


def test_build_client_rejects_duplicate_providers() -> None:
    with pytest.raises(LLMConfigurationError):
        build_client(primary="mock", fallbacks=["mock"], env={})


def test_build_client_requires_anthropic_key_when_anthropic_in_chain() -> None:
    with pytest.raises(LLMConfigurationError) as exc:
        build_client(primary="anthropic", env={})
    assert "ANTHROPIC_API_KEY" in str(exc.value)


def test_build_client_constructs_anthropic_when_key_present() -> None:
    router = build_client(
        primary="anthropic",
        env={"ANTHROPIC_API_KEY": "sk-test"},
    )
    assert router.primary.provider_id == "anthropic"


def test_build_client_constructs_mixed_chain_with_keys_present() -> None:
    router = build_client(
        primary="anthropic",
        fallbacks=["openai"],
        env={
            "ANTHROPIC_API_KEY": "sk-a",
            "OPENAI_API_KEY": "sk-o",
        },
    )
    assert router.chain_provider_ids == ("anthropic", "openai")


def test_build_client_rejects_mock_in_production() -> None:
    with pytest.raises(LLMConfigurationError) as exc:
        build_client(
            primary="mock",
            env={"ECHO_ENV": "production"},
        )
    assert "production" in str(exc.value).lower()


def test_build_client_from_env_uses_default_primary() -> None:
    """Default primary is anthropic; without an API key it should
    raise so misconfigured production deploys fail loud."""
    with pytest.raises(LLMConfigurationError):
        build_client_from_env(env={})


def test_build_client_from_env_with_mock_primary_works_for_dev() -> None:
    router = build_client_from_env(env={"ECHO_LLM_PRIMARY": "mock"})
    assert router.primary.provider_id == "mock"


def test_build_client_from_env_parses_fallback_list() -> None:
    router = build_client_from_env(
        env={
            "ECHO_LLM_PRIMARY": "anthropic",
            "ECHO_LLM_FALLBACKS": "openai,mock",
            "ANTHROPIC_API_KEY": "sk-a",
            "OPENAI_API_KEY": "sk-o",
        },
    )
    assert router.chain_provider_ids == ("anthropic", "openai", "mock")


def test_build_client_from_env_trims_whitespace_in_fallback_list() -> None:
    router = build_client_from_env(
        env={
            "ECHO_LLM_PRIMARY": "mock",
            "ECHO_LLM_FALLBACKS": "  ,  ,  ",  # blank entries only
        },
    )
    assert router.fallbacks == ()


def test_build_client_from_env_anthropic_model_override() -> None:
    router = build_client_from_env(
        env={
            "ECHO_LLM_PRIMARY": "anthropic",
            "ANTHROPIC_API_KEY": "sk-a",
            "ANTHROPIC_MODEL": "claude-3-5-haiku-20241022",
        },
    )
    primary = router.primary
    assert isinstance(primary, AnthropicClient)
    assert primary.model == "claude-3-5-haiku-20241022"
