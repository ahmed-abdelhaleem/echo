"""Tests for the rule-based trait scoring engine (T-ML-010).

These tests pin the contract the rest of the system depends on:

- output dimension set
- determinism (same input -> same output)
- clamping bounds per dimension family
- additive aggregation
- behaviour with unknown dimensions (soft warn, do not raise)

The HTTP layer is covered separately in :mod:`test_score_endpoint`.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app.main import create_app
from app.services import trait_scoring
from app.services.trait_scoring import (
    ALL_DIMENSIONS,
    ATTACHMENT_DIMENSIONS,
    SCORING_VERSION,
    TraitWeight,
    score_vector,
    score_weights,
)


def test_all_dimensions_has_18_canonical_entries() -> None:
    # Five OCEAN + ten Schwartz + three Attachment = eighteen.
    assert len(ALL_DIMENSIONS) == 18
    assert len(set(ALL_DIMENSIONS)) == 18


def test_empty_input_returns_zero_vector_with_all_dimensions() -> None:
    vector, report = score_weights([])
    assert vector.scoring_version == SCORING_VERSION
    assert set(vector.values.keys()) == set(ALL_DIMENSIONS)
    assert all(v == 0.0 for v in vector.values.values())
    assert report.unknown_dimensions == []


def test_single_weight_aggregates_to_that_dimension() -> None:
    vector = score_vector([TraitWeight("OCEAN-O", 0.3)])
    assert vector.values["OCEAN-O"] == 0.3
    # Every other dimension defaults to zero.
    other_dims = [d for d in ALL_DIMENSIONS if d != "OCEAN-O"]
    assert all(vector.values[d] == 0.0 for d in other_dims)


def test_multiple_weights_sum_per_dimension() -> None:
    vector = score_vector(
        [
            TraitWeight("OCEAN-C", 0.2),
            TraitWeight("OCEAN-C", 0.3),
            TraitWeight("OCEAN-E", -0.1),
        ]
    )
    assert vector.values["OCEAN-C"] == 0.5
    assert vector.values["OCEAN-E"] == -0.1


def test_aggregation_is_order_independent() -> None:
    weights_a = [TraitWeight("OCEAN-O", 0.4), TraitWeight("SCH-POWER", -0.3)]
    weights_b = list(reversed(weights_a))
    assert score_vector(weights_a).values == score_vector(weights_b).values


def test_clamp_positive_for_signed_dimensions() -> None:
    # Aggregating beyond +1.0 must clamp to +1.0 for OCEAN / Schwartz.
    vector = score_vector([TraitWeight("OCEAN-O", 0.7), TraitWeight("OCEAN-O", 0.7)])
    assert vector.values["OCEAN-O"] == 1.0


def test_clamp_negative_for_signed_dimensions() -> None:
    vector = score_vector([TraitWeight("SCH-POWER", -0.6), TraitWeight("SCH-POWER", -0.6)])
    assert vector.values["SCH-POWER"] == -1.0


def test_clamp_attachment_lower_bound_is_zero() -> None:
    # Attachment dimensions never go negative.
    for dim in ATTACHMENT_DIMENSIONS:
        vector = score_vector([TraitWeight(dim, -0.5)])
        assert vector.values[dim] == 0.0


def test_clamp_attachment_upper_bound_is_one() -> None:
    for dim in ATTACHMENT_DIMENSIONS:
        vector = score_vector([TraitWeight(dim, 0.7), TraitWeight(dim, 0.7)])
        assert vector.values[dim] == 1.0


def test_unknown_dimension_is_reported_but_does_not_raise() -> None:
    vector, report = score_weights(
        [
            TraitWeight("OCEAN-O", 0.2),
            TraitWeight("NOT-A-REAL-DIM", 0.5),
        ]
    )
    assert vector.values["OCEAN-O"] == 0.2
    assert report.unknown_dimensions == ["NOT-A-REAL-DIM"]
    # Unknown deltas do not leak into any real dimension.
    assert sum(abs(v) for v in vector.values.values()) == 0.2


def test_engine_is_deterministic() -> None:
    weights = [
        TraitWeight("OCEAN-O", 0.1),
        TraitWeight("OCEAN-A", -0.2),
        TraitWeight("ATT-SECURE", 0.3),
    ]
    first = score_vector(weights).values
    second = score_vector(weights).values
    assert first == second


def test_legacy_score_signature_now_raises_with_guidance() -> None:
    # The old M0 stub used to raise NotImplementedError(...T-ML-010...);
    # the new stub raises NotImplementedError but with new guidance pointing
    # callers at score_weights. The "T-ML-010" tag is preserved in the
    # message so the existing reference in docs stays linkable.
    import pytest

    with pytest.raises(NotImplementedError, match="score_weights"):
        trait_scoring.score("playthrough-test")


# ---------------------------------------------------------------------------
# HTTP integration
# ---------------------------------------------------------------------------


def _client() -> TestClient:
    return TestClient(create_app())


def test_score_endpoint_happy_path() -> None:
    response = _client().post(
        "/score",
        json={
            "playthrough_id": "p1",
            "weights": [
                {"dimension": "OCEAN-O", "delta": 0.3},
                {"dimension": "OCEAN-O", "delta": 0.2},
                {"dimension": "ATT-SECURE", "delta": 0.4},
            ],
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["playthrough_id"] == "p1"
    assert body["scoring_version"] == SCORING_VERSION
    assert body["vector"]["OCEAN-O"] == 0.5
    assert body["vector"]["ATT-SECURE"] == 0.4
    # Dimension-complete.
    assert set(body["vector"].keys()) == set(ALL_DIMENSIONS)
    assert body["unknown_dimensions"] == []


def test_score_endpoint_clamps_at_bounds() -> None:
    response = _client().post(
        "/score",
        json={
            "playthrough_id": "p2",
            "weights": [
                {"dimension": "OCEAN-N", "delta": 0.9},
                {"dimension": "OCEAN-N", "delta": 0.9},
                {"dimension": "ATT-AVOIDANT", "delta": -0.5},
            ],
        },
    )
    body = response.json()
    assert body["vector"]["OCEAN-N"] == 1.0
    assert body["vector"]["ATT-AVOIDANT"] == 0.0


def test_score_endpoint_surfaces_unknown_dimensions() -> None:
    response = _client().post(
        "/score",
        json={
            "playthrough_id": "p3",
            "weights": [
                {"dimension": "OCEAN-A", "delta": 0.1},
                {"dimension": "MADE-UP-DIM", "delta": 0.9},
            ],
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["unknown_dimensions"] == ["MADE-UP-DIM"]
    assert body["vector"]["OCEAN-A"] == 0.1


def test_score_endpoint_rejects_empty_dimension() -> None:
    response = _client().post(
        "/score",
        json={
            "playthrough_id": "p4",
            "weights": [{"dimension": "", "delta": 0.1}],
        },
    )
    assert response.status_code == 422


def test_score_endpoint_rejects_empty_playthrough_id() -> None:
    response = _client().post(
        "/score",
        json={"playthrough_id": "", "weights": []},
    )
    assert response.status_code == 422
