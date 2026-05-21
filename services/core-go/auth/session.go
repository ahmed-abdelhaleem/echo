package auth

import "time"

// Session is the typed domain representation of a Kratos session as Echo's
// handlers see it. The shape is intentionally narrow — anything that
// requires more than these fields should be looked up explicitly via the
// admin API rather than smuggled here.
type Session struct {
	ID          string
	IdentityID  string
	Email       string
	DisplayName string
	// Birthdate is the raw ISO date from Kratos identity traits. The
	// canonical age-band classification is computed by [EvaluateAgeGate],
	// not parsed here, so that callers cannot accidentally bypass the
	// age-gating policy.
	Birthdate string
	IssuedAt  time.Time
	ExpiresAt time.Time
}

// HasIdentity reports whether the session refers to a real Kratos identity.
// A zero-value Session has HasIdentity() == false, which makes it safe to
// initialise structs without immediately checking the ID field.
func (s Session) HasIdentity() bool { return s.IdentityID != "" }
