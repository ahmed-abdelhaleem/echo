package playthrough

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrNotFound is returned when a Playthrough id has no matching row.
var ErrNotFound = errors.New("playthrough: not found")

// ErrTraitVectorNotFound is returned when GetTraitVector has no row for
// the playthrough — usually because scoring hasn't finished yet.
var ErrTraitVectorNotFound = errors.New("playthrough: trait vector not found")

// ErrChoiceConflict is returned when RecordChoice is called twice on the
// same (playthrough, vignette) with *different* choice ids. Clients must
// treat this as a hard failure — the player cannot change their mind once
// a choice is committed.
var ErrChoiceConflict = errors.New("playthrough: choice already recorded with a different value")

// pgUniqueViolation is the SQLSTATE for "unique_violation". Kept as a
// package constant so the magic string doesn't sprawl.
const pgUniqueViolation = "23505"

// Repository abstracts the persistence layer. Defined as an interface so
// tests can fake out the pool without spinning Postgres.
type Repository interface {
	CreatePlaythrough(ctx context.Context, userID uuid.UUID, seasonID string, seasonVersion int) (Playthrough, error)
	GetPlaythrough(ctx context.Context, id uuid.UUID) (Playthrough, error)
	InsertChoice(ctx context.Context, in RecordChoiceInput) (ChoiceEvent, error)
	GetChoice(ctx context.Context, playthroughID uuid.UUID, vignetteID string) (ChoiceEvent, error)
	ListChoices(ctx context.Context, playthroughID uuid.UUID) ([]ChoiceEvent, error)
	MarkCompleted(ctx context.Context, playthroughID uuid.UUID) (Playthrough, error)
	UpsertTraitVector(ctx context.Context, playthroughID uuid.UUID, vec TraitVector, scoringVersion, seasonVersion int) (StoredTraitVector, error)
	GetTraitVector(ctx context.Context, playthroughID uuid.UUID) (StoredTraitVector, error)
}

// PgRepository is the pgxpool-backed Repository implementation.
type PgRepository struct {
	pool *pgxpool.Pool
}

// NewPgRepository constructs a PgRepository.
func NewPgRepository(pool *pgxpool.Pool) *PgRepository {
	return &PgRepository{pool: pool}
}

// CreatePlaythrough inserts a fresh playthrough row. The (season_id,
// season_version) pair is taken on trust here — validation happens in the
// Service layer where the content.Service is available.
func (r *PgRepository) CreatePlaythrough(ctx context.Context, userID uuid.UUID, seasonID string, seasonVersion int) (Playthrough, error) {
	const q = `
		INSERT INTO playthrough.playthroughs (user_id, season_id, season_version)
		VALUES ($1, $2, $3)
		RETURNING id, user_id, season_id, season_version, status, started_at, completed_at, created_at, updated_at
	`
	var p Playthrough
	err := r.pool.QueryRow(ctx, q, userID, seasonID, seasonVersion).Scan(
		&p.ID, &p.UserID, &p.SeasonID, &p.SeasonVersion, &p.Status,
		&p.StartedAt, &p.CompletedAt, &p.CreatedAt, &p.UpdatedAt,
	)
	if err != nil {
		return Playthrough{}, fmt.Errorf("playthrough: create: %w", err)
	}
	return p, nil
}

// GetPlaythrough fetches a single playthrough by id.
func (r *PgRepository) GetPlaythrough(ctx context.Context, id uuid.UUID) (Playthrough, error) {
	const q = `
		SELECT id, user_id, season_id, season_version, status, started_at, completed_at, created_at, updated_at
		FROM playthrough.playthroughs
		WHERE id = $1
	`
	var p Playthrough
	err := r.pool.QueryRow(ctx, q, id).Scan(
		&p.ID, &p.UserID, &p.SeasonID, &p.SeasonVersion, &p.Status,
		&p.StartedAt, &p.CompletedAt, &p.CreatedAt, &p.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Playthrough{}, ErrNotFound
	}
	if err != nil {
		return Playthrough{}, fmt.Errorf("playthrough: get: %w", err)
	}
	return p, nil
}

