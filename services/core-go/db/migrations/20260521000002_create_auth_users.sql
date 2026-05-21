-- 20260521000002_create_auth_users.sql
--
-- The slim users table that joins Echo's domain rows to a Kratos identity.
-- Kratos owns identity and credentials in its own schema (created by Kratos
-- migrations against the `kratos` database). This table owns the few
-- Echo-specific facts about a player: which Kratos identity they are, the
-- age band that decides their privacy posture, and the consent-version
-- timestamps that decide whether re-consent is required.
--
-- Migration policy: additive only (AGENTS.md §"Safety rails"). Drops/renames
-- are human-review-required and ship in a separate migration after
-- observability confirms no traffic.
-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS auth.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The Kratos identity UUID. NOT a foreign key — Kratos lives in its own
    -- database; integrity is enforced by the application via a unique
    -- constraint here.
    kratos_identity_id UUID NOT NULL UNIQUE,

    -- 'youth' (13–17) or 'adult' (18+). Under-13 is rejected at sign-up
    -- by services/core-go/auth.EvaluateAgeGate and never reaches this table.
    age_band TEXT NOT NULL,

    -- Consent record. Versions are docs (TOS v1.0, privacy policy v1.0, etc.);
    -- when either version changes the application surfaces a re-consent flow
    -- and updates these columns.
    tos_version TEXT NOT NULL,
    tos_accepted_at TIMESTAMPTZ NOT NULL,
    privacy_version TEXT NOT NULL,
    privacy_accepted_at TIMESTAMPTZ NOT NULL,

    -- Lifecycle timestamps.
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ,

    -- Hard rule from docs/08_Data_Privacy_Compliance.md §"Age gating".
    CONSTRAINT auth_users_age_band_chk CHECK (age_band IN ('youth', 'adult'))
);

-- The UNIQUE constraint on kratos_identity_id above already creates a
-- B-tree index that covers the lookup path (`SELECT ... WHERE
-- kratos_identity_id = $1`). No additional index needed.

CREATE INDEX IF NOT EXISTS auth_users_age_band_idx
    ON auth.users (age_band)
    WHERE deleted_at IS NULL;

COMMENT ON TABLE auth.users IS
    'Echo''s slim user record. The identity / credentials live in Kratos; this table holds the Echo-side facts (age band, consent state). See services/core-go/auth/.';

COMMENT ON COLUMN auth.users.age_band IS
    'Privacy posture per docs/08. Under-13 are rejected at sign-up and never inserted here.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Per AGENTS.md, destructive migrations are human-review-required. This
-- Down is provided for local dev / CI rollback only; production rollbacks
-- go through the documented runbook in docs/07.
DROP INDEX IF EXISTS auth.auth_users_age_band_idx;
DROP TABLE IF EXISTS auth.users;

-- +goose StatementEnd
