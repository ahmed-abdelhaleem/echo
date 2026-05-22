"""Rule-based trait scoring (T-ML-010).

The engine is a pure function of (Season, choice_events):

  vector[d] = sum(weight.delta for weight in chosen_weights if weight.dimension == d)
  vector[d] = clamp(vector[d], lo, hi)

For Big Five and Schwartz dimensions the range is ``[-1.0, 1.0]``;
attachment proxies live in ``[0.0, 1.0]`` because they are conceptually
intensities, not bipolar contrasts (docs/04_Game_Design.md §"Trait model").

The function is deterministic: same input -> byte-identical output.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

# Canonical, ordered enums. These must stay in sync with
# services/core-go/content/types.go and
# packages/content-schema/trait_weight.schema.json.
BIG_FIVE_ORDER: tuple[str, ...] = (
    "OCEAN-O",
    "OCEAN-C",
    "OCEAN-E",
    "OCEAN-A",
    "OCEAN-N",
)

SCHWARTZ_ORDER: tuple[str, ...] = (
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

ATTACHMENT_ORDER: tuple[str, ...] = (
    "ATT-SECURE",
    "ATT-ANXIOUS",
    "ATT-AVOIDANT",
)


@dataclass(frozen=True, slots=True)
class TraitVector:
    """Output of the trait scoring engine.

    Big Five values are floats in ``[-1.0, 1.0]``. Schwartz values map to
    the 10 dimensions defined by Shalom Schwartz, also clamped to
    ``[-1.0, 1.0]``. Attachment proxies are floats in ``[0.0, 1.0]``.

    The vector is deterministic for a given (season, events) input: the
    ``trait-replay`` tool (M2) reproduces it byte-identical on repeated
    runs.
    """

    big_five: tuple[float, float, float, float, float]
    schwartz: tuple[float, float, float, float, float, float, float, float, float, float]
    attachment: tuple[float, float, float]


@dataclass(frozen=True, slots=True)
class ScoredChoice:
    """One recorded choice on a single vignette."""

    vignette_id: str
    choice_id: str


class SeasonNotFoundError(LookupError):
    """Raised when the requested season_id has no `season.json` on disk."""


class UnknownVignetteError(LookupError):
    """Raised when a ScoredChoice points at a vignette not in the Season."""


class UnknownChoiceError(LookupError):
    """Raised when a ScoredChoice points at a choice not on the vignette."""


# Default location of the content tree. Production deployments mount the
# tree as a read-only volume; unit tests pass an explicit `content_root`.
# `parents[4]` is the repo root from `services/ml-py/app/services/trait_scoring.py`.
DEFAULT_CONTENT_ROOT = Path(__file__).resolve().parents[4] / "content" / "seasons"


def score(
    *,
    season_id: str,
    events: Sequence[ScoredChoice],
    content_root: Path | None = None,
) -> TraitVector:
    """Aggregate trait weights across the events into a TraitVector.

    The Season is loaded fresh from disk on each call. This is intentional:
    the M1 deployment runs the scorer behind a long-lived gRPC server, so
    each call must re-resolve in case content was hot-swapped. M2 will add
    a memoizing loader if profiling indicates it's worth doing.

    Args:
        season_id: The Season whose vignettes/choices the events refer to.
        events: The finalized choice log, in commit order. Order is not
            material to the output (sum is commutative).
        content_root: Override of the directory under which `{season_id}/season.json`
            lives. Defaults to `content/seasons/` relative to the repo root.

    Returns:
        TraitVector with all 18 dimensions populated.

    Raises:
        SeasonNotFoundError: no `season.json` for the given id.
        UnknownVignetteError: an event referenced a missing vignette.
        UnknownChoiceError: an event referenced a missing choice.
    """
    effective_root = content_root if content_root is not None else DEFAULT_CONTENT_ROOT
    season = _load_season(season_id, content_root=effective_root)
    choice_index = _index_choices(season)

    big_five: dict[str, float] = dict.fromkeys(BIG_FIVE_ORDER, 0.0)
    schwartz: dict[str, float] = dict.fromkeys(SCHWARTZ_ORDER, 0.0)
    attachment: dict[str, float] = dict.fromkeys(ATTACHMENT_ORDER, 0.0)

    for ev in events:
        if ev.vignette_id not in choice_index:
            raise UnknownVignetteError(
                f"vignette {ev.vignette_id!r} not in season {season_id!r}",
            )
        choices = choice_index[ev.vignette_id]
        if ev.choice_id not in choices:
            raise UnknownChoiceError(
                f"choice {ev.choice_id!r} not on vignette {ev.vignette_id!r}",
            )
        for weight in choices[ev.choice_id]:
            dim_raw = weight.get("dimension")
            delta_raw = weight.get("delta")
            if not isinstance(dim_raw, str) or not isinstance(delta_raw, (int, float)):
                continue
            dim = dim_raw
            delta = float(delta_raw)
            if dim in big_five:
                big_five[dim] += delta
            elif dim in schwartz:
                schwartz[dim] += delta
            elif dim in attachment:
                attachment[dim] += delta
            # Unknown dimensions are silently ignored — content authors
            # are not allowed to invent new dimensions without bumping the
            # trait dimension enum, and the content-validator enforces
            # this at PR time. We don't want to fail a player's
            # playthrough over a content authoring bug; the validator
            # gate is already loud.

    # Big Five and Schwartz are bipolar contrasts in [-1, 1].
    # Attachment proxies are intensities in [0, 1].
    bf = tuple(_clamp(big_five[d], lo=-1.0, hi=1.0) for d in BIG_FIVE_ORDER)
    sw = tuple(_clamp(schwartz[d], lo=-1.0, hi=1.0) for d in SCHWARTZ_ORDER)
    at = tuple(_clamp(attachment[d], lo=0.0, hi=1.0) for d in ATTACHMENT_ORDER)
    return TraitVector(
        big_five=(bf[0], bf[1], bf[2], bf[3], bf[4]),
        schwartz=(sw[0], sw[1], sw[2], sw[3], sw[4], sw[5], sw[6], sw[7], sw[8], sw[9]),
        attachment=(at[0], at[1], at[2]),
    )


def _load_season(season_id: str, *, content_root: Path) -> dict[str, object]:
    path = content_root / season_id / "season.json"
    if not path.is_file():
        raise SeasonNotFoundError(f"no season.json at {path}")
    with path.open("r", encoding="utf-8") as fh:
        data: object = json.load(fh)
    if not isinstance(data, dict):
        # season.json is contractually an object; treat anything else as
        # "not found" so the gRPC layer maps it to NOT_FOUND rather than
        # propagating a TypeError.
        raise SeasonNotFoundError(f"season.json at {path} is not a JSON object")
    return data


def _index_choices(
    season: dict[str, object],
) -> dict[str, dict[str, list[dict[str, object]]]]:
    """Build a (vignette_id -> choice_id -> [weights]) index.

    Pre-indexing avoids quadratic scans over the season for each event.
    """
    out: dict[str, dict[str, list[dict[str, object]]]] = {}
    acts = season.get("acts", [])
    if not isinstance(acts, list):
        return out
    for act in acts:
        if not isinstance(act, dict):
            continue
        vignettes = act.get("vignettes", [])
        if not isinstance(vignettes, list):
            continue
        for v in vignettes:
            if not isinstance(v, dict):
                continue
            vid = v.get("id")
            if not isinstance(vid, str):
                continue
            by_choice: dict[str, list[dict[str, object]]] = {}
            choices = v.get("choices", [])
            if not isinstance(choices, list):
                continue
            for c in choices:
                if not isinstance(c, dict):
                    continue
                cid = c.get("id")
                weights = c.get("weights", [])
                if not isinstance(cid, str) or not isinstance(weights, list):
                    continue
                by_choice[cid] = [w for w in weights if isinstance(w, dict)]
            out[vid] = by_choice
    return out


def _clamp(value: float, *, lo: float, hi: float) -> float:
    if value < lo:
        return lo
    if value > hi:
        return hi
    return value
