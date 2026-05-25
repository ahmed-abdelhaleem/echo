"""Reflection generation stub (T-ML-021).

The real two-stage pipeline (LLM completion -> safety classifier ->
tone classifier) lands at M2 (T-ML-040..042). This M1 stub returns a
deterministic templated string composed of trait-derived language —
no LLM call, no network egress, no API keys required.

The acceptance criterion is "response includes recognizable
trait-derived language" (docs/07_AI_Agent_Implementation_Guide.md
T-ML-021). We do that by picking phrases keyed on which trait
dimension is the strongest signal — e.g. high openness yields
"you reach toward what is unfamiliar", high conscientiousness yields
"you tidy the path before you walk down it", high anxious-attachment
yields "you watch the door even when no one is at it". Two
playthroughs with different dominant traits produce different
reflections.

The phrases live in this file (not in ``content/reflection-templates/``)
because the M1 stub is *not* part of the M2 brand-voice review surface.
Once the real template library lands (T-ML-040), this stub is
deleted; the proto contract stays.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final

# Bump when the templated language changes in a way that would
# produce different text for the same trait vector. core-go can
# stash this for audit / replay.
STUB_VERSION_M1 = 1


@dataclass(frozen=True, slots=True)
class Reflection:
    """One generated reflection plus its audit metadata."""

    text: str
    template_id: str
    used_fallback: bool


# Trait-dimension order mirrors trait_scoring.BIG_FIVE_ORDER etc. Each
# entry is (high_pole_phrase, low_pole_phrase). For Big Five and
# Schwartz the value is in [-1, 1] so both poles are meaningful; for
# attachment the value is in [0, 1] and the low pole reads as "this
# style was not prominent today".
_LANGUAGE: Final[dict[str, tuple[str, str]]] = {
    # Big Five
    "OCEAN-O": (
        "you reach toward what is unfamiliar",
        "you stay close to what you already trust",
    ),
    "OCEAN-C": (
        "you tidy the path before you walk down it",
        "you let the path unfold one step at a time",
    ),
    "OCEAN-E": (
        "you draw warmth out of the room",
        "you let the room come to you on its own terms",
    ),
    "OCEAN-A": (
        "you keep the other person whole",
        "you keep your own line steady",
    ),
    "OCEAN-N": (
        "you carry the weight of the moment with you",
        "you set the weight of the moment down quickly",
    ),
    # Schwartz
    "SCH-SELF_DIRECTION": (
        "you choose your own way",
        "you take the shape the situation hands you",
    ),
    "SCH-STIMULATION": (
        "you turn toward what crackles",
        "you turn toward what is quiet",
    ),
    "SCH-HEDONISM": (
        "you let pleasure be a reason",
        "you let pleasure be a small thing",
    ),
    "SCH-ACHIEVEMENT": (
        "you mind whether the work was done well",
        "you mind whether the work was done at all",
    ),
    "SCH-POWER": (
        "you take up the room when the room asks for it",
        "you take up just enough room and no more",
    ),
    "SCH-SECURITY": (
        "you check the locks",
        "you leave the door on the latch",
    ),
    "SCH-CONFORMITY": (
        "you keep within the lines that others drew",
        "you redraw the lines as you go",
    ),
    "SCH-TRADITION": (
        "you honour what was passed down",
        "you set down what was passed down",
    ),
    "SCH-BENEVOLENCE": (
        "you keep the people near you warm",
        "you let them find their own warmth",
    ),
    "SCH-UNIVERSALISM": (
        "you keep the people far from you in mind",
        "you keep your circle small and tend it close",
    ),
    # Attachment proxies — low pole reads as "not prominent today"
    "ATT-SECURE": (
        "you trust that the people in the room are still there",
        "you watch to see if the people in the room are still there",
    ),
    "ATT-ANXIOUS": (
        "you watch the door even when no one is at it",
        "you let the door be a door",
    ),
    "ATT-AVOIDANT": (
        "you keep a little distance, just in case",
        "you let the distance close",
    ),
}

# Dimension order must match trait_scoring.BIG_FIVE_ORDER +
# SCHWARTZ_ORDER + ATTACHMENT_ORDER exactly. Tests assert this.
_DIMENSION_ORDER: Final[tuple[str, ...]] = (
    "OCEAN-O",
    "OCEAN-C",
    "OCEAN-E",
    "OCEAN-A",
    "OCEAN-N",
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
    "ATT-SECURE",
    "ATT-ANXIOUS",
    "ATT-AVOIDANT",
)

# Bipolar dimensions (Big Five + Schwartz) use both poles; attachment
# uses the "high pole" only when the value is high enough, else the
# trait is omitted from the reflection.
_ATTACHMENT_DIMENSIONS: Final[frozenset[str]] = frozenset(
    {"ATT-SECURE", "ATT-ANXIOUS", "ATT-AVOIDANT"},
)

# Threshold below which an attachment proxy is not prominent enough to
# mention. The bipolar dimensions are mentioned whenever |value| >=
# _BIPOLAR_THRESHOLD; this saves the reflection from cataloguing every
# near-zero dimension.
_BIPOLAR_THRESHOLD: Final[float] = 0.15
_ATTACHMENT_THRESHOLD: Final[float] = 0.30


def generate(
    *,
    big_five: tuple[float, ...],
    schwartz: tuple[float, ...],
    attachment: tuple[float, ...],
    youth_safe: bool = False,
    locale: str = "en-GB",
) -> Reflection:
    """Render a deterministic templated reflection from a trait vector.

    Args:
        big_five: 5-tuple of Big Five scores in ``[-1, 1]``.
        schwartz: 10-tuple of Schwartz scores in ``[-1, 1]``.
        attachment: 3-tuple of attachment proxies in ``[0, 1]``.
        youth_safe: kept for proto-contract parity with M2. The stub
            uses the same templated phrases either way; M2's real
            pipeline switches prompt profiles when this flag is on.
        locale: BCP-47 locale. M1 stub supports only "en-GB"; non-en-GB
            locales fall back silently (logged at the gRPC layer).

    Returns:
        ``Reflection`` with templated text, a stable ``template_id``
        identifying the stub, and ``used_fallback=False`` because the
        stub never invokes a fallback path (there is no LLM to fail).

    Raises:
        ValueError: if any dimension array has the wrong shape.
    """
    del youth_safe, locale  # M1 stub ignores both; M2 picks them up.

    if len(big_five) != 5:
        raise ValueError(f"big_five must have 5 values, got {len(big_five)}")
    if len(schwartz) != 10:
        raise ValueError(f"schwartz must have 10 values, got {len(schwartz)}")
    if len(attachment) != 3:
        raise ValueError(f"attachment must have 3 values, got {len(attachment)}")

    by_dim = dict(
        zip(
            _DIMENSION_ORDER,
            tuple(big_five) + tuple(schwartz) + tuple(attachment),
            strict=True,
        ),
    )

    # Pick the strongest signal first, then walk down. We cap at the
    # top three so the reflection stays under five sentences.
    ranked = sorted(
        by_dim.items(),
        key=lambda kv: -abs(kv[1]),
    )

    phrases: list[str] = []
    for dim, value in ranked:
        phrase = _phrase_for(dim, value)
        if phrase is None:
            continue
        phrases.append(phrase)
        if len(phrases) >= 3:
            break

    if not phrases:
        # All dimensions sat at exactly zero. Fall back to a stable
        # phrase so the client never sees an empty reflection.
        text = (
            "Today you moved through the day quietly, leaving little to read in either direction."
        )
    else:
        intro = "Today, "
        body = "; ".join(phrases)
        text = f"{intro}{body}."

    return Reflection(
        text=text,
        template_id=f"m1-stub.v{STUB_VERSION_M1}",
        used_fallback=False,
    )


def _phrase_for(dim: str, value: float) -> str | None:
    """Return the phrase for `dim` at `value`, or None if too weak to mention."""
    high, low = _LANGUAGE[dim]
    if dim in _ATTACHMENT_DIMENSIONS:
        # Attachment proxies are [0, 1] intensities. Only mention the
        # high pole when prominent; "not prominent" doesn't read as
        # reflection material.
        if value >= _ATTACHMENT_THRESHOLD:
            return high
        return None
    # Bipolar: meaningful in either direction.
    if value >= _BIPOLAR_THRESHOLD:
        return high
    if value <= -_BIPOLAR_THRESHOLD:
        return low
    return None
