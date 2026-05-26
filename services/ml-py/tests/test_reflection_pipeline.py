"""End-to-end reflection pipeline tests (T-ML-042 acceptance).

The acceptance criterion for T-ML-042:

> end-to-end test produces a reflection that passes both classifiers
> for a happy-path input; fails closed for a contrived problematic
> input.

The tests in this module wire the full pipeline (template selection
+ prompt assembly + LLM completion + safety classifier + tone
classifier) and verify both branches.
"""

from __future__ import annotations

import pytest

from app.services.llm import (
    Completion,
    CompletionRequest,
    LLMProviderTimeoutError,
    MockLLMClient,
    RoutingLLMClient,
)
from app.services.reflection import (
    ReflectionPipeline,
    ReflectionResult,
)
from app.services.reflection_templates import default_template_dir, load_templates


@pytest.fixture(scope="module")
def templates() -> tuple:
    return load_templates(default_template_dir())


def _curated_completion(text: str, *, provider: str = "mock") -> object:
    """Return a function for MockLLMClient that ignores the request and
    emits a curated text instead. Used to drive the pipeline with
    known-good and known-bad outputs."""

    def _fn(req: CompletionRequest) -> Completion:
        return Completion(
            text=text,
            provider=provider,
            model=f"{provider}-1",
            finish_reason="stop",
            input_tokens=0,
            output_tokens=len(text) // 4,
        )

    return _fn


# Hand-curated reflection text for the high-openness vector. Three
# sentences, second-person, references the signal moment, no archetypes,
# no clinical terms.
_HAPPY_PATH_REFLECTION = (
    "You wrote down the unfamiliar word and then took a side street "
    "that was not on the way home. Neither of those was useful. "
    "Both of them were the same gesture, reaching for something the "
    "day had not offered yet."
)


@pytest.mark.asyncio
async def test_happy_path_returns_passing_reflection(templates: tuple) -> None:
    """T-ML-042 acceptance, half 1: happy-path input produces a
    reflection that passes both classifiers."""
    llm = MockLLMClient(fn=_curated_completion(_HAPPY_PATH_REFLECTION))
    pipeline = ReflectionPipeline(llm_client=llm, templates=templates)

    result = await pipeline.generate(
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=[
            "the unfamiliar word you wrote down",
            "the side street you took instead",
        ],
    )

    assert isinstance(result, ReflectionResult)
    assert not result.is_fallback
    assert result.fallback_reason is None
    assert result.text == _HAPPY_PATH_REFLECTION
    assert result.provider == "mock"
    assert result.template_id == "high-openness"
    assert result.classifier_scores is not None
    assert result.classifier_scores.safety.passed
    assert result.classifier_scores.tone.passed


@pytest.mark.asyncio
async def test_problematic_safety_input_fails_closed(templates: tuple) -> None:
    """T-ML-042 acceptance, half 2: contrived problematic input fails
    closed (returns the curated fallback)."""
    # Forced LLM output trips the clinical-term rule.
    bad = (
        "You are clearly narcissistic and slightly bipolar. "
        "You walked through the day with that diagnosis. "
        "It will pass."
    )
    llm = MockLLMClient(fn=_curated_completion(bad))
    pipeline = ReflectionPipeline(llm_client=llm, templates=templates)

    result = await pipeline.generate(
        big_five=(0.0, 0.0, 0.8, 0.0, 0.6),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["the room you stayed in too long"],
    )

    assert result.is_fallback
    assert result.fallback_reason == "safety-failed"
    # Curated fallback text is one of the safe defaults.
    assert "you" in result.text.lower()
    # Classifier scores carry the reason so telemetry can see what fired.
    assert result.classifier_scores is not None
    assert not result.classifier_scores.safety.passed
    assert result.classifier_scores.safety.reason == "clinical-term"


@pytest.mark.asyncio
async def test_tone_failure_falls_back(templates: tuple) -> None:
    """A reflection that passes safety but flunks tone (e.g. archetype
    phrasing) also fails closed."""
    bad = (
        "You moved through the day; the curious one is who you have "
        "always been. You wrote two things down. Tomorrow will be the "
        "same shape."
    )
    llm = MockLLMClient(fn=_curated_completion(bad))
    pipeline = ReflectionPipeline(llm_client=llm, templates=templates)

    result = await pipeline.generate(
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["the curious thing"],
    )

    assert result.is_fallback
    assert result.fallback_reason == "tone-failed"
    assert result.classifier_scores is not None
    assert result.classifier_scores.safety.passed
    assert not result.classifier_scores.tone.passed


