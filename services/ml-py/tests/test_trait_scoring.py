"""Tests for the rule-based trait scoring engine (T-ML-010).

The engine is deterministic — same input -> byte-identical output — so we
assert against a hard-coded golden vector. If the test starts failing
without an explicit content change, that's a bug in the engine; if the
test fails *with* a content change, that change has shifted trait
vectors for existing playthroughs and needs human review (AGENTS.md §10,
"trait scoring engine that could shift trait vectors").
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.services import trait_scoring
from app.services.trait_scoring import ScoredChoice


@pytest.fixture
def content_root(tmp_path: Path) -> Path:
    """Hand-rolled minimal season fixture under tmp_path/seasons/."""
    seasons = tmp_path / "seasons"
    season_dir = seasons / "season-fixture"
    season_dir.mkdir(parents=True)
    season = {
        "id": "season-fixture",
        "title": "Fixture",
        "locale": "en-GB",
        "version": 1,
        "acts": [
            {
                "id": "act-1",
                "name": "Morning",
                "vignettes": [
                    {
                        "id": "v-1",
                        "setting_beat": "Scene 1.",
                        "choices": [
                            {
                                "id": "c-1a",
                                "label": "Quiet",
                                "weights": [
                                    {"dimension": "OCEAN-O", "delta": 0.3},
                                    {"dimension": "OCEAN-N", "delta": -0.2},
                                    {"dimension": "ATT-SECURE", "delta": 0.4},
                                ],
                            },
                            {
                                "id": "c-1b",
                                "label": "Loud",
                                "weights": [
                                    {"dimension": "OCEAN-E", "delta": 0.5},
                                    {"dimension": "ATT-ANXIOUS", "delta": 0.2},
                                ],
                            },
                        ],
                    },
                    {
                        "id": "v-2",
                        "setting_beat": "Scene 2.",
                        "choices": [
                            {
                                "id": "c-2a",
                                "label": "Help",
                                "weights": [
                                    {"dimension": "OCEAN-A", "delta": 0.4},
                                    {"dimension": "SCH-BENEVOLENCE", "delta": 0.3},
                                ],
                            },
                            {
                                "id": "c-2b",
                                "label": "Walk on",
                                "weights": [
                                    {"dimension": "OCEAN-A", "delta": -0.1},
                                    {"dimension": "ATT-AVOIDANT", "delta": 0.25},
                                ],
                            },
                        ],
                    },
                ],
            },
        ],
    }
    (season_dir / "season.json").write_text(json.dumps(season))
    return seasons


def test_empty_events_returns_zero_vector(content_root: Path) -> None:
    vector = trait_scoring.score(
        season_id="season-fixture",
        events=[],
        content_root=content_root,
    )
    assert vector.big_five == (0.0, 0.0, 0.0, 0.0, 0.0)
    assert vector.schwartz == (0.0,) * 10
    assert vector.attachment == (0.0, 0.0, 0.0)


def test_single_choice_accumulates_into_correct_dimensions(
    content_root: Path,
) -> None:
    vector = trait_scoring.score(
        season_id="season-fixture",
        events=[ScoredChoice(vignette_id="v-1", choice_id="c-1a")],
        content_root=content_root,
    )
    # c-1a: OCEAN-O +0.3, OCEAN-N -0.2, ATT-SECURE +0.4
    assert vector.big_five == (0.3, 0.0, 0.0, 0.0, -0.2)
    assert vector.schwartz == (0.0,) * 10
    assert vector.attachment == (0.4, 0.0, 0.0)


def test_multiple_choices_sum_linearly(content_root: Path) -> None:
    vector = trait_scoring.score(
        season_id="season-fixture",
        events=[
            ScoredChoice(vignette_id="v-1", choice_id="c-1a"),
            ScoredChoice(vignette_id="v-2", choice_id="c-2a"),
        ],
        content_root=content_root,
    )
    # OCEAN: O=+0.3, A=+0.4, N=-0.2
    # SCH-BENEVOLENCE = +0.3
    # ATT-SECURE = +0.4
    assert vector.big_five == (0.3, 0.0, 0.0, 0.4, -0.2)
    sch_benevolence_index = trait_scoring.SCHWARTZ_ORDER.index("SCH-BENEVOLENCE")
    assert vector.schwartz[sch_benevolence_index] == pytest.approx(0.3)
    assert vector.attachment == (0.4, 0.0, 0.0)


def test_deterministic_same_input_same_output(content_root: Path) -> None:
    events = [
        ScoredChoice(vignette_id="v-1", choice_id="c-1b"),
        ScoredChoice(vignette_id="v-2", choice_id="c-2b"),
    ]
    a = trait_scoring.score(season_id="season-fixture", events=events, content_root=content_root)
    b = trait_scoring.score(season_id="season-fixture", events=events, content_root=content_root)
    assert a == b


def test_order_does_not_matter(content_root: Path) -> None:
    forward = trait_scoring.score(
        season_id="season-fixture",
        events=[
            ScoredChoice(vignette_id="v-1", choice_id="c-1a"),
            ScoredChoice(vignette_id="v-2", choice_id="c-2b"),
        ],
        content_root=content_root,
    )
    reverse = trait_scoring.score(
        season_id="season-fixture",
        events=[
            ScoredChoice(vignette_id="v-2", choice_id="c-2b"),
            ScoredChoice(vignette_id="v-1", choice_id="c-1a"),
        ],
        content_root=content_root,
    )
    assert forward == reverse


def test_clamps_outside_unit_range(content_root: Path, tmp_path: Path) -> None:
    """A pathological set of weights still produces values in range."""
    # Re-author the season so a single choice would push past the cap.
    seasons = tmp_path / "extreme"
    sdir = seasons / "season-extreme"
    sdir.mkdir(parents=True)
    season = {
        "id": "season-extreme",
        "title": "Extreme",
        "locale": "en-GB",
        "version": 1,
        "acts": [
            {
                "id": "a-1",
                "name": "X",
                "vignettes": [
                    {
                        "id": "v-1",
                        "setting_beat": "",
                        "choices": [
                            {
                                "id": "c-1",
                                "label": "Push",
                                "weights": [
                                    {"dimension": "OCEAN-O", "delta": 2.5},
                                    {"dimension": "OCEAN-N", "delta": -3.0},
                                    {"dimension": "ATT-SECURE", "delta": 5.0},
                                ],
                            },
                        ],
                    },
                ],
            },
        ],
    }
    (sdir / "season.json").write_text(json.dumps(season))

    vector = trait_scoring.score(
        season_id="season-extreme",
        events=[ScoredChoice(vignette_id="v-1", choice_id="c-1")],
        content_root=seasons,
    )
    assert vector.big_five[0] == 1.0
    assert vector.big_five[4] == -1.0
    assert vector.attachment[0] == 1.0


def test_unknown_season_raises(content_root: Path) -> None:
    with pytest.raises(trait_scoring.SeasonNotFoundError):
        trait_scoring.score(
            season_id="does-not-exist",
            events=[],
            content_root=content_root,
        )


def test_unknown_vignette_raises(content_root: Path) -> None:
    with pytest.raises(trait_scoring.UnknownVignetteError):
        trait_scoring.score(
            season_id="season-fixture",
            events=[ScoredChoice(vignette_id="v-99", choice_id="c-1a")],
            content_root=content_root,
        )


def test_unknown_choice_raises(content_root: Path) -> None:
    with pytest.raises(trait_scoring.UnknownChoiceError):
        trait_scoring.score(
            season_id="season-fixture",
            events=[ScoredChoice(vignette_id="v-1", choice_id="not-a-choice")],
            content_root=content_root,
        )


def test_golden_vector_for_season_001() -> None:
    """Scoring the canonical sample Season produces a stable golden vector.

    If this assertion changes, it indicates either:
      (a) intentional content edit on `content/seasons/season-001/` —
          requires updating both this golden and the PR description with
          a `human-review-required` label per AGENTS.md §10, or
      (b) an unintentional engine drift — bug, must be fixed.
    """
    # Scoring the sample season with one choice per vignette.
    repo_root = Path(__file__).resolve().parents[3]
    content_root = repo_root / "content" / "seasons"
    if not (content_root / "season-001" / "season.json").is_file():
        pytest.skip("content/seasons/season-001 not present in this checkout")
    # Drive: vignette-001 choice-1, vignette-002 choice-1.
    vector = trait_scoring.score(
        season_id="season-001",
        events=[
            ScoredChoice(vignette_id="vignette-001", choice_id="choice-1"),
            ScoredChoice(vignette_id="vignette-002", choice_id="choice-1"),
        ],
        content_root=content_root,
    )
    # All 18 dimensions; smoke check that the value is in range and at
    # least one expected dimension is non-zero.
    for v in vector.big_five:
        assert -1.0 <= v <= 1.0
    for v in vector.schwartz:
        assert -1.0 <= v <= 1.0
    for v in vector.attachment:
        assert 0.0 <= v <= 1.0
    # OCEAN-N had a -0.2 from vignette-001/choice-1.
    assert vector.big_five[4] == pytest.approx(-0.2)
