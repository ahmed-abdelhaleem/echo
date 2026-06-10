-- 20260610000001_create_generated_assets.sql
--
-- Metadata and lifecycle state for the T-ML-051 background 3D asset worker.
-- Binary GLBs, thumbnails, and LODs live in R2; this table stores their
-- deterministic object URIs and the authored spec used to reproduce them.
--
-- The content-address is the idempotency key shared with the content manifest
-- validator. Duplicate JetStream deliveries therefore converge on one row.
--
-- Migration policy: additive only (AGENTS.md "Safety rails").

-- +goose Up
-- +goose StatementBegin

CREATE SCHEMA IF NOT EXISTS content;

CREATE TABLE IF NOT EXISTS content.generated_assets (
    content_address   TEXT        PRIMARY KEY,
    season_id         TEXT        NOT NULL DEFAULT '',
    asset_id          TEXT        NOT NULL,
    spec              JSONB       NOT NULL,
    status            TEXT        NOT NULL DEFAULT 'queued',
    provider_requested TEXT       NOT NULL,
    provider_used     TEXT        NOT NULL DEFAULT '',
    pipeline_version  INTEGER     NOT NULL,
    glb_uri           TEXT        NOT NULL DEFAULT '',
    thumbnail_uri     TEXT        NOT NULL DEFAULT '',
    lod_uris          JSONB       NOT NULL DEFAULT '[]'::jsonb,
    polycount         BIGINT      NOT NULL DEFAULT 0,
    size_bytes        BIGINT      NOT NULL DEFAULT 0,
    error             TEXT        NOT NULL DEFAULT '',
    attempt_count     INTEGER     NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ready_at          TIMESTAMPTZ,
    lease_expires_at  TIMESTAMPTZ,

    CONSTRAINT generated_assets_content_address_chk CHECK (
        content_address ~ '^sha256:[a-f0-9]{64}$'
    ),
    CONSTRAINT generated_assets_status_chk CHECK (
        status IN (
            'desired',
            'queued',
            'generating',
            'postprocessing',
            'qa',
            'ready',
            'failed'
        )
    ),
    CONSTRAINT generated_assets_pipeline_version_chk CHECK (
        pipeline_version >= 1
    ),
    CONSTRAINT generated_assets_counts_chk CHECK (
        polycount >= 0 AND size_bytes >= 0 AND attempt_count >= 0
    )
);

CREATE INDEX IF NOT EXISTS generated_assets_season_status_idx
    ON content.generated_assets (season_id, status, created_at);

CREATE INDEX IF NOT EXISTS generated_assets_asset_id_idx
    ON content.generated_assets (asset_id);

COMMENT ON TABLE content.generated_assets IS
    'Idempotent lifecycle and R2 metadata for generated vignette-world GLBs.';
COMMENT ON COLUMN content.generated_assets.content_address IS
    'Cross-language sha256 of kind + generation inputs; the queue dedup key.';
COMMENT ON COLUMN content.generated_assets.spec IS
    'Authored AssetSpec snapshot used to reproduce and audit generation.';

-- +goose StatementEnd

-- +goose Down
-- Additive migration: production rollback leaves generated asset metadata
-- intact. Removal requires a separate reviewed migration after observability.
SELECT 1;
