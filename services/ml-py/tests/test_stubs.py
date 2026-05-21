"""Tests for the service stubs.

These tests document the intentional NotImplementedError contract of M0 so a
future M1 PR that replaces the stub has to explicitly delete these expectations.
"""

from __future__ import annotations

import pytest

from app.services import portrait_gen, reflection_gen, trait_scoring


def test_trait_scoring_score_is_unimplemented_in_m0() -> None:
    with pytest.raises(NotImplementedError, match="T-ML-010"):
        trait_scoring.score("playthrough-test")


def test_portrait_gen_generate_is_unimplemented_in_m0() -> None:
    with pytest.raises(NotImplementedError, match="T-ML-030"):
        portrait_gen.generate("playthrough-test")


def test_reflection_gen_generate_is_unimplemented_in_m0() -> None:
    with pytest.raises(NotImplementedError, match="T-ML-040"):
        reflection_gen.generate("playthrough-test", youth_safe=True)
