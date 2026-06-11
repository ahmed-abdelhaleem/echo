"""JetStream and in-memory job queues for T-ML-051."""

from __future__ import annotations

import asyncio
import importlib
import logging
from collections import deque
from typing import Any, Protocol

from app.services.asset_gen.models import AssetJob, AssetRecord, AssetSpec, AssetStatus
from app.services.asset_gen.repository import AssetRepository
from app.services.asset_gen.spend_cap import NoSpendCap, SpendCap
from app.services.asset_gen.worker import AssetGenerationWorker

logger = logging.getLogger(__name__)

DEFAULT_NATS_URL = "nats://127.0.0.1:4222"
DEFAULT_STREAM = "ECHO_ASSET_GEN"
DEFAULT_SUBJECT = "echo.asset-gen.generate"
DEFAULT_DURABLE = "echo-asset-gen-workers"


class AssetJobPublisher(Protocol):
    def publish(self, job: AssetJob) -> None: ...


class AssetSubmissionService:
    """Persist desired state and publish jobs without generating inline."""

    def __init__(
        self,
        *,
        repository: AssetRepository,
        publisher: AssetJobPublisher,
        spend_cap: SpendCap | None = None,
    ) -> None:
        self.repository = repository
        self._publisher = publisher
        # Per-environment spend guard (T-INFRA-040). Defaults to no cap so
        # tests and dev are unaffected until ECHO_ASSET_GEN_PERIOD_CAP is set.
        self._spend_cap: SpendCap = spend_cap or NoSpendCap()

    def submit(self, spec: AssetSpec, *, dry_run: bool = False) -> tuple[AssetRecord, bool]:
        if dry_run:
            return AssetRecord(spec=spec, status=AssetStatus.QUEUED), False
        # Charge the spend cap only for submissions that would incur paid
        # work (a publish): a missing or FAILED row will (re)publish; a
        # READY or already-pending row is free. We peek BEFORE enqueue so a
        # capped submission leaves no zombie QUEUED row with no job behind
        # it — the asset stays missing and is retried when the window rolls.
        existing = self.repository.get(spec.content_address)
        would_publish = existing is None or existing.status == AssetStatus.FAILED
        if would_publish:
            self._spend_cap.charge()  # raises AssetGenBudgetExceededError when over
        result = self.repository.enqueue(spec)
        if result.should_publish:
            self._publisher.publish(AssetJob(spec))
        return result.record, result.deduplicated


class InMemoryAssetJobQueue:
    """Small FIFO queue used by the T-ML-051 integration test."""

    def __init__(self) -> None:
        self._jobs: deque[AssetJob] = deque()

    def publish(self, job: AssetJob) -> None:
        self._jobs.append(job)

    def drain(self, worker: AssetGenerationWorker) -> tuple[AssetRecord, ...]:
        records: list[AssetRecord] = []
        while self._jobs:
            records.append(worker.process(self._jobs.popleft()))
        return tuple(records)

    def __len__(self) -> int:
        return len(self._jobs)


class NatsAssetJobPublisher:
    """Blocking facade used by the synchronous gRPC service."""

    def __init__(
        self,
        *,
        nats_url: str = DEFAULT_NATS_URL,
        stream: str = DEFAULT_STREAM,
        subject: str = DEFAULT_SUBJECT,
    ) -> None:
        self._nats_url = nats_url
        self._stream = stream
        self._subject = subject

    def publish(self, job: AssetJob) -> None:
        asyncio.run(self._publish(job))

    async def _publish(self, job: AssetJob) -> None:
        nats = importlib.import_module("nats")
        connection = await nats.connect(self._nats_url)
        try:
            jetstream = connection.jetstream()
            await _ensure_stream(jetstream, self._stream, self._subject)
            await jetstream.publish(self._subject, job.to_bytes())
        finally:
            await connection.drain()


async def run_nats_worker(
    worker: AssetGenerationWorker,
    *,
    nats_url: str = DEFAULT_NATS_URL,
    stream: str = DEFAULT_STREAM,
    subject: str = DEFAULT_SUBJECT,
    durable: str = DEFAULT_DURABLE,
) -> None:
    """Run one pull consumer forever; JetStream redelivers failed jobs."""
    nats = importlib.import_module("nats")
    connection = await nats.connect(nats_url)
    jetstream = connection.jetstream()
    await _ensure_stream(jetstream, stream, subject)
    subscription = await jetstream.pull_subscribe(
        subject,
        durable=durable,
        stream=stream,
    )
    try:
        while True:
            try:
                messages = await subscription.fetch(1, timeout=1)
            except Exception as exc:
                if type(exc).__name__ == "TimeoutError":
                    continue
                raise
            for message in messages:
                try:
                    job = AssetJob.from_bytes(message.data)
                    await _process_with_heartbeat(worker, job, message)
                except Exception:
                    logger.exception("asset job delivery failed")
                    await message.nak(delay=30)
                else:
                    await message.ack()
    finally:
        await connection.drain()


async def _process_with_heartbeat(
    worker: AssetGenerationWorker,
    job: AssetJob,
    message: Any,
    *,
    heartbeat_seconds: float = 20,
) -> None:
    task = asyncio.create_task(asyncio.to_thread(worker.process, job))
    while True:
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout=heartbeat_seconds)
            return
        except TimeoutError:
            await message.in_progress()


async def _ensure_stream(jetstream: Any, stream: str, subject: str) -> None:
    try:
        info = await jetstream.stream_info(stream)
    except Exception as exc:
        if type(exc).__name__ not in {"NotFoundError", "NotFound"}:
            raise
        api = importlib.import_module("nats.js.api")
        await jetstream.add_stream(
            config=api.StreamConfig(
                name=stream,
                subjects=[subject],
                retention=api.RetentionPolicy.WORK_QUEUE,
                storage=api.StorageType.FILE,
            )
        )
        return
    retention = info.config.retention
    if hasattr(retention, "value"):
        retention = retention.value
    if str(retention) != "workqueue":
        raise RuntimeError(f"JetStream {stream} must use work-queue retention")
