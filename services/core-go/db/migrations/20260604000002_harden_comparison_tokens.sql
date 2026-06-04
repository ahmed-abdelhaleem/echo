-- 20260604000002_harden_comparison_tokens.sql
--
-- Hardens friend-comparison token handling by introducing token hashes,
-- token lifetimes, and explicit share-enable state.

-- +goose Up
-- +goose StatementBegin

ALTER TABLE playthrough.comparisons
    ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS share_enabled BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS share_enabled_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS divergence_vignette_id TEXT;

UPDATE playthrough.comparisons
SET expires_at = COALESCE(expires_at, created_at + INTERVAL '7 days')
WHERE expires_at IS NULL;

ALTER TABLE playthrough.comparisons
    DROP CONSTRAINT IF EXISTS comparisons_status_chk;

ALTER TABLE playthrough.comparisons
    ADD CONSTRAINT comparisons_status_chk
    CHECK (status IN ('pending', 'accepted', 'revoked', 'expired'));

CREATE TABLE IF NOT EXISTS playthrough.comparison_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    comparison_id UUID NOT NULL REFERENCES playthrough.comparisons(id) ON DELETE CASCADE,
    token_type TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    created_by_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT comparison_tokens_type_chk CHECK (token_type IN ('invite', 'share'))
);

CREATE UNIQUE INDEX IF NOT EXISTS comparison_tokens_hash_type_uniq
    ON playthrough.comparison_tokens(token_hash, token_type)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS comparison_tokens_comparison_idx
    ON playthrough.comparison_tokens(comparison_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Down intentionally keeps additive columns/tables in place.
SELECT 1;

-- +goose StatementEnd

