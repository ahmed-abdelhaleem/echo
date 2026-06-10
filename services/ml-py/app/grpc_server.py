"""gRPC server wiring for the Echo ML service.

Serves four RPC services on a single port:
  - TraitScoringService (T-ML-010, real)
  - PortraitGenService (T-ML-020 / T-ML-030, real parametric renderer)
  - ReflectionGenService (M1 stub or M2 pipeline)
  - AssetGenService (T-ML-050 provider abstraction; T-ML-051 owns the worker)

ReflectionGenService has two paths:
  - **M1 templated stub** (``reflection_gen.generate``): deterministic
    trait-keyed prose. Used as the default for back-compat.
  - **M2 reflection pipeline** (``reflection.ReflectionPipeline``):
    template selection -> prompt assembly -> LLM completion -> safety
    classify -> tone classify. Opted into via
    ``ECHO_REFLECTION_PIPELINE=enabled``; otherwise the stub serves the
    call. The pipeline is built once at server start; the templates are
    loaded eagerly from ``content/reflection-templates/``.

AssetGenService persists desired asset metadata and publishes T-ML-051 jobs to
NATS JetStream. Provider generation happens only in the separate worker
process. Opt in via ``ECHO_ASSET_GEN_ENABLED=true``.
"""

from __future__ import annotations

import logging
import os
from concurrent import futures
from typing import Any, Final, cast

import grpc
import structlog

