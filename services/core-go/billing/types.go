// Package billing implements T-MONEY-001: Echo+ subscription management.
//
// Three payment stores are supported:
//   - Stripe     (desktop: Windows, macOS)
//   - Apple IAP  (iOS, macOS App Store)
//   - Google Play Billing (Android)
//
// The service is the single source of truth for subscription state. All three
// stores write into billing.subscriptions via their respective webhook paths.
// The application reads GetOrDefault(userID) to gate Echo+ features.
package billing

import (
	"time"

	"github.com/google/uuid"
)

// Tier is the subscription tier.
type Tier string

const (
	// TierFree is the default unpaid tier. One Season available at a time.
	TierFree Tier = "free"
	// TierEchoPlus is the premium Echo+ tier.
	TierEchoPlus Tier = "echo_plus"
)

// Status is the subscription lifecycle status.
type Status string

const (
	StatusActive   Status = "active"
	StatusTrialing Status = "trialing"
	StatusPastDue  Status = "past_due"
	StatusCanceled Status = "canceled"
	StatusExpired  Status = "expired"
)

// Store identifies the payment provider.
type Store string

const (
	StoreNone   Store = "none"
	StoreStripe Store = "stripe"
	StoreApple  Store = "apple"
	StoreGoogle Store = "google"
)

// Subscription is the in-memory projection of a billing.subscriptions row.
// A missing row is equivalent to a free-tier subscription (see GetOrDefault).
type Subscription struct {
	ID                  uuid.UUID
	UserID              uuid.UUID
	Tier                Tier
	Status              Status
	Store               Store
	StoreCustomerID     string
	StoreSubscriptionID string
	CurrentPeriodEnd    *time.Time
	CanceledAt          *time.Time
	CreatedAt           time.Time
	UpdatedAt           time.Time
}

// IsPremium reports whether this subscription grants Echo+ access.
// A trialing subscription is treated as premium so the trial period
// delivers the full experience.
func (s Subscription) IsPremium() bool {
	return s.Tier == TierEchoPlus &&
		(s.Status == StatusActive || s.Status == StatusTrialing)
}

// defaultFree returns the zero-value free subscription for a user.
// Used by GetOrDefault when no DB row exists.
func defaultFree(userID uuid.UUID) Subscription {
	now := time.Now().UTC()
	return Subscription{
		UserID:    userID,
		Tier:      TierFree,
		Status:    StatusActive,
		Store:     StoreNone,
		CreatedAt: now,
		UpdatedAt: now,
	}
}
