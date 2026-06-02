// Package sharing implements T-CORE-030: public, opaque, revocable
// share links pointing at a finished playthrough's Portrait page.
//
// Surface (HTTP):
//   - POST  /playthroughs/{id}/share  — owner creates a link  (auth required)
//   - DELETE /share/{token}           — owner revokes a link  (auth required)
//   - GET   /share/{token}            — public payload for share-web (no auth)
//
// Privacy invariants enforced here (docs/08_Data_Privacy_Compliance.md):
//   - Sharing is opt-in: the only way to create a link is the explicit
//     POST. We never auto-create links.
//   - Youth-safe accounts (age_band='youth') cannot create links. This
//     is gated by the application; the database does NOT store
//     youth-safe state on share_links.
//   - Only the playthrough's owner may share or revoke it.
//
// The token is generated once at create time, returned to the caller,
// and never reissued. Revocation flips revoked_at; the public GET
// returns 410 Gone forever after.
package sharing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/google/uuid"
)

// ErrYouthSafeDenied is returned by Create when the caller's age_band is
// 'youth'. The HTTP layer maps this to 403.
var ErrYouthSafeDenied = errors.New("sharing: youth-safe accounts cannot create public shares")

// ErrNotOwner is returned by Create / Revoke when the caller is not the
// playthrough's owner. The HTTP layer maps this to 404 (don't leak
// ownership; the URL was right-shaped, the caller just can't see it).
var ErrNotOwner = errors.New("sharing: caller does not own the playthrough")

// ErrPlaythroughNotComplete is returned by Create when the playthrough
// hasn't been finalized yet. There's nothing to share until a trait
// vector + Portrait exists.
var ErrPlaythroughNotComplete = errors.New("sharing: playthrough is not complete")

// ErrLinkNotFound is returned by GetByToken / Revoke when no live row
// matches the token. The public GET handler maps this to 404 to avoid
// confirming or denying that a token ever existed.
var ErrLinkNotFound = errors.New("sharing: link not found")

// ErrLinkRevoked is returned by GetByToken when the row exists but
// revoked_at is non-NULL. The public GET handler maps this to 410 Gone
// — a deliberately-different status from ErrLinkNotFound so a caller
// who has the link can tell it was explicitly killed.
var ErrLinkRevoked = errors.New("sharing: link has been revoked")

// Link is the in-memory projection of a sharing.share_links row.
type Link struct {
	Token         string
	PlaythroughID uuid.UUID
	UserID        uuid.UUID
	RevokedAt     *time.Time
	ViewCount     int64
	CreatedAt     time.Time
}

// IsRevoked is a small convenience for handlers.
func (l Link) IsRevoked() bool {
	return l.RevokedAt != nil
}

// Repository abstracts the persistence layer so service tests can run
// without Postgres. The shapes match the migration in
// services/core-go/db/migrations/20260521000005_create_share_links.sql.
type Repository interface {
	Insert(ctx context.Context, l Link) (Link, error)
	GetByToken(ctx context.Context, token string) (Link, error)
	Revoke(ctx context.Context, token string, userID uuid.UUID, now time.Time) error
	IncrementViewCount(ctx context.Context, token string) error
	ListByPlaythrough(ctx context.Context, playthroughID uuid.UUID) ([]Link, error)
}

// PlaythroughReader is the slice of playthrough.Service the sharing
// flow needs. Kept narrow so the dependency is explicit.
type PlaythroughReader interface {
	GetPlaythrough(ctx context.Context, id uuid.UUID) (playthrough.Playthrough, error)
}

// Service is the domain entry point for sharing.
type Service struct {
	repo         Repository
	playthroughs PlaythroughReader
	users        auth.UsersRepository
	tokens       TokenSource
	now          func() time.Time
}

// TokenSource produces opaque, URL-safe, ≥128-bit share tokens. The
// production implementation is NewTokenSource (crypto/rand). Tests pass
// a deterministic source.
type TokenSource interface {
	NewToken() (string, error)
}

// Config groups the constructor's dependencies.
type Config struct {
	Repository   Repository
	Playthroughs PlaythroughReader
	Users        auth.UsersRepository
	Tokens       TokenSource
	Now          func() time.Time
}