from app.grpc_gen import (
    asset_gen_pb2,
    asset_gen_pb2_grpc,
    portrait_gen_pb2,
    portrait_gen_pb2_grpc,
    reflection_gen_pb2,
    reflection_gen_pb2_grpc,
    trait_scoring_pb2,
    trait_scoring_pb2_grpc,
)
from app.services import portrait_gen, reflection_gen, trait_scoring
from app.services.asset_gen import (
    AssetFormat,
    AssetKind,
    AssetRecord,
    AssetSpec,
    AssetStatus,
    AssetSubmissionService,
    GenerationInputs,
    GenMode,
    NatsAssetJobPublisher,
    PostgresAssetRepository,
    ProviderID,
    Reference,
)
from app.services.reflection import ReflectionPipeline, build_pipeline_from_env

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
    """gRPC adapter around the Portrait renderer (T-ML-020 / T-ML-030).

    The pure function lives in ``portrait_gen`` (which delegates to the
    parametric renderer in ``portrait_renderer``); this class translates
    the proto message into Python kwargs and returns the inline asset
    bytes.

    When ``request.animate`` is true the response carries both the
    static PNG and the animated WebP loop (T-ML-031). Animation roughly
    doubles render time, so callers only opt in for the share-web Story
    / in-app reveal surfaces.
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
                animate=bool(request.animate),
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
            webp_bytes=len(assets.animated_webp),
            animate=bool(request.animate),
        )
        generate_response = portrait_gen_pb2.GeneratePortraitResponse  # type: ignore[attr-defined]
        return generate_response(
            png=assets.png,
            static_png_key=assets.static_png_key,
            animated_webp_key=assets.animated_webp_key,
            renderer_version=assets.renderer_version,
            animated_webp=assets.animated_webp,
        )


class ReflectionGenServicer(reflection_gen_pb2_grpc.ReflectionGenServiceServicer):
    """gRPC adapter for ReflectionGen.

    Routes between the M1 templated stub and the M2 reflection pipeline
    depending on whether a pipeline was injected at construction time.
    The M2 pipeline call shape is async; this sync servicer wraps it
    via :meth:`ReflectionPipeline.generate_sync`.
    """

    def __init__(self, pipeline: ReflectionPipeline | None = None) -> None:
        self._pipeline = pipeline

    def Generate(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        if self._pipeline is not None:
            return self._generate_via_pipeline(request, context)
        return self._generate_via_stub(request, context)

    def _generate_via_pipeline(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        try:
            result = self._pipeline.generate_sync(  # type: ignore[union-attr]
                big_five=tuple(request.big_five),
                schwartz=tuple(request.schwartz),
                attachment=tuple(request.attachment),
                signal_moments=tuple(request.signal_moments),
                fallback_seed=hash(str(request.playthrough_id)) & 0xFFFF,
            )
        except ValueError as exc:
            logger.warning(
                "reflection_pipeline.invalid_input",
                playthrough_id=request.playthrough_id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))

        logger.info(
            "reflection_pipeline.generated",
            playthrough_id=request.playthrough_id,
            template_id=result.template_id,
            provider=result.provider,
            is_fallback=result.is_fallback,
            fallback_reason=result.fallback_reason,
        )
        generate_response = reflection_gen_pb2.GenerateReflectionResponse  # type: ignore[attr-defined]
        return generate_response(
            text=result.text,
            used_fallback=result.is_fallback,
            template_id=result.template_id,
        )

    def _generate_via_stub(
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


class AssetGenServicer(asset_gen_pb2_grpc.AssetGenServiceServicer):
    """gRPC adapter for T-ML-051 queue submission and metadata lookup."""

    def __init__(self, service: AssetSubmissionService) -> None:
        self._service = service

    def SubmitAsset(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        """Persist desired state and enqueue generation without running inline."""
        try:
            spec = _asset_spec_from_proto(request.spec)
            record, deduplicated = self._service.submit(
                spec,
                dry_run=bool(request.dry_run),
            )
        except (ValueError, KeyError) as exc:
            logger.warning(
                "asset_gen.submit.invalid_spec",
                asset_id=request.spec.id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))
        except Exception as exc:
            logger.error(
                "asset_gen.submit.enqueue_failed",
                asset_id=request.spec.id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.UNAVAILABLE, str(exc))

        logger.info(
            "asset_gen.submit.queued",
            asset_id=request.spec.id,
            content_address=record.content_address,
            deduplicated=deduplicated,
            dry_run=bool(request.dry_run),
        )
        submit_response = asset_gen_pb2.SubmitAssetResponse  # type: ignore[attr-defined]
        return submit_response(
            content_address=record.content_address,
            status=_STATUS_TO_PROTO[record.status],
            deduplicated=deduplicated,
        )

    def GetAssetStatus(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        record = self._service.repository.get(request.content_address)
        if record is None:
            context.abort(grpc.StatusCode.NOT_FOUND, "asset not found")
        assert record is not None
        return _asset_record_to_proto(record)

    def ReconcileManifest(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        """Stub: T-ML-052 implements real reconciler/scheduler."""
        context.abort(grpc.StatusCode.UNIMPLEMENTED, "ReconcileManifest: wired in T-ML-052")

    def ListAssets(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        try:
            status = _proto_status_to_model(int(request.status_filter))
        except KeyError as exc:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))
        records = self._service.repository.list(
            season_id=request.season_id,
            status=status,
        )
        response = asset_gen_pb2.ListAssetsResponse  # type: ignore[attr-defined]
        return response(assets=[_asset_record_to_proto(record) for record in records])


# ---------------------------------------------------------------------------
# Proto enum → Python string helpers
# ---------------------------------------------------------------------------

_KIND_MAP: dict[int, str] = {
    0: "prop",  # ASSET_KIND_UNSPECIFIED -> default to prop
    1: "prop",
    2: "environment",
    3: "character",
    4: "ambient",
}

_PROVIDER_MAP: dict[int, str] = {
    0: "meshy",  # PROVIDER_UNSPECIFIED -> default to meshy
    1: "meshy",
    2: "tripo",
    3: "luma",
    4: "rodin",
    5: "stability",
    6: "trellis",
}

_MODE_MAP: dict[int, str] = {
    0: "text-to-3d",  # GEN_MODE_UNSPECIFIED -> default
    1: "text-to-3d",
    2: "image-to-3d",
}

_FORMAT_MAP: dict[int, str] = {
    0: "glb",  # ASSET_FORMAT_UNSPECIFIED -> default
    1: "glb",
    2: "gltf",
}

_STATUS_TO_PROTO: dict[AssetStatus, int] = {
    AssetStatus.DESIRED: 1,
    AssetStatus.QUEUED: 2,
    AssetStatus.GENERATING: 3,
    AssetStatus.POSTPROCESSING: 4,
    AssetStatus.QA: 5,
    AssetStatus.READY: 6,
    AssetStatus.FAILED: 7,
}

_PROTO_TO_STATUS: dict[int, AssetStatus | None] = {
    0: None,
    1: AssetStatus.DESIRED,
    2: AssetStatus.QUEUED,
    3: AssetStatus.GENERATING,
    4: AssetStatus.POSTPROCESSING,
    5: AssetStatus.QA,
    6: AssetStatus.READY,
    7: AssetStatus.FAILED,
}

_PROVIDER_TO_PROTO: dict[str, int] = {
    provider: value for value, provider in _PROVIDER_MAP.items() if value != 0
}


def _proto_kind_to_str(value: int) -> str:
    if value not in _KIND_MAP:
        raise KeyError(f"unknown AssetKind enum value {value}")
    return _KIND_MAP[value]


def _proto_provider_to_str(value: int) -> str:
    if value not in _PROVIDER_MAP:
        raise KeyError(f"unsupported Provider enum value {value}")
    return _PROVIDER_MAP[value]


def _proto_mode_to_str(value: int) -> str:
    if value not in _MODE_MAP:
        raise KeyError(f"unknown GenMode enum value {value}")
    return _MODE_MAP[value]


def _proto_format_to_str(value: int) -> str:
    if value not in _FORMAT_MAP:
        raise KeyError(f"unknown AssetFormat enum value {value}")
    return _FORMAT_MAP[value]


def _proto_status_to_model(value: int) -> AssetStatus | None:
    if value not in _PROTO_TO_STATUS:
        raise KeyError(f"unknown AssetStatus enum value {value}")
    return _PROTO_TO_STATUS[value]


def _asset_spec_from_proto(spec: Any) -> AssetSpec:
    generation = spec.generation
    references = tuple(
        Reference(uri=reference.uri, sha256=reference.sha256) for reference in generation.references
    )
    inputs = GenerationInputs(
        kind=cast("AssetKind", _proto_kind_to_str(spec.kind)),
        provider=cast("ProviderID", _proto_provider_to_str(generation.provider)),
        mode=cast("GenMode", _proto_mode_to_str(generation.mode)),
        prompt=generation.prompt,
        pipeline_version=int(generation.pipeline_version) or 1,
        format=cast("AssetFormat", _proto_format_to_str(generation.format)),
        negative_prompt=generation.negative_prompt or "",
        references=references,
        params=dict(generation.params) if generation.params else {},
    )
    return AssetSpec(
        asset_id=spec.id,
        name=spec.name,
        description=spec.description,
        inputs=inputs,
        vignette_ids=tuple(spec.vignette_ids),
        license=spec.license or "provider-terms",
        budget_tier=spec.budget_tier or "standard",
        claimed_content_address=spec.content_address,
    )


def _asset_record_to_proto(record: AssetRecord) -> Any:
    from google.protobuf.timestamp_pb2 import Timestamp

    inputs = record.spec.inputs
    generation = asset_gen_pb2.Generation(  # type: ignore[attr-defined]
        provider=_PROVIDER_TO_PROTO[inputs.provider],
        mode=1 if inputs.mode == "text-to-3d" else 2,
        prompt=inputs.prompt,
        negative_prompt=inputs.negative_prompt,
        references=[
            asset_gen_pb2.Reference(uri=reference.uri, sha256=reference.sha256)  # type: ignore[attr-defined]
            for reference in inputs.references
        ],
        params=inputs.params,
        pipeline_version=inputs.pipeline_version,
        format=1 if inputs.format == "glb" else 2,
    )
    spec = asset_gen_pb2.AssetSpec(  # type: ignore[attr-defined]
        id=record.spec.asset_id,
        name=record.spec.name,
        description=record.spec.description,
        kind={value: key for key, value in _KIND_MAP.items() if key != 0}[inputs.kind],
        vignette_ids=record.spec.vignette_ids,
        generation=generation,
        license=record.spec.license,
        budget_tier=record.spec.budget_tier,
        content_address=record.content_address,
    )
    created_at = Timestamp()
    created_at.FromDatetime(record.created_at)
    ready_at = Timestamp()
    if record.ready_at is not None:
        ready_at.FromDatetime(record.ready_at)
    return asset_gen_pb2.Asset(  # type: ignore[attr-defined]
        spec=spec,
        status=_STATUS_TO_PROTO[record.status],
        glb_uri=record.glb_uri,
        thumbnail_uri=record.thumbnail_uri,
        polycount=record.polycount,
        size_bytes=record.size_bytes,
        provider_used=_PROVIDER_TO_PROTO.get(record.provider_used, 0),
        error=record.error,
        created_at=created_at,
        ready_at=ready_at,
    )


def build_server(
    bind: str = DEFAULT_BIND,
    max_workers: int = 10,
    *,
    reflection_pipeline: ReflectionPipeline | None = None,
    asset_gen_service: AssetSubmissionService | None = None,
) -> grpc.Server:
    """Build a configured but unstarted gRPC server.

    The server is built but not started so callers (or tests) can attach
    additional servicers before calling `.start()`.

    Args:
        reflection_pipeline: Optional pre-built reflection pipeline. If
            provided, ReflectionGenService uses it; otherwise it falls
            back to the M1 templated stub. Tests inject a pipeline with
            a mock LLM client; production wires this from env via
            :func:`build_pipeline_from_env` when
            ``ECHO_REFLECTION_PIPELINE=enabled``.
        asset_gen_service: Optional queue submission and metadata service.
            Production wires Postgres + JetStream from the environment.
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
        ReflectionGenServicer(pipeline=reflection_pipeline),
        server,
    )
    if asset_gen_service is not None:
        asset_gen_pb2_grpc.add_AssetGenServiceServicer_to_server(  # type: ignore[no-untyped-call]
            AssetGenServicer(service=asset_gen_service),
            server,
        )
    server.add_insecure_port(bind)
    return server


