"""Tests for the M1 reflection stub (T-ML-021).

Acceptance: response includes recognizable trait-derived language.
"""

from __future__ import annotations

import pytest

from app.services import reflection_gen

_ZERO_BIG_FIVE = (0.0, 0.0, 0.0, 0.0, 0.0)
_ZERO_SCHWARTZ = (0.0,) * 10
_ZERO_ATTACHMENT = (0.0, 0.0, 0.0)


def test_high_openness_yields_openness_language() -> None:
    # Spike OCEAN-O high; everything else flat.
    r = reflection_gen.generate(
        big_five=(0.9, 0.0, 0.0, 0.0, 0.0),
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert "you reach toward what is unfamiliar" in r.text


def test_low_openness_yields_low_pole_language() -> None:
    # Bipolar dimension: low pole should also appear.
    r = reflection_gen.generate(
        big_five=(-0.9, 0.0, 0.0, 0.0, 0.0),
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert "you stay close to what you already trust" in r.text


def test_high_anxious_attachment_yields_attachment_language() -> None:
    r = reflection_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=(0.0, 0.9, 0.0),
    )
    assert "you watch the door even when no one is at it" in r.text


def test_low_attachment_intensity_is_not_mentioned() -> None:
    # Attachment proxies are [0, 1]; only the high pole reads as
    # reflection material. A 0.1 anxious score should NOT trigger.
    r = reflection_gen.generate(
        big_five=(0.9, 0.0, 0.0, 0.0, 0.0),  # something else triggers
        schwartz=_ZERO_SCHWARTZ,
        attachment=(0.0, 0.1, 0.0),
    )
    assert "you watch the door even when no one is at it" not in r.text


def test_same_vector_produces_same_reflection() -> None:
    vector = dict(
        big_five=(0.2, -0.4, 0.6, 0.1, -0.3),
        schwartz=(0.1, 0.2, 0.3, 0.4, 0.5, -0.1, -0.2, -0.3, -0.4, -0.5),
        attachment=(0.7, 0.2, 0.5),
    )
    a = reflection_gen.generate(**vector)
    b = reflection_gen.generate(**vector)
    assert a.text == b.text
    assert a.template_id == b.template_id
    assert a.used_fallback is False


def test_different_dominant_dimension_produces_different_reflections() -> None:
    a = reflection_gen.generate(
        big_five=(0.9, 0.0, 0.0, 0.0, 0.0),
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    b = reflection_gen.generate(
        big_five=(0.0, 0.0, 0.0, 0.0, 0.9),
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert a.text != b.text


def test_at_most_three_phrases() -> None:
    # Spike every dimension; reflection should still cap at three to
    # stay under five sentences.
    r = reflection_gen.generate(
        big_five=(0.9, 0.9, 0.9, 0.9, 0.9),
        schwartz=(0.9,) * 10,
        attachment=(0.9, 0.9, 0.9),
    )
    # Three phrases separated by "; ", so two semicolons in the body.
    assert r.text.count(";") == 2


def test_flat_vector_falls_back_to_neutral_sentence() -> None:
    r = reflection_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert "moved through the day quietly" in r.text


def test_template_id_is_m1_stub() -> None:
    r = reflection_gen.generate(
        big_five=_ZERO_BIG_FIVE,
        schwartz=_ZERO_SCHWARTZ,
        attachment=_ZERO_ATTACHMENT,
    )
    assert r.template_id.startswith("m1-stub.")
    assert r.used_fallback is False


def test_youth_safe_does_not_change_m1_stub_output() -> None:
    # M2 swaps prompt profiles based on youth_safe; M1 stub uses the
    # same templated phrases either way (no LLM to switch).
    vector = dict(
        big_five=(0.5, 0.2, 0.0, -0.3, 0.1),
        schwartz=_ZERO_SCHWARTZ,
        attachment=(0.6, 0.0, 0.0),
    )
    a = reflection_gen.generate(**vector, youth_safe=False)
    b = reflection_gen.generate(**vector, youth_safe=True)
    assert a.text == b.text


@pytest.mark.parametrize(
    ("big_five", "schwartz", "attachment"),
    [
        ((0.0,) * 4, _ZERO_SCHWARTZ, _ZERO_ATTACHMENT),
        (_ZERO_BIG_FIVE, (0.0,) * 9, _ZERO_ATTACHMENT),
        (_ZERO_BIG_FIVE, _ZERO_SCHWARTZ, (0.0, 0.0)),
    ],
)
def test_wrong_dimension_count_raises_value_error(
    big_five: tuple[float, ...],
    schwartz: tuple[float, ...],
    attachment: tuple[float, ...],
) -> None:
    with pytest.raises(ValueError, match="must have"):
        reflection_gen.generate(
            big_five=big_five,
            schwartz=schwartz,
            attachment=attachment,
        )
