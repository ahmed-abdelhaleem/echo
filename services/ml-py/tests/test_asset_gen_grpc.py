"""gRPC coverage for T-ML-051 queue submission and metadata lookup."""

from __future__ import annotations

import time
from collections.abc import Generator
from concurrent import futures
from dataclasses import dataclass

import grpc
import pytest

from app import grpc_server
from app.grpc_gen import asset_gen_pb2, asset_gen_pb2_grpc
from app.services.asset_gen.models import AssetStatus
from app.services.asset_gen.queue import AssetSubmissionService, InMemoryAssetJobQueue
from app.services.asset_gen.repository import InMemoryAssetRepository


@dataclass(frozen=True)
class _GrpcFixture:
    channel: grpc.Channel
    repository: InMemoryAssetRepository
    queue: InMemoryAssetJobQueue


@pytest.fixture
def asset_grpc() -> Generator[_GrpcFixture, None, None]:
    repository = InMemoryAssetRepository()
    queue = InMemoryAssetJobQueue()
    service = AssetSubmissionService(repository=repository, publisher=queue)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
    asset_gen_pb2_grpc.add_AssetGenServiceServicer_to_server(
        grpc_server.AssetGenServicer(service),
        server,
    )
    port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    channel = grpc.insecure_channel(f"127.0.0.1:{port}")
    grpc.channel_ready_future(channel).result(timeout=5)
    try:
        yield _GrpcFixture(channel, repository, queue)
    finally:
        channel.close()
        server.stop(grace=0)
        time.sleep(0.05)


def _request(*, dry_run: bool = False, content_address: str = "") -> object:
    return asset_gen_pb2.SubmitAssetRequest(
        dry_run=dry_run,
        spec=asset_gen_pb2.AssetSpec(
            id="grpc-coffee-mug",
            name="gRPC coffee mug",
            kind=asset_gen_pb2.ASSET_KIND_PROP,
            license="CC0",
            content_address=content_address,
            generation=asset_gen_pb2.Generation(
                provider=asset_gen_pb2.PROVIDER_TRELLIS,
                mode=asset_gen_pb2.GEN_MODE_TEXT_TO_3D,
                prompt="a chipped enamel coffee mug",
                params={"target_polycount": 8000, "seed": 7},
                pipeline_version=1,
                format=asset_gen_pb2.ASSET_FORMAT_GLB,
            ),
        ),
    )


