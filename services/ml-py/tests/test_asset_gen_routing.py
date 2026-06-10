"""Tests for the asset-gen provider abstraction (T-ML-050).

Covers:
- :func:`compute_content_address` determinism and canonical-form guarantees.
- :class:`TrellisProvider` happy path.
- :class:`MeshyProvider` configuration validation and stub failure.
- :class:`RoutingAssetGenProvider` happy-path, primary-fail-fallback-success,
  all-fail, chain ordering, and close behaviour.
  **The primary-fail-fallback-success test is the T-ML-050 acceptance
  criterion: "a forced failure on the primary routes to the fallback with
  no caller change."**
- :func:`build_provider` / :func:`build_provider_from_env` factory paths.
"""

from __future__ import annotations

import base64
import hashlib
import json
from typing import Any

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
    TrellisProvider,
    build_provider,
    build_provider_from_env,
    compute_content_address,
)

_TEST_GLB = b"glTF\x02\x00\x00\x00\x0c\x00\x00\x00"


class _FakeHTTPResponse:
    def __init__(self, body: bytes = _TEST_GLB) -> None:
        self._body = body

    def read(self, size: int = -1) -> bytes:
        return self._body if size < 0 else self._body[:size]

    def __enter__(self) -> _FakeHTTPResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        pass


