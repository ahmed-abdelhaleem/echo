package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrUserNotFound is returned when the auth.users row for a given Kratos
// identity id does not exist (yet — call EnsureUser to provision it).
var ErrUserNotFound = errors.New("auth: user not found")

// ErrUnderageIdentity is returned by EnsureUser when the Kratos identity's
// birthdate evaluates to under-13. Under-13 identities should never reach
// EnsureUser — Kratos rejects them at registration — but the check is
// here as a defense-in-depth backstop so the youth-safe path is
// statically un-bypassable.
var ErrUnderageIdentity = errors.New("auth: identity is under 13")

// User is the in-memory projection of an auth.users row.
type User struct {
	ID                uuid.UUID
	KratosIdentityID  uuid.UUID
	AgeBand           AgeBand
	TosVersion        string
	TosAcceptedAt     time.Time
	PrivacyVersion    string
	PrivacyAcceptedAt time.Time
	CreatedAt         time.Time
}

// UsersRepository is the persistence interface for auth.users. Defined as
// an interface so playthrough/http tests can fake it without Postgres.
type UsersRepository interface {
	GetByKratosID(ctx context.Context, kratosIdentityID uuid.UUID) (User, error)
	EnsureFromSession(ctx context.Context, sess Session, now time.Time) (User, error)
	// EnsureForKratosIdentity provisions an auth.users row for a Kratos
	// identity given an already-validated age band. Used by the Kratos
	// after-registration hook where the birthdate has been re-checked at
	// the boundary; takes the band directly rather than re-running the
	// gate so the policy lives in exactly one place (the hook handler).
	EnsureForKratosIdentity(ctx context.Context, identityID uuid.UUID, band AgeBand, now time.Time) (User, error)
	// SoftDeleteByKratosID marks the row deleted. The Kratos identity is
	// expected to have been (or will be) removed separately via the
	// admin API; the rows here remain for audit retention windows
	// configured in docs/08.
	SoftDeleteByKratosID(ctx context.Context, identityID uuid.UUID, now time.Time) error
}

// PgUsersRepository is the pgxpool-backed UsersRepository.
type PgUsersRepository struct {
	pool *pgxpool.Pool
}

// NewPgUsersRepository constructs a PgUsersRepository.
func NewPgUsersRepository(pool *pgxpool.Pool) *PgUsersRepository {
	return &PgUsersRepository{pool: pool}
}

// GetByKratosID looks up an existing user row.
func (r *PgUsersRepository) GetByKratosID(ctx context.Context, kratosIdentityID uuid.UUID) (User, error) {
	const q = `
		SELECT id, kratos_identity_id, age_band, tos_version, tos_accepted_at,
		       privacy_version, privacy_accepted_at, created_at
		FROM auth.users
		WHERE kratos_identity_id = $1 AND deleted_at IS NULL
	`
	var u User
	err := r.pool.QueryRow(ctx, q, kratosIdentityID).Scan(
		&u.ID, &u.KratosIdentityID, &u.AgeBand, &u.TosVersion, &u.TosAcceptedAt,
		&u.PrivacyVersion, &u.PrivacyAcceptedAt, &u.CreatedAt,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrUserNotFound
	}
	if err != nil {
		return User{}, fmt.Errorf("auth: get user: %w", err)
	}
	return u, nil
}

// Placeholder consent versions used during M1. The real consent flow
// (T-CORE-021, M2) supplies authentic accepted_at timestamps and the
// actual policy versions from the consent surface. Until then any
// authenticated request implicitly accepts the v1.0 policies it had to
// have seen at registration time.
const (
	m1TosVersion     = "v1.0"
	m1PrivacyVersion = "v1.0"
)