// New constructs a Service. Defaults Tokens to a crypto/rand source and
// Now to time.Now when omitted.
func New(cfg Config) *Service {
	if cfg.Repository == nil {
		panic("sharing: New requires Repository")
	}
	if cfg.Playthroughs == nil {
		panic("sharing: New requires PlaythroughReader")
	}
	if cfg.Users == nil {
		panic("sharing: New requires UsersRepository")
	}
	tokens := cfg.Tokens
	if tokens == nil {
		tokens = NewTokenSource()
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Service{
		repo:         cfg.Repository,
		playthroughs: cfg.Playthroughs,
		users:        cfg.Users,
		tokens:       tokens,
		now:          now,
	}
}

// CreateInput is what Create consumes.
type CreateInput struct {
	UserID        uuid.UUID
	PlaythroughID uuid.UUID
}

// Create issues a new public share link for the caller's playthrough.
// All gates run before token generation so a failed create produces no
// side effects.
//
// Gates (in order):
//  1. Caller's user row exists and age_band != 'youth' (youth-safe)
//  2. Playthrough exists and is owned by caller
//  3. Playthrough is completed (status='completed')
//
// On success returns the freshly-issued Link. The token in the Link is
// the only credential the caller will ever see for this row.
func (s *Service) Create(ctx context.Context, in CreateInput) (Link, error) {
	// 1. Youth-safe gate. We re-load the auth.users row rather than
	//    trusting a flag on the input because the gate should sit on
	//    the canonical row, not a stale client claim. Failing closed
	//    on lookup error is intentional — we'd rather error a share
	//    request than risk leaking a youth Portrait into the public
	//    web on a transient DB hiccup.
	if in.UserID == uuid.Nil {
		return Link{}, fmt.Errorf("sharing: create: empty user id")
	}
	band, err := s.lookupBand(ctx, in.UserID)
	if err != nil {
		return Link{}, err
	}
	if band == auth.AgeBandYouth {
		return Link{}, ErrYouthSafeDenied
	}

	// 2. Ownership gate. ErrNotFound from playthrough is mapped to
	//    ErrNotOwner — we don't want to confirm that a playthrough id
	//    exists if the caller isn't its owner.
	pt, err := s.playthroughs.GetPlaythrough(ctx, in.PlaythroughID)
	if err != nil {
		if errors.Is(err, playthrough.ErrNotFound) {
			return Link{}, ErrNotOwner
		}
		return Link{}, fmt.Errorf("sharing: create: load playthrough: %w", err)
	}
	if pt.UserID != in.UserID {
		return Link{}, ErrNotOwner
	}

	// 3. Completeness gate. The reflection + Portrait endpoints already
	//    return 404 on a missing trait vector; the share endpoint
	//    refuses up-front so the player doesn't get a broken-looking
	//    public page.
	if pt.Status != playthrough.StatusCompleted {
		return Link{}, ErrPlaythroughNotComplete
	}

	token, err := s.tokens.NewToken()
	if err != nil {
		return Link{}, fmt.Errorf("sharing: create: token: %w", err)
	}
	now := s.now().UTC()
	row := Link{
		Token:         token,
		PlaythroughID: in.PlaythroughID,
		UserID:        in.UserID,
		CreatedAt:     now,
	}
	row, err = s.repo.Insert(ctx, row)
	if err != nil {
		return Link{}, fmt.Errorf("sharing: create: insert: %w", err)
	}
	return row, nil
}

// Revoke marks the token's row as revoked. Only the owner may revoke.
// Idempotent: re-revoking a row is a no-op (returns nil).
func (s *Service) Revoke(ctx context.Context, token string, userID uuid.UUID) error {
	if token == "" {
		return ErrLinkNotFound
	}
	link, err := s.repo.GetByToken(ctx, token)
	if err != nil {
		return err
	}
	if link.UserID != userID {
		return ErrNotOwner
	}
	if link.IsRevoked() {
		return nil
	}
	return s.repo.Revoke(ctx, token, userID, s.now().UTC())
}

// GetByToken returns the link row for a public token. It enforces that
// the row is live (not revoked) — callers should treat ErrLinkRevoked
// distinctly from ErrLinkNotFound.
//
// Side effect on success: best-effort view counter increment. We swallow
// the increment error rather than failing the read; the share page must
// stay available even if the analytics write is unhealthy.
func (s *Service) GetByToken(ctx context.Context, token string) (Link, error) {
	if token == "" {
		return Link{}, ErrLinkNotFound
	}
	link, err := s.repo.GetByToken(ctx, token)
	if err != nil {
		return Link{}, err
	}
	if link.IsRevoked() {
		return Link{}, ErrLinkRevoked
	}
	// Best-effort. Logged at the HTTP layer if it ever fails so we can
	// see it but we never bubble the error.
	_ = s.repo.IncrementViewCount(ctx, token)
	return link, nil
}

// lookupBand finds the auth.users row by its internal id and returns
// its AgeBand. The youth-safe gate is the single most important check
// in this package — keep this helper small and audit-friendly.
func (s *Service) lookupBand(ctx context.Context, userID uuid.UUID) (auth.AgeBand, error) {
	u, err := s.users.GetByID(ctx, userID)
	if err != nil {
		return "", fmt.Errorf("sharing: create: lookup user: %w", err)
	}
	return u.AgeBand, nil
}
