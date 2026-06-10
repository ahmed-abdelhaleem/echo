"""Tests for the asset-gen provider abstraction (T-ML-050).

Covers:
- :func:`compute_content_address` determinism and canonical-form guarantees.
- :class:`SelfHostedProvider` happy path.
- :class:`MeshyProvider` configuration validation and stub failure.
- :class:`RoutingAssetGenProvider` happy-path, primary-fail-fallback-success,
  all-fail, chain ordering, and close behaviour.
  **The primary-fail-fallback-success test is the T-ML-050 acceptance
  criterion: "a forced failure on the primary routes to the fallback with
  no caller change."**
- :func:`build_provider` / :func:`build_provider_from_env` factory paths.
"""

from __future__ import annotations

import pytest

from app.services.asset_gen import (
    AllAssetGenProvidersFailedError,
    AssetGenConfigurationError,
    AssetGenProvider,
    AssetGenProviderError,
    AssetGenProviderHTTPError,
    AssetGenProviderTimeoutError,
    AssetGenRequest,
    AssetGenResult,
    GenerationInputs,
    MeshyProvider,
    Reference,
    RoutingAssetGenProvider,
    RoutingResult,
    SelfHostedProvider,
    build_provider,
    build_provider_from_env,
    compute_content_address,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _basic_inputs(prompt: str = "A worn leather satchel") -> GenerationInputs:
    return GenerationInputs(
        kind="prop",
        provider="self-hosted",
        mode="text-to-3d",
        prompt=prompt,
        pipeline_version=1,
    )


def _basic_request(prompt: str = "A worn leather satchel") -> AssetGenRequest:
    return AssetGenRequest(inputs=_basic_inputs(prompt), asset_id="test-asset")


# ---------------------------------------------------------------------------
# GenerationInputs validation
# ---------------------------------------------------------------------------


def test_generation_inputs_rejects_empty_prompt() -> None:
    with pytest.raises(ValueError, match="prompt"):
        GenerationInputs(
            kind="prop",
            provider="self-hosted",
            mode="text-to-3d",
            prompt="",
            pipeline_version=1,
        )


def test_generation_inputs_rejects_zero_pipeline_version() -> None:
    with pytest.raises(ValueError, match="pipeline_version"):
        GenerationInputs(
            kind="prop",
            provider="self-hosted",
            mode="text-to-3d",
            prompt="hello",
            pipeline_version=0,
        )


def test_generation_inputs_rejects_image_to_3d_without_references() -> None:
    with pytest.raises(ValueError, match="references"):
        GenerationInputs(
            kind="prop",
            provider="self-hosted",
            mode="image-to-3d",
            prompt="hello",
            pipeline_version=1,
            references=(),  # empty for image-to-3d
        )


def test_generation_inputs_accepts_image_to_3d_with_references() -> None:
    inputs = GenerationInputs(
        kind="environment",
        provider="self-hosted",
        mode="image-to-3d",
        prompt="rainy street",
        pipeline_version=1,
        references=(Reference(uri="https://cdn.example/ref.jpg"),),
    )
    assert inputs.mode == "image-to-3d"
    assert len(inputs.references) == 1


# ---------------------------------------------------------------------------
# content_address — T-ML-050 AC2: identical inputs → same address
# ---------------------------------------------------------------------------


def test_content_address_deterministic() -> None:
    """T-ML-050 AC2: identical inputs produce the same content-address."""
    inputs = _basic_inputs()
    addr1 = compute_content_address(inputs)
    addr2 = compute_content_address(inputs)
    assert addr1 == addr2, "content-address must be deterministic"


def test_content_address_has_sha256_prefix() -> None:
    addr = compute_content_address(_basic_inputs())
    assert addr.startswith("sha256:"), f"expected sha256: prefix, got {addr!r}"
    assert len(addr) == 7 + 64, f"expected 71 chars total, got {len(addr)}"


def test_content_address_different_prompts_differ() -> None:
    addr_a = compute_content_address(_basic_inputs("A worn leather satchel"))
    addr_b = compute_content_address(_basic_inputs("A polished obsidian mirror"))
    assert addr_a != addr_b


def test_content_address_different_pipeline_versions_differ() -> None:
    inputs_v1 = GenerationInputs(
        kind="prop", provider="meshy", mode="text-to-3d", prompt="chair", pipeline_version=1
    )
    inputs_v2 = GenerationInputs(
        kind="prop", provider="meshy", mode="text-to-3d", prompt="chair", pipeline_version=2
    )
    assert compute_content_address(inputs_v1) != compute_content_address(inputs_v2)


def test_content_address_params_key_order_does_not_matter() -> None:
    """Canonical JSON sorts keys so insertion order doesn't change the hash."""
    inputs_ab = GenerationInputs(
        kind="prop",
        provider="meshy",
        mode="text-to-3d",
        prompt="chair",
        pipeline_version=1,
        params={"art_style": "realistic", "pbr": True},
    )
    inputs_ba = GenerationInputs(
        kind="prop",
        provider="meshy",
        mode="text-to-3d",
        prompt="chair",
        pipeline_version=1,
        params={"pbr": True, "art_style": "realistic"},
    )
    assert compute_content_address(inputs_ab) == compute_content_address(inputs_ba)


def test_content_address_reference_sha256_included() -> None:
    """A reference with a sha256 must produce a different address than one without."""
    ref_without = Reference(uri="https://cdn.example/img.jpg")
    ref_with = Reference(uri="https://cdn.example/img.jpg", sha256="a" * 64)
    inputs_without = GenerationInputs(
        kind="environment",
        provider="self-hosted",
        mode="image-to-3d",
        prompt="forest",
        pipeline_version=1,
        references=(ref_without,),
    )
    inputs_with = GenerationInputs(
        kind="environment",
        provider="self-hosted",
        mode="image-to-3d",
        prompt="forest",
        pipeline_version=1,
        references=(ref_with,),
    )
    assert compute_content_address(inputs_without) != compute_content_address(inputs_with)


# ---------------------------------------------------------------------------
# SelfHostedProvider
# ---------------------------------------------------------------------------


def test_self_hosted_returns_glb_bytes() -> None:
    provider = SelfHostedProvider()
    result = provider.generate(_basic_request())
    assert result.glb_bytes is not None
    assert result.glb_bytes[:4] == b"glTF"


def test_self_hosted_content_address_is_sha256() -> None:
    provider = SelfHostedProvider()
    result = provider.generate(_basic_request())
    assert result.content_address.startswith("sha256:")


def test_self_hosted_dry_run_returns_no_bytes() -> None:
    provider = SelfHostedProvider()
    req = AssetGenRequest(inputs=_basic_inputs(), asset_id="dry", dry_run=True)
    result = provider.generate(req)
    assert result.glb_bytes is None
    assert result.content_address.startswith("sha256:")


def test_self_hosted_provider_id() -> None:
    assert SelfHostedProvider().provider_id == "self-hosted"


def test_self_hosted_is_stub() -> None:
    provider = SelfHostedProvider()
    result = provider.generate(_basic_request())
    assert result.is_stub is True


def test_self_hosted_satisfies_protocol() -> None:
    provider: AssetGenProvider = SelfHostedProvider()
    assert isinstance(provider, AssetGenProvider)


# ---------------------------------------------------------------------------
# MeshyProvider
# ---------------------------------------------------------------------------


def test_meshy_rejects_empty_api_key() -> None:
    with pytest.raises(AssetGenConfigurationError, match="MESHY_API_KEY"):
        MeshyProvider(api_key="")


def test_meshy_accepts_non_empty_api_key() -> None:
    provider = MeshyProvider(api_key="sk-test")
    assert provider.provider_id == "meshy"


def test_meshy_generate_raises_provider_error() -> None:
    """Stub behaviour: generate always raises AssetGenProviderError."""
    provider = MeshyProvider(api_key="sk-test")
    with pytest.raises(AssetGenProviderError) as exc_info:
        provider.generate(_basic_request())
    assert exc_info.value.provider == "meshy"


def test_meshy_dry_run_returns_content_address() -> None:
    """Dry-run must not raise even when the provider is a stub."""
    provider = MeshyProvider(api_key="sk-test")
    req = AssetGenRequest(inputs=_basic_inputs(), asset_id="dry", dry_run=True)
    result = provider.generate(req)
    assert result.content_address.startswith("sha256:")
    assert result.glb_bytes is None


# ---------------------------------------------------------------------------
# RoutingAssetGenProvider — happy path
# ---------------------------------------------------------------------------


class _MockProvider:
    """In-test provider: succeeds or raises on demand."""

    def __init__(
        self,
        provider_id: str = "mock",
        raises: type[AssetGenProviderError] | None = None,
    ) -> None:
        self.provider_id = provider_id
        self._raises = raises
        self.call_count = 0
        self.close_count = 0

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        self.call_count += 1
        if self._raises is not None:
            if issubclass(self._raises, AssetGenProviderHTTPError):
                raise self._raises(
                    f"{self.provider_id} failed",
                    provider=self.provider_id,
                    status_code=503,
                )
            raise self._raises(f"{self.provider_id} failed", provider=self.provider_id)
        addr = compute_content_address(request.inputs)
        return AssetGenResult(
            content_address=addr,
            provider_used=self.provider_id,
            glb_bytes=b"glTF\x02\x00\x00\x00\x0c\x00\x00\x00",
            is_stub=True,
        )

    def close(self) -> None:
        self.close_count += 1


def test_router_returns_primary_on_success() -> None:
    primary = _MockProvider(provider_id="primary")
    fallback = _MockProvider(provider_id="fallback")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])

    result = router.generate(_basic_request())

    assert result.provider_used == "primary"
    assert primary.call_count == 1
    assert fallback.call_count == 0


