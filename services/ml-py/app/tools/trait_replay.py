"""Deterministic trait-vector replay tool (`tools/trait-replay`).

Replays a corpus of recorded playthroughs through the *same* rule-based
trait-scoring engine the server uses (:mod:`app.services.trait_scoring`) and
asserts each one still produces its recorded :class:`TraitVector`.

A drift means a content edit (or an engine change) shifted trait vectors for
*existing* playthroughs — a breaking change that requires human review
(AGENTS.md §4 / §10). `make replay` runs this in compare mode; regenerate the
baselines after an intentional, human-reviewed content change with `--update`.

Design choice: this reuses :func:`app.services.trait_scoring.score` rather
than reimplementing the math. A second implementation could silently drift
from the engine and make the gate lie. Alternative considered — a standalone
Go reimplementation — was rejected for exactly that reason.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from app.services.trait_scoring import (
    ATTACHMENT_ORDER,
    BIG_FIVE_ORDER,
    SCHWARTZ_ORDER,
    ScoredChoice,
    TraitVector,
    score,
)

# Absolute tolerance for the per-dimension compare. The engine sums small
# decimal deltas, so a "byte-identical" result can still differ from a clean
# JSON decimal by IEEE-754 noise (e.g. 0.2 - 0.1 != 0.1). 1e-9 is far below
# any real trait delta (the smallest authored weight is 0.1), so genuine
# shifts are always caught while float noise never trips the gate.
COMPARE_ABS_TOL = 1e-9

_DIM_LABELS: tuple[str, ...] = (*BIG_FIVE_ORDER, *SCHWARTZ_ORDER, *ATTACHMENT_ORDER)


@dataclass(frozen=True, slots=True)
class Playthrough:
    """One recorded playthrough fixture loaded from the corpus."""

    playthrough_id: str
    season_id: str
    events: tuple[ScoredChoice, ...]
    expected: TraitVector | None
    source_path: Path


@dataclass(frozen=True, slots=True)
class ReplayResult:
    """Outcome of replaying one playthrough."""

    playthrough_id: str
    status: str  # "ok" | "drift" | "missing_baseline" | "recorded"
    computed: TraitVector
    expected: TraitVector | None = None

    @property
    def ok(self) -> bool:
        return self.status in {"ok", "recorded"}


@dataclass(frozen=True, slots=True)
class ReplayReport:
    """Aggregate of every replayed playthrough."""

    results: tuple[ReplayResult, ...]

    @property
    def ok(self) -> bool:
        return all(r.ok for r in self.results)

    @property
    def drifted(self) -> tuple[ReplayResult, ...]:
        return tuple(r for r in self.results if r.status == "drift")

    @property
    def missing(self) -> tuple[ReplayResult, ...]:
        return tuple(r for r in self.results if r.status == "missing_baseline")


def _floats(value: object, n: int, name: str) -> list[float]:
    if not isinstance(value, list) or len(value) != n:
        raise ValueError(f"{name} must be a list of {n} numbers")
    out: list[float] = []
    for x in value:
        if isinstance(x, bool) or not isinstance(x, (int, float)):
            raise ValueError(f"{name} must contain only numbers")
        out.append(float(x))
    return out


def vector_to_dict(v: TraitVector) -> dict[str, list[float]]:
    """Serialize a TraitVector to the corpus ``expected`` shape."""
    return {
        "big_five": list(v.big_five),
        "schwartz": list(v.schwartz),
        "attachment": list(v.attachment),
    }


def vector_from_dict(value: object) -> TraitVector:
    """Parse a corpus ``expected`` object into a TraitVector (strict shape)."""
    if not isinstance(value, dict):
        raise ValueError("expected must be an object")
    bf = _floats(value.get("big_five"), 5, "big_five")
    sw = _floats(value.get("schwartz"), 10, "schwartz")
    at = _floats(value.get("attachment"), 3, "attachment")
    return TraitVector(
        big_five=(bf[0], bf[1], bf[2], bf[3], bf[4]),
        schwartz=(sw[0], sw[1], sw[2], sw[3], sw[4], sw[5], sw[6], sw[7], sw[8], sw[9]),
        attachment=(at[0], at[1], at[2]),
    )


def _flat(v: TraitVector) -> tuple[float, ...]:
    return (*v.big_five, *v.schwartz, *v.attachment)


def vectors_close(a: TraitVector, b: TraitVector) -> bool:
    """True when every one of the 18 dimensions matches within tolerance."""
    return all(
        math.isclose(x, y, abs_tol=COMPARE_ABS_TOL) for x, y in zip(_flat(a), _flat(b), strict=True)
    )


def load_playthrough(path: Path) -> Playthrough:
    """Load and validate one ``*.json`` playthrough fixture."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: playthrough must be a JSON object")
    season_id = doc.get("season_id")
    if not isinstance(season_id, str) or not season_id:
        raise ValueError(f"{path}: season_id must be a non-empty string")
    events_raw = doc.get("events", [])
    if not isinstance(events_raw, list):
        raise ValueError(f"{path}: events must be a list")
    events: list[ScoredChoice] = []
    for ev in events_raw:
        if not isinstance(ev, dict):
            raise ValueError(f"{path}: each event must be an object")
        vid = ev.get("vignette_id")
        cid = ev.get("choice_id")
        if not isinstance(vid, str) or not isinstance(cid, str):
            raise ValueError(f"{path}: event needs string vignette_id and choice_id")
        events.append(ScoredChoice(vignette_id=vid, choice_id=cid))
    expected_raw = doc.get("expected")
    expected = vector_from_dict(expected_raw) if expected_raw is not None else None
    pid = doc.get("playthrough_id")
    return Playthrough(
        playthrough_id=pid if isinstance(pid, str) and pid else path.stem,
        season_id=season_id,
        events=tuple(events),
        expected=expected,
        source_path=path,
    )


