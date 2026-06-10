"""Metadata repositories for generated assets."""

from __future__ import annotations

import importlib
import json
import threading
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

from app.services.asset_gen.models import (
    AssetRecord,
    AssetSpec,
    AssetStatus,
    EnqueueResult,
)


class AssetRepository(Protocol):
    def enqueue(self, spec: AssetSpec) -> EnqueueResult: ...

    def get(self, content_address: str) -> AssetRecord | None: ...

    def claim(
        self,
        content_address: str,
        *,
        lease_seconds: int,
    ) -> AssetRecord | None: ...

    def set_status(self, content_address: str, status: AssetStatus) -> AssetRecord: ...

    def mark_ready(
        self,
        content_address: str,
        *,
        provider_used: str,
        glb_uri: str,
        thumbnail_uri: str,
        lod_uris: tuple[str, ...],
        polycount: int,
        size_bytes: int,
    ) -> AssetRecord: ...

    def mark_failed(self, content_address: str, error: str) -> AssetRecord: ...

    def list(
        self,
        *,
        season_id: str = "",
        status: AssetStatus | None = None,
    ) -> tuple[AssetRecord, ...]: ...


class InMemoryAssetRepository:
    """Thread-safe repository used by deterministic worker tests."""

    def __init__(self) -> None:
        self._records: dict[str, AssetRecord] = {}
        self._lock = threading.Lock()

    def enqueue(self, spec: AssetSpec) -> EnqueueResult:
        address = spec.content_address
        now = datetime.now(UTC)
        with self._lock:
            existing = self._records.get(address)
            if existing is None:
                record = AssetRecord(
                    spec=spec,
                    status=AssetStatus.QUEUED,
                    created_at=now,
                    updated_at=now,
                )
                self._records[address] = record
                return EnqueueResult(record, deduplicated=False, should_publish=True)
            if existing.status == AssetStatus.FAILED:
                record = replace(
                    existing,
                    status=AssetStatus.QUEUED,
                    error="",
                    updated_at=now,
                    lease_expires_at=None,
                )
                self._records[address] = record
                return EnqueueResult(record, deduplicated=True, should_publish=True)
            return EnqueueResult(
                existing,
                deduplicated=True,
                should_publish=existing.status == AssetStatus.QUEUED,
            )

    def get(self, content_address: str) -> AssetRecord | None:
        with self._lock:
            return self._records.get(content_address)

    def claim(
        self,
        content_address: str,
        *,
        lease_seconds: int = 3600,
    ) -> AssetRecord | None:
        now = datetime.now(UTC)
        with self._lock:
            existing = self._records.get(content_address)
            if existing is None:
                return None
            claimable = existing.status == AssetStatus.QUEUED or (
                existing.status
                in {
                    AssetStatus.GENERATING,
                    AssetStatus.POSTPROCESSING,
                    AssetStatus.QA,
                }
                and existing.lease_expires_at is not None
                and existing.lease_expires_at <= now
            )
            if not claimable:
                return None
            record = replace(
                existing,
                status=AssetStatus.GENERATING,
                attempt_count=existing.attempt_count + 1,
                error="",
                updated_at=now,
                lease_expires_at=now + timedelta(seconds=lease_seconds),
            )
            self._records[content_address] = record
            return record

    def set_status(self, content_address: str, status: AssetStatus) -> AssetRecord:
        with self._lock:
            record = replace(
                self._required(content_address),
                status=status,
                updated_at=datetime.now(UTC),
            )
            self._records[content_address] = record
            return record

    def mark_ready(
        self,
        content_address: str,
        *,
        provider_used: str,
        glb_uri: str,
        thumbnail_uri: str,
        lod_uris: tuple[str, ...],
        polycount: int,
        size_bytes: int,
    ) -> AssetRecord:
        now = datetime.now(UTC)
        with self._lock:
            record = replace(
                self._required(content_address),
                status=AssetStatus.READY,
                provider_used=provider_used,
                glb_uri=glb_uri,
                thumbnail_uri=thumbnail_uri,
                lod_uris=lod_uris,
                polycount=polycount,
                size_bytes=size_bytes,
                error="",
                updated_at=now,
                ready_at=now,
                lease_expires_at=None,
            )
            self._records[content_address] = record
            return record

    def mark_failed(self, content_address: str, error: str) -> AssetRecord:
        with self._lock:
            record = replace(
                self._required(content_address),
                status=AssetStatus.FAILED,
                error=error[:2000],
                updated_at=datetime.now(UTC),
                lease_expires_at=None,
            )
            self._records[content_address] = record
            return record

    def list(
        self,
        *,
        season_id: str = "",
        status: AssetStatus | None = None,
    ) -> tuple[AssetRecord, ...]:
        with self._lock:
            records = self._records.values()
            return tuple(
                sorted(
                    (
                        record
                        for record in records
                        if (not season_id or record.spec.season_id == season_id)
                        and (status is None or record.status == status)
                    ),
                    key=lambda record: (record.created_at, record.content_address),
                )
            )

    def _required(self, content_address: str) -> AssetRecord:
        record = self._records.get(content_address)
        if record is None:
            raise KeyError(f"unknown asset {content_address}")
        return record