def test_router_complete_with_route_returns_telemetry() -> None:
    primary = _MockProvider(provider_id="primary")
    fallback = _MockProvider(provider_id="fallback")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])

    route: RoutingResult = router.generate_with_route(_basic_request())

    assert route.served_by_provider == "primary"
    assert route.attempted_providers == ("primary",)
    assert route.result.provider_used == "primary"


# ---------------------------------------------------------------------------
# T-ML-050 Acceptance Criterion 1: forced primary failure → fallback, no caller change
# ---------------------------------------------------------------------------


def test_router_falls_back_on_primary_failure() -> None:
    """T-ML-050 AC1: a forced failure on the primary routes to the fallback
    with no caller change.

    The caller calls ``router.generate(req)`` exactly once and receives an
    AssetGenResult from the fallback provider, with no awareness that the
    primary failed.
    """
    primary = _MockProvider(provider_id="primary", raises=AssetGenProviderError)
    fallback = _MockProvider(provider_id="fallback")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])

    result = router.generate(_basic_request())

    assert result.provider_used == "fallback", "router must return fallback's result"
    assert primary.call_count == 1
    assert fallback.call_count == 1


def test_router_falls_back_on_timeout_error() -> None:
    primary = _MockProvider(provider_id="primary", raises=AssetGenProviderTimeoutError)
    fallback = _MockProvider(provider_id="fallback")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])

    result = router.generate(_basic_request())
    assert result.provider_used == "fallback"


