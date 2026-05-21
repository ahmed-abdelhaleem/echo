"""FastAPI entrypoint for the Echo ML service.

In M0 the HTTP surface was only health endpoints. M1 adds the rule-based
trait scoring endpoint (T-ML-010) so core-go can produce a TraitVector for
a completed playthrough. Portrait and reflection endpoints follow in PR 10.

We deliberately serve over HTTP+JSON rather than gRPC for M1. The gRPC
contract is on the roadmap (docs/06 §"gRPC"), but it adds a proto build
step we don't need to unblock M1's vertical slice; the call surface is
already typed via Pydantic and the request/response shapes match what a
future TraitScoring.Score RPC would look like.
"""

from __future__ import annotations

import os
from collections.abc import Mapping

import structlog
from fastapi import FastAPI
from pydantic import BaseModel, Field

from app.services import trait_scoring
from app.services.trait_scoring import TraitWeight

logger = structlog.get_logger(__name__)


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class TraitWeightModel(BaseModel):
    """Wire representation of a single TraitWeight.

    Matches the JSON shape produced by core-go when it serialises the
    weights for a playthrough's choices.
    """

    dimension: str = Field(min_length=1)
    delta: float


class ScoreRequest(BaseModel):
    """Request body for ``POST /score``.

    ``playthrough_id`` is carried through for telemetry / log correlation
    but does not affect the result. Scoring is a pure function of the
    weights — the engine is stateless.
    """

    playthrough_id: str = Field(min_length=1)
    weights: list[TraitWeightModel]


class ScoreResponse(BaseModel):
    """Response body for ``POST /score``.

    ``vector`` is the post-clamp, dimension-complete mapping. ``unknown_dimensions``
    lists any wire dimensions the engine did not recognise (soft warning;
    the request still succeeds so content authors can preview new dimensions
    before the engine is updated).
    """

    playthrough_id: str
    scoring_version: str
    vector: dict[str, float]
    unknown_dimensions: list[str]


# ---------------------------------------------------------------------------
# App factory
# ---------------------------------------------------------------------------


def create_app() -> FastAPI:
    """Build and return the FastAPI app."""
    app = FastAPI(
        title="Echo ML service",
        version="0.1.0",
        description=(
            "Trait scoring, Portrait generation, reflection generation. "
            "M1 adds POST /score (T-ML-010); Portrait and reflection follow "
            "in PR 10."
        ),
    )

    @app.get("/healthz")
    def healthz() -> Mapping[str, str]:
        """Always 200 if the process is up."""
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz() -> Mapping[str, str]:
        """Reflects whether the service is ready to serve traffic.

        In M1 there are no external dependencies on the hot path
        (scoring is in-process and pure), so readiness equals healthz.
        Postgres and model weights become load-bearing in M2 and this
        endpoint expands then.
        """
        env = os.getenv("ECHO_ENV", "dev")
        return {"status": "ok", "env": env}

    @app.post("/score", response_model=ScoreResponse)
    def score(request: ScoreRequest) -> ScoreResponse:
        """Rule-based trait scoring (T-ML-010).

        Aggregates ``request.weights`` into a clamped, dimension-complete
        vector. Deterministic: identical input -> identical output.

        ``unknown_dimensions`` is informative — the server logs them but
        the request still succeeds, so content authors can preview a new
        dimension before the engine is updated for it.
        """
        weights = [TraitWeight(dimension=w.dimension, delta=w.delta) for w in request.weights]
        vector, report = trait_scoring.score_weights(weights)
        if report.unknown_dimensions:
            logger.warning(
                "trait_scoring.unknown_dimensions",
                playthrough_id=request.playthrough_id,
                unknown=sorted(set(report.unknown_dimensions)),
            )
        return ScoreResponse(
            playthrough_id=request.playthrough_id,
            scoring_version=vector.scoring_version,
            vector=dict(vector.values),
            unknown_dimensions=sorted(set(report.unknown_dimensions)),
        )

    return app


app = create_app()