@pytest.fixture(autouse=True)
def _stub_trellis_http(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.services.asset_gen.trellis.urlopen",
        lambda *_args, **_kwargs: _FakeHTTPResponse(),
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _basic_inputs(prompt: str = "A worn leather satchel") -> GenerationInputs:
    return GenerationInputs(
        kind="prop",
        provider="trellis",
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
            provider="trellis",
            mode="text-to-3d",
            prompt="",
            pipeline_version=1,
        )


def test_generation_inputs_rejects_zero_pipeline_version() -> None:
    with pytest.raises(ValueError, match="pipeline_version"):
        GenerationInputs(
            kind="prop",
            provider="trellis",
            mode="text-to-3d",
            prompt="hello",
            pipeline_version=0,
        )


def test_generation_inputs_rejects_image_to_3d_without_references() -> None:
    with pytest.raises(ValueError, match="references"):
        GenerationInputs(
            kind="prop",
            provider="trellis",
            mode="image-to-3d",
            prompt="hello",
            pipeline_version=1,
            references=(),  # empty for image-to-3d
        )


def test_generation_inputs_accepts_image_to_3d_with_references() -> None:
    inputs = GenerationInputs(
        kind="environment",
        provider="trellis",
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


# Locks the cross-language algorithm in place. If this value changes,
# the Node validator at tools/content-validator/lib/content_address.js
# will disagree with the server about asset identity — and every
# manifest in content/assets-3d/** carries an address from the Node
# validator, so a drift here silently double-generates every asset.
# This is the same fixture used in tools/content-validator/test/content_address.test.js.
_KNOWN_CROSS_LANGUAGE_ADDRESS = (
    "sha256:6b03ec452f43b2ffc920bb615cd1d76749f3f526a32060ba30d16f788016935c"
)


def test_content_address_matches_node_validator_known_vector() -> None:
    """The Python and Node algorithms must produce byte-identical hashes.

    The fixture matches the one in
    ``tools/content-validator/test/content_address.test.js``. Updating
    one side without the other will fail this test by design.
    """
    inputs = GenerationInputs(
        kind="prop",
        provider="meshy",
        mode="text-to-3d",
        prompt="a chipped enamel coffee mug, half full",
        params={"seed": 7, "pbr": True, "target_polycount": 12000},
        pipeline_version=1,
    )
    assert compute_content_address(inputs) == _KNOWN_CROSS_LANGUAGE_ADDRESS


def test_content_address_matches_node_validator_with_defaults() -> None:
    """Default-valued fields (negative_prompt, references, params) must
    still be hashed — otherwise the Python and Node algorithms drift
    for the common case of a minimal manifest entry."""
    inputs = GenerationInputs(
        kind="prop",
        provider="meshy",
        mode="text-to-3d",
        prompt="A worn leather satchel",
        pipeline_version=1,
    )
    # Computed by running tools/content-validator/lib/content_address.js
    # on the equivalent JSON literal.
    expected = "sha256:cb713e945255cd5ae822ddcfaedfd99b1eaef4f65e77d9bf8ef6f6d03d01d12c"
    assert compute_content_address(inputs) == expected


def test_content_address_matches_stamped_manifest_addresses() -> None:
    """The addresses stamped on content/assets-3d/season-001/assets.manifest.json
    (by the Node validator) must round-trip through the Python algorithm.

    This is the practical version of the cross-language lock: if a real
    manifest ships with content-addresses A/B/C, the Python server must
    look up exactly A/B/C when those same inputs come in. Anything else
    breaks deduplication for assets already in flight.
    """
    # The three real entries in content/assets-3d/season-001/assets.manifest.json,
    # transcribed as GenerationInputs and paired with the addresses that
    # ship in the JSON.
    cases: list[tuple[GenerationInputs, str]] = [
        (
            GenerationInputs(
                kind="environment",
                provider="meshy",
                mode="text-to-3d",
                prompt=(
                    "a small sunlit bedroom at 7am, unmade bed, soft linen, "
                    "a window overlooking a quiet european city, warm muted "
                    "palette, calm and intimate"
                ),
                negative_prompt="people, text, logos, clutter",
                params={
                    "art_style": "stylized-realistic",
                    "target_polycount": 40000,
                    "pbr": True,
                    "seed": 101,
                },
                pipeline_version=1,
            ),
            "sha256:4502d522b4dd28fb7385d388a4a501ffa0f951af0ddd75e7b74e6690343003d9",
        ),
        (
            GenerationInputs(
                kind="prop",
                provider="meshy",
                mode="text-to-3d",
                prompt="a chipped white enamel coffee mug, half full, slight tea stain",
                params={
                    "art_style": "stylized-realistic",
                    "target_polycount": 8000,
                    "pbr": True,
                    "seed": 7,
                },
                pipeline_version=1,
            ),
            "sha256:36c928da02a7ac43c1e1ef52a15af33d4c4b5568f5aefb9962df03ad819ff79a",
        ),
        (
            GenerationInputs(
                kind="environment",
                provider="tripo",
                mode="image-to-3d",
                prompt="an empty city bus stop at dusk, rain just stopped, reflective pavement",
                references=(
                    Reference(uri="r2://echo-content/refs/season-001/bus-stop-evening.png"),
                ),
                params={
                    "art_style": "stylized-realistic",
                    "target_polycount": 35000,
                    "pbr": True,
                },
                pipeline_version=1,
            ),
            "sha256:7220bed9e00872f56c5da83cf3fee46eb06e4bda845f3abce181b83e9117cc34",
        ),
    ]
    for inputs, expected in cases:
        assert compute_content_address(inputs) == expected, (
            f"stamped manifest address drifted from server computation for kind={inputs.kind}"
        )


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
        provider="trellis",
        mode="image-to-3d",
        prompt="forest",
        pipeline_version=1,
        references=(ref_without,),
    )
    inputs_with = GenerationInputs(
        kind="environment",
        provider="trellis",
        mode="image-to-3d",
        prompt="forest",
        pipeline_version=1,
        references=(ref_with,),
    )
    assert compute_content_address(inputs_without) != compute_content_address(inputs_with)


# ---------------------------------------------------------------------------
# TrellisProvider
# ---------------------------------------------------------------------------


def test_trellis_returns_glb_bytes() -> None:
    provider = TrellisProvider(base_url="http://trellis.test")
    result = provider.generate(_basic_request())
    assert result.glb_bytes is not None
    assert result.glb_bytes[:4] == b"glTF"


def test_trellis_content_address_is_sha256() -> None:
    provider = TrellisProvider(base_url="http://trellis.test")
    result = provider.generate(_basic_request())
    assert result.content_address.startswith("sha256:")


def test_trellis_dry_run_returns_no_bytes() -> None:
    provider = TrellisProvider(base_url="http://trellis.test")
    req = AssetGenRequest(inputs=_basic_inputs(), asset_id="dry", dry_run=True)
    result = provider.generate(req)
    assert result.glb_bytes is None
    assert result.content_address.startswith("sha256:")


def test_trellis_provider_id() -> None:
    assert TrellisProvider(base_url="http://trellis.test").provider_id == "trellis"


def test_trellis_rejects_unknown_api_style() -> None:
    with pytest.raises(AssetGenConfigurationError, match="TRELLIS_API_STYLE"):
        TrellisProvider(base_url="http://trellis.test", api_style="metal-maybe")


def test_trellis_sends_generation_inputs(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, Any] = {}

    def fake_urlopen(request: Any, *, timeout: float) -> _FakeHTTPResponse:
        captured["url"] = request.full_url
        captured["payload"] = json.loads(request.data)
        captured["timeout"] = timeout
        return _FakeHTTPResponse()

    monkeypatch.setattr("app.services.asset_gen.trellis.urlopen", fake_urlopen)
    provider = TrellisProvider(base_url="http://trellis.test")
    result = provider.generate(_basic_request())

    assert captured["url"] == "http://trellis.test/v1/generate"
    assert captured["payload"]["prompt"] == "A worn leather satchel"
    assert captured["payload"]["mode"] == "text-to-3d"
    assert captured["timeout"] == 900.0
    assert result.is_stub is False


def test_trellis2_apple_sends_image_and_decodes_glb(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    image_bytes = b"example-image"
    image_sha256 = hashlib.sha256(image_bytes).hexdigest()
    captured: dict[str, Any] = {}

    def fake_urlopen(target: Any, *, timeout: float) -> _FakeHTTPResponse:
        if isinstance(target, str):
            assert target == "https://cdn.example/ref.png"
            assert timeout == 30
            return _FakeHTTPResponse(image_bytes)
        captured["url"] = target.full_url
        captured["payload"] = json.loads(target.data)
        return _FakeHTTPResponse(
            json.dumps({"glb": base64.b64encode(_TEST_GLB).decode("ascii")}).encode()
        )

    monkeypatch.setattr("app.services.asset_gen.trellis.urlopen", fake_urlopen)
    inputs = GenerationInputs(
        kind="prop",
        provider="trellis",
        mode="image-to-3d",
        prompt="A worn leather satchel",
        pipeline_version=1,
        references=(Reference(uri="https://cdn.example/ref.png", sha256=image_sha256),),
        params={"seed": 7, "target_polycount": 250_000, "texture_size": 512},
    )
    provider = TrellisProvider(
        base_url="http://trellis.test",
        api_style="trellis2-apple",
    )

    result = provider.generate(AssetGenRequest(inputs=inputs))

    assert captured["url"] == "http://trellis.test/generate"
    assert base64.b64decode(captured["payload"]["image"]) == image_bytes
    assert captured["payload"]["seed"] == 7
    assert captured["payload"]["decimation_target"] == 250_000
    assert captured["payload"]["texture_size"] == 512
    assert result.glb_bytes == _TEST_GLB


def test_trellis2_apple_rejects_text_to_3d() -> None:
    provider = TrellisProvider(
        base_url="http://trellis.test",
        api_style="trellis2-apple",
    )
    with pytest.raises(AssetGenProviderError, match="image-to-3d"):
        provider.generate(_basic_request())


def test_trellis_rejects_invalid_glb(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        "app.services.asset_gen.trellis.urlopen",
        lambda *_args, **_kwargs: _FakeHTTPResponse(b"not a glb"),
    )
    provider = TrellisProvider(base_url="http://trellis.test")
    with pytest.raises(AssetGenProviderError, match="invalid GLB"):
        provider.generate(_basic_request())


def test_trellis_maps_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    def time_out(*_args: object, **_kwargs: object) -> _FakeHTTPResponse:
        raise TimeoutError

    monkeypatch.setattr("app.services.asset_gen.trellis.urlopen", time_out)
    provider = TrellisProvider(base_url="http://trellis.test")
    with pytest.raises(AssetGenProviderTimeoutError):
        provider.generate(_basic_request())


def test_trellis_satisfies_protocol() -> None:
    provider: AssetGenProvider = TrellisProvider(base_url="http://trellis.test")
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


def test_build_provider_with_trellis_primary_no_fallback() -> None:
    router = build_provider(primary="trellis", env={})
    assert router.primary.provider_id == "trellis"
    assert router.fallbacks == ()


def test_build_provider_rejects_unknown_provider() -> None:
    with pytest.raises(AssetGenConfigurationError, match="unknown"):
        build_provider(primary="dalle", env={})


def test_build_provider_rejects_duplicate_providers() -> None:
    with pytest.raises(AssetGenConfigurationError, match="duplicate"):
        build_provider(primary="trellis", fallbacks=["trellis"], env={})


def test_build_provider_rejects_unknown_trellis_api_style() -> None:
    with pytest.raises(AssetGenConfigurationError, match="TRELLIS_API_STYLE"):
        build_provider(
            primary="trellis",
            env={"TRELLIS_API_STYLE": "metal-maybe"},
        )


def test_build_provider_requires_meshy_key_when_meshy_in_chain() -> None:
    with pytest.raises(AssetGenConfigurationError, match="MESHY_API_KEY"):
        build_provider(primary="meshy", env={})


def test_build_provider_constructs_meshy_when_key_present() -> None:
    router = build_provider(primary="meshy", env={"MESHY_API_KEY": "sk-test"})
    assert router.primary.provider_id == "meshy"


def test_build_provider_constructs_mixed_chain() -> None:
    router = build_provider(
        primary="meshy",
        fallbacks=["trellis"],
        env={"MESHY_API_KEY": "sk-test"},
    )
    assert router.chain_provider_ids == ("meshy", "trellis")


def test_build_provider_from_env_uses_default_primary() -> None:
    """Default primary is meshy; without an API key it should raise so
    misconfigured production deploys fail loud."""
    with pytest.raises(AssetGenConfigurationError):
        build_provider_from_env(env={})


def test_build_provider_from_env_trellis_works_for_dev() -> None:
    router = build_provider_from_env(
        env={"ECHO_ASSET_GEN_PRIMARY": "trellis", "ECHO_ASSET_GEN_FALLBACKS": ""}
    )
    assert router.primary.provider_id == "trellis"


def test_build_provider_from_env_parses_fallback_list() -> None:
    router = build_provider_from_env(
        env={
            "ECHO_ASSET_GEN_PRIMARY": "meshy",
            "ECHO_ASSET_GEN_FALLBACKS": "trellis",
            "MESHY_API_KEY": "sk-test",
        },
    )
    assert router.chain_provider_ids == ("meshy", "trellis")


def test_build_provider_from_env_trims_whitespace_in_fallback_list() -> None:
    router = build_provider_from_env(
        env={
            "ECHO_ASSET_GEN_PRIMARY": "trellis",
            "ECHO_ASSET_GEN_FALLBACKS": "  ,  ,  ",  # blank entries only
        },
    )
    assert router.fallbacks == ()


# ---------------------------------------------------------------------------
# Integration: meshy → trellis mirrors T-ML-050 production topology
# ---------------------------------------------------------------------------


def test_meshy_primary_trellis_fallback_production_topology() -> None:
    """End-to-end: MeshyProvider (stub → always fails) routes to
    TrellisProvider (HTTP response stubbed in-process).

    This is exactly the T-ML-050 acceptance criterion on real classes,
    not mocks.
    """
    meshy = MeshyProvider(api_key="sk-test")
    trellis = TrellisProvider(base_url="http://trellis.test")
    router = RoutingAssetGenProvider(primary=meshy, fallbacks=[trellis])

    result = router.generate(_basic_request())

    assert result.provider_used == "trellis"
    assert result.glb_bytes is not None
    assert result.glb_bytes[:4] == b"glTF"
    assert result.content_address.startswith("sha256:")


def test_content_address_is_same_regardless_of_provider_used() -> None:
    """The content-address is a function of *inputs* not of the provider.

    MeshyProvider (dry_run) and TrellisProvider must return the same
    address for the same inputs, since the address is the dedup key.
    """
    inputs = _basic_inputs()
    req = AssetGenRequest(inputs=inputs, asset_id="x", dry_run=True)

    meshy_result = MeshyProvider(api_key="sk-test").generate(req)
    self_result = TrellisProvider(base_url="http://trellis.test").generate(req)

    assert meshy_result.content_address == self_result.content_address, (
        "Content-address must be provider-independent"
    )
