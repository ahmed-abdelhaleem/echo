"""Executable bootstrap for the T-ML-051 background asset worker."""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import Mapping
from pathlib import Path

from app.services.asset_gen.factory import build_provider_from_env
from app.services.asset_gen.postprocess import (
    AutomatedAssetQualityGate,
    GltfpackPostProcessor,
)
from app.services.asset_gen.queue import run_nats_worker
from app.services.asset_gen.repository import PostgresAssetRepository
from app.services.asset_gen.storage import (
    AssetObjectStore,
    LocalAssetObjectStore,
    R2AssetObjectStore,
)
from app.services.asset_gen.worker import AssetGenerationWorker


def build_worker_from_env(
    env: Mapping[str, str] | None = None,
) -> AssetGenerationWorker:
    settings = dict(os.environ if env is None else env)
    max_size_raw = settings.get("ECHO_ASSET_MAX_BYTES")
    if not max_size_raw:
        raise ValueError("ECHO_ASSET_MAX_BYTES is required")
    try:
        max_size_bytes = int(max_size_raw)
    except ValueError as exc:
        raise ValueError("ECHO_ASSET_MAX_BYTES must be an integer") from exc

    repository = PostgresAssetRepository(settings.get("DATABASE_URL", ""))
    object_store = _build_object_store(settings)
    return AssetGenerationWorker(
        provider=build_provider_from_env(env=settings),
        repository=repository,
        object_store=object_store,
        postprocessor=GltfpackPostProcessor(binary=settings.get("GLTFPACK_BIN", "gltfpack")),
        quality_gate=AutomatedAssetQualityGate(),
        max_size_bytes=max_size_bytes,
        lease_seconds=int(settings.get("ECHO_ASSET_LEASE_SECONDS", "3600")),
    )


def _build_object_store(settings: Mapping[str, str]) -> AssetObjectStore:
    backend = settings.get("ECHO_ASSET_STORE_BACKEND", "local")
    if backend == "local":
        root = Path(settings.get("ECHO_ASSET_STORE_DIR", ".echo-assets"))
        return LocalAssetObjectStore(
            root,
            base_uri=settings.get("ECHO_ASSET_STORE_BASE_URI", ""),
        )
    if backend == "r2":
        return R2AssetObjectStore(
            bucket=settings.get("R2_ASSET_BUCKET", ""),
            endpoint_url=settings.get("R2_ENDPOINT_URL", ""),
            access_key_id=settings.get("R2_ACCESS_KEY_ID", ""),
            secret_access_key=settings.get("R2_SECRET_ACCESS_KEY", ""),
            public_base_url=settings.get("R2_PUBLIC_BASE_URL", ""),
        )
    raise ValueError("ECHO_ASSET_STORE_BACKEND must be local or r2")


async def _main() -> None:
    worker = build_worker_from_env()
    await run_nats_worker(
        worker,
        nats_url=os.environ.get("NATS_URL", "nats://127.0.0.1:4222"),
    )


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(_main())


if __name__ == "__main__":
    main()
