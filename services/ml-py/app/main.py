"""FastAPI entrypoint for the Echo ML service.

The HTTP surface today is only health endpoints; real RPCs are over gRPC and
land at M1 (T-ML-010 onward). Keeping a FastAPI app exposed gives us a uniform
``/healthz`` and ``/readyz`` story across services and a place to plug a
GraphQL/REST surface later if needed.
"""

from __future__ import annotations

import os
from collections.abc import Mapping

import structlog
from fastapi import FastAPI

logger = structlog.get_logger(__name__)


def create_app() -> FastAPI:
    """Build and return the FastAPI app."""
    app = FastAPI(
        title="Echo ML service",
        version="0.1.0",
        description=(
            "Trait scoring, Portrait generation, reflection generation. "
            "M0 scaffolding; see docs/07_AI_Agent_Implementation_Guide.md."
        ),
    )

    @app.get("/healthz")
    def healthz() -> Mapping[str, str]:
        """Always 200 if the process is up."""
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz() -> Mapping[str, str]:
        """Reflects whether the service is ready to serve traffic.

        In M0 there are no external dependencies on the hot path, so readiness
        equals healthz. As ML model weights and Postgres connectivity become
        load-bearing, this endpoint expands.
        """
        env = os.getenv("ECHO_ENV", "dev")
        return {"status": "ok", "env": env}

    return app


app = create_app()