def test_submit_enqueues_and_duplicate_is_idempotent(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    first = stub.SubmitAsset(_request())
    second = stub.SubmitAsset(_request())

    assert first.status == asset_gen_pb2.ASSET_STATUS_QUEUED
    assert not first.deduplicated
    assert second.content_address == first.content_address
    assert second.deduplicated
    assert len(asset_grpc.queue) == 2
    record = asset_grpc.repository.get(first.content_address)
    assert record is not None
    assert record.status == AssetStatus.QUEUED


def test_dry_run_does_not_persist_or_publish(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    response = stub.SubmitAsset(_request(dry_run=True))
    assert response.content_address.startswith("sha256:")
    assert asset_grpc.repository.get(response.content_address) is None
    assert len(asset_grpc.queue) == 0


def test_get_and_list_return_persisted_metadata(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    submitted = stub.SubmitAsset(_request())
    asset_grpc.repository.claim(submitted.content_address)
    asset_grpc.repository.mark_ready(
        submitted.content_address,
        provider_used="trellis",
        glb_uri="https://cdn.example.test/asset.glb",
        thumbnail_uri="https://cdn.example.test/thumbnail.png",
        lod_uris=("https://cdn.example.test/lod-1.glb",),
        polycount=7990,
        size_bytes=123456,
    )

    asset = stub.GetAssetStatus(
        asset_gen_pb2.GetAssetStatusRequest(content_address=submitted.content_address)
    )
    listed = stub.ListAssets(
        asset_gen_pb2.ListAssetsRequest(status_filter=asset_gen_pb2.ASSET_STATUS_READY)
    )

    assert asset.status == asset_gen_pb2.ASSET_STATUS_READY
    assert asset.provider_used == asset_gen_pb2.PROVIDER_TRELLIS
    assert asset.polycount == 7990
    assert asset.size_bytes == 123456
    assert asset.glb_uri.endswith("asset.glb")
    assert [item.spec.id for item in listed.assets] == ["grpc-coffee-mug"]


def test_get_missing_asset_returns_not_found(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    with pytest.raises(grpc.RpcError) as exc_info:
        stub.GetAssetStatus(
            asset_gen_pb2.GetAssetStatusRequest(content_address="sha256:" + ("0" * 64))
        )
    assert exc_info.value.code() == grpc.StatusCode.NOT_FOUND


def test_submit_rejects_mismatched_claimed_address(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    with pytest.raises(grpc.RpcError) as exc_info:
        stub.SubmitAsset(_request(content_address="sha256:" + ("0" * 64)))
    assert exc_info.value.code() == grpc.StatusCode.INVALID_ARGUMENT


# ---------------------------------------------------------------------------
# ReconcileManifest (T-ML-052)
# ---------------------------------------------------------------------------


def _desired_spec(asset_id: str, prompt: str) -> object:
    return asset_gen_pb2.AssetSpec(
        id=asset_id,
        kind=asset_gen_pb2.ASSET_KIND_PROP,
        license="CC0",
        generation=asset_gen_pb2.Generation(
            provider=asset_gen_pb2.PROVIDER_TRELLIS,
            mode=asset_gen_pb2.GEN_MODE_TEXT_TO_3D,
            prompt=prompt,
            pipeline_version=1,
            format=asset_gen_pb2.ASSET_FORMAT_GLB,
        ),
    )


def test_reconcile_enqueues_missing_assets(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    resp = stub.ReconcileManifest(
        asset_gen_pb2.ReconcileManifestRequest(
            season_id="season-001",
            desired=[
                _desired_spec("a", "asset a"),
                _desired_spec("b", "asset b"),
                _desired_spec("c", "asset c"),
            ],
        )
    )
    assert len(resp.enqueued_addresses) == 3
    assert list(resp.already_ready) == []
    assert len(asset_grpc.queue) == 3


def test_reconcile_respects_budget_cap(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    resp = stub.ReconcileManifest(
        asset_gen_pb2.ReconcileManifestRequest(
            season_id="season-001",
            budget_cap=1,
            desired=[
                _desired_spec("a", "asset a"),
                _desired_spec("b", "asset b"),
                _desired_spec("c", "asset c"),
            ],
        )
    )
    assert len(resp.enqueued_addresses) == 1
    assert resp.budget_remaining == 0
    assert len(asset_grpc.queue) == 1


def test_reconcile_is_idempotent(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    desired = [_desired_spec("a", "asset a"), _desired_spec("b", "asset b")]

    first = stub.ReconcileManifest(
        asset_gen_pb2.ReconcileManifestRequest(season_id="season-001", desired=desired)
    )
    assert len(first.enqueued_addresses) == 2

    second = stub.ReconcileManifest(
        asset_gen_pb2.ReconcileManifestRequest(season_id="season-001", desired=desired)
    )
    assert list(second.enqueued_addresses) == []
    assert len(asset_grpc.queue) == 2  # nothing re-published


def test_reconcile_dry_run_enqueues_nothing(asset_grpc: _GrpcFixture) -> None:
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(asset_grpc.channel)
    resp = stub.ReconcileManifest(
        asset_gen_pb2.ReconcileManifestRequest(
            season_id="season-001",
            dry_run=True,
            desired=[_desired_spec("a", "asset a")],
        )
    )
    assert len(resp.enqueued_addresses) == 1  # reported
    assert len(asset_grpc.queue) == 0  # but not published
