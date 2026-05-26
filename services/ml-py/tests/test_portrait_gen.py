"""Public-API tests for the Portrait generator (T-ML-020 / T-ML-030).

These tests pin the contract the gRPC servicer + core-go rely on:
- same trait vector → byte-identical PNG;
- different vector → different PNG;
- seed sensitivity;
- shape validation;
- renderer version surface;
- ``animate=True`` adds a non-empty WebP and leaves the static PNG
  unchanged.

The visual *output* is exercised in
``tests/test_portrait_renderer_goldens.py`` (the 10 golden vectors).
"""

from __future__ import annotations

import struct

import pytest

from app.services import portrait_gen

_ZERO_BIG_FIVE = (0.0, 0.0, 0.0, 0.0, 0.0)
_ZERO_SCHWARTZ = (0.0,) * 10
_ZERO_ATTACHMENT = (0.0, 0.0, 0.0)


def _png_signature() -> bytes:
    return b"\x89PNG\r\n\x1a\n"


def _png_dimensions(png: bytes) -> tuple[int, int]:
    """Parse the IHDR chunk to confirm we're producing the right size."""
    ihdr_start = len(_png_signature()) + 4 + 4  # past length + "IHDR"
    width, height = struct.unpack(">II", png[ihdr_start : ihdr_start + 8])
    return width, height


def test_returns_a_valid_png() -> None:
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.png.startswith(_png_signature())
    width, height = _png_dimensions(assets.png)
    # M2 renderer ships 1080x1080. Tests in
    # tests/test_portrait_renderer_goldens.py use a smaller size to
    # keep the committed golden fixtures lightweight.
    assert width == 1080
    assert height == 1080


def test_same_vector_produces_byte_identical_png() -> None:
    vector = dict(
        big_five=(0.2, -0.4, 0.6, 0.1, -0.3),
        schwartz=(0.1, 0.2, 0.3, 0.4, 0.5, -0.1, -0.2, -0.3, -0.4, -0.5),
        attachment=(0.7, 0.2, 0.5),
    )
    a = portrait_gen.generate(**vector)
    b = portrait_gen.generate(**vector)
    assert a.png == b.png
    assert a.renderer_version == b.renderer_version


def test_different_vectors_produce_different_pngs() -> None:
    a = portrait_gen.generate(
        big_five=(0.5, 0.0, 0.0, 0.0, 0.0),
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    b = portrait_gen.generate(
        big_five=(0.0, 0.0, 0.0, 0.0, 0.5),
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert a.png != b.png


def test_different_seeds_produce_different_outputs() -> None:
    vector = dict(
        big_five=(0.2, -0.4, 0.6, 0.1, -0.3),
        schwartz=(0.1, 0.2, 0.3, 0.4, 0.5, -0.1, -0.2, -0.3, -0.4, -0.5),
        attachment=(0.7, 0.2, 0.5),
    )
    a = portrait_gen.generate(**vector, seed=0)
    b = portrait_gen.generate(**vector, seed=42)
    assert a.png != b.png


def test_renderer_version_is_m2() -> None:
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.renderer_version == portrait_gen.RENDERER_VERSION
    assert assets.renderer_version == 2


def test_r2_keys_are_empty_by_default() -> None:
    # T-CORE-030 (sharing endpoint, M2) writes to R2 and populates these
    # keys. The renderer itself never touches object storage.
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.static_png_key == ""
    assert assets.animated_webp_key == ""


def test_animation_off_by_default() -> None:
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.animated_webp == b""


def test_animate_emits_webp_and_preserves_static_png() -> None:
    vector = dict(
        big_five=(0.2, -0.4, 0.6, 0.1, -0.3),
        schwartz=(0.1, 0.2, 0.3, 0.4, 0.5, -0.1, -0.2, -0.3, -0.4, -0.5),
        attachment=(0.7, 0.2, 0.5),
    )
    plain = portrait_gen.generate(**vector)
    animated = portrait_gen.generate(**vector, animate=True)
    # Animation must NOT alter the static frame — the share-web Story
    # surface uses the static PNG as the poster image.
    assert plain.png == animated.png
    # WebP must be present and start with RIFF/WEBP magic.
    assert animated.animated_webp.startswith(b"RIFF")
    assert b"WEBP" in animated.animated_webp[:16]


@pytest.mark.parametrize(
    ("big_five", "schwartz", "attachment"),
    [
        ((0.0,) * 4, _ZERO_SCHWARTZ, _ZERO_ATTACHMENT),  # 4 instead of 5
        (_ZERO_BIG_FIVE, (0.0,) * 9, _ZERO_ATTACHMENT),  # 9 instead of 10
        (_ZERO_BIG_FIVE, _ZERO_SCHWARTZ, (0.0, 0.0)),  # 2 instead of 3
    ],
)
def test_wrong_dimension_count_raises_value_error(
    big_five: tuple[float, ...],
    schwartz: tuple[float, ...],
    attachment: tuple[float, ...],
) -> None:
    with pytest.raises(ValueError, match="must have"):
        portrait_gen.generate(
            big_five=big_five,
            schwartz=schwartz,
            attachment=attachment,
        )
