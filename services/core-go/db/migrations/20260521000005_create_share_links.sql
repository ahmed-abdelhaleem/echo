-- 20260521000005_create_share_links.sql
--
-- Public-Portrait share links (T-CORE-030).
--
-- A share_link is a public, opaque, revocable pointer to a finished
-- playthrough's Portrait + reflection. The token in the URL is the
-- only credential — there is no second factor — so the entropy of
-- `token` is what protects against enumeration. Per
-- services/core-go/sharing/token.go we generate 22-char base64-urlsafe
-- (≈128 bits), which is enough.
--
-- Privacy invariants (docs/08_Data_Privacy_Compliance.md §F-SHARE-001):
--   - Sharing is opt-in, every time. The CREATE happens because the
--     player tapped a share button; nothing is auto-shared.
--   - Public sharing is disabled for accounts with age_band='youth'.
--     The application enforces this; this table does not store
--     youth-safe state.
--   - Revocation is fast and final: revoked_at flips and GET /share/{token}
--     returns 410 Gone forever after.
--
-- Migration policy: additive only (AGENTS.md §"Safety rails").

-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS sharing.share_links (
    -- The opaque token in the public URL. We store the token directly
    -- rather than a hash because revocation lookups must be fast and the
    -- token alone is the credential (cf. an unsalted password — this is
    -- closer to an API key). 22-char base64url ≈ 128 bits of entropy.
    token TEXT PRIMARY KEY,

    -- The finished playthrough this link reveals. Cascade delete: if the
    -- player deletes the playthrough, all share links to it die with it.
    playthrough_id UUID NOT NULL REFERENCES playthrough.playthroughs(id) ON DELETE CASCADE,

    -- The owning user (denormalised for fast lookup-by-owner). Cascade
    -- delete: deleting the user nukes their share links (DSAR right-to-
    -- erasure compliance, docs/08 §"Erasure").
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- NULL means the link is live. A non-NULL revoked_at means the link
    -- is dead; the GET handler returns 410 Gone. We never delete rows on
    -- revoke so a revoked link cannot be re-created with the same token
    -- (defense against the case where the token has leaked).
    revoked_at TIMESTAMPTZ,

    -- View counter for product metrics ("did anyone actually click my
    -- link?"). Best-effort: updated by the public GET handler with a
    -- simple UPDATE; we accept lost updates on contention.
    view_count BIGINT NOT NULL DEFAULT 0,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Lookup a user's own share links (for the "manage my links" surface
-- in settings, which lands as a follow-up).
CREATE INDEX IF NOT EXISTS share_links_user_id_idx
    ON sharing.share_links (user_id, created_at DESC);

-- Lookup a playthrough's share links (a player may revoke + re-share).
CREATE INDEX IF NOT EXISTS share_links_playthrough_id_idx
    ON sharing.share_links (playthrough_id, created_at DESC);

COMMENT ON TABLE sharing.share_links IS
    'Public, opaque, revocable pointers to finished playthroughs. The token IS the credential — protect entropy.';
COMMENT ON COLUMN sharing.share_links.token IS
    'Opaque base64-urlsafe identifier in the public URL. Treat as a secret-shaped value.';
COMMENT ON COLUMN sharing.share_links.revoked_at IS
    'NULL=live, non-NULL=permanently dead. Once revoked, the row stays so the token cannot be re-issued.';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Per AGENTS.md, destructive migrations are human-review-required in
-- production. Provided for local dev / CI rollback only.
DROP TABLE IF EXISTS sharing.share_links;

-- +goose StatementEnd
