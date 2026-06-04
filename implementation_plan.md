# Implementation Plan — Friend Comparison (`F-SOCIAL-001` / `T-SOCIAL-001`)

## Scope
Implement end-to-end Friend Comparison for Milestone M3, enabling two consenting users who completed the same season to compare portraits and one divergence moment.

Acceptance baseline is `docs/03_Product_Requirements.md` (`F-SOCIAL-001`) and privacy/youth-safe constraints in `docs/08_Data_Privacy_Compliance.md`.

## Locked Decisions

1. **Season compatibility:** comparisons are restricted to the same `season_id`.
2. **Revocation rights:** either participant may revoke at any time.
3. **Youth-safe rule:** users in youth-safe path (13-17) are blocked unless guardian consent is verified.
4. **Consent separation:** comparison acceptance and public sharing are separate consent actions.
5. **Divergence selection:** deterministic first differing vignette using canonical season order.

## Open Questions (Resolved)

### Q1: Compare different seasons?
**Decision:** No. Restrict to same season only.

### Q2: Can either side revoke?
**Decision:** Yes. Immediate invalidation of access.

## Non-Goals (M3)

- No cross-season semantic comparison.
- No multi-vignette comparison timeline.
- No trait-vector scoring model changes.
- No changes to billing flows.

## Architecture Overview

- **Core service (`services/core-go`)** owns invite lifecycle, acceptance rules, divergence selection, and revocation.
- **Client (`apps/client`)** handles invite acceptance UX and private compare view.
- **Share web (`apps/share-web`)** renders a public read-only artifact only when sharing consent is enabled.

## Data Model Plan

## 1) Comparisons
Table: `playthrough.comparisons`

- `id UUID PK`
- `inviter_playthrough_id UUID NOT NULL`
- `invitee_playthrough_id UUID NULL`
- `season_id TEXT NOT NULL`
- `status TEXT NOT NULL` (`pending`, `accepted`, `revoked`, `expired`)
- `created_at TIMESTAMPTZ NOT NULL`
- `accepted_at TIMESTAMPTZ NULL`
- `revoked_at TIMESTAMPTZ NULL`
- `expires_at TIMESTAMPTZ NOT NULL`
- `share_enabled BOOLEAN NOT NULL DEFAULT false`
- `share_enabled_by_inviter_at TIMESTAMPTZ NULL`
- `share_enabled_by_invitee_at TIMESTAMPTZ NULL`
- `divergence_vignette_id TEXT NULL`

Constraints:
- accepted state requires `invitee_playthrough_id` and `accepted_at`.
- revoked state requires `revoked_at`.
- `season_id` must match both linked playthroughs at write time.

## 2) Token Storage
Table: `playthrough.comparison_tokens`

- `id UUID PK`
- `comparison_id UUID NOT NULL REFERENCES playthrough.comparisons(id) ON DELETE CASCADE`
- `token_type TEXT NOT NULL` (`invite`, `share`)
- `token_hash TEXT NOT NULL`
- `created_by_user_id UUID NOT NULL`
- `created_at TIMESTAMPTZ NOT NULL`
- `expires_at TIMESTAMPTZ NOT NULL`
- `revoked_at TIMESTAMPTZ NULL`

Security:
- store token hash only (never plaintext token).
- unique active token hash per token type.

## Token and Security Rules

- Token entropy >= 128 bits, URL-safe encoding.
- Constant-time hash compare.
- Invite TTL default 7 days.
- Share TTL default 30 days (configurable).
- Rate limits on token resolution and acceptance endpoints.
- No token logging in structured logs.
- Audit events on resolve/accept/revoke/share-enable.

## Service Layer Plan (`services/core-go/playthrough`)

Add/extend operations:

- `CreateComparisonInvite(ctx, userID, playthroughID)`
- `AcceptComparisonInvite(ctx, userID, inviteToken, playthroughID)`
- `GetComparisonResult(ctx, token)`
- `EnableComparisonShare(ctx, userID, comparisonID)`
- `RevokeComparison(ctx, userID, comparisonID|token)`

