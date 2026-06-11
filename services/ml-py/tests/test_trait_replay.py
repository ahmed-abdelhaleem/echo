"""Tests for the trait-replay drift gate (tools/trait-replay).

The replay tool reuses app.services.trait_scoring, so these tests build a
synthetic season under tmp_path (mirroring test_trait_scoring) to exercise
the ok / drift / missing-baseline / update paths deterministically, then
assert the *committed* season-001 corpus still matches its baselines — the
same guarantee `make replay` provides in CI.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.tools import trait_replay

# Synthetic season: two vignettes, weights chosen so the expected vector is
# trivial to verify by hand.
_SEASON_ID = "season-replay-fixture"
_EVENTS = [
    {"vignette_id": "v-1", "choice_id": "c-1a"},
    {"vignette_id": "v-2", "choice_id": "c-2a"},
]
# c-1a: OCEAN-O +0.3, OCEAN-N -0.2, ATT-SECURE +0.4
# c-2a: OCEAN-A +0.4, SCH-BENEVOLENCE +0.3
_EXPECTED = {
    "big_five": [0.3, 0.0, 0.0, 0.4, -0.2],
    "schwartz": [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.0],
    "attachment": [0.4, 0.0, 0.0],
}


def _write_season(root: Path) -> Path:
    seasons = root / "seasons"
    sdir = seasons / _SEASON_ID
    sdir.mkdir(parents=True)
    season = {
        "id": _SEASON_ID,
        "title": "Replay Fixture",
        "locale": "en-GB",
        "version": 1,
        "acts": [
            {
                "id": "act-1",
                "name": "Only",
                "vignettes": [
                    {
                        "id": "v-1",
                        "setting_beat": "",
                        "choices": [
                            {
                                "id": "c-1a",
                                "label": "A",
                                "weights": [
                                    {"dimension": "OCEAN-O", "delta": 0.3},
                                    {"dimension": "OCEAN-N", "delta": -0.2},
                                    {"dimension": "ATT-SECURE", "delta": 0.4},
                                ],
                            }
                        ],
                    },
                    {
                        "id": "v-2",
                        "setting_beat": "",
                        "choices": [
                            {
                                "id": "c-2a",
                                "label": "B",
                                "weights": [
                                    {"dimension": "OCEAN-A", "delta": 0.4},
                                    {"dimension": "SCH-BENEVOLENCE", "delta": 0.3},
                                ],
                            }
                        ],
                    },
                ],
            }
        ],
    }
    (sdir / "season.json").write_text(json.dumps(season))
    return seasons


def _write_fixture(
    corpus: Path,
    name: str,
    *,
    expected: dict[str, list[float]] | None = None,
) -> Path:
    corpus.mkdir(parents=True, exist_ok=True)
    doc: dict[str, object] = {
        "playthrough_id": name,
        "season_id": _SEASON_ID,
        "events": _EVENTS,
    }
    if expected is not None:
        doc["expected"] = expected
    path = corpus / f"{name}.json"
    path.write_text(json.dumps(doc))
    return path


def test_replay_all_ok_on_correct_baseline(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    _write_fixture(corpus, "ok", expected=_EXPECTED)
    report = trait_replay.replay(trait_replay.load_corpus(corpus), content_root=content_root)
    assert report.ok
    assert [r.status for r in report.results] == ["ok"]


def test_replay_detects_drift(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    drifted = {**_EXPECTED, "big_five": [0.3, 0.0, 0.0, 0.4, 0.0]}  # N: -0.2 -> 0.0
    _write_fixture(corpus, "shifted", expected=drifted)
    report = trait_replay.replay(trait_replay.load_corpus(corpus), content_root=content_root)
    assert not report.ok
    assert [r.playthrough_id for r in report.drifted] == ["shifted"]


def test_replay_reports_missing_baseline(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    _write_fixture(corpus, "unbaselined", expected=None)
    report = trait_replay.replay(trait_replay.load_corpus(corpus), content_root=content_root)
    assert not report.ok
    assert [r.playthrough_id for r in report.missing] == ["unbaselined"]


def test_replay_is_deterministic(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    _write_fixture(corpus, "ok", expected=_EXPECTED)
    pts = trait_replay.load_corpus(corpus)
    a = trait_replay.replay(pts, content_root=content_root)
    b = trait_replay.replay(pts, content_root=content_root)
    assert a.results[0].computed == b.results[0].computed


def test_main_returns_zero_when_stable(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    _write_fixture(corpus, "ok", expected=_EXPECTED)
    rc = trait_replay.main(["--corpus", str(corpus), "--content-root", str(content_root)])
    assert rc == 0


def test_main_returns_one_on_drift(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    _write_fixture(corpus, "shifted", expected={**_EXPECTED, "attachment": [0.0, 0.0, 0.0]})
    rc = trait_replay.main(["--corpus", str(corpus), "--content-root", str(content_root)])
    assert rc == 1


def test_main_update_records_then_replays_clean(tmp_path: Path) -> None:
    content_root = _write_season(tmp_path)
    corpus = tmp_path / "corpus"
    fixture = _write_fixture(corpus, "rec", expected=None)
    rc_update = trait_replay.main(
        ["--corpus", str(corpus), "--content-root", str(content_root), "--update"]
    )
    assert rc_update == 0
    written = json.loads(fixture.read_text())
    assert written["expected"]["big_five"] == _EXPECTED["big_five"]
    rc_compare = trait_replay.main(["--corpus", str(corpus), "--content-root", str(content_root)])
    assert rc_compare == 0


def test_main_missing_corpus_dir_returns_two(tmp_path: Path) -> None:
    assert trait_replay.main(["--corpus", str(tmp_path / "nope")]) == 2


def test_main_empty_corpus_returns_zero(tmp_path: Path) -> None:
    corpus = tmp_path / "corpus"
    corpus.mkdir()
    assert trait_replay.main(["--corpus", str(corpus)]) == 0


def test_committed_season_001_corpus_matches_baselines() -> None:
    """The shipped season-001 corpus must replay clean against real content.

    This is the regression gate `make replay` enforces: if a season-001
    content edit shifts these vectors, both this test and `make replay`
    fail until the baselines are regenerated under human review.
    """
    repo_root = Path(__file__).resolve().parents[3]
    content_root = repo_root / "content" / "seasons"
    corpus_dir = repo_root / "tools" / "trait-replay" / "corpus"
    if not (content_root / "season-001" / "season.json").is_file():
        pytest.skip("content/seasons/season-001 not present in this checkout")
    if not corpus_dir.is_dir():
        pytest.skip("tools/trait-replay/corpus not present in this checkout")
    playthroughs = trait_replay.load_corpus(corpus_dir)
    assert playthroughs, "expected at least one committed playthrough fixture"
    report = trait_replay.replay(playthroughs, content_root=content_root)
    drifted = [r.playthrough_id for r in report.drifted]
    missing = [r.playthrough_id for r in report.missing]
    assert report.ok, f"season-001 baselines drifted={drifted} missing={missing}"
