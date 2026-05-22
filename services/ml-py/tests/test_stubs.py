"""Tests for the service stubs that have NOT yet been implemented.

These tests document the intentional NotImplementedError contract so a
future PR that replaces a stub has to explicitly delete the expectation.

`trait_scoring.score` was the M0 stub; it landed for real in T-ML-010 and
its tests live in `test_trait_scoring.py`.
"""

from __future__ import annotations

import pytest

from app.services import portrait_gen, reflection_gen


def test_portrait_gen_generate_is_unimplemented_in_m0() -> None:
    with pytest.raises(NotImplementedError, match="T-ML-030"):
        portrait_gen.generate("playthrough-test")


def test_reflection_gen_generate_is_unimplemented_in_m0() -> None:
    with pytest.raises(NotImplementedError, match="T-ML-040"):
        reflection_gen.generate("playthrough-test", youth_safe=True)