def load_corpus(corpus_dir: Path) -> list[Playthrough]:
    """Load every ``*.json`` fixture under *corpus_dir*, in sorted path order."""
    return [load_playthrough(p) for p in sorted(corpus_dir.glob("*.json"))]


def replay(
    playthroughs: Sequence[Playthrough],
    *,
    content_root: Path | None = None,
    update: bool = False,
) -> ReplayReport:
    """Recompute each playthrough's trait vector and classify the outcome."""
    results: list[ReplayResult] = []
    for pt in playthroughs:
        computed = score(season_id=pt.season_id, events=pt.events, content_root=content_root)
        if update:
            status = "recorded"
        elif pt.expected is None:
            status = "missing_baseline"
        elif vectors_close(computed, pt.expected):
            status = "ok"
        else:
            status = "drift"
        results.append(
            ReplayResult(
                playthrough_id=pt.playthrough_id,
                status=status,
                computed=computed,
                expected=pt.expected,
            )
        )
    return ReplayReport(tuple(results))


def write_baseline(playthrough: Playthrough, computed: TraitVector) -> None:
    """Rewrite a fixture's ``expected`` block from a freshly computed vector."""
    doc = json.loads(playthrough.source_path.read_text(encoding="utf-8"))
    doc["expected"] = vector_to_dict(computed)
    playthrough.source_path.write_text(
        json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def _print_diff(expected: TraitVector, computed: TraitVector) -> None:
    for label, e, c in zip(_DIM_LABELS, _flat(expected), _flat(computed), strict=True):
        if not math.isclose(e, c, abs_tol=COMPARE_ABS_TOL):
            print(f"        {label}: expected {e} got {c}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="trait-replay",
        description="Replay recorded playthroughs and detect trait-vector drift.",
    )
    parser.add_argument(
        "--corpus",
        type=Path,
        required=True,
        help="directory of *.json playthrough fixtures",
    )
    parser.add_argument(
        "--content-root",
        type=Path,
        default=None,
        help="seasons content root (defaults to the repo's content/seasons)",
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="record/refresh expected baselines after a human-reviewed content change",
    )
    args = parser.parse_args(argv)

    corpus_dir: Path = args.corpus
    if not corpus_dir.is_dir():
        print(f"trait-replay: corpus dir {corpus_dir} not found", file=sys.stderr)
        return 2

    playthroughs = load_corpus(corpus_dir)
    if not playthroughs:
        print(f"trait-replay: no playthroughs in {corpus_dir}; nothing to replay")
        return 0

    report = replay(playthroughs, content_root=args.content_root, update=bool(args.update))

    if args.update:
        for pt, res in zip(playthroughs, report.results, strict=True):
            write_baseline(pt, res.computed)
            print(f"trait-replay: recorded baseline for {res.playthrough_id}")
        return 0

    for res in report.results:
        if res.status == "ok":
            print(f"  ok    {res.playthrough_id}")
        elif res.status == "missing_baseline":
            print(f"  MISS  {res.playthrough_id}: no expected baseline (run with --update)")
        else:
            print(f"  DRIFT {res.playthrough_id}:")
            assert res.expected is not None  # drift implies a recorded baseline
            _print_diff(res.expected, res.computed)

    if report.ok:
        print(f"trait-replay: {len(report.results)} playthrough(s) stable")
        return 0

    print(
        f"trait-replay: {len(report.drifted)} drift(s), "
        f"{len(report.missing)} missing baseline(s) — trait vectors shifted for "
        "unchanged playthroughs; human review required (AGENTS.md §4/§10)",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
