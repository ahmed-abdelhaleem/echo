"""gRPC server wiring for the Echo ML service.

Today only `TraitScoringService` is implemented (T-ML-010). Portrait and
reflection servicers land in T-ML-020 / T-ML-021.
"""

from __future__ import annotations

import logging
from concurrent import futures
from typing import Any, Final

import grpc
import structlog

from app.grpc_gen import trait_scoring_pb2, trait_scoring_pb2_grpc
from app.services import trait_scoring

# protoc emits dynamically-generated message classes that mypy cannot
# follow (attribute lookups happen at descriptor-set load time). We
# intentionally accept `Any` at the seam between generated stubs and
# hand-written code; structural correctness of these translations is
# covered by tests/test_grpc_server.py.

logger = structlog.get_logger(__name__)

DEFAULT_BIND: Final[str] = "0.0.0.0:50051"


class TraitScoringServicer(trait_scoring_pb2_grpc.TraitScoringServiceServicer):
    """gRPC adapter around the rule-based scoring engine.

    The servicer is intentionally thin: it translates proto messages to
    `trait_scoring.ScoredChoice` records, calls `trait_scoring.score`, and
    packages the resulting `TraitVector` back into a `ScoreResponse`.
    All of the business logic lives in the pure function so the
    `trait-replay` tool (M2) can reproduce it offline.
    """

    def Score(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        events = [
            trait_scoring.ScoredChoice(vignette_id=e.vignette_id, choice_id=e.choice_id)
            for e in request.events
        ]
        try:
            vector = trait_scoring.score(
                season_id=request.season_id,
                events=events,
            )
        except trait_scoring.SeasonNotFoundError as exc:
            logger.warning(
                "trait_scoring.season_not_found",
                playthrough_id=request.playthrough_id,
                season_id=request.season_id,
            )
            context.abort(grpc.StatusCode.NOT_FOUND, str(exc))
        except (
            trait_scoring.UnknownVignetteError,
            trait_scoring.UnknownChoiceError,
        ) as exc:
            logger.warning(
                "trait_scoring.invalid_event",
                playthrough_id=request.playthrough_id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))

        logger.info(
            "trait_scoring.scored",
            playthrough_id=request.playthrough_id,
            season_id=request.season_id,
            event_count=len(events),
        )
        score_response = trait_scoring_pb2.ScoreResponse  # type: ignore[attr-defined]
        return score_response(
            big_five=list(vector.big_five),
            schwartz=list(vector.schwartz),
            attachment=list(vector.attachment),
        )


def build_server(
    bind: str = DEFAULT_BIND,
    max_workers: int = 10,
) -> grpc.Server:
    """Build a configured but unstarted gRPC server.

    The server is built but not started so callers (or tests) can attach
    additional servicers before calling `.start()`.
    """
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=max_workers))
    trait_scoring_pb2_grpc.add_TraitScoringServiceServicer_to_server(  # type: ignore[no-untyped-call]
        TraitScoringServicer(),
        server,
    )
    server.add_insecure_port(bind)
    return server


def serve_forever(bind: str = DEFAULT_BIND) -> None:
    """Start the server and block until the process is signalled.

    Intended as the entry point for `python -m app.grpc_server`. The
    FastAPI app keeps owning the HTTP healthz / readyz surface; the gRPC
    server runs alongside it (different port).
    """
    logging.basicConfig(level=logging.INFO)
    server = build_server(bind=bind)
    server.start()
    logger.info("ml_grpc.serving", bind=bind)
    server.wait_for_termination()


if __name__ == "__main__":
    serve_forever()
