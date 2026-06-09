package billing

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrNotFound is returned when no subscription row exists for the given lookup.
var ErrNotFound = errors.New("billing: subscription not found")

// Repository abstracts the persistence layer so service tests can run without
// Postgres.
type Repository interface {
	// Upsert creates or updates a subscription row. The row is keyed on user_id
	// so each user has at most one active subscription record.
	Upsert(ctx context.Context, sub Subscription) (Subscription, error)

	// GetByUserID returns the subscription row for a user. Returns ErrNotFound
	// when no row exists.
	GetByUserID(ctx context.Context, userID uuid.UUID) (Subscription, error)

	// GetByStoreSubscriptionID returns the subscription row for a store +
	// provider subscription identifier (e.g. Stripe subscription ID, Apple
	// originalTransactionId, Google purchaseToken). Returns ErrNotFound when
	// no row matches.
	GetByStoreSubscriptionID(ctx context.Context, store Store, storeSubID string) (Subscription, error)

	// GetByStoreCustomerID returns the subscription row for a store +
	// provider customer identifier (e.g. Stripe customer ID). Returns
	// ErrNotFound when no row matches.
	GetByStoreCustomerID(ctx context.Context, store Store, customerID string) (Subscription, error)

	// LogEvent appends an immutable record of a received webhook payload.
	LogEvent(ctx context.Context, store Store, eventType, payload string) error
}

// pgRepository is the production Postgres-backed implementation.
type pgRepository struct {
	pool *pgxpool.Pool
}

// NewPgRepository returns a Repository backed by a pgxpool.Pool.
func NewPgRepository(pool *pgxpool.Pool) Repository {
	return &pgRepository{pool: pool}
}

const upsertSQL = `
INSERT INTO billing.subscriptions (
    id, user_id, tier, status, store,
    store_customer_id, store_subscription_id,
    current_period_end, canceled_at, created_at, updated_at
) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
ON CONFLICT (user_id) DO UPDATE SET
    tier                  = EXCLUDED.tier,
    status                = EXCLUDED.status,
    store                 = EXCLUDED.store,
    store_customer_id     = EXCLUDED.store_customer_id,
    store_subscription_id = EXCLUDED.store_subscription_id,
    current_period_end    = EXCLUDED.current_period_end,
    canceled_at           = EXCLUDED.canceled_at,
    updated_at            = EXCLUDED.updated_at
RETURNING id, user_id, tier, status, store,
    store_customer_id, store_subscription_id,
    current_period_end, canceled_at, created_at, updated_at`

func (r *pgRepository) Upsert(ctx context.Context, sub Subscription) (Subscription, error) {
	if sub.ID == uuid.Nil {
		sub.ID = uuid.New()
	}
	if sub.CreatedAt.IsZero() {
		sub.CreatedAt = time.Now().UTC()
	}
	sub.UpdatedAt = time.Now().UTC()

	row := r.pool.QueryRow(ctx, upsertSQL,
		sub.ID, sub.UserID, string(sub.Tier), string(sub.Status), string(sub.Store),
		sub.StoreCustomerID, sub.StoreSubscriptionID,
		sub.CurrentPeriodEnd, sub.CanceledAt,
		sub.CreatedAt, sub.UpdatedAt,
	)
	return scanSub(row)
}

const getByUserSQL = `
SELECT id, user_id, tier, status, store,
    store_customer_id, store_subscription_id,
    current_period_end, canceled_at, created_at, updated_at
FROM billing.subscriptions WHERE user_id = $1`

func (r *pgRepository) GetByUserID(ctx context.Context, userID uuid.UUID) (Subscription, error) {
	row := r.pool.QueryRow(ctx, getByUserSQL, userID)
	sub, err := scanSub(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Subscription{}, ErrNotFound
		}
		return Subscription{}, fmt.Errorf("billing: get by user: %w", err)
	}
	return sub, nil
}

const getByStoreSubSQL = `
SELECT id, user_id, tier, status, store,
    store_customer_id, store_subscription_id,
    current_period_end, canceled_at, created_at, updated_at
FROM billing.subscriptions
WHERE store = $1 AND store_subscription_id = $2`

func (r *pgRepository) GetByStoreSubscriptionID(ctx context.Context, store Store, storeSubID string) (Subscription, error) {
	row := r.pool.QueryRow(ctx, getByStoreSubSQL, string(store), storeSubID)
	sub, err := scanSub(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Subscription{}, ErrNotFound
		}
		return Subscription{}, fmt.Errorf("billing: get by store sub id: %w", err)
	}
	return sub, nil
}

const getByStoreCustSQL = `
SELECT id, user_id, tier, status, store,
    store_customer_id, store_subscription_id,
    current_period_end, canceled_at, created_at, updated_at
FROM billing.subscriptions
WHERE store = $1 AND store_customer_id = $2`

func (r *pgRepository) GetByStoreCustomerID(ctx context.Context, store Store, customerID string) (Subscription, error) {
	row := r.pool.QueryRow(ctx, getByStoreCustSQL, string(store), customerID)
	sub, err := scanSub(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Subscription{}, ErrNotFound
		}
		return Subscription{}, fmt.Errorf("billing: get by store customer id: %w", err)
	}
	return sub, nil
}

const logEventSQL = `
INSERT INTO billing.subscription_events (store, event_type, payload)
VALUES ($1, $2, $3::jsonb)`

func (r *pgRepository) LogEvent(ctx context.Context, store Store, eventType, payload string) error {
	_, err := r.pool.Exec(ctx, logEventSQL, string(store), eventType, payload)
	if err != nil {
		return fmt.Errorf("billing: log event: %w", err)
	}
	return nil
}

type scannable interface {
	Scan(dest ...any) error
}

func scanSub(row scannable) (Subscription, error) {
	var sub Subscription
	var tier, status, store string
	err := row.Scan(
		&sub.ID, &sub.UserID, &tier, &status, &store,
		&sub.StoreCustomerID, &sub.StoreSubscriptionID,
		&sub.CurrentPeriodEnd, &sub.CanceledAt,
		&sub.CreatedAt, &sub.UpdatedAt,
	)
	if err != nil {
		return Subscription{}, err
	}
	sub.Tier = Tier(tier)
	sub.Status = Status(status)
	sub.Store = Store(store)
	return sub, nil
}
