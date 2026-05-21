-- 20260521000004_create_trait_vectors.sql
--
-- Stores the computed trait vector for a completed playthrough. One row per
-- playthrough (FK enforced), produced by the scoring engine in ml-py
-- (T-ML-010) and written back by core-go (T-CORE-011).
--
-- Migration policy: additive only. No existing columns/tables dropped.

-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS playthrough.trait_vectors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    playthrough_id UUID NOT NULL
        REFERENCES playthrough.playthroughs(id) ON DELETE CASCADE,

    -- The full vector as a JSONB object mapping dimension -> float value.
    -- Example: {"OCEAN-O": 0.35, "OCEAN-C": -0.1, ...}
    -- Using JSONB rather than 18 float columns so new dimensions can be
    -- added without a migration. The application-layer types enforce the
    -- schema; Postgres just stores the blob.
    vector JSONB NOT NULL DEFAULT '{}',

    -- Metadata for reproducibility and debugging.
    scoring_version TEXT NOT NULL DEFAULT 'rule-v1',
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- One vector per playthrough.
    CONSTRAINT trait_vectors_playthrough_uniq UNIQUE (playthrough_id)
);

COMMENT ON TABLE playthrough.trait_vectors IS
    'Computed trait vector for a completed playthrough. One row per playthrough, produced by ml-py rule engine.';
COMMENT ON COLUMN playthrough.trait_vectors.scoring_version IS
    'Tag identifying the scoring algorithm variant (rule-v1, ml-v1, etc.) for reproducibility.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TABLE IF EXISTS playthrough.trait_vectors;

-- +goose StatementEnd