@pytest.mark.asyncio
async def test_llm_failure_falls_back(templates: tuple) -> None:
    """When every provider in the chain fails, the pipeline returns the
    fallback string instead of raising."""
    primary = MockLLMClient(provider_id="primary", raises=LLMProviderTimeoutError)
    fallback = MockLLMClient(provider_id="fallback", raises=LLMProviderTimeoutError)
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])
    pipeline = ReflectionPipeline(llm_client=router, templates=templates)

    result = await pipeline.generate(
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["one moment"],
    )

    assert result.is_fallback
    assert result.fallback_reason == "llm-failed"
    assert "primary" in result.routing_attempted_providers
    assert "fallback" in result.routing_attempted_providers


@pytest.mark.asyncio
async def test_router_fallback_succeeds_when_primary_fails(
    templates: tuple,
) -> None:
    """Composition with the routing client: primary fails, fallback
    succeeds, pipeline returns the fallback's completion *passing both
    classifiers* — the classifier path is unchanged."""
    primary = MockLLMClient(provider_id="primary", raises=LLMProviderTimeoutError)
    fallback = MockLLMClient(
        provider_id="fallback",
        fn=_curated_completion(_HAPPY_PATH_REFLECTION, provider="fallback"),
    )
    router = RoutingLLMClient(primary=primary, fallbacks=[fallback])
    pipeline = ReflectionPipeline(llm_client=router, templates=templates)

    result = await pipeline.generate(
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=[
            "the unfamiliar word you wrote down",
            "the side street you took instead",
        ],
    )

    assert not result.is_fallback
    assert result.provider == "fallback"
    assert result.routing_attempted_providers == ("primary", "fallback")


@pytest.mark.asyncio
async def test_pipeline_picks_correct_template_for_vector(
    templates: tuple,
) -> None:
    """End-to-end sanity: a different trait vector picks a different
    template id."""
    llm = MockLLMClient(fn=_curated_completion(_HAPPY_PATH_REFLECTION))
    pipeline = ReflectionPipeline(llm_client=llm, templates=templates)

    high_o = await pipeline.generate(
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["the unfamiliar word you wrote down"],
    )
    high_c = await pipeline.generate(
        big_five=(0.0, 0.8, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["the list you reread"],
    )
    assert high_o.template_id != high_c.template_id


@pytest.mark.asyncio
async def test_pipeline_returns_fallback_text_when_no_candidates() -> None:
    """If the only template available doesn't match any vector,
    the pipeline still returns a fallback rather than raising."""
    # Build a tiny library that only has the fallback-generic template
    # so we can construct a vector that... wait, fallback-generic
    # matches everything. Instead, build a library that has only one
    # narrow template whose predicates won't fire for our test vector.
    real_templates = load_templates(default_template_dir())
    narrow = next(t for t in real_templates if t.id == "high-openness")
    # Hand-trim the library to only one narrow template by swapping
    # priorities so the test vector (all zeros) cannot trigger it.
    llm = MockLLMClient()
    pipeline = ReflectionPipeline(llm_client=llm, templates=(narrow,))
    # high-openness needs OCEAN-O >= 0.4; we pass zero across the board.
    result = await pipeline.generate(
        big_five=(0.0, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=[],
    )
    assert result.is_fallback
    assert result.fallback_reason == "no-candidates"
    assert result.provider == "none"


@pytest.mark.asyncio
async def test_pipeline_uses_seed_to_pick_fallback_text(
    templates: tuple,
) -> None:
    """Different fallback_seed values can produce different fallback
    text (deterministic per seed). This prevents a player who sees two
    fallbacks in a row from seeing the same string twice."""
    bad = "you are clearly narcissistic and unwell."  # forces safety fail
    llm = MockLLMClient(fn=_curated_completion(bad))
    pipeline = ReflectionPipeline(llm_client=llm, templates=templates)

    a = await pipeline.generate(
        big_five=(0.5, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["m"],
        fallback_seed=0,
    )
    b = await pipeline.generate(
        big_five=(0.5, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=["m"],
        fallback_seed=1,
    )
    assert a.is_fallback and b.is_fallback
    assert a.text != b.text


def test_pipeline_generate_sync_works(templates: tuple) -> None:
    """The sync wrapper used by the gRPC server works without an
    explicit event loop."""
    llm = MockLLMClient(fn=_curated_completion(_HAPPY_PATH_REFLECTION))
    pipeline = ReflectionPipeline(llm_client=llm, templates=templates)
    result = pipeline.generate_sync(
        big_five=(0.8, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
        signal_moments=[
            "the unfamiliar word you wrote down",
            "the side street you took instead",
        ],
    )
    assert not result.is_fallback
    assert result.text == _HAPPY_PATH_REFLECTION


def test_pipeline_rejects_empty_templates() -> None:
    llm = MockLLMClient()
    with pytest.raises(ValueError):
        ReflectionPipeline(llm_client=llm, templates=())
