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

AssetGenService routes through a :class:`RoutingAssetGenProvider` chain
(Meshy primary, self-hosted fallback). Opted into via
``ECHO_ASSET_GEN_ENABLED=true``; otherwise the servicer returns
``UNIMPLEMENTED`` for all four RPCs.
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
    AllAssetGenProvidersFailedError,
    AssetFormat,
    AssetGenProviderError,
    AssetGenRequest,
    AssetKind,
    GenerationInputs,
    GenMode,
    ProviderID,
    Reference,
    RoutingAssetGenProvider,
    build_provider_from_env,
    compute_content_address,
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
    """gRPC adapter for the T-ML-050 asset-gen provider abstraction.

    Routes ``SubmitAsset`` calls through the injected
    :class:`RoutingAssetGenProvider` (Meshy primary, self-hosted fallback).

    The three other RPCs — ``GetAssetStatus``, ``ReconcileManifest``,
    ``ListAssets`` — are stubs returning ``UNIMPLEMENTED``. Real
    implementations land with T-ML-051 (worker + DB) and T-ML-052
    (reconciler/scheduler).
    """

    def __init__(self, provider: RoutingAssetGenProvider) -> None:
        self._provider = provider

    def SubmitAsset(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        """Declare/enqueue a single asset. Idempotent on content-address.

        In T-ML-050 the "enqueueing" is simulated: we compute the
        content-address, call the routing provider (which in the stub
        chain either fails over to self-hosted or succeeds), and return
        the address and status. T-ML-051 replaces this with NATS JetStream
        enqueuing and a real DB row.
        """
        # Build GenerationInputs from the proto message.
        gen = request.spec.generation
        try:
            refs = tuple(Reference(uri=r.uri, sha256=r.sha256) for r in gen.references)
            inputs = GenerationInputs(
                kind=cast("AssetKind", _proto_kind_to_str(request.spec.kind)),
                provider=cast("ProviderID", _proto_provider_to_str(gen.provider)),
                mode=cast("GenMode", _proto_mode_to_str(gen.mode)),
                prompt=gen.prompt,
                pipeline_version=int(gen.pipeline_version) or 1,
                format=cast("AssetFormat", _proto_format_to_str(gen.format)),
                negative_prompt=gen.negative_prompt or "",
                references=refs,
                params=dict(gen.params) if gen.params else {},
            )
        except (ValueError, KeyError) as exc:
            logger.warning(
                "asset_gen.submit.invalid_spec",
                asset_id=request.spec.id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(exc))

        asset_request = AssetGenRequest(
            inputs=inputs,
            asset_id=request.spec.id or "",
            dry_run=bool(request.dry_run),
        )

        if request.dry_run:
            addr = compute_content_address(inputs)
            logger.info(
                "asset_gen.submit.dry_run",
                asset_id=request.spec.id,
                content_address=addr,
            )
            submit_response = asset_gen_pb2.SubmitAssetResponse  # type: ignore[attr-defined]
            return submit_response(
                content_address=addr,
                status=2,  # ASSET_STATUS_QUEUED
                deduplicated=False,
            )

        try:
            routing_result = self._provider.generate_with_route(asset_request)
        except (AssetGenProviderError, AllAssetGenProvidersFailedError) as exc:
            logger.error(
                "asset_gen.submit.all_providers_failed",
                asset_id=request.spec.id,
                error=str(exc),
            )
            context.abort(grpc.StatusCode.UNAVAILABLE, str(exc))

        result = routing_result.result
        logger.info(
            "asset_gen.submit.success",
            asset_id=request.spec.id,
            content_address=result.content_address,
            provider_used=result.provider_used,
            attempted_providers=routing_result.attempted_providers,
            is_stub=result.is_stub,
        )
        submit_response = asset_gen_pb2.SubmitAssetResponse  # type: ignore[attr-defined]
        return submit_response(
            content_address=result.content_address,
            status=2,  # ASSET_STATUS_QUEUED (T-ML-051 flips to READY)
            deduplicated=False,
        )

    def GetAssetStatus(
        self,
        request: Any,
        context: grpc.ServicerContext,
    ) -> Any:
        """Stub: T-ML-051 implements real DB lookup."""
        context.abort(grpc.StatusCode.UNIMPLEMENTED, "GetAssetStatus: wired in T-ML-051")

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
        """Stub: T-ML-051 implements real asset listing."""
        context.abort(grpc.StatusCode.UNIMPLEMENTED, "ListAssets: wired in T-ML-051")


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
    6: "self-hosted",
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


def build_server(
    bind: str = DEFAULT_BIND,
    max_workers: int = 10,
    *,
    reflection_pipeline: ReflectionPipeline | None = None,
    asset_gen_provider: RoutingAssetGenProvider | None = None,
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
        asset_gen_provider: Optional pre-built routing provider for the
            AssetGenService. If provided, SubmitAsset routes through it.
            If None, the servicer returns UNIMPLEMENTED for all RPCs.
            Production wires this from env via
            :func:`build_provider_from_env` when
            ``ECHO_ASSET_GEN_ENABLED=true``.
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
    if asset_gen_provider is not None:
        asset_gen_pb2_grpc.add_AssetGenServiceServicer_to_server(  # type: ignore[no-untyped-call]
            AssetGenServicer(provider=asset_gen_provider),
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


def _build_asset_gen_provider_if_enabled() -> RoutingAssetGenProvider | None:
    """Return an asset-gen routing provider iff the env opts in.

    Opt-in via ``ECHO_ASSET_GEN_ENABLED=true``. CI and dev shells that
    have no provider keys can set
    ``ECHO_ASSET_GEN_PRIMARY=self-hosted ECHO_ASSET_GEN_FALLBACKS=``
    without setting the opt-in flag.
    """
    if os.environ.get("ECHO_ASSET_GEN_ENABLED", "").lower() != "true":
        return None
    try:
        return build_provider_from_env()
    except Exception:
        logger.exception("asset_gen_provider.bootstrap_failed")
        return None


def serve_forever(bind: str = DEFAULT_BIND) -> None:
    """Start the server and block until the process is signalled.

    Intended as the entry point for `python -m app.grpc_server`. The
    FastAPI app keeps owning the HTTP healthz / readyz surface; the gRPC
    server runs alongside it (different port).
    """
    logging.basicConfig(level=logging.INFO)
    pipeline = _build_pipeline_if_enabled()
    asset_gen_provider = _build_asset_gen_provider_if_enabled()
    server = build_server(
        bind=bind,
        reflection_pipeline=pipeline,
        asset_gen_provider=asset_gen_provider,
    )
    server.start()
    logger.info("ml_grpc.serving", bind=bind)
    server.wait_for_termination()


if __name__ == "__main__":
    serve_forever()
