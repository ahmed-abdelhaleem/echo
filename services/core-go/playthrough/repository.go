package playthrough

import (
	"context"
	"encoding/json"
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

	// ListChoices returns every recorded choice for a playthrough in
	// insertion order. The scoring engine consumes this set unordered
	// (the sum is commutative), but the deterministic ordering helps
	// debugging and trait-replay diffing.
	ListChoices(ctx context.Context, playthroughID uuid.UUID) ([]ChoiceEvent, error)

	// MarkCompleted flips a playthrough's status to "completed" and
	// stamps completed_at. Returns ErrNotFound if the row is gone.
	// Idempotent: a second call on an already-completed row is a no-op
	// and returns nil.
	MarkCompleted(ctx context.Context, playthroughID uuid.UUID) error

	// UpsertTraitVector writes (or overwrites) the trait vector row for
	// a playthrough. We never expose "regenerate" as a public API in
	// M1, but trait-replay re-runs need to overwrite cleanly — hence
	// upsert rather than insert.
	UpsertTraitVector(ctx context.Context, v TraitVector) error

	// GetTraitVector fetches the stored trait vector for a playthrough.
	// Returns ErrNotFound if the playthrough has not been scored.
	GetTraitVector(ctx context.Context, playthroughID uuid.UUID) (TraitVector, error)
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

// ListChoices returns every choice_event for the given playthrough in
// (server_received_at, id) order. Deterministic ordering matters for
// trait-replay diffs against pinned playthroughs.
func (r *PgRepository) ListChoices(ctx context.Context, playthroughID uuid.UUID) ([]ChoiceEvent, error) {
	const q = `
		SELECT id, playthrough_id, vignette_id, choice_id, client_timestamp, server_received_at, deliberation_ms, created_at
		FROM playthrough.choice_events
		WHERE playthrough_id = $1
		ORDER BY server_received_at ASC, id ASC
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
			return nil, fmt.Errorf("playthrough: list choices scan: %w", err)
		}
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("playthrough: list choices rows: %w", err)
	}
	return out, nil
}

// MarkCompleted flips a playthrough's status to 'completed' and stamps
// completed_at = NOW(). The CHECK constraint on the table (see
// 20260521000003_create_playthroughs.sql) requires completed_at IS NOT NULL
// when status = 'completed', so we set both in one UPDATE.
//
// Idempotent: re-running on an already-completed row leaves status,
// completed_at and updated_at unchanged.
func (r *PgRepository) MarkCompleted(ctx context.Context, playthroughID uuid.UUID) error {
	const q = `
		UPDATE playthrough.playthroughs
		SET status = 'completed',
		    completed_at = COALESCE(completed_at, NOW()),
		    updated_at = NOW()
		WHERE id = $1
		  AND status <> 'completed'
	`
	tag, err := r.pool.Exec(ctx, q, playthroughID)
	if err != nil {
		return fmt.Errorf("playthrough: mark completed: %w", err)
	}
	if tag.RowsAffected() == 0 {
		// Either already-completed (idempotent ok) or genuinely missing.
		// Disambiguate with a follow-up SELECT.
		const probe = `SELECT 1 FROM playthrough.playthroughs WHERE id = $1`
		var dummy int
		if err := r.pool.QueryRow(ctx, probe, playthroughID).Scan(&dummy); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotFound
			}
			return fmt.Errorf("playthrough: mark completed probe: %w", err)
		}
	}
	return nil
}

// UpsertTraitVector writes the trait vector row for a playthrough. The
// JSONB column stores the dimension->float mapping verbatim.
func (r *PgRepository) UpsertTraitVector(ctx context.Context, v TraitVector) error {
	payload, err := json.Marshal(v.Values)
	if err != nil {
		return fmt.Errorf("playthrough: marshal trait vector: %w", err)
	}
	const q = `
		INSERT INTO playthrough.trait_vectors (playthrough_id, vector, scoring_version, computed_at)
		VALUES ($1, $2::jsonb, $3, COALESCE($4, NOW()))
		ON CONFLICT (playthrough_id) DO UPDATE
		SET vector = EXCLUDED.vector,
		    scoring_version = EXCLUDED.scoring_version,
		    computed_at = EXCLUDED.computed_at
	`
	var computedAt any
	if !v.ComputedAt.IsZero() {
		computedAt = v.ComputedAt
	}
	if _, err := r.pool.Exec(ctx, q, v.PlaythroughID, string(payload), v.ScoringVersion, computedAt); err != nil {
		return fmt.Errorf("playthrough: upsert trait vector: %w", err)
	}
	return nil
}

// GetTraitVector fetches the stored trait vector for a playthrough.
func (r *PgRepository) GetTraitVector(ctx context.Context, playthroughID uuid.UUID) (TraitVector, error) {
	const q = `
		SELECT playthrough_id, vector, scoring_version, computed_at
		FROM playthrough.trait_vectors
		WHERE playthrough_id = $1
	`
	var (
		v   TraitVector
		raw []byte
	)
	err := r.pool.QueryRow(ctx, q, playthroughID).Scan(
		&v.PlaythroughID, &raw, &v.ScoringVersion, &v.ComputedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return TraitVector{}, ErrNotFound
	}
	if err != nil {
		return TraitVector{}, fmt.Errorf("playthrough: get trait vector: %w", err)
	}
	if err := json.Unmarshal(raw, &v.Values); err != nil {
		return TraitVector{}, fmt.Errorf("playthrough: unmarshal trait vector: %w", err)
	}
	return v, nil
}
