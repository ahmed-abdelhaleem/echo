"""T-ML-051 worker integration and adapter tests."""

from __future__ import annotations

import json
import shutil
import struct
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from app.services.asset_gen import (
    AssetGenRequest,
    AssetGenResult,
    GenerationInputs,
    RoutingAssetGenProvider,
    compute_content_address,
)
from app.services.asset_gen.models import AssetJob, AssetSpec, AssetStatus
from app.services.asset_gen.postprocess import (
    AssetPostProcessingError,
    AutomatedAssetQualityGate,
    GltfpackPostProcessor,
    ProcessedAsset,
    inspect_glb,
)
from app.services.asset_gen.queue import (
    AssetSubmissionService,
    InMemoryAssetJobQueue,
    _ensure_stream,
    _process_with_heartbeat,
)
from app.services.asset_gen.repository import InMemoryAssetRepository
from app.services.asset_gen.storage import LocalAssetObjectStore, R2AssetObjectStore
from app.services.asset_gen.worker import AssetGenerationWorker


def _glb(*, triangles: int = 100, external_uri: str = "") -> bytes:
    document: dict[str, Any] = {
        "asset": {"version": "2.0"},
        "accessors": [
            {"count": triangles * 3, "type": "SCALAR", "componentType": 5125},
            {"count": triangles * 2, "type": "VEC3", "componentType": 5126},
        ],
        "meshes": [{"primitives": [{"indices": 0, "attributes": {"POSITION": 1}}]}],
    }
    if external_uri:
        document["buffers"] = [{"uri": external_uri, "byteLength": 12}]
    encoded = json.dumps(document, separators=(",", ":")).encode()
    encoded += b" " * ((4 - len(encoded) % 4) % 4)
    total_length = 12 + 8 + len(encoded)
    return (
        b"glTF"
        + struct.pack("<II", 2, total_length)
        + struct.pack("<II", len(encoded), 0x4E4F534A)
        + encoded
    )


def _spec(*, target_polycount: int = 100) -> AssetSpec:
    return AssetSpec(
        asset_id="test-coffee-mug",
        season_id="season-001",
        name="Test coffee mug",
        license="CC0",
        inputs=GenerationInputs(
            kind="prop",
            provider="trellis",
            mode="text-to-3d",
            prompt="a chipped enamel coffee mug",
            params={"target_polycount": target_polycount, "seed": 7},
            pipeline_version=1,
        ),
    )


class _StubProvider:
    provider_id = "trellis"

    def __init__(self, glb: bytes) -> None:
        self._glb = glb
        self.calls = 0

    def generate(self, request: AssetGenRequest) -> AssetGenResult:
        self.calls += 1
        return AssetGenResult(
            content_address=compute_content_address(request.inputs),
            provider_used=self.provider_id,
            glb_bytes=self._glb,
        )

    def close(self) -> None:
        pass


class _StubPostProcessor:
    def process(
        self,
        source_glb: bytes,
        spec: AssetSpec,
        *,
        max_size_bytes: int,
    ) -> ProcessedAsset:
        del source_glb, spec
        optimized = _glb(triangles=100)
        assert len(optimized) < max_size_bytes
        return ProcessedAsset(
            glb_bytes=optimized,
            thumbnail_png=b"\x89PNG\r\n\x1a\nstub",
            lod_glbs=(_glb(triangles=50), _glb(triangles=20)),
            polycount=100,
            size_bytes=len(optimized),
            processor_version="test-v1",
        )


def test_job_round_trip_preserves_content_address() -> None:
    job = AssetJob(_spec())
    decoded = AssetJob.from_bytes(job.to_bytes())
    assert decoded == job
    assert decoded.spec.content_address == job.spec.content_address


def test_worker_drains_queue_and_is_idempotent_on_retry(tmp_path: Path) -> None:
    provider = _StubProvider(_glb(triangles=300))
    repository = InMemoryAssetRepository()
    queue = InMemoryAssetJobQueue()
    submission = AssetSubmissionService(repository=repository, publisher=queue)
    store = LocalAssetObjectStore(tmp_path / "objects")
    worker = AssetGenerationWorker(
        provider=RoutingAssetGenProvider(primary=provider),
        repository=repository,
        object_store=store,
        postprocessor=_StubPostProcessor(),
        quality_gate=AutomatedAssetQualityGate(),
        max_size_bytes=1_000_000,
    )

    first, first_deduplicated = submission.submit(_spec())
    second, second_deduplicated = submission.submit(_spec())
    assert first.status == AssetStatus.QUEUED
    assert second.status == AssetStatus.QUEUED
    assert not first_deduplicated
    assert second_deduplicated
    assert len(queue) == 2

    drained = queue.drain(worker)
    ready = repository.get(_spec().content_address)

    assert [record.status for record in drained] == [
        AssetStatus.READY,
        AssetStatus.READY,
    ]
    assert ready is not None
    assert ready.status == AssetStatus.READY
    assert ready.provider_used == "trellis"
    assert ready.polycount == 100
    assert ready.size_bytes < 1_000_000
    assert ready.attempt_count == 1
    assert len(ready.lod_uris) == 2
    assert provider.calls == 1
    assert len(tuple((tmp_path / "objects").rglob("*.*"))) == 4