Validation rules:

- inviter and invitee must own their respective playthroughs.
- both playthroughs must be completed.
- both playthroughs must reference same `season_id`.
- inviter and invitee cannot be the same user.
- youth-safe users blocked unless guardian consent verified.

Divergence selection algorithm:

1. Load canonical vignette order from season content.
2. Build lookup of both users' chosen `choice_id` by `vignette_id`.
3. Select first vignette in canonical order where both answered and choices differ.
4. If no divergence, return `ErrNoDivergence` and do not expose raw choices for non-selected vignettes.

## HTTP API Plan (`services/core-go/http`)

### Authenticated

- `POST /playthroughs/{id}/compare`
  - Creates invite token for inviter playthrough.

- `POST /compare/accept`
  - Body: `{ "token": "...", "playthrough_id": "..." }`

- `POST /compare/{id}/share-enable`
  - Participant consents to publish a public share artifact.

- `DELETE /compare/{id}` (and compatibility support for token-based delete if needed)
  - Either participant can revoke.

### Public

- `GET /compare/{token}`
  - Returns minimal compare artifact DTO:
    - inviter portrait summary
    - invitee portrait summary
    - single divergence moment
  - Must not include other vignette choices.

## API Response Contract Guards

- Never return full choice-event timelines.
- Never return unresolved or expired token internals.
- Return explicit states for `pending`, `accepted`, `revoked`, `expired`.

## Client Plan (`apps/client`)

- Add route: `/compare/accept/:token`
- Add route: `/compare/:token`
- Build compare screen with:
  - side-by-side portrait presentation
  - one divergence vignette display with both selected options
  - explicit share-enable consent action
- Add states for:
  - pending invite
  - accepted but not share-enabled
  - revoked/expired/invalid token

## Share Web Plan (`apps/share-web`)

- Add SSR page for comparison artifact.
- Read-only rendering of:
  - two portraits
  - one divergence moment
  - CTA to download Echo
- 404/410 handling for invalid/revoked/expired links.

## Privacy and Youth-Safe Enforcement

- Youth-safe participation blocked by default.
- Guardian consent flag required to unlock comparison participation.
- Public sharing requires explicit consent step (separate from accept).
- Revocation must immediately disable public access.

## Testing Plan

## Core-Go Unit Tests

- invite creation access control and owner checks
- accept flow season mismatch rejection
- deterministic divergence selection order
- no-divergence error path
- revoke by inviter and invitee
- youth-safe deny paths

## Core-Go Integration Tests

- invite -> accept -> get -> share-enable -> public-read
- revoke invalidates reads immediately
- expired token returns 410/404 per contract
- API payload shape does not leak non-selected choices

## Client Tests

- compare screen renders success/error states
- router deep-link acceptance flow
- share-enable consent state transitions

## Web Tests

- SSR compare page success
- revoked/expired states
- metadata and preview payload checks

## Rollout Plan

1. Ship backend support behind feature flag.
2. Enable internal testing with seeded users.
3. Enable client routes in beta cohort.
4. Enable public share-web compare pages.
5. Monitor metrics, logs, and revocation events.

## Observability

Metrics:
- invites created
- invites accepted
- share-enabled events
- revoked comparisons
- token resolution failures

Structured logs:
- comparison lifecycle events with redacted token info

## Execution Checklist

- [x] finalize migration spec and apply locally
- [x] implement repository updates
- [x] implement service rules and divergence selector
- [x] wire HTTP routes + handlers
- [x] implement client compare and accept routes
- [x] implement share-web compare page
- [x] add tests for all layers
- [x] run `make lint`
- [x] run `make test`
- [x] run `make build`
- [x] run `make validate-content`

## Human Review Required

This task touches youth-safe controls and public API contract behavior. Mark PR with `human-review-required` before merge.

