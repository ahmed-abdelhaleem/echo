package sharing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// pgUniqueViolation is the SQLSTATE for unique_violation. Repeated here
// rather than imported from playthrough to keep the packages decoupled.
const pgUniqueViolation = "23505"

// PgRepository is the pgxpool-backed Repository implementation.
type PgRepository struct {
	pool *pgxpool.Pool
}

// NewPgRepository constructs a PgRepository.
func NewPgRepository(pool *pgxpool.Pool) *PgRepository {
	return &PgRepository{pool: pool}
}

// Insert persists a fresh share link row. The (token, playthrough_id,
// user_id) triple is the input; created_at / view_count default in the
// migration.
//
// A unique-violation on `token` is exceedingly unlikely with 128 bits of
// entropy and should be treated as transient — the caller can retry.
func (r *PgRepository) Insert(ctx context.Context, l Link) (Link, error) {
	const q = `
		INSERT INTO sharing.share_links (token, playthrough_id, user_id)
		VALUES ($1, $2, $3)
		RETURNING token, playthrough_id, user_id, revoked_at, view_count, created_at
	`
	var out Link
	err := r.pool.QueryRow(ctx, q, l.Token, l.PlaythroughID, l.UserID).Scan(
		&out.Token, &out.PlaythroughID, &out.UserID,
		&out.RevokedAt, &out.ViewCount, &out.CreatedAt,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation {
			return Link{}, fmt.Errorf("sharing: insert: token collision (retryable): %w", err)
		}
		return Link{}, fmt.Errorf("sharing: insert: %w", err)
	}
	return out, nil
}

// GetByToken looks up a share link by its public token. Returns
// ErrLinkNotFound on no-row.
func (r *PgRepository) GetByToken(ctx context.Context, token string) (Link, error) {
	const q = `
		SELECT token, playthrough_id, user_id, revoked_at, view_count, created_at
		FROM sharing.share_links
		WHERE token = $1
	`
	var l Link
	err := r.pool.QueryRow(ctx, q, token).Scan(
		&l.Token, &l.PlaythroughID, &l.UserID,
		&l.RevokedAt, &l.ViewCount, &l.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Link{}, ErrLinkNotFound
	}
	if err != nil {
		return Link{}, fmt.Errorf("sharing: get by token: %w", err)
	}
	return l, nil
}

// Revoke flips revoked_at if the (token, user_id) pair matches and the
// row is not already revoked. Returns ErrLinkNotFound if the row does
// not exist (or is not owned by `userID`); returns nil on idempotent
// re-revoke (the WHERE clause filters it out and the UPDATE affects 0
// rows, which we treat as success).
func (r *PgRepository) Revoke(ctx context.Context, token string, userID uuid.UUID, now time.Time) error {
	const q = `
		UPDATE sharing.share_links
		SET revoked_at = $3
		WHERE token = $1 AND user_id = $2 AND revoked_at IS NULL
	`
	tag, err := r.pool.Exec(ctx, q, token, userID, now)
	if err != nil {
		return fmt.Errorf("sharing: revoke: %w", err)
	}
	if tag.RowsAffected() == 0 {
		// Could mean: token doesn't exist, isn't owned, or was already
		// revoked. The Service layer disambiguates by calling
		// GetByToken first. If we got here directly, treat it as
		// idempotent success.
		return nil
	}
	return nil
}

// IncrementViewCount bumps the view counter best-effort. Lost updates
// on contention are acceptable.
func (r *PgRepository) IncrementViewCount(ctx context.Context, token string) error {
	const q = `
		UPDATE sharing.share_links
		SET view_count = view_count + 1
		WHERE token = $1 AND revoked_at IS NULL
	`
	if _, err := r.pool.Exec(ctx, q, token); err != nil {
		return fmt.Errorf("sharing: increment view: %w", err)
	}
	return nil
}

// ListByPlaythrough returns all share links for a playthrough (revoked
// and live), most-recent first. Used by the per-playthrough "manage my
// shares" surface in client settings.
func (r *PgRepository) ListByPlaythrough(ctx context.Context, playthroughID uuid.UUID) ([]Link, error) {
	const q = `
		SELECT token, playthrough_id, user_id, revoked_at, view_count, created_at
		FROM sharing.share_links
		WHERE playthrough_id = $1
		ORDER BY created_at DESC
	`
	rows, err := r.pool.Query(ctx, q, playthroughID)
	if err != nil {
		return nil, fmt.Errorf("sharing: list by playthrough: %w", err)
	}
	defer rows.Close()
	out := make([]Link, 0)
	for rows.Next() {
		var l Link
		if err := rows.Scan(&l.Token, &l.PlaythroughID, &l.UserID, &l.RevokedAt, &l.ViewCount, &l.CreatedAt); err != nil {
			return nil, fmt.Errorf("sharing: list by playthrough: scan: %w", err)
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("sharing: list by playthrough: rows: %w", err)
	}
	return out, nil
}
