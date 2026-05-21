"""Reflection generation service stub.

Two-stage pipeline (LLM completion → safety classify → tone classify → output)
lands at M2 (T-ML-040 / T-ML-041 / T-ML-042). See
``packages/proto/reflection_gen.proto`` and ``docs/04_Game_Design.md``
§"The prose reflection".
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Reflection:
    """One generated reflection plus its audit metadata."""

    text: str
    template_id: str
    used_fallback: bool


def generate(playthrough_id: str, *, youth_safe: bool, locale: str = "en-GB") -> Reflection:
    """Stub. Returns NotImplementedError until M2.

    Args:
        playthrough_id: stable ID of the playthrough to reflect on.
        youth_safe: when True the stricter prompt profile is used.
        locale: BCP-47 locale. Only ``en-GB`` is planned for V1.

    Raises:
        NotImplementedError: always, in M0.
    """
    del playthrough_id, youth_safe, locale
    msg = "reflection generation not implemented in M0; see T-ML-040"
    raise NotImplementedError(msg)
