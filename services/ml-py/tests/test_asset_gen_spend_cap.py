"""Tests for the per-environment asset-gen spend cap (T-INFRA-040).

Acceptance criterion (docs/07): "exceeding the budget cap halts
generation and alerts rather than spending unbounded."

Coverage:
- under-cap submissions pass; the cap counts them.
- at-cap submission raises AssetGenBudgetExceededError; alert sink
  fires exactly once per window.
- rolling window resets after period_seconds; alert can fire again in
  the next window.
- dedup hits (READY rows) and already-pending rows are FREE — they
  don't consume cap.
- the reconciler halts gracefully on cap, defers the rest, and reports
  spend_capped=True. Assets enqueued before the trip stand.
- build_spend_cap_from_env: zero/unset cap => NoSpendCap; positive cap
  => WindowedSubmissionCap with the configured window.
- gRPC SubmitAsset maps the error to RESOURCE_EXHAUSTED.
"""

from __future__ import annotations

import time
from collections.abc import Generator
from concurrent import futures
from datetime import UTC, datetime, timedelta

import grpc
import pytest

from app import grpc_server
from app.grpc_gen import asset_gen_pb2, asset_gen_pb2_grpc
from app.services.asset_gen import (
    AssetGenBudgetExceededError,
    AssetReconciler,
    AssetSpec,
    AssetSubmissionService,
    GenerationInputs,
    InMemoryAssetJobQueue,
    InMemoryAssetRepository,
    NoSpendCap,
    SpendUsage,
    WindowedSubmissionCap,
    build_spend_cap_from_env,
)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _spec(prompt: str, *, asset_id: str | None = None) -> AssetSpec:
    return AssetSpec(
        asset_id=asset_id or prompt.replace(" ", "-"),
        season_id="season-001",
        inputs=GenerationInputs(
            kind="prop",
            provider="trellis",
            mode="text-to-3d",
            prompt=prompt,
            pipeline_version=1,
        ),
    )


class _FakeClock:
    """Monotonic injectable clock for the windowed cap."""

    def __init__(self, start: datetime) -> None:
        self.now = start

    def __call__(self) -> datetime:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now = self.now + timedelta(seconds=seconds)


# ---------------------------------------------------------------------------
# WindowedSubmissionCap
# ---------------------------------------------------------------------------


def test_no_spend_cap_is_unlimited() -> None:
    cap = NoSpendCap()
    for _ in range(50):
        cap.charge()  # never raises
    usage = cap.usage()
    assert usage.limit == 0
    assert usage.remaining == -1  # unlimited sentinel


def test_under_cap_charges_pass() -> None:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="dev", limit=3, period_seconds=60, clock=clock)
    for _ in range(3):
        cap.charge()
    assert cap.usage().used == 3
    assert cap.usage().remaining == 0


def test_at_cap_raises_and_alerts_once_per_window() -> None:
    alerts: list[AssetGenBudgetExceededError] = []
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(
        environment="prod",
        limit=2,
        period_seconds=60,
        clock=clock,
        alert_sink=alerts.append,
    )
    cap.charge()
    cap.charge()
    # Two more attempts in the same window -> both raise, but alert fires once.
    with pytest.raises(AssetGenBudgetExceededError) as first:
        cap.charge()
    with pytest.raises(AssetGenBudgetExceededError):
        cap.charge()
    assert len(alerts) == 1
    err = first.value
    assert err.environment == "prod"
    assert err.limit == 2
    assert err.usage == 2
    # Usage does not advance past the limit on a denied charge.
    assert cap.usage().used == 2


def test_window_rolls_and_resets_count_and_alerts() -> None:
    alerts: list[AssetGenBudgetExceededError] = []
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(
        environment="prod",
        limit=1,
        period_seconds=60,
        clock=clock,
        alert_sink=alerts.append,
    )
    cap.charge()
    with pytest.raises(AssetGenBudgetExceededError):
        cap.charge()
    assert len(alerts) == 1

    # Roll the window forward.
    clock.advance(61)

    # A fresh window: new charge passes, no new alert until the next breach.
    cap.charge()
    assert cap.usage().used == 1
    with pytest.raises(AssetGenBudgetExceededError):
        cap.charge()
    assert len(alerts) == 2  # one per window


def test_default_alert_sink_logs_critical(caplog: pytest.LogCaptureFixture) -> None:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=1, period_seconds=60, clock=clock)
    cap.charge()
    with (
        caplog.at_level("CRITICAL", logger="app.services.asset_gen.spend_cap"),
        pytest.raises(AssetGenBudgetExceededError),
    ):
        cap.charge()
    assert any("spend_cap.breached" in rec.message for rec in caplog.records)


