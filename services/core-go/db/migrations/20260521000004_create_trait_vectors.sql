-- 20260521000004_create_trait_vectors.sql
--
-- One row per playthrough, populated when scoring finishes (T-ML-010 +
-- T-CORE-011). The vector is stored as three native double-precision
-- arrays so SQL can be used to filter / compare without round-tripping
-- through JSON.
--
-- Migration policy: additive only (AGENTS.md §"Safety rails"). The
-- shape of the vector (5 / 10 / 3) is locked to the trait dimension
-- enum in services/core-go/content/types.go; growing it later requires
-- a NEW migration with backfill semantics, NOT an ALTER on this one.

-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS playthrough.trait_vectors (
    -- Sharing the primary key with the playthrough makes the 1:1
    -- relationship explicit and gives us cheap idempotency: a re-score
    -- call after a transient failure UPSERTs into the same row.
    playthrough_id UUID PRIMARY KEY REFERENCES playthrough.playthroughs(id) ON DELETE CASCADE,

    -- 5-vector: OCEAN-{O, C, E, A, N}. Each entry in [-1.0, 1.0].
    big_five    DOUBLE PRECISION[] NOT NULL,
    -- 10-vector: Schwartz basic human values, ordered as in
    -- services/core-go/content/types.go (AllDimensions). [-1.0, 1.0].
    schwartz    DOUBLE PRECISION[] NOT NULL,
    -- 3-vector: ATT-{SECURE, ANXIOUS, AVOIDANT}. Each entry in [0.0, 1.0].
    attachment  DOUBLE PRECISION[] NOT NULL,

    -- The version of the scoring engine that produced this vector. M1
    -- ships v1; bumping this is part of any "trait engine change"
    -- (AGENTS.md §10) and gates re-scoring of historical playthroughs.
    scoring_version INTEGER NOT NULL DEFAULT 1,

    -- Snapshot of the Season.Version under which the playthrough was
    -- scored. Should match playthroughs.season_version at insert time;
    -- carried separately so a future re-score against a newer Season
    -- can be tracked without losing the original.
    season_version  INTEGER NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- The shape is locked to the M1 trait vector definition. If the
    -- scoring engine ever changes shape, that lands in a new migration
    -- with a new column, not by relaxing these CHECKs.
    CONSTRAINT trait_vectors_big_five_dim_chk    CHECK (array_length(big_five, 1)   = 5),
    CONSTRAINT trait_vectors_schwartz_dim_chk    CHECK (array_length(schwartz, 1)   = 10),
    CONSTRAINT trait_vectors_attachment_dim_chk  CHECK (array_length(attachment, 1) = 3)
);

COMMENT ON TABLE playthrough.trait_vectors IS
    'Per-playthrough Trait Vector produced by ml-py.TraitScoringService (T-ML-010). One row per completed playthrough; row appears at the moment scoring succeeds.';
COMMENT ON COLUMN playthrough.trait_vectors.scoring_version IS
    'Version of the trait scoring engine. Bumping this is gated on AGENTS.md §10 (trait scoring engine change).';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Per AGENTS.md, destructive migrations are human-review-required in
-- production. This Down is provided for local dev / CI rollback only;
-- production rollback requires a separate, reviewed migration.
DROP TABLE IF EXISTS playthrough.trait_vectors;

-- +goose StatementEnd
