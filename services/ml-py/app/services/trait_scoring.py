"""Trait scoring service stub.

Real implementation lands at M1 (T-ML-010 / T-ML-011). See
``packages/proto/trait_scoring.proto`` for the gRPC contract and
``docs/04_Game_Design.md`` §"Trait model" for the design.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class TraitVector:
    """Output of the trait scoring engine.

    Big Five values are floats in ``[-1.0, 1.0]``. Schwartz values map to the
    10 dimensions defined by Shalom Schwartz. Attachment proxies are floats
    in ``[0.0, 1.0]``.

    The vector is deterministic for a given playthrough event log: the
    ``trait-replay`` tool reproduces it byte-identical on repeated runs.
    """

    big_five: tuple[float, float, float, float, float]
    schwartz: tuple[float, ...]
    attachment: tuple[float, float, float]


def score(playthrough_id: str) -> TraitVector:
    """Stub. Returns a zero vector. M1 replaces this with real scoring.

    Args:
        playthrough_id: stable ID of the playthrough whose events to score.

    Raises:
        NotImplementedError: always, in M0.
    """
    del playthrough_id  # silence unused-arg until M1 implementation
    msg = "trait scoring not implemented in M0; see T-ML-010"
    raise NotImplementedError(msg)
