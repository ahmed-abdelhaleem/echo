"""Tests for the reflection template library (T-ML-040)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from app.services.reflection_templates import (
    ATTACHMENT_ORDER,
    BIG_FIVE_ORDER,
    SCHWARTZ_ORDER,
    ReflectionTemplate,
    default_template_dir,
    load_templates,
    select_candidates,
)
from app.services.trait_scoring import ATTACHMENT_ORDER as TS_ATTACHMENT_ORDER
from app.services.trait_scoring import BIG_FIVE_ORDER as TS_BIG_FIVE_ORDER
from app.services.trait_scoring import SCHWARTZ_ORDER as TS_SCHWARTZ_ORDER

REPO_ROOT = Path(__file__).resolve().parents[3]
TEMPLATES_DIR = REPO_ROOT / "content" / "reflection-templates"


@pytest.fixture(scope="module")
def templates() -> tuple[ReflectionTemplate, ...]:
    return load_templates(TEMPLATES_DIR)


# ---------------------------------------------------------------------------
# Library-level invariants
# ---------------------------------------------------------------------------


def test_dimension_order_matches_trait_scoring() -> None:
    """The selector indexes the trait vector by dimension order. If the
    scorer ever bumps the order, the selector must follow in lockstep."""
    assert BIG_FIVE_ORDER == TS_BIG_FIVE_ORDER
    assert SCHWARTZ_ORDER == TS_SCHWARTZ_ORDER
    assert ATTACHMENT_ORDER == TS_ATTACHMENT_ORDER


def test_library_meets_acceptance_count(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """T-ML-040 acceptance: >=50 templates."""
    assert len(templates) >= 50


def test_all_templates_have_unique_ids(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    ids = [t.id for t in templates]
    assert len(ids) == len(set(ids))


def test_all_template_ids_match_their_filenames() -> None:
    for path in TEMPLATES_DIR.glob("*.template.json"):
        import json

        with path.open() as fh:
            data = json.load(fh)
        expected = path.name.removesuffix(".template.json")
        assert data["id"] == expected, f"{path.name}: id {data['id']!r} != filename {expected!r}"


def test_every_template_has_at_least_one_exemplar(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """The library spec says >=1 exemplar with brand-voice notes."""
    for t in templates:
        assert len(t.exemplars) >= 1, t.id
        for ex in t.exemplars:
            assert ex.output.strip(), f"{t.id}: empty exemplar"
            assert ex.notes.strip(), f"{t.id}: empty exemplar notes"
            assert ex.signal_moments, f"{t.id}: exemplar has no signal_moments"


def test_every_template_has_voice_notes(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    for t in templates:
        assert t.voice_notes.notes.strip(), f"{t.id}: empty voice notes"
        assert t.voice_notes.emphasize, f"{t.id}: no emphasize rules"
        assert t.voice_notes.avoid, f"{t.id}: no avoid rules"


# ---------------------------------------------------------------------------
# Per-exemplar voice rule sanity
# ---------------------------------------------------------------------------


_YOU_RE = re.compile(r"\byou(?:r|re|ll|ve|d)?\b", re.IGNORECASE)
_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+")


def test_every_exemplar_is_second_person(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """docs/04 voice rule: 'Always second person.'"""
    for t in templates:
        for i, ex in enumerate(t.exemplars):
            assert _YOU_RE.search(ex.output), (
                f"{t.id} exemplar {i}: no second-person 'you'-form found"
            )


def test_every_exemplar_respects_sentence_count(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    for t in templates:
        for i, ex in enumerate(t.exemplars):
            sents = [s for s in _SENT_SPLIT.split(ex.output.strip()) if s.strip()]
            count = len(sents)
            assert t.constraints.min_sentences <= count <= t.constraints.max_sentences, (
                f"{t.id} exemplar {i}: {count} sentences not in "
                f"[{t.constraints.min_sentences}, {t.constraints.max_sentences}]"
            )


def test_every_exemplar_avoids_template_forbidden_terms(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """Forbidden terms defined on the template must not appear in the
    template's own exemplars. This catches accidental drift between the
    voice rules and the canonical samples we promise to the LLM."""
    for t in templates:
        for i, ex in enumerate(t.exemplars):
            lowered = ex.output.lower()
            for term in t.constraints.forbidden_terms:
                assert term.lower() not in lowered, (
                    f"{t.id} exemplar {i}: forbidden term {term!r} appears in output"
                )


def test_every_exemplar_avoids_voice_notes_avoid_phrases(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """Voice-notes 'avoid' phrases are softer guidance for the LLM, but
    they must also not appear in the curated exemplars."""
    for t in templates:
        for i, ex in enumerate(t.exemplars):
            lowered = ex.output.lower()
            for phrase in t.voice_notes.avoid:
                assert phrase.lower() not in lowered, (
                    f"{t.id} exemplar {i}: avoid-phrase {phrase!r} appears in output"
                )


# ---------------------------------------------------------------------------
# Selection behaviour
# ---------------------------------------------------------------------------


def _zero_vector() -> tuple[tuple[float, ...], tuple[float, ...], tuple[float, ...]]:
    return ((0.0,) * 5, (0.0,) * 10, (0.0,) * 3)


def test_selector_rejects_wrong_shape(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    with pytest.raises(ValueError):
        select_candidates(
            big_five=(0.1, 0.1),  # wrong shape
            schwartz=(0.0,) * 10,
            attachment=(0.0,) * 3,
            templates=templates,
        )


def test_selector_picks_high_openness_template_for_high_openness_vector(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    big_five = (0.8, 0.0, 0.0, 0.0, 0.0)  # high O only
    schwartz = (0.0,) * 10
    attachment = (0.0,) * 3
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    ids = [c.template.id for c in cands]
    assert "high-openness" in ids


def test_selector_picks_low_openness_for_low_openness_vector(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    big_five = (-0.8, 0.0, 0.0, 0.0, 0.0)
    schwartz = (0.0,) * 10
    attachment = (0.0,) * 3
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    ids = [c.template.id for c in cands]
    assert "low-openness" in ids


def test_selector_prefers_contrast_template_when_two_dimensions_strong(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """High O + low C should bring the curious-impulsive contrast above
    the single-dimension templates because contrast templates carry a
    higher priority."""
    big_five = (0.7, -0.6, 0.0, 0.0, 0.0)  # high O, low C
    schwartz = (0.0,) * 10
    attachment = (0.0,) * 3
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    assert cands, "selector returned no candidates for a clear signal"
    assert cands[0].template.id == "curious-impulsive", (
        f"expected contrast template at top, got {cands[0].template.id}"
    )


def test_selector_picks_attachment_template_for_anxious_vector(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    big_five = (0.0,) * 5
    schwartz = (0.0,) * 10
    attachment = (0.0, 0.8, 0.0)  # anxious prominent
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    ids = [c.template.id for c in cands]
    assert "anxious-attachment-prominent" in ids


def test_selector_falls_back_for_muted_vector(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    """A near-zero vector should still produce candidates — the
    fallback/meta templates exist exactly for this case."""
    big_five, schwartz, attachment = _zero_vector()
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    assert cands, "selector returned no candidates for muted vector"
    ids = [c.template.id for c in cands]
    # muted-day should be among them.
    assert "muted-day" in ids


def test_selector_is_deterministic(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    big_five = (0.5, 0.3, -0.2, 0.4, 0.1)
    schwartz = (0.3, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    attachment = (0.4, 0.0, 0.0)
    a = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    b = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=3,
    )
    assert [c.template.id for c in a] == [c.template.id for c in b]
    assert [round(c.score, 6) for c in a] == [round(c.score, 6) for c in b]


def test_selector_ranks_by_score(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    big_five = (0.6, 0.0, 0.0, 0.0, 0.0)
    schwartz = (0.0,) * 10
    attachment = (0.0,) * 3
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=10,
    )
    scores = [c.score for c in cands]
    assert scores == sorted(scores, reverse=True), "candidates not score-ranked"


def test_selector_limit_is_respected(
    templates: tuple[ReflectionTemplate, ...],
) -> None:
    big_five = (0.7, 0.0, 0.0, 0.0, 0.0)
    schwartz = (0.0,) * 10
    attachment = (0.0,) * 3
    cands = select_candidates(
        big_five=big_five,
        schwartz=schwartz,
        attachment=attachment,
        templates=templates,
        limit=2,
    )
    assert len(cands) <= 2


# ---------------------------------------------------------------------------
# default_template_dir locates the repo path
# ---------------------------------------------------------------------------


def test_default_template_dir_points_to_repo_content() -> None:
    p = default_template_dir()
    assert p.is_dir()
    # Should contain the same files we load in fixtures.
    files = list(p.glob("*.template.json"))
    assert len(files) >= 50


# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------


def test_load_templates_raises_on_missing_directory(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_templates(tmp_path / "nope")


def test_load_templates_handles_empty_directory(tmp_path: Path) -> None:
    # Empty dir is valid at the loader level (validator gates the
    # >=50 requirement). Loader returns an empty tuple.
    assert load_templates(tmp_path) == ()