def test_expired_worker_lease_can_be_reclaimed() -> None:
    repository = InMemoryAssetRepository()
    spec = _spec()
    repository.enqueue(spec)
    first = repository.claim(spec.content_address, lease_seconds=0)
    second = repository.claim(spec.content_address, lease_seconds=60)
    assert first is not None
    assert second is not None
    assert second.attempt_count == 2


def test_quality_gate_rejects_external_resources() -> None:
    spec = _spec()
    glb = _glb(external_uri="https://example.test/texture.png")
    asset = ProcessedAsset(
        glb_bytes=glb,
        thumbnail_png=b"\x89PNG\r\n\x1a\nstub",
        lod_glbs=(_glb(), _glb()),
        polycount=100,
        size_bytes=len(glb),
        processor_version="test-v1",
    )
    result = AutomatedAssetQualityGate().evaluate(
        asset,
        spec,
        max_size_bytes=1_000_000,
    )
    assert not result.passed
    assert "external resource URIs" in result.reasons[0]


def test_inspect_glb_rejects_declared_length_mismatch() -> None:
    malformed = bytearray(_glb())
    struct.pack_into("<I", malformed, 8, len(malformed) + 4)
    with pytest.raises(AssetPostProcessingError, match="declared length"):
        inspect_glb(bytes(malformed))


def test_gltfpack_postprocessor_builds_primary_and_lods() -> None:
    commands: list[list[str]] = []

    def copy_runner(command: list[str]) -> None:
        commands.append(command)
        source = Path(command[command.index("-i") + 1])
        destination = Path(command[command.index("-o") + 1])
        shutil.copyfile(source, destination)

    result = GltfpackPostProcessor(
        binary="/opt/tools/gltfpack",
        runner=copy_runner,
    ).process(
        _glb(triangles=300),
        _spec(target_polycount=100),
        max_size_bytes=1_000_000,
    )

    assert len(commands) == 3
    assert commands[0][:1] == ["/opt/tools/gltfpack"]
    assert "-cc" in commands[0]
    assert commands[0][commands[0].index("-si") + 1] == "0.333333"
    assert len(result.lod_glbs) == 2
    assert result.thumbnail_png.startswith(b"\x89PNG\r\n\x1a\n")


def test_local_object_store_rejects_parent_traversal(tmp_path: Path) -> None:
    store = LocalAssetObjectStore(tmp_path)
    with pytest.raises(ValueError, match="safe relative path"):
        store.put("../asset.glb", b"x", content_type="model/gltf-binary")


def test_r2_object_store_uploads_with_content_type() -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.kwargs: dict[str, object] = {}

        def put_object(self, **kwargs: object) -> None:
            self.kwargs = kwargs

    client = FakeClient()
    store = R2AssetObjectStore(
        bucket="echo-assets",
        endpoint_url="https://account.r2.cloudflarestorage.com",
        access_key_id="test",
        secret_access_key="test",
        public_base_url="https://cdn.example.test",
        client=client,
    )
    uri = store.put("assets/test.glb", b"glTF", content_type="model/gltf-binary")
    assert uri == "https://cdn.example.test/assets/test.glb"
    assert client.kwargs["Bucket"] == "echo-assets"
    assert client.kwargs["ContentType"] == "model/gltf-binary"


@pytest.mark.asyncio
async def test_long_job_sends_jetstream_progress_heartbeats() -> None:
    class SlowWorker:
        def process(self, job: AssetJob) -> None:
            del job
            time.sleep(0.04)

    class FakeMessage:
        def __init__(self) -> None:
            self.heartbeats = 0

        async def in_progress(self) -> None:
            self.heartbeats += 1

    message = FakeMessage()
    await _process_with_heartbeat(
        SlowWorker(),  # type: ignore[arg-type]
        AssetJob(_spec()),
        message,
        heartbeat_seconds=0.01,
    )
    assert message.heartbeats >= 1


@pytest.mark.asyncio
async def test_jetstream_is_created_with_work_queue_retention() -> None:
    # The stream-creation path builds a real nats.js.api.StreamConfig, so
    # this test needs the `asset-worker` optional extra installed. CI runs
    # `uv sync --dev` (no extra), so skip rather than fail there; the test
    # runs wherever nats-py is present. The "rejects" sibling test does not
    # reach this import (it raises before building a config).
    pytest.importorskip("nats.js.api")

    class NotFoundError(Exception):
        pass

    class FakeJetStream:
        def __init__(self) -> None:
            self.config: object | None = None

        async def stream_info(self, stream: str) -> None:
            del stream
            raise NotFoundError

        async def add_stream(self, *, config: object) -> None:
            self.config = config

    jetstream = FakeJetStream()
    await _ensure_stream(jetstream, "ECHO_ASSET_GEN", "echo.asset-gen.generate")
    assert jetstream.config is not None
    assert getattr(jetstream.config, "retention").value == "workqueue"


@pytest.mark.asyncio
async def test_jetstream_rejects_non_queue_retention() -> None:
    class FakeJetStream:
        async def stream_info(self, stream: str) -> object:
            del stream
            return SimpleNamespace(
                config=SimpleNamespace(
                    retention=SimpleNamespace(value="limits"),
                )
            )

    with pytest.raises(RuntimeError, match="work-queue retention"):
        await _ensure_stream(
            FakeJetStream(),
            "ECHO_ASSET_GEN",
            "echo.asset-gen.generate",
        )
