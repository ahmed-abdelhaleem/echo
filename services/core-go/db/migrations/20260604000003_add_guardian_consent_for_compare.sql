-- 20260604000003_add_guardian_consent_for_compare.sql
--
-- Adds optional guardian-verification timestamp used to gate youth access
-- to friend comparison features.

-- +goose Up
-- +goose StatementBegin

ALTER TABLE auth.users
    ADD COLUMN IF NOT EXISTS guardian_comparison_consent_verified_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS auth_users_guardian_compare_consent_idx
    ON auth.users (guardian_comparison_consent_verified_at)
    WHERE deleted_at IS NULL AND guardian_comparison_consent_verified_at IS NOT NULL;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Additive migration; no destructive rollback.
SELECT 1;

-- +goose StatementEnd

