"""Reflection template library loader and selector (T-ML-040).

Reads every ``*.template.json`` under ``content/reflection-templates/``
into an immutable in-memory index, and exposes :func:`select_candidates`
which scores a :class:`TraitVector`-shaped input against each template's
``applies_when`` block and returns the matching candidates ranked by
priority + signal strength.

This module is **only** concerned with selection. The M2 reflection
pipeline (T-ML-042) is responsible for picking a single template (or a
blend of two), prompting the LLM with the chosen template's voice notes
+ exemplars, running the output through the safety + tone classifiers,
and falling back to a curated string if either classifier rejects.

The selector is a pure function. Templates load once at import time; we
do not watch the filesystem. Production code reloads via process
restart, which is how every other content artefact in this repo behaves
(seasons, art-tokens). Tests use :func:`load_templates` directly with a
test-supplied path.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final, Literal, cast

# ---------------------------------------------------------------------------
# Canonical dimension order. Mirrors ``trait_scoring`` exactly. Keeping
# the two in lockstep is asserted in tests.
# ---------------------------------------------------------------------------

BIG_FIVE_ORDER: Final[tuple[str, ...]] = (
    "OCEAN-O",
    "OCEAN-C",
    "OCEAN-E",
    "OCEAN-A",
    "OCEAN-N",
)
SCHWARTZ_ORDER: Final[tuple[str, ...]] = (
    "SCH-SELF_DIRECTION",
    "SCH-STIMULATION",
    "SCH-HEDONISM",
    "SCH-ACHIEVEMENT",
    "SCH-POWER",
    "SCH-SECURITY",
    "SCH-CONFORMITY",
    "SCH-TRADITION",
    "SCH-BENEVOLENCE",
    "SCH-UNIVERSALISM",
)
ATTACHMENT_ORDER: Final[tuple[str, ...]] = (
    "ATT-SECURE",
    "ATT-ANXIOUS",
    "ATT-AVOIDANT",
)

# Attachment values live in [0, 1] and only have a single pole. Big Five
# and Schwartz live in [-1, 1] and are bipolar.
_ATTACHMENT_DIMS: Final[frozenset[str]] = frozenset(ATTACHMENT_ORDER)


# ---------------------------------------------------------------------------
# Data classes mirroring the JSON schema. ``frozen=True`` so the loaded
# library is shareable across threads.
# ---------------------------------------------------------------------------


Direction = Literal["high", "low", "prominent", "muted"]


@dataclass(frozen=True, slots=True)
class Predicate:
    dimension: str
    direction: Direction
    min_magnitude: float


@dataclass(frozen=True, slots=True)
class Signal:
    """Conjunction of predicates. All must hold for the signal to fire."""

    all_of: tuple[Predicate, ...]


@dataclass(frozen=True, slots=True)
class Exemplar:
    signal_moments: tuple[str, ...]
    output: str
    notes: str


@dataclass(frozen=True, slots=True)
class VoiceNotes:
    emphasize: tuple[str, ...]
    avoid: tuple[str, ...]
    notes: str


@dataclass(frozen=True, slots=True)
class Constraints:
    voice: str
    min_sentences: int
    max_sentences: int
    forbidden_terms: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ReflectionTemplate:
    id: str
    version: int
    summary: str
    applies_when: tuple[Signal, ...]
    priority: int
    voice_notes: VoiceNotes
    exemplars: tuple[Exemplar, ...]
    constraints: Constraints


@dataclass(frozen=True, slots=True)
class Candidate:
    """One template that matched a trait vector, plus a stable score.

    ``score`` combines the template's declared priority with the
    strongest matching signal's magnitude, so a "high openness 0.9"
    vector beats "high openness 0.5" even at the same priority. Ties
    break alphabetically by ``template.id`` to keep selection
    deterministic across runs.
    """

    template: ReflectionTemplate
    score: float
    matched_signal: Signal


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------


_VALID_DIMENSIONS: Final[frozenset[str]] = frozenset(
    BIG_FIVE_ORDER + SCHWARTZ_ORDER + ATTACHMENT_ORDER,
)
_VALID_DIRECTIONS: Final[frozenset[str]] = frozenset(
    {"high", "low", "prominent", "muted"},
)


def load_templates(directory: Path | str) -> tuple[ReflectionTemplate, ...]:
    """Load every ``*.template.json`` file in ``directory``.

    Templates are returned sorted by id for deterministic iteration.
    Raises:
        FileNotFoundError: if the directory does not exist.
        ValueError: if any template fails structural validation (the
            JSON schema is checked by the Node validator at CI time;
            this raises on the small set of cross-field invariants the
            schema cannot express).
    """
    root = Path(directory)
    if not root.is_dir():
        raise FileNotFoundError(f"reflection-templates dir not found: {root}")

    templates: list[ReflectionTemplate] = []
    for path in sorted(root.glob("*.template.json")):
        with path.open(encoding="utf-8") as fh:
            data: Any = json.load(fh)
        template = _parse(data, source=str(path))
        templates.append(template)
    return tuple(templates)


def _parse(data: Any, *, source: str) -> ReflectionTemplate:
    """Translate a JSON dict into a :class:`ReflectionTemplate`.

    ``data`` is typed as ``Any`` because the JSON schema (validated by
    the Node tool in CI) already shapes the input; mypy adding a
    structural type would force ``cast`` calls everywhere. The dynamic
    typing is intentionally local to this function.
    """
    try:
        applies_raw: Any = data["applies_when"]
        constraints_raw: Any = data["constraints"]
        voice_raw: Any = data["voice_notes"]
        exemplars_raw: Any = data["exemplars"]
    except KeyError as exc:  # pragma: no cover - schema-validated upstream
        raise ValueError(f"{source}: missing required field {exc}") from exc

    signals = tuple(_parse_signal(s, source=source) for s in applies_raw["any_of"])

    constraints = Constraints(
        voice=str(constraints_raw["voice"]),
        min_sentences=int(constraints_raw["min_sentences"]),
        max_sentences=int(constraints_raw["max_sentences"]),
        forbidden_terms=tuple(constraints_raw.get("forbidden_terms", [])),
    )
    if constraints.min_sentences > constraints.max_sentences:
        raise ValueError(
            f"{source}: min_sentences ({constraints.min_sentences}) > "
            f"max_sentences ({constraints.max_sentences})",
        )

    voice = VoiceNotes(
        emphasize=tuple(voice_raw["emphasize"]),
        avoid=tuple(voice_raw["avoid"]),
        notes=str(voice_raw["notes"]),
    )

    exemplars: list[Exemplar] = [
        Exemplar(
            signal_moments=tuple(raw["signal_moments"]),
            output=str(raw["output"]),
            notes=str(raw["notes"]),
        )
        for raw in exemplars_raw
    ]

    return ReflectionTemplate(
        id=str(data["id"]),
        version=int(data["version"]),
        summary=str(data.get("summary", "")),
        applies_when=signals,
        priority=int(data.get("priority", 50)),
        voice_notes=voice,
        exemplars=tuple(exemplars),
        constraints=constraints,
    )


def _parse_signal(raw: Any, *, source: str) -> Signal:
    predicates: list[Predicate] = []
    for p in raw["all_of"]:
        dim = str(p["dimension"])
        direction = str(p["direction"])
        if dim not in _VALID_DIMENSIONS:
            raise ValueError(f"{source}: unknown dimension {dim!r}")
        if direction not in _VALID_DIRECTIONS:
            raise ValueError(f"{source}: unknown direction {direction!r}")
        # An attachment proxy being "low"/"muted" is a valid signal —
        # e.g. avoidant < 0.3 means avoidance was not prominent today,
        # so a secure-leaning template can fire. The matcher does the
        # right comparison; we just need to admit the predicate here.
        predicates.append(
            Predicate(
                dimension=dim,
                direction=cast(Direction, direction),
                min_magnitude=float(p["min_magnitude"]),
            ),
        )
    return Signal(all_of=tuple(predicates))


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------


def select_candidates(
    *,
    big_five: Sequence[float],
    schwartz: Sequence[float],
    attachment: Sequence[float],
    templates: Iterable[ReflectionTemplate],
    limit: int = 3,
) -> tuple[Candidate, ...]:
    """Return up to ``limit`` templates whose ``applies_when`` matches.

    The matcher walks each template's ``any_of`` list and picks the
    strongest matching signal (max sum of magnitudes across its
    predicates). The candidate's score is:

        score = priority + 10 * mean(matching_magnitudes)

    The 10x multiplier weights signal strength below priority — a
    high-priority contrast template at 0.4 magnitude still beats a
    single-dimension template at 0.9 magnitude. This is intentional:
    contrast templates are more diagnostic and were curated as such
    (docs/04 §"Voice rules" — "real people are contradictory").

    Args:
        big_five: 5-tuple of OCEAN scores in [-1, 1].
        schwartz: 10-tuple of Schwartz scores in [-1, 1].
        attachment: 3-tuple of attachment proxies in [0, 1].
        templates: the loaded library.
        limit: max number of candidates to return. The reflection
            pipeline (T-ML-042) uses ``limit=2`` (one or a blend).

    Returns:
        A tuple of :class:`Candidate` ordered by descending score, ties
        broken alphabetically by template id.
    """
    if len(big_five) != 5:
        raise ValueError(f"big_five must have 5 values, got {len(big_five)}")
    if len(schwartz) != 10:
        raise ValueError(f"schwartz must have 10 values, got {len(schwartz)}")
    if len(attachment) != 3:
        raise ValueError(f"attachment must have 3 values, got {len(attachment)}")

    by_dim: dict[str, float] = {}
    by_dim.update(dict(zip(BIG_FIVE_ORDER, big_five, strict=True)))
    by_dim.update(dict(zip(SCHWARTZ_ORDER, schwartz, strict=True)))
    by_dim.update(dict(zip(ATTACHMENT_ORDER, attachment, strict=True)))

    candidates: list[Candidate] = []
    for tpl in templates:
        best: tuple[float, Signal] | None = None
        for signal in tpl.applies_when:
            magnitudes = _evaluate_signal(signal, by_dim)
            if magnitudes is None:
                continue
            mean_magnitude = sum(magnitudes) / len(magnitudes)
            if best is None or mean_magnitude > best[0]:
                best = (mean_magnitude, signal)
        if best is None:
            continue
        score = tpl.priority + 10 * best[0]
        candidates.append(Candidate(template=tpl, score=score, matched_signal=best[1]))

    candidates.sort(key=lambda c: (-c.score, c.template.id))
    return tuple(candidates[:limit])


def _evaluate_signal(
    signal: Signal,
    by_dim: dict[str, float],
) -> list[float] | None:
    """Return the matching magnitudes if the signal fires, else None."""
    magnitudes: list[float] = []
    for pred in signal.all_of:
        value = by_dim[pred.dimension]
        is_attachment = pred.dimension in _ATTACHMENT_DIMS
        if pred.direction == "high":
            if value < pred.min_magnitude:
                return None
            magnitudes.append(value)
        elif pred.direction == "low":
            if is_attachment:
                if value >= pred.min_magnitude:
                    return None
                # Magnitude for an attachment "low" predicate is how
                # quiet it is — saturates at 1.0 when value == 0.
                magnitudes.append(1.0 - value)
            else:
                if value > -pred.min_magnitude:
                    return None
                magnitudes.append(-value)
        elif pred.direction == "prominent":
            mag = value if is_attachment else abs(value)
            if mag < pred.min_magnitude:
                return None
            magnitudes.append(mag)
        elif pred.direction == "muted":
            mag = value if is_attachment else abs(value)
            if mag >= pred.min_magnitude:
                return None
            # Mutedness magnitude: how close to zero (1 - mag).
            magnitudes.append(1.0 - mag)
        else:  # pragma: no cover - schema-validated upstream
            raise ValueError(f"unknown direction {pred.direction!r}")
    return magnitudes


# ---------------------------------------------------------------------------
# Convenience for production callers
# ---------------------------------------------------------------------------


def default_template_dir() -> Path:
    """Locate ``content/reflection-templates/`` from this module's path.

    Allows the gRPC server to call ``load_templates(default_template_dir())``
    without hard-coding a repo-root path.
    """
    here = Path(__file__).resolve()
    # services/ml-py/app/services/reflection_templates.py
    # parents[0]=services parents[1]=app parents[2]=ml-py
    # parents[3]=services parents[4]=repo_root
    repo_root = here.parents[4]
    direct = repo_root / "content" / "reflection-templates"
    if direct.is_dir():
        return direct
    # Fallback for sandboxed dev runs where the working dir overrides.
    env_override = os.environ.get("ECHO_REFLECTION_TEMPLATES_DIR")
    if env_override:
        return Path(env_override)
    return direct
