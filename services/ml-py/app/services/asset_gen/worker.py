"""Idempotent T-ML-051 background generation worker."""

from __future__ import annotations

import logging

from app.services.asset_gen.models import AssetJob, AssetRecord, AssetStatus
from app.services.asset_gen.postprocess import (
    AssetPostProcessor,
    AssetQualityGate,
)
from app.services.asset_gen.repository import AssetRepository
from app.services.asset_gen.routing import RoutingAssetGenProvider
from app.services.asset_gen.storage import AssetObjectStore
from app.services.asset_gen.types import AssetGenRequest

logger = logging.getLogger(__name__)


class AssetGenerationWorker:
    def __init__(
        self,
        *,
        provider: RoutingAssetGenProvider,
        repository: AssetRepository,
        object_store: AssetObjectStore,
        postprocessor: AssetPostProcessor,
        quality_gate: AssetQualityGate,
        max_size_bytes: int,
        lease_seconds: int = 3600,
    ) -> None:
        if max_size_bytes <= 0:
            raise ValueError("max_size_bytes must be positive")
        if lease_seconds <= 0:
            raise ValueError("lease_seconds must be positive")
        self._provider = provider
        self._repository = repository
        self._object_store = object_store
        self._postprocessor = postprocessor
        self._quality_gate = quality_gate
        self._max_size_bytes = max_size_bytes
        self._lease_seconds = lease_seconds

    def process(self, job: AssetJob) -> AssetRecord:
        """Process one at-least-once delivery without double-generation."""
        enqueue = self._repository.enqueue(job.spec)
        if enqueue.record.status == AssetStatus.READY:
            return enqueue.record

        claimed = self._repository.claim(
            job.spec.content_address,
            lease_seconds=self._lease_seconds,
        )
        if claimed is None:
            current = self._repository.get(job.spec.content_address)
            if current is None:
                raise RuntimeError("asset disappeared after enqueue")
            if current.status == AssetStatus.READY:
                return current
            raise RuntimeError(f"asset {job.spec.content_address} is already being processed")

        try:
            route = self._provider.generate_with_route(
                AssetGenRequest(inputs=job.spec.inputs, asset_id=job.spec.asset_id)
            )
            generated = route.result
            if generated.content_address != job.spec.content_address:
                raise RuntimeError("provider returned a mismatched content_address")
            if generated.glb_bytes is None:
                raise RuntimeError("provider returned no GLB bytes")

            self._repository.set_status(
                job.spec.content_address,
                AssetStatus.POSTPROCESSING,
            )
            processed = self._postprocessor.process(
                generated.glb_bytes,
                job.spec,
                max_size_bytes=self._max_size_bytes,
            )
            self._repository.set_status(job.spec.content_address, AssetStatus.QA)
            gate = self._quality_gate.evaluate(
                processed,
                job.spec,
                max_size_bytes=self._max_size_bytes,
            )
            if not gate.passed:
                raise RuntimeError(f"asset QA failed: {', '.join(gate.reasons)}")

            prefix = _storage_prefix(job.spec.content_address)
            glb_uri = self._object_store.put(
                f"{prefix}/asset.glb",
                processed.glb_bytes,
                content_type="model/gltf-binary",
            )
            thumbnail_uri = self._object_store.put(
                f"{prefix}/thumbnail.png",
                processed.thumbnail_png,
                content_type="image/png",
            )
            lod_uris = tuple(
                self._object_store.put(
                    f"{prefix}/lod-{index}.glb",
                    lod,
                    content_type="model/gltf-binary",
                )
                for index, lod in enumerate(processed.lod_glbs, start=1)
            )
            return self._repository.mark_ready(
                job.spec.content_address,
                provider_used=route.served_by_provider,
                glb_uri=glb_uri,
                thumbnail_uri=thumbnail_uri,
                lod_uris=lod_uris,
                polycount=processed.polycount,
                size_bytes=processed.size_bytes,
            )
        except Exception as exc:
            logger.exception(
                "asset generation failed",
                extra={
                    "asset_id": job.spec.asset_id,
                    "content_address": job.spec.content_address,
                },
            )
            self._repository.mark_failed(job.spec.content_address, str(exc))
            raise


def _storage_prefix(content_address: str) -> str:
    algorithm, separator, digest = content_address.partition(":")
    if algorithm != "sha256" or not separator or len(digest) != 64:
        raise ValueError("invalid content_address")
    return f"assets/sha256/{digest}"
