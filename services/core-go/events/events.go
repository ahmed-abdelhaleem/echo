// Package events handles ingestion of per-vignette telemetry events
// (selection, hesitation time, hover, pacing) per docs/04_Game_Design.md
// §"Hidden signals". M1 scope. Today this package contains only the type
// definitions so callers can be type-checked.
package events

import "time"

// Choice is one recorded selection during a playthrough. Persisted to
// playthrough.choice_events in Postgres; replicated to NATS JetStream for
// downstream consumers.
type Choice struct {
	PlaythroughID string
	VignetteID    string
	ChoiceID      string
	SelectedAt    time.Time
	HesitationMS  int64
}

// Service is the placeholder façade for the events domain.
type Service struct{}

// New constructs an empty Service.
func New() Service {
	return Service{}
}