// EnsureFromSession finds the auth.users row for the session's Kratos
// identity, creating it on first contact. Side-effects:
//   - if Session.Birthdate evaluates to AgeBandUnder13 the function returns
//     ErrUnderageIdentity and writes nothing
//   - first contact uses (m1TosVersion, m1PrivacyVersion, now) as a
//     placeholder consent record. Replaced by T-CORE-021 in M2.
func (r *PgUsersRepository) EnsureFromSession(ctx context.Context, sess Session, now time.Time) (User, error) {
	if !sess.HasIdentity() {
		return User{}, fmt.Errorf("auth: ensure user: empty session")
	}
	identityID, err := uuid.Parse(sess.IdentityID)
	if err != nil {
		return User{}, fmt.Errorf("auth: invalid identity id %q: %w", sess.IdentityID, err)
	}

	// Fast path: the row already exists. The majority of requests take
	// this branch (users are provisioned once, used many times).
	existing, err := r.GetByKratosID(ctx, identityID)
	if err == nil {
		return existing, nil
	}
	if !errors.Is(err, ErrUserNotFound) {
		return User{}, err
	}

	// Compute the age band from the identity's birthdate. Refuse under-13
	// outright. This defense-in-depth check exists because the youth-safe
	// path must never have a fallback for under-13 users.
	decision, gateErr := EvaluateAgeGate(sess.Birthdate, now)
	if gateErr != nil {
		return User{}, fmt.Errorf("auth: ensure user: %w", gateErr)
	}
	if !decision.Allowed {
		return User{}, ErrUnderageIdentity
	}
	band := decision.Band

	const insert = `
		INSERT INTO auth.users (
			kratos_identity_id, age_band,
			tos_version, tos_accepted_at, privacy_version, privacy_accepted_at
		)
		VALUES ($1, $2, $3, $4, $5, $4)
		ON CONFLICT (kratos_identity_id) DO UPDATE SET updated_at = NOW()
		RETURNING id, kratos_identity_id, age_band, tos_version, tos_accepted_at,
		          privacy_version, privacy_accepted_at, created_at
	`
	var u User
	err = r.pool.QueryRow(ctx, insert,
		identityID, string(band), m1TosVersion, now, m1PrivacyVersion,
	).Scan(
		&u.ID, &u.KratosIdentityID, &u.AgeBand, &u.TosVersion, &u.TosAcceptedAt,
		&u.PrivacyVersion, &u.PrivacyAcceptedAt, &u.CreatedAt,
	)
	if err != nil {
		return User{}, fmt.Errorf("auth: ensure user: %w", err)
	}
	return u, nil
}

// EnsureForKratosIdentity provisions a row directly from the Kratos
// after-registration hook. The age band is supplied by the caller because
// the gate ran against the registration payload's birthdate (the canonical
// source) inside the hook handler.
func (r *PgUsersRepository) EnsureForKratosIdentity(ctx context.Context, identityID uuid.UUID, band AgeBand, now time.Time) (User, error) {
	if identityID == uuid.Nil {
		return User{}, fmt.Errorf("auth: ensure user: empty identity id")
	}
	if band != AgeBandYouth && band != AgeBandAdult {
		return User{}, fmt.Errorf("auth: ensure user: invalid age band %q", band)
	}

	existing, err := r.GetByKratosID(ctx, identityID)
	if err == nil {
		return existing, nil
	}
	if !errors.Is(err, ErrUserNotFound) {
		return User{}, err
	}

	const insert = `
		INSERT INTO auth.users (
			kratos_identity_id, age_band,
			tos_version, tos_accepted_at, privacy_version, privacy_accepted_at
		)
		VALUES ($1, $2, $3, $4, $5, $4)
		ON CONFLICT (kratos_identity_id) DO UPDATE SET updated_at = NOW()
		RETURNING id, kratos_identity_id, age_band, tos_version, tos_accepted_at,
		          privacy_version, privacy_accepted_at, created_at
	`
	var u User
	err = r.pool.QueryRow(ctx, insert,
		identityID, string(band), m1TosVersion, now, m1PrivacyVersion,
	).Scan(
		&u.ID, &u.KratosIdentityID, &u.AgeBand, &u.TosVersion, &u.TosAcceptedAt,
		&u.PrivacyVersion, &u.PrivacyAcceptedAt, &u.CreatedAt,
	)
	if err != nil {
		return User{}, fmt.Errorf("auth: ensure for kratos identity: %w", err)
	}
	return u, nil
}

// SoftDeleteByKratosID marks an existing row as deleted. The lookup
// follows the same `deleted_at IS NULL` predicate as GetByKratosID, so
// repeated calls are idempotent (a second call finds nothing to update
// and returns nil).
func (r *PgUsersRepository) SoftDeleteByKratosID(ctx context.Context, identityID uuid.UUID, now time.Time) error {
	if identityID == uuid.Nil {
		return fmt.Errorf("auth: soft delete: empty identity id")
	}
	const q = `
		UPDATE auth.users
		SET deleted_at = $2, updated_at = $2
		WHERE kratos_identity_id = $1 AND deleted_at IS NULL
	`
	_, err := r.pool.Exec(ctx, q, identityID, now)
	if err != nil {
		return fmt.Errorf("auth: soft delete: %w", err)
	}
	return nil
}