def test_router_falls_back_on_http_error() -> None:
    primary = _MockProvider(provider_id="primary", raises=AssetGenProviderHTTPError)
    fallback = _MockProvider(provider_id="fallback")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])

    result = router.generate(_basic_request())
    assert result.provider_used == "fallback"


def test_router_walks_chain_in_order_until_one_succeeds() -> None:
    """The chain is tried in declared order; the first success wins."""
    a = _MockProvider(provider_id="a", raises=AssetGenProviderTimeoutError)
    b = _MockProvider(provider_id="b", raises=AssetGenProviderTimeoutError)
    c = _MockProvider(provider_id="c")  # succeeds
    d = _MockProvider(provider_id="d")  # would succeed too

    router = RoutingAssetGenProvider(primary=a, fallbacks=[b, c, d])
    route = router.generate_with_route(_basic_request())

    assert route.served_by_provider == "c"
    assert route.attempted_providers == ("a", "b", "c")
    assert d.call_count == 0, "router must stop at first success"


def test_router_raises_all_failed_when_chain_exhausted() -> None:
    a = _MockProvider(provider_id="a", raises=AssetGenProviderTimeoutError)
    b = _MockProvider(provider_id="b", raises=AssetGenProviderHTTPError)
    router = RoutingAssetGenProvider(primary=a, fallbacks=[b])

    with pytest.raises(AllAssetGenProvidersFailedError) as exc_info:
        router.generate(_basic_request())

    err = exc_info.value
    assert len(err.failures) == 2
    assert {f.provider for f in err.failures} == {"a", "b"}


def test_router_raises_immediately_with_no_fallbacks_and_primary_fails() -> None:
    a = _MockProvider(provider_id="a", raises=AssetGenProviderTimeoutError)
    router = RoutingAssetGenProvider(primary=a)

    with pytest.raises(AllAssetGenProvidersFailedError):
        router.generate(_basic_request())


def test_router_does_not_retry_same_provider() -> None:
    """One attempt per provider. Per-provider retry is provider's responsibility."""
    primary = _MockProvider(provider_id="primary", raises=AssetGenProviderTimeoutError)
    fallback = _MockProvider(provider_id="fallback")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])

    router.generate(_basic_request())
    assert primary.call_count == 1


def test_router_chain_provider_ids() -> None:
    a = _MockProvider(provider_id="a")
    b = _MockProvider(provider_id="b")
    c = _MockProvider(provider_id="c")
    router = RoutingAssetGenProvider(primary=a, fallbacks=[b, c])
    assert router.chain_provider_ids == ("a", "b", "c")


def test_router_rejects_none_primary() -> None:
    with pytest.raises(ValueError):
        RoutingAssetGenProvider(primary=None)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# Router.close
# ---------------------------------------------------------------------------


def test_router_close_closes_every_provider() -> None:
    primary = _MockProvider(provider_id="p")
    fallback = _MockProvider(provider_id="f")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])
    router.close()
    assert primary.close_count == 1
    assert fallback.close_count == 1