// InsertChoice writes a choice_event row. If the (playthrough, vignette)
// pair is already present the unique violation surfaces as a typed error
// the Service layer can interpret — same choice → idempotent success,
// different choice → ErrChoiceConflict.
func (r *PgRepository) InsertChoice(ctx context.Context, in RecordChoiceInput) (ChoiceEvent, error) {
	const q = `
		INSERT INTO playthrough.choice_events
			(playthrough_id, vignette_id, choice_id, client_timestamp, deliberation_ms)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, playthrough_id, vignette_id, choice_id, client_timestamp, server_received_at, deliberation_ms, created_at
	`
	var ev ChoiceEvent
	err := r.pool.QueryRow(ctx, q,
		in.PlaythroughID, in.VignetteID, in.ChoiceID, in.ClientTimestamp, in.DeliberationMS,
	).Scan(
		&ev.ID, &ev.PlaythroughID, &ev.VignetteID, &ev.ChoiceID,
		&ev.ClientTimestamp, &ev.ServerReceivedAt, &ev.DeliberationMS, &ev.CreatedAt,
	)
	if err == nil {
		return ev, nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation {
		// The Service layer decides whether the existing row is the same
		// choice (idempotent) or a different one (conflict). Return a
		// sentinel to keep this layer dumb about that policy.
		return ChoiceEvent{}, ErrChoiceConflict
	}
	return ChoiceEvent{}, fmt.Errorf("playthrough: insert choice: %w", err)
}

// GetChoice fetches the recorded choice for a (playthrough, vignette) pair,
// if any. Returns ErrNotFound when none exists.
func (r *PgRepository) GetChoice(ctx context.Context, playthroughID uuid.UUID, vignetteID string) (ChoiceEvent, error) {
	const q = `
		SELECT id, playthrough_id, vignette_id, choice_id, client_timestamp, server_received_at, deliberation_ms, created_at
		FROM playthrough.choice_events
		WHERE playthrough_id = $1 AND vignette_id = $2
	`
	var ev ChoiceEvent
	err := r.pool.QueryRow(ctx, q, playthroughID, vignetteID).Scan(
		&ev.ID, &ev.PlaythroughID, &ev.VignetteID, &ev.ChoiceID,
		&ev.ClientTimestamp, &ev.ServerReceivedAt, &ev.DeliberationMS, &ev.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return ChoiceEvent{}, ErrNotFound
	}
	if err != nil {
		return ChoiceEvent{}, fmt.Errorf("playthrough: get choice: %w", err)
	}
	return ev, nil
}

// ListChoices returns every choice event for the playthrough in commit
// order. Used by FinalizeIfComplete to assemble the trait scoring payload.
func (r *PgRepository) ListChoices(ctx context.Context, playthroughID uuid.UUID) ([]ChoiceEvent, error) {
	const q = `
		SELECT id, playthrough_id, vignette_id, choice_id, client_timestamp, server_received_at, deliberation_ms, created_at
		FROM playthrough.choice_events
		WHERE playthrough_id = $1
		ORDER BY server_received_at, id
	`
	rows, err := r.pool.Query(ctx, q, playthroughID)
	if err != nil {
		return nil, fmt.Errorf("playthrough: list choices: %w", err)
	}
	defer rows.Close()

	var out []ChoiceEvent
	for rows.Next() {
		var ev ChoiceEvent
		if err := rows.Scan(
			&ev.ID, &ev.PlaythroughID, &ev.VignetteID, &ev.ChoiceID,
			&ev.ClientTimestamp, &ev.ServerReceivedAt, &ev.DeliberationMS, &ev.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("playthrough: scan choice: %w", err)
		}
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("playthrough: iterate choices: %w", err)
	}
	return out, nil
}

// MarkCompleted flips a playthrough's status to 'completed' and stamps
// completed_at to NOW(). Idempotent: a second call on an already-completed
// row is a no-op and returns the existing values.
func (r *PgRepository) MarkCompleted(ctx context.Context, playthroughID uuid.UUID) (Playthrough, error) {
	const q = `
		UPDATE playthrough.playthroughs
		SET status = 'completed',
		    completed_at = COALESCE(completed_at, NOW()),
		    updated_at = NOW()
		WHERE id = $1
		RETURNING id, user_id, season_id, season_version, status, started_at, completed_at, created_at, updated_at
	`
	var p Playthrough
	err := r.pool.QueryRow(ctx, q, playthroughID).Scan(
		&p.ID, &p.UserID, &p.SeasonID, &p.SeasonVersion, &p.Status,
		&p.StartedAt, &p.CompletedAt, &p.CreatedAt, &p.UpdatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return Playthrough{}, ErrNotFound
	}
	if err != nil {
		return Playthrough{}, fmt.Errorf("playthrough: mark completed: %w", err)
	}
	return p, nil
}

// UpsertTraitVector writes the scoring result for a playthrough. The
// (playthrough_id) primary key gives us natural idempotency on retry.
func (r *PgRepository) UpsertTraitVector(
	ctx context.Context,
	playthroughID uuid.UUID,
	vec TraitVector,
	scoringVersion, seasonVersion int,
) (StoredTraitVector, error) {
	const q = `
		INSERT INTO playthrough.trait_vectors
			(playthrough_id, big_five, schwartz, attachment, scoring_version, season_version)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (playthrough_id) DO UPDATE
		SET big_five = EXCLUDED.big_five,
		    schwartz = EXCLUDED.schwartz,
		    attachment = EXCLUDED.attachment,
		    scoring_version = EXCLUDED.scoring_version,
		    season_version = EXCLUDED.season_version
		RETURNING playthrough_id, big_five, schwartz, attachment, scoring_version, season_version, created_at
	`
	var out StoredTraitVector
	err := r.pool.QueryRow(ctx, q,
		playthroughID, vec.BigFive, vec.Schwartz, vec.Attachment, scoringVersion, seasonVersion,
	).Scan(
		&out.PlaythroughID, &out.BigFive, &out.Schwartz, &out.Attachment,
		&out.ScoringVersion, &out.SeasonVersion, &out.CreatedAt,
	)
	if err != nil {
		return StoredTraitVector{}, fmt.Errorf("playthrough: upsert trait vector: %w", err)
	}
	return out, nil
}

// GetTraitVector fetches the stored trait vector for a playthrough.
// Returns ErrTraitVectorNotFound when the row is absent (typically
// because scoring hasn't completed yet).
func (r *PgRepository) GetTraitVector(ctx context.Context, playthroughID uuid.UUID) (StoredTraitVector, error) {
	const q = `
		SELECT playthrough_id, big_five, schwartz, attachment, scoring_version, season_version, created_at
		FROM playthrough.trait_vectors
		WHERE playthrough_id = $1
	`
	var out StoredTraitVector
	err := r.pool.QueryRow(ctx, q, playthroughID).Scan(
		&out.PlaythroughID, &out.BigFive, &out.Schwartz, &out.Attachment,
		&out.ScoringVersion, &out.SeasonVersion, &out.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return StoredTraitVector{}, ErrTraitVectorNotFound
	}
	if err != nil {
		return StoredTraitVector{}, fmt.Errorf("playthrough: get trait vector: %w", err)
	}
	return out, nil
}
