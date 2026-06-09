-- 20260521000003_create_playthroughs.sql
--
-- The two tables Echo's vertical slice (T-CORE-010 + T-CLIENT-010..012) writes
-- to: a playthrough header and one row per recorded choice. Trait scoring
-- (T-ML-010) consumes choice_events; the result Vector lives in a separate
-- table added with that PR.
--
-- Migration policy: additive only (AGENTS.md §"Safety rails"). Drops/renames
-- are human-review-required and ship in a separate migration after
-- observability confirms no traffic.

-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS playthrough.playthroughs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- The Echo-side user. Kratos identity is one hop away via auth.users.
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Season identifier from /content/seasons/<id>/season.json. NOT a foreign
    -- key — content is filesystem-authored, not row-modeled. The application
    -- validates that this id exists before inserting (content.Service.GetSeason).
    season_id TEXT NOT NULL,

    -- Snapshot of Season.Version at the moment the playthrough started. Locks
    -- the player's experience to that version of the content so re-publishes
    -- don't retroactively change a finished playthrough's trait vector.
    season_version INTEGER NOT NULL,

    -- Lifecycle. 'in_progress' on creation; flips to 'completed' when the
    -- player reaches the end vignette and the trait vector is computed;
    -- 'abandoned' is set by a server-side timeout sweeper in M2.
    status TEXT NOT NULL DEFAULT 'in_progress',

    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT playthroughs_status_chk CHECK (status IN ('in_progress', 'completed', 'abandoned')),
    CONSTRAINT playthroughs_completed_at_chk CHECK (
        (status = 'completed' AND completed_at IS NOT NULL)
        OR (status <> 'completed' AND completed_at IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS playthroughs_user_id_idx
    ON playthrough.playthroughs (user_id, started_at DESC);

CREATE INDEX IF NOT EXISTS playthroughs_status_idx
    ON playthrough.playthroughs (status)
    WHERE status = 'in_progress';

COMMENT ON TABLE playthrough.playthroughs IS
    'Header row for a single attempt at a Season. Choice events live in playthrough.choice_events.';
COMMENT ON COLUMN playthrough.playthroughs.season_version IS
    'Locked-in Season.Version at start. A re-publish that bumps Season.Version does NOT retroactively affect an in-progress or completed row.';

CREATE TABLE IF NOT EXISTS playthrough.choice_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    playthrough_id UUID NOT NULL REFERENCES playthrough.playthroughs(id) ON DELETE CASCADE,

    -- Content identifiers. Validated against the content.Service at the
    -- application layer before insert; not foreign-keyed for the same reason
    -- season_id isn't (content is filesystem-authored).
    vignette_id TEXT NOT NULL,
    choice_id TEXT NOT NULL,

    -- Timing facts for the analytics pipeline. client_timestamp is the
    -- player-local moment of choice (used for offline-then-sync ordering);
    -- server_received_at is when we wrote the row.
    client_timestamp TIMESTAMPTZ,
    server_received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- deliberation_ms is the time between vignette presentation and choice
    -- tap, measured client-side. Used as a feature by the scoring engine in
    -- M2; null is acceptable in M1.
    deliberation_ms INTEGER,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- A vignette is a one-shot decision: the same (playthrough, vignette)
    -- pair must resolve to exactly one row. This is what makes RecordChoice
    -- idempotent on retry — a second insert with the same vignette_id and
    -- the same choice_id is a no-op; a second insert with a *different*
    -- choice_id is a 409 at the application layer (client must not change
    -- its mind once committed).
    CONSTRAINT choice_events_playthrough_vignette_uniq UNIQUE (playthrough_id, vignette_id),

    -- deliberation_ms must be non-negative when present.
    CONSTRAINT choice_events_deliberation_ms_chk CHECK (deliberation_ms IS NULL OR deliberation_ms >= 0)
);

CREATE INDEX IF NOT EXISTS choice_events_playthrough_id_idx
    ON playthrough.choice_events (playthrough_id, server_received_at);

COMMENT ON TABLE playthrough.choice_events IS
    'One row per choice the player commits during a playthrough. The UNIQUE constraint on (playthrough_id, vignette_id) is what enables RecordChoice idempotency: see services/core-go/playthrough/service.go.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Per AGENTS.md, destructive migrations are human-review-required in
-- production. This Down is provided for local dev / CI rollback only;
-- production rollbacks go through the documented runbook in docs/07.
DROP INDEX IF EXISTS playthrough.choice_events_playthrough_id_idx;
DROP TABLE IF EXISTS playthrough.choice_events;
DROP INDEX IF EXISTS playthrough.playthroughs_status_idx;
DROP INDEX IF EXISTS playthrough.playthroughs_user_id_idx;
DROP TABLE IF EXISTS playthrough.playthroughs;

-- +goose StatementEnd