def _build_pipeline_if_enabled() -> ReflectionPipeline | None:
    """Return a reflection pipeline iff the env opts in.

    The opt-in keeps production traffic on the M1 stub until provider
    keys + the real wire impls land in a follow-up PR. CI never opts
    in; the pipeline tests use direct injection.
    """
    if os.environ.get("ECHO_REFLECTION_PIPELINE", "").lower() != "enabled":
        return None
    try:
        return build_pipeline_from_env()
    except Exception:
        logger.exception("reflection_pipeline.bootstrap_failed")
        return None


def _build_asset_gen_service_if_enabled() -> AssetSubmissionService | None:
    """Return the Postgres + JetStream submission service when enabled."""
    if os.environ.get("ECHO_ASSET_GEN_ENABLED", "").lower() != "true":
        return None
    try:
        repository = PostgresAssetRepository(os.environ["DATABASE_URL"])
        publisher = NatsAssetJobPublisher(
            nats_url=os.environ.get("NATS_URL", "nats://127.0.0.1:4222")
        )
        return AssetSubmissionService(repository=repository, publisher=publisher)
    except Exception:
        logger.exception("asset_gen_service.bootstrap_failed")
        return None


def serve_forever(bind: str = DEFAULT_BIND) -> None:
    """Start the server and block until the process is signalled.

    Intended as the entry point for `python -m app.grpc_server`. The
    FastAPI app keeps owning the HTTP healthz / readyz surface; the gRPC
    server runs alongside it (different port).
    """
    logging.basicConfig(level=logging.INFO)
    pipeline = _build_pipeline_if_enabled()
    asset_gen_service = _build_asset_gen_service_if_enabled()
    server = build_server(
        bind=bind,
        reflection_pipeline=pipeline,
        asset_gen_service=asset_gen_service,
    )
    server.start()
    logger.info("ml_grpc.serving", bind=bind)
    server.wait_for_termination()


if __name__ == "__main__":
    serve_forever()
