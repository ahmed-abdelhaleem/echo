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
