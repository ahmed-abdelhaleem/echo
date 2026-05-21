"""Tests for the M0 service stubs.

PR 9 (T-ML-010) replaces the trait_scoring stub with a real engine, so the
trait_scoring assertion has moved to ``test_trait_scoring.py``. The portrait
and reflection stubs remain — they are replaced in PR 10.
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