def test_alert_sink_failure_does_not_mask_the_breach() -> None:
    def _broken_sink(exc: AssetGenBudgetExceededError) -> None:
        raise RuntimeError("sink down")

    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(
        environment="prod",
        limit=1,
        period_seconds=60,
        clock=clock,
        alert_sink=_broken_sink,
    )
    cap.charge()
    with pytest.raises(AssetGenBudgetExceededError):
        cap.charge()  # broken sink doesn't suppress the cap exception


def test_invalid_configuration_rejected() -> None:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    with pytest.raises(ValueError):
        WindowedSubmissionCap(environment="", limit=1, period_seconds=60, clock=clock)
    with pytest.raises(ValueError):
        WindowedSubmissionCap(environment="x", limit=0, period_seconds=60, clock=clock)
    with pytest.raises(ValueError):
        WindowedSubmissionCap(environment="x", limit=1, period_seconds=0, clock=clock)


def test_spend_usage_remaining_signals_unlimited() -> None:
    usage = SpendUsage(
        environment="x",
        limit=0,
        used=0,
        period_seconds=0,
        window_started_at=None,
    )
    assert usage.remaining == -1


# ---------------------------------------------------------------------------
# AssetSubmissionService integration
# ---------------------------------------------------------------------------


def _service(
    cap: object | None = None,
) -> tuple[AssetSubmissionService, InMemoryAssetRepository, InMemoryAssetJobQueue]:
    repo = InMemoryAssetRepository()
    queue = InMemoryAssetJobQueue()
    svc = AssetSubmissionService(repository=repo, publisher=queue, spend_cap=cap)  # type: ignore[arg-type]
    return svc, repo, queue


def test_submission_under_cap_publishes_and_charges() -> None:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=3, period_seconds=60, clock=clock)
    svc, _repo, queue = _service(cap)
    svc.submit(_spec("alpha"))
    svc.submit(_spec("beta"))
    assert len(queue) == 2
    assert cap.usage().used == 2


def test_submission_at_cap_raises_and_leaves_no_zombie_row() -> None:
    """T-INFRA-040 acceptance: cap halts before any persistence."""
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=1, period_seconds=60, clock=clock)
    svc, repo, queue = _service(cap)
    svc.submit(_spec("alpha"))
    blocked = _spec("beta")
    with pytest.raises(AssetGenBudgetExceededError):
        svc.submit(blocked)
    # No half-state: no queue publish and no metadata row for the rejected spec.
    assert len(queue) == 1
    assert repo.get(blocked.content_address) is None


def test_dedup_on_ready_is_free() -> None:
    """A submission whose content-address is already READY must not charge."""
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=1, period_seconds=60, clock=clock)
    svc, repo, _queue = _service(cap)
    spec = _spec("alpha")
    repo.enqueue(spec)
    repo.mark_ready(
        spec.content_address,
        provider_used="trellis",
        glb_uri="memory://x.glb",
        thumbnail_uri="",
        lod_uris=(),
        polycount=10,
        size_bytes=512,
    )
    # READY row exists. Re-submit -> charge skipped.
    svc.submit(spec)
    assert cap.usage().used == 0  # nothing charged
    # Limit still available for a real, missing asset.
    svc.submit(_spec("beta"))
    assert cap.usage().used == 1


def test_dedup_on_pending_is_free() -> None:
    """A submission for an already-QUEUED asset must not consume cap."""
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=1, period_seconds=60, clock=clock)
    svc, repo, _queue = _service(cap)
    spec = _spec("alpha")
    repo.enqueue(spec)  # pre-existing QUEUED row, no charge yet
    svc.submit(spec)  # second submit for the same content-address
    assert cap.usage().used == 0
    # Cap still available for a fresh asset.
    svc.submit(_spec("beta"))
    assert cap.usage().used == 1


def test_failed_row_resubmission_does_charge() -> None:
    """A FAILED row is a retry that re-publishes -> chargeable."""
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=2, period_seconds=60, clock=clock)
    svc, repo, queue = _service(cap)
    spec = _spec("alpha")
    repo.enqueue(spec)
    repo.mark_failed(spec.content_address, "transient provider error")
    svc.submit(spec)
    assert cap.usage().used == 1
    assert len(queue) == 1


