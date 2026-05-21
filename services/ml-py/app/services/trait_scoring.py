"""Rule-based trait scoring (T-ML-010).

The M1 engine is intentionally boring: aggregate the signed `delta` of every
TraitWeight attached to the player's chosen Choice, then clamp the result
per dimension.

Why rule-based? Three reasons:

1. **Deterministic.** ``trait-replay`` over a corpus of pinned playthroughs
   must produce byte-identical vectors. A linear sum has no model weights to
   drift, no temperature, no nondeterminism.
2. **Auditable.** Content authors can reason about their TraitWeights without
   the engine being a black box; this is necessary for the youth-safe path
   (docs/08 §"Bounds on inference").
3. **Sufficient.** docs/04 calibrates the content so that authored TraitWeights
   already encode the desired signal. The M2 engine (T-ML-014) will add
   deliberation-time features on top of this base.

Clamping bounds (docs/04 §"Trait model"):
  * Big Five (``OCEAN-*``)  -> [-1.0, 1.0]
  * Schwartz (``SCH-*``)    -> [-1.0, 1.0]
  * Attachment (``ATT-*``)  -> [ 0.0, 1.0]

Behaviour for missing dimensions: a vector that comes back from this engine
always reports the **18 canonical dimensions**, even if no weight contributed
to a given dimension (value defaults to 0.0). This is what the downstream
PortraitGen / ReflectionGen contracts in T-ML-020/021 expect.

The exposed function signature returns a plain dict so the FastAPI handler
can serialise it directly; the dataclass is kept for the trait-replay CLI
which prefers structured access.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Canonical dimensions
# ---------------------------------------------------------------------------

# Mirrors services/core-go/content/types.go::AllDimensions and
# packages/content-schema/trait_weight.schema.json. Keep these three in lockstep.

OCEAN_DIMENSIONS: tuple[str, ...] = (
    "OCEAN-O",
    "OCEAN-C",
    "OCEAN-E",
    "OCEAN-A",
    "OCEAN-N",
)

SCHWARTZ_DIMENSIONS: tuple[str, ...] = (
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

ATTACHMENT_DIMENSIONS: tuple[str, ...] = (
    "ATT-SECURE",
    "ATT-ANXIOUS",
    "ATT-AVOIDANT",
)

ALL_DIMENSIONS: tuple[str, ...] = (
    *OCEAN_DIMENSIONS,
    *SCHWARTZ_DIMENSIONS,
    *ATTACHMENT_DIMENSIONS,
)

SCORING_VERSION: str = "rule-v1"

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TraitWeight:
    """One signed contribution from a single choice."""

    dimension: str
    delta: float


@dataclass(frozen=True, slots=True)
class TraitVector:
    """The result of aggregating a playthrough's weights.

    ``values`` is the post-clamp, dimension-complete mapping the downstream
    PortraitGen and ReflectionGen contracts consume. ``scoring_version`` is
    stamped at compute time so the database row can be re-derived later.
    """

    values: Mapping[str, float]
    scoring_version: str = SCORING_VERSION


@dataclass(slots=True)
class ScoreReport:
    """Diagnostic accompaniment to a [TraitVector].

    Returned by [`score_weights`] for debugging and for the
    `tools/trait-replay` CLI. Not surfaced through the production API.
    """

    raw_totals: dict[str, float] = field(default_factory=dict)
    unknown_dimensions: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def score_weights(
    weights: Iterable[TraitWeight],
) -> tuple[TraitVector, ScoreReport]:
    """Aggregate the provided weights into a clamped, dimension-complete vector.

    Args:
        weights: every TraitWeight from every Choice the player committed.
            Order does not matter; the operation is commutative and
            associative (linear sum followed by per-dimension clamp).

    Returns:
        A tuple of (TraitVector, ScoreReport). The vector exposes the
        18 canonical dimensions with floats; the report carries the
        un-clamped totals and any unknown dimensions seen on the wire
        (the production server treats unknowns as a soft warning rather
        than a hard error so content authors can preview a new dimension
        before the engine is updated for it).
    """
    totals: dict[str, float] = {d: 0.0 for d in ALL_DIMENSIONS}
    unknown: list[str] = []
    for w in weights:
        if w.dimension not in totals:
            unknown.append(w.dimension)
            continue
        totals[w.dimension] += float(w.delta)

    clamped: dict[str, float] = {}
    for d in ALL_DIMENSIONS:
        raw = totals[d]
        lo, hi = _bounds_for(d)
        if raw < lo:
            clamped[d] = lo
        elif raw > hi:
            clamped[d] = hi
        else:
            clamped[d] = raw

    return (
        TraitVector(values=clamped),
        ScoreReport(raw_totals=dict(totals), unknown_dimensions=unknown),
    )


# Backwards-compatible alias for callers that still treat the engine as a
# simple function. The signature returns only the TraitVector (no report).
def score_vector(weights: Iterable[TraitWeight]) -> TraitVector:
    vector, _ = score_weights(weights)
    return vector


# Compatibility shim with the M0 stub signature. Kept so old callers /
# tests that referenced ``trait_scoring.score(playthrough_id)`` get a
# clear "playthrough_id-only signature is no longer supported" message.
def score(playthrough_id: str) -> TraitVector:  # pragma: no cover
    """Removed. Use :func:`score_weights` instead.

    Args:
        playthrough_id: kept only so the signature matches the M0 stub
            and existing imports don't break.

    Raises:
        NotImplementedError: always — the engine is now stateless and
            consumes weights, not playthrough ids.
    """
    del playthrough_id
    msg = (
        "trait_scoring.score(playthrough_id) is replaced by "
        "trait_scoring.score_weights(weights); see T-ML-010."
    )
    raise NotImplementedError(msg)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------


def _bounds_for(dimension: str) -> tuple[float, float]:
    if dimension in ATTACHMENT_DIMENSIONS:
        return (0.0, 1.0)
    return (-1.0, 1.0)