class _BrokenCloseProvider(_MockProvider):
    def close(self) -> None:
        raise RuntimeError("close failed")


def test_router_close_continues_after_broken_close() -> None:
    """A failing close on one provider must not skip closing the others."""
    primary = _BrokenCloseProvider(provider_id="broken")
    fallback = _MockProvider(provider_id="f")
    router = RoutingAssetGenProvider(primary=primary, fallbacks=[fallback])
    router.close()  # must not raise
    assert fallback.close_count == 1


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def test_build_provider_with_self_hosted_primary_no_fallback() -> None:
    router = build_provider(primary="self-hosted", env={})
    assert router.primary.provider_id == "self-hosted"
    assert router.fallbacks == ()


def test_build_provider_rejects_unknown_provider() -> None:
    with pytest.raises(AssetGenConfigurationError, match="unknown"):
        build_provider(primary="dalle", env={})


def test_build_provider_rejects_duplicate_providers() -> None:
    with pytest.raises(AssetGenConfigurationError, match="duplicate"):
        build_provider(primary="self-hosted", fallbacks=["self-hosted"], env={})


def test_build_provider_requires_meshy_key_when_meshy_in_chain() -> None:
    with pytest.raises(AssetGenConfigurationError, match="MESHY_API_KEY"):
        build_provider(primary="meshy", env={})


def test_build_provider_constructs_meshy_when_key_present() -> None:
    router = build_provider(primary="meshy", env={"MESHY_API_KEY": "sk-test"})
    assert router.primary.provider_id == "meshy"


def test_build_provider_constructs_mixed_chain() -> None:
    router = build_provider(
        primary="meshy",
        fallbacks=["self-hosted"],
        env={"MESHY_API_KEY": "sk-test"},
    )
    assert router.chain_provider_ids == ("meshy", "self-hosted")


def test_build_provider_from_env_uses_default_primary() -> None:
    """Default primary is meshy; without an API key it should raise so
    misconfigured production deploys fail loud."""
    with pytest.raises(AssetGenConfigurationError):
        build_provider_from_env(env={})


def test_build_provider_from_env_self_hosted_works_for_dev() -> None:
    router = build_provider_from_env(
        env={"ECHO_ASSET_GEN_PRIMARY": "self-hosted", "ECHO_ASSET_GEN_FALLBACKS": ""}
    )
    assert router.primary.provider_id == "self-hosted"


def test_build_provider_from_env_parses_fallback_list() -> None:
    router = build_provider_from_env(
        env={
            "ECHO_ASSET_GEN_PRIMARY": "meshy",
            "ECHO_ASSET_GEN_FALLBACKS": "self-hosted",
            "MESHY_API_KEY": "sk-test",
        },
    )
    assert router.chain_provider_ids == ("meshy", "self-hosted")


def test_build_provider_from_env_trims_whitespace_in_fallback_list() -> None:
    router = build_provider_from_env(
        env={
            "ECHO_ASSET_GEN_PRIMARY": "self-hosted",
            "ECHO_ASSET_GEN_FALLBACKS": "  ,  ,  ",  # blank entries only
        },
    )
    assert router.fallbacks == ()


# ---------------------------------------------------------------------------
# Integration: meshy → self-hosted mirrors T-ML-050 production topology
# ---------------------------------------------------------------------------


def test_meshy_primary_self_hosted_fallback_production_topology() -> None:
    """End-to-end: MeshyProvider (stub → always fails) routes to
    SelfHostedProvider (stub → returns placeholder GLB).

    This is exactly the T-ML-050 acceptance criterion on real classes,
    not mocks.
    """
    meshy = MeshyProvider(api_key="sk-test")
    self_hosted = SelfHostedProvider()
    router = RoutingAssetGenProvider(primary=meshy, fallbacks=[self_hosted])

    result = router.generate(_basic_request())

    assert result.provider_used == "self-hosted"
    assert result.glb_bytes is not None
    assert result.glb_bytes[:4] == b"glTF"
    assert result.content_address.startswith("sha256:")


def test_content_address_is_same_regardless_of_provider_used() -> None:
    """The content-address is a function of *inputs* not of the provider.

    MeshyProvider (dry_run) and SelfHostedProvider must return the same
    address for the same inputs, since the address is the dedup key.
    """
    inputs = _basic_inputs()
    req = AssetGenRequest(inputs=inputs, asset_id="x", dry_run=True)

    meshy_result = MeshyProvider(api_key="sk-test").generate(req)
    self_result = SelfHostedProvider().generate(req)

    assert meshy_result.content_address == self_result.content_address, (
        "Content-address must be provider-independent"
    )