def test_dry_run_does_not_charge() -> None:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=1, period_seconds=60, clock=clock)
    svc, _repo, _queue = _service(cap)
    svc.submit(_spec("alpha"), dry_run=True)
    assert cap.usage().used == 0


# ---------------------------------------------------------------------------
# Reconciler integration
# ---------------------------------------------------------------------------


def test_reconciler_halts_gracefully_when_cap_trips() -> None:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    cap = WindowedSubmissionCap(environment="prod", limit=2, period_seconds=60, clock=clock)
    svc, _repo, queue = _service(cap)
    reconciler = AssetReconciler(submission=svc)
    specs = [_spec(f"asset-{i}") for i in range(5)]

    outcome = reconciler.reconcile(specs)

    assert outcome.spend_capped is True
    assert len(outcome.enqueued) == 2  # cap allowed 2
    # The other three are deferred (the cap halt accounts for one; the
    # implicit fall-through covers the rest in the same loop).
    assert len(outcome.deferred) == 3
    assert len(queue) == 2


# ---------------------------------------------------------------------------
# build_spend_cap_from_env
# ---------------------------------------------------------------------------


def test_build_spend_cap_unset_returns_no_cap() -> None:
    cap = build_spend_cap_from_env({})
    assert isinstance(cap, NoSpendCap)


def test_build_spend_cap_zero_returns_no_cap() -> None:
    cap = build_spend_cap_from_env({"ECHO_ASSET_GEN_PERIOD_CAP": "0"})
    assert isinstance(cap, NoSpendCap)


def test_build_spend_cap_positive_returns_windowed() -> None:
    cap = build_spend_cap_from_env(
        {
            "ECHO_ASSET_GEN_PERIOD_CAP": "100",
            "ECHO_ASSET_GEN_PERIOD_SECONDS": "120",
            "ECHO_ENV": "production",
        }
    )
    assert isinstance(cap, WindowedSubmissionCap)
    assert cap.usage().limit == 100
    assert cap.usage().period_seconds == 120
    assert cap.environment == "production"


def test_build_spend_cap_rejects_non_integer() -> None:
    with pytest.raises(ValueError):
        build_spend_cap_from_env({"ECHO_ASSET_GEN_PERIOD_CAP": "many"})
    with pytest.raises(ValueError):
        build_spend_cap_from_env(
            {"ECHO_ASSET_GEN_PERIOD_CAP": "10", "ECHO_ASSET_GEN_PERIOD_SECONDS": "soon"}
        )


# ---------------------------------------------------------------------------
# gRPC RESOURCE_EXHAUSTED mapping
# ---------------------------------------------------------------------------


@pytest.fixture
def capped_grpc() -> Generator[
    tuple[grpc.Channel, InMemoryAssetRepository, InMemoryAssetJobQueue, _FakeClock],
    None,
    None,
]:
    clock = _FakeClock(datetime(2026, 6, 11, 12, 0, 0, tzinfo=UTC))
    repo = InMemoryAssetRepository()
    queue = InMemoryAssetJobQueue()
    cap = WindowedSubmissionCap(environment="prod", limit=1, period_seconds=60, clock=clock)
    svc = AssetSubmissionService(repository=repo, publisher=queue, spend_cap=cap)
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
    asset_gen_pb2_grpc.add_AssetGenServiceServicer_to_server(
        grpc_server.AssetGenServicer(svc),
        server,
    )
    port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    channel = grpc.insecure_channel(f"127.0.0.1:{port}")
    grpc.channel_ready_future(channel).result(timeout=5)
    try:
        yield channel, repo, queue, clock
    finally:
        channel.close()
        server.stop(grace=0)
        time.sleep(0.02)


def _submit_request(prompt: str) -> object:
    return asset_gen_pb2.SubmitAssetRequest(
        spec=asset_gen_pb2.AssetSpec(
            id=prompt.replace(" ", "-"),
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
    )


def test_grpc_submit_returns_resource_exhausted_when_capped(
    capped_grpc: tuple[grpc.Channel, InMemoryAssetRepository, InMemoryAssetJobQueue, _FakeClock],
) -> None:
    channel, _repo, _queue, _clock = capped_grpc
    stub = asset_gen_pb2_grpc.AssetGenServiceStub(channel)
    stub.SubmitAsset(_submit_request("alpha"))  # consumes the cap of 1
    with pytest.raises(grpc.RpcError) as exc_info:
        stub.SubmitAsset(_submit_request("beta"))
    assert exc_info.value.code() == grpc.StatusCode.RESOURCE_EXHAUSTED
    assert "cap" in exc_info.value.details().lower()
