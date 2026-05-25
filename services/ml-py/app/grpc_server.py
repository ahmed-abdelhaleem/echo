"""gRPC server wiring for the Echo ML service.

Serves three RPC services on a single port:
  - TraitScoringService (T-ML-010, real)
  - PortraitGenService (T-ML-020, M1 stub)
  - ReflectionGenService (T-ML-021, M1 stub)

The M1 stubs return deterministic, trait-vector-keyed output. Real
renderers replace them at M2 (T-ML-030, T-ML-040..042) behind the
same proto contracts.
"""

from __future__ import annotations

import logging
from concurrent import futures
from typing import Any, Final

import grpc
import structlog

from app.grpc_gen import (
    portrait_gen_pb2,
    portrait_gen_pb2_grpc,
    reflection_gen_pb2,
    reflection_gen_pb2_grpc,
    trait_scoring_pb2,
    trait_scoring_pb2_grpc,
)
from app.services import portrait_gen, reflection_gen, trait_scoring

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


class PortraitGenServicer(portrait_gen_pb2_grpc.PortraitGenServiceServicer):
    """gRPC adapter around the M1 Portrait stub (T-ML-020).

    The pure function lives in ``portrait_gen``; this class translates
    the proto message and returns the inline PNG bytes. The real
    parametric renderer (T-ML-030) is M2.
    """

    def Generate(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        try:
            assets = portrait_gen.generate(
                big_five=tuple(request.big_five),
                schwartz=tuple(request.schwartz),
                attachment=tuple(request.attachment),
                seed=int(request.seed),
            )
        except ValueError as exc:
            logger.warning(
                "portrait_gen.invalid_vector",
                playthrough_id=request.playthrough_id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))

        logger.info(
            "portrait_gen.generated",
            playthrough_id=request.playthrough_id,
            renderer_version=assets.renderer_version,
            png_bytes=len(assets.png),
        )
        generate_response = portrait_gen_pb2.GeneratePortraitResponse  # type: ignore[attr-defined]
        return generate_response(
            png=assets.png,
            static_png_key=assets.static_png_key,
            animated_webp_key=assets.animated_webp_key,
            renderer_version=assets.renderer_version,
        )


class ReflectionGenServicer(reflection_gen_pb2_grpc.ReflectionGenServiceServicer):
    """gRPC adapter around the M1 reflection stub (T-ML-021).

    M1 returns a templated string. The real LLM-backed pipeline
    (T-ML-040..042) replaces this at M2 behind the same proto.
    """

    def Generate(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        try:
            reflection = reflection_gen.generate(
                big_five=tuple(request.big_five),
                schwartz=tuple(request.schwartz),
                attachment=tuple(request.attachment),
                youth_safe=bool(request.youth_safe),
                locale=str(request.locale) or "en-GB",
            )
        except ValueError as exc:
            logger.warning(
                "reflection_gen.invalid_vector",
                playthrough_id=request.playthrough_id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))

        logger.info(
            "reflection_gen.generated",
            playthrough_id=request.playthrough_id,
            template_id=reflection.template_id,
            youth_safe=bool(request.youth_safe),
        )
        generate_response = reflection_gen_pb2.GenerateReflectionResponse  # type: ignore[attr-defined]
        return generate_response(
            text=reflection.text,
            used_fallback=reflection.used_fallback,
            template_id=reflection.template_id,
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
    portrait_gen_pb2_grpc.add_PortraitGenServiceServicer_to_server(  # type: ignore[no-untyped-call]
        PortraitGenServicer(),
        server,
    )
    reflection_gen_pb2_grpc.add_ReflectionGenServiceServicer_to_server(  # type: ignore[no-untyped-call]
        ReflectionGenServicer(),
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
