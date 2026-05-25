"""Golden tests for the parametric Portrait renderer (T-ML-030).

Per AGENTS.md §"Testing requirements", any Portrait rendering code
ships with golden tests. We pin the rendered PNG bytes for 10
representative trait vectors. A change to the renderer (geometry,
palette, animation parameters) that produces a different image for any
of these vectors must:

1. Bump ``portrait_renderer.RENDERER_VERSION_M2``.
2. Refresh the goldens by running this file with the
   ``REGENERATE_PORTRAIT_GOLDENS=1`` env var.
3. Open the resulting diff as a ``human-review-required`` PR per
   AGENTS.md §10 (trait engine boundary).

Goldens are rendered at **128x128** rather than the production 1080x1080
to keep the committed artifacts lightweight (the .png blobs total ~80 KB
for the ten vectors at 128, vs ~2 MB at 1080). The composition algorithm
is the same; only the resolution differs.

The 10 vectors cover:
- the all-zero baseline,
- the all-positive and all-negative extremes,
- five "single-trait-pinned" vectors (one per Big Five dimension),
- a "high Schwartz hedonism / openness-to-change" vector,
- a "secure attachment dominant" vector.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import NamedTuple

import pytest

from app.services import portrait_renderer

GOLDEN_DIR = Path(__file__).parent / "goldens" / "portrait"
GOLDEN_SIZE = 128


class GoldenVector(NamedTuple):
    name: str
    big_five: tuple[float, ...]
    schwartz: tuple[float, ...]
    attachment: tuple[float, ...]


_GOLDENS: tuple[GoldenVector, ...] = (
    GoldenVector(
        name="all-zero",
        big_five=(0.0, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.0, 0.0, 0.0),
    ),
    GoldenVector(
        name="all-positive",
        big_five=(0.9, 0.9, 0.9, 0.9, 0.9),
        schwartz=(0.9,) * 10,
        attachment=(0.9, 0.9, 0.9),
    ),
    GoldenVector(
        name="all-negative",
        big_five=(-0.9, -0.9, -0.9, -0.9, -0.9),
        schwartz=(-0.9,) * 10,
        # Attachment is unidirectional [0, 1]; use zeros for the
        # "negative" extreme to represent very-low attachment signal.
        attachment=(0.0, 0.0, 0.0),
    ),
    GoldenVector(
        name="high-openness",
        big_five=(0.85, 0.0, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.5, 0.0, 0.0),
    ),
    GoldenVector(
        name="high-conscientiousness",
        big_five=(0.0, 0.85, 0.0, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.5, 0.0, 0.0),
    ),
    GoldenVector(
        name="high-agreeableness",
        big_five=(0.0, 0.0, 0.85, 0.0, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.5, 0.0, 0.0),
    ),
    GoldenVector(
        name="high-neuroticism",
        big_five=(0.0, 0.0, 0.0, 0.85, 0.0),
        schwartz=(0.0,) * 10,
        attachment=(0.2, 0.7, 0.0),
    ),
    GoldenVector(
        name="high-extraversion",
        big_five=(0.0, 0.0, 0.0, 0.0, 0.85),
        schwartz=(0.0,) * 10,
        attachment=(0.5, 0.0, 0.0),
    ),
    GoldenVector(
        name="hedonism-openness-to-change",
        big_five=(0.4, -0.3, 0.0, 0.0, 0.7),
        # Schwartz dims: self-direction, stimulation, hedonism in pos
        # quadrant; tradition/conformity/security negative.
        schwartz=(0.7, 0.8, 0.9, 0.4, 0.3, -0.5, -0.6, -0.4, -0.2, -0.1),
        attachment=(0.6, 0.3, 0.0),
    ),
    GoldenVector(
        name="secure-attachment-dominant",
        big_five=(0.3, 0.4, 0.6, -0.4, 0.5),
        schwartz=(0.2, 0.1, 0.0, 0.3, 0.0, 0.4, 0.5, 0.3, 0.2, 0.1),
        attachment=(0.9, 0.1, 0.1),
    ),
)


def _golden_path(name: str) -> Path:
    return GOLDEN_DIR / f"{name}.png"


def _render(vector: GoldenVector) -> bytes:
    out = portrait_renderer.generate(
        big_five=vector.big_five,
        schwartz=vector.schwartz,
        attachment=vector.attachment,
        seed=0,
        animate=False,
        size=GOLDEN_SIZE,
    )
    return out.png


@pytest.mark.parametrize("vector", _GOLDENS, ids=[v.name for v in _GOLDENS])
def test_portrait_golden(vector: GoldenVector) -> None:
    actual = _render(vector)
    path = _golden_path(vector.name)

    if os.getenv("REGENERATE_PORTRAIT_GOLDENS") == "1":
        GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
        path.write_bytes(actual)
        pytest.skip(f"regenerated golden {vector.name}")

    assert path.exists(), (
        f"missing golden {path}; rerun with REGENERATE_PORTRAIT_GOLDENS=1 to refresh"
    )
    expected = path.read_bytes()
    assert actual == expected, (
        f"portrait golden drift on {vector.name}: "
        f"expected {len(expected)} bytes (sha-prefix={expected[:16].hex()}), "
        f"got {len(actual)} bytes (sha-prefix={actual[:16].hex()}). "
        "If this is intentional, bump portrait_renderer.RENDERER_VERSION_M2 "
        "and rerun with REGENERATE_PORTRAIT_GOLDENS=1."
    )


def test_golden_vectors_are_distinct() -> None:
    """The 10 chosen vectors must produce 10 distinct PNGs.

    Guards against accidentally picking two near-duplicate vectors that
    would silently weaken the regression net.
    """
    rendered = {v.name: _render(v) for v in _GOLDENS}
    distinct = set(rendered.values())
    assert len(distinct) == len(_GOLDENS), (
        f"expected {len(_GOLDENS)} distinct outputs, got {len(distinct)} "
        f"(some goldens collapsed to identical PNGs)"
    )
