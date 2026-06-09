-- 20260604000001_create_comparisons.sql
--
-- Friend comparisons table (T-SOCIAL-001).
--
-- Maps two completed playthroughs of the same season together.

-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS playthrough.comparisons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token TEXT NOT NULL UNIQUE,
    inviter_playthrough_id UUID NOT NULL REFERENCES playthrough.playthroughs(id) ON DELETE CASCADE,
    invitee_playthrough_id UUID REFERENCES playthrough.playthroughs(id) ON DELETE CASCADE,
    season_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    accepted_at TIMESTAMPTZ,

    CONSTRAINT comparisons_status_chk CHECK (status IN ('pending', 'accepted', 'revoked')),
    CONSTRAINT comparisons_accepted_at_chk CHECK (
        (status = 'accepted' AND accepted_at IS NOT NULL AND invitee_playthrough_id IS NOT NULL)
        OR (status <> 'accepted' AND accepted_at IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS comparisons_token_idx ON playthrough.comparisons(token);
CREATE INDEX IF NOT EXISTS comparisons_inviter_idx ON playthrough.comparisons(inviter_playthrough_id);
CREATE INDEX IF NOT EXISTS comparisons_invitee_idx ON playthrough.comparisons(invitee_playthrough_id) WHERE invitee_playthrough_id IS NOT NULL;

COMMENT ON TABLE playthrough.comparisons IS 'Stores comparison invitations and completions between friends.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

DROP TABLE IF EXISTS playthrough.comparisons;

-- +goose StatementEnd
