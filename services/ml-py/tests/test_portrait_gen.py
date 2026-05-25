"""Tests for the M1 Portrait stub (T-ML-020).

Acceptance: same trait vector -> same PNG; different vector -> different PNG.
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


def test_returns_a_valid_png() -> None:
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.png.startswith(_png_signature())
    # IHDR chunk follows: 4 length + 4 type "IHDR" + 13 data + 4 crc
    ihdr_start = len(_png_signature()) + 4 + 4  # past length + "IHDR"
    width, height = struct.unpack(">II", assets.png[ihdr_start : ihdr_start + 8])
    assert width == 64
    assert height == 64


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


def test_different_seeds_produce_different_palettes() -> None:
    vector = dict(
        big_five=(0.2, -0.4, 0.6, 0.1, -0.3),
        schwartz=(0.1, 0.2, 0.3, 0.4, 0.5, -0.1, -0.2, -0.3, -0.4, -0.5),
        attachment=(0.7, 0.2, 0.5),
    )
    a = portrait_gen.generate(**vector, seed=0)
    b = portrait_gen.generate(**vector, seed=42)
    assert a.png != b.png


def test_renderer_version_is_m1() -> None:
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.renderer_version == portrait_gen.RENDERER_VERSION_M1


def test_r2_keys_are_empty_in_m1() -> None:
    # M2 will populate these once we upload to object storage.
    assets = portrait_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert assets.static_png_key == ""
    assert assets.animated_webp_key == ""


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