_SELECT_COLUMNS = """
content_address, spec, status, provider_used, glb_uri, thumbnail_uri,
lod_uris, polycount, size_bytes, error, attempt_count,
created_at, updated_at, ready_at, lease_expires_at
"""


class PostgresAssetRepository:
    """Blocking Psycopg repository used by gRPC and worker processes."""

    def __init__(self, dsn: str) -> None:
        if not dsn:
            raise ValueError("DATABASE_URL is required")
        self._dsn = dsn

    def _connect(self) -> Any:
        psycopg = importlib.import_module("psycopg")
        return psycopg.connect(self._dsn)

    def enqueue(self, spec: AssetSpec) -> EnqueueResult:
        address = spec.content_address
        spec_json = json.dumps(spec.to_dict(), separators=(",", ":"))
        with self._connect() as conn:
            inserted = conn.execute(
                """
                INSERT INTO content.generated_assets (
                    content_address, season_id, asset_id, spec, status,
                    provider_requested, pipeline_version
                )
                VALUES (%s, %s, %s, %s::jsonb, 'queued', %s, %s)
                ON CONFLICT (content_address) DO NOTHING
                RETURNING content_address
                """,
                (
                    address,
                    spec.season_id,
                    spec.asset_id,
                    spec_json,
                    spec.inputs.provider,
                    spec.inputs.pipeline_version,
                ),
            ).fetchone()
            if inserted is None:
                conn.execute(
                    """
                    UPDATE content.generated_assets
                    SET status = 'queued',
                        error = '',
                        lease_expires_at = NULL,
                        updated_at = NOW()
                    WHERE content_address = %s AND status = 'failed'
                    """,
                    (address,),
                )
            row = conn.execute(
                f"SELECT {_SELECT_COLUMNS} FROM content.generated_assets "
                "WHERE content_address = %s",
                (address,),
            ).fetchone()
        record = _record_from_row(row)
        return EnqueueResult(
            record=record,
            deduplicated=inserted is None,
            should_publish=record.status == AssetStatus.QUEUED,
        )

    def get(self, content_address: str) -> AssetRecord | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {_SELECT_COLUMNS} FROM content.generated_assets "
                "WHERE content_address = %s",
                (content_address,),
            ).fetchone()
        return _record_from_row(row) if row is not None else None

    def claim(
        self,
        content_address: str,
        *,
        lease_seconds: int = 3600,
    ) -> AssetRecord | None:
        with self._connect() as conn:
            row = conn.execute(
                f"""
                UPDATE content.generated_assets
                SET status = 'generating',
                    attempt_count = attempt_count + 1,
                    error = '',
                    lease_expires_at = NOW() + (%s * INTERVAL '1 second'),
                    updated_at = NOW()
                WHERE content_address = %s
                  AND (
                    status = 'queued'
                    OR (
                      status IN ('generating', 'postprocessing', 'qa')
                      AND lease_expires_at <= NOW()
                    )
                  )
                RETURNING {_SELECT_COLUMNS}
                """,
                (lease_seconds, content_address),
            ).fetchone()
        return _record_from_row(row) if row is not None else None

    def set_status(self, content_address: str, status: AssetStatus) -> AssetRecord:
        with self._connect() as conn:
            row = conn.execute(
                f"""
                UPDATE content.generated_assets
                SET status = %s, updated_at = NOW()
                WHERE content_address = %s
                RETURNING {_SELECT_COLUMNS}
                """,
                (status.value, content_address),
            ).fetchone()
        return _record_from_required_row(row, content_address)

    def mark_ready(
        self,
        content_address: str,
        *,
        provider_used: str,
        glb_uri: str,
        thumbnail_uri: str,
        lod_uris: tuple[str, ...],
        polycount: int,
        size_bytes: int,
    ) -> AssetRecord:
        with self._connect() as conn:
            row = conn.execute(
                f"""
                UPDATE content.generated_assets
                SET status = 'ready',
                    provider_used = %s,
                    glb_uri = %s,
                    thumbnail_uri = %s,
                    lod_uris = %s::jsonb,
                    polycount = %s,
                    size_bytes = %s,
                    error = '',
                    ready_at = NOW(),
                    lease_expires_at = NULL,
                    updated_at = NOW()
                WHERE content_address = %s
                RETURNING {_SELECT_COLUMNS}
                """,
                (
                    provider_used,
                    glb_uri,
                    thumbnail_uri,
                    json.dumps(lod_uris),
                    polycount,
                    size_bytes,
                    content_address,
                ),
            ).fetchone()
        return _record_from_required_row(row, content_address)

    def mark_failed(self, content_address: str, error: str) -> AssetRecord:
        with self._connect() as conn:
            row = conn.execute(
                f"""
                UPDATE content.generated_assets
                SET status = 'failed',
                    error = %s,
                    lease_expires_at = NULL,
                    updated_at = NOW()
                WHERE content_address = %s
                RETURNING {_SELECT_COLUMNS}
                """,
                (error[:2000], content_address),
            ).fetchone()
        return _record_from_required_row(row, content_address)

    def list(
        self,
        *,
        season_id: str = "",
        status: AssetStatus | None = None,
    ) -> tuple[AssetRecord, ...]:
        clauses: list[str] = []
        params: list[object] = []
        if season_id:
            clauses.append("season_id = %s")
            params.append(season_id)
        if status is not None:
            clauses.append("status = %s")
            params.append(status.value)
        where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
        with self._connect() as conn:
            rows = conn.execute(
                f"SELECT {_SELECT_COLUMNS} FROM content.generated_assets"
                f"{where} ORDER BY created_at, content_address",
                tuple(params),
            ).fetchall()
        return tuple(_record_from_row(row) for row in rows)


def _record_from_required_row(row: Any, content_address: str) -> AssetRecord:
    if row is None:
        raise KeyError(f"unknown asset {content_address}")
    return _record_from_row(row)


def _record_from_row(row: Any) -> AssetRecord:
    spec_value = row[1]
    if isinstance(spec_value, str):
        spec_value = json.loads(spec_value)
    lod_value = row[6]
    if isinstance(lod_value, str):
        lod_value = json.loads(lod_value)
    return AssetRecord(
        spec=AssetSpec.from_dict(spec_value),
        status=AssetStatus(row[2]),
        provider_used=row[3] or "",
        glb_uri=row[4] or "",
        thumbnail_uri=row[5] or "",
        lod_uris=tuple(lod_value or ()),
        polycount=int(row[7] or 0),
        size_bytes=int(row[8] or 0),
        error=row[9] or "",
        attempt_count=int(row[10] or 0),
        created_at=row[11],
        updated_at=row[12],
        ready_at=row[13],
        lease_expires_at=row[14],
    )
