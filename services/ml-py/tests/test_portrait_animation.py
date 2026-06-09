"""Animation tests for the parametric Portrait renderer (T-ML-031).

Acceptance criteria (docs/07 §M2):
- animation loops smoothly;
- file size < 800 KB at 1080x1080.

These tests run at the production size (1080x1080) because the file-size
budget is part of the contract — testing at a smaller size would not
exercise the budget meaningfully.
"""

from __future__ import annotations

import io

import pytest
from PIL import Image

from app.services import portrait_renderer

# 800 KB is the docs/07 budget. We assert a slightly tighter 800_000
# bytes so any drift toward the budget is loud.
_WEBP_BYTE_BUDGET = 800_000


@pytest.fixture(scope="module")
def representative_vector() -> dict[str, tuple[float, ...]]:
    """A vector with non-trivial values across all 18 dimensions."""
    return {
        "big_five": (0.3, 0.4, -0.5, 0.2, 0.6),
        "schwartz": (0.5, -0.4, 0.6, 0.2, -0.3, 0.4, -0.5, 0.3, -0.2, 0.5),
        "attachment": (0.7, 0.3, 0.4),
    }


def test_webp_signature(representative_vector: dict[str, tuple[float, ...]]) -> None:
    out = portrait_renderer.generate(**representative_vector, animate=True)
    assert out.animated_webp.startswith(b"RIFF")
    assert b"WEBP" in out.animated_webp[:16]


def test_webp_under_size_budget_at_1080(
    representative_vector: dict[str, tuple[float, ...]],
) -> None:
    out = portrait_renderer.generate(**representative_vector, animate=True)
    assert len(out.animated_webp) < _WEBP_BYTE_BUDGET, (
        f"WebP exceeded {_WEBP_BYTE_BUDGET} byte budget: {len(out.animated_webp)} bytes. "
        f"Per docs/07 §M2 T-ML-031, file size must be < 800 KB at 1080x1080."
    )


def test_webp_frame_count_matches_animation_setting(
    representative_vector: dict[str, tuple[float, ...]],
) -> None:
    out = portrait_renderer.generate(**representative_vector, animate=True, size=256)
    img = Image.open(io.BytesIO(out.animated_webp))
    assert getattr(img, "n_frames", 1) == portrait_renderer.ANIMATION_FRAMES


def test_webp_loop_infinite(
    representative_vector: dict[str, tuple[float, ...]],
) -> None:
    """A loop count of 0 means infinite playback; the share-web Story
    surface relies on the loop never stalling."""
    out = portrait_renderer.generate(**representative_vector, animate=True, size=256)
    img = Image.open(io.BytesIO(out.animated_webp))
    # Pillow exposes loop count via .info; 0 == infinite.
    assert img.info.get("loop", 0) == 0


def test_webp_is_deterministic(
    representative_vector: dict[str, tuple[float, ...]],
) -> None:
    a = portrait_renderer.generate(**representative_vector, animate=True, size=256)
    b = portrait_renderer.generate(**representative_vector, animate=True, size=256)
    assert a.animated_webp == b.animated_webp


def test_animation_advances_between_frames(
    representative_vector: dict[str, tuple[float, ...]],
) -> None:
    """Two non-zero phases must produce different frames. Without this
    test a regression that froze the polygon rotation would silently
    pass the loop-count + signature checks."""
    palette = portrait_renderer._derive_palette(
        tuple(representative_vector["big_five"])
        + tuple(representative_vector["schwartz"])
        + tuple(representative_vector["attachment"]),
        seed=0,
    )
    base = portrait_renderer._render_static_layers(
        tuple(representative_vector["big_five"])
        + tuple(representative_vector["schwartz"])
        + tuple(representative_vector["attachment"]),
        palette=palette,
        seed=0,
        size=128,
    )
    frame_a = portrait_renderer._apply_animated_layers(
        base.copy(),
        tuple(representative_vector["big_five"])
        + tuple(representative_vector["schwartz"])
        + tuple(representative_vector["attachment"]),
        palette=palette,
        phase=0.0,
    )
    frame_b = portrait_renderer._apply_animated_layers(
        base.copy(),
        tuple(representative_vector["big_five"])
        + tuple(representative_vector["schwartz"])
        + tuple(representative_vector["attachment"]),
        palette=palette,
        phase=0.5,
    )
    assert frame_a.tobytes() != frame_b.tobytes()
