// Package playthrough manages the lifecycle of a player's journey through a
// Season: create, record choices, finalize.
//
// The data model is two tables (playthrough.playthroughs + .choice_events,
// see services/core-go/db/migrations/20260521000003_create_playthroughs.sql).
// Idempotency for RecordChoice is enforced by a UNIQUE constraint on
// (playthrough_id, vignette_id); the service catches that conflict and
// either returns 200 (same choice) or 409 (player tried to change a
// committed answer).
package playthrough

import (
	"time"

	"github.com/google/uuid"
)

// Status is the lifecycle of a Playthrough header row.
type Status string

const (
	// StatusInProgress is the only status a freshly-created Playthrough has.
	// Flips to StatusCompleted once trait scoring finishes (T-CORE-011).
	StatusInProgress Status = "in_progress"

	// StatusCompleted means every required vignette has a recorded choice
	// and the trait vector has been computed.
	StatusCompleted Status = "completed"

	// StatusAbandoned is set by a server-side sweeper after the
	// inactivity window defined in docs/05. M2 task.
	StatusAbandoned Status = "abandoned"
)

// Playthrough is one player's attempt at one Season.
type Playthrough struct {
	ID            uuid.UUID  `json:"id"`
	UserID        uuid.UUID  `json:"user_id"`
	SeasonID      string     `json:"season_id"`
	SeasonVersion int        `json:"season_version"`
	Status        Status     `json:"status"`
	StartedAt     time.Time  `json:"started_at"`
	CompletedAt   *time.Time `json:"completed_at,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
}

// ChoiceEvent is a single recorded choice within a Playthrough.
//
// The (PlaythroughID, VignetteID) pair is unique — each vignette is a
// one-shot decision. RecordChoice surfaces a duplicate as either an
// idempotent success (same ChoiceID) or a conflict (different ChoiceID).
type ChoiceEvent struct {
	ID               uuid.UUID  `json:"id"`
	PlaythroughID    uuid.UUID  `json:"playthrough_id"`
	VignetteID       string     `json:"vignette_id"`
	ChoiceID         string     `json:"choice_id"`
	ClientTimestamp  *time.Time `json:"client_timestamp,omitempty"`
	ServerReceivedAt time.Time  `json:"server_received_at"`
	DeliberationMS   *int       `json:"deliberation_ms,omitempty"`
	CreatedAt        time.Time  `json:"created_at"`
}

// RecordChoiceInput is the shape RecordChoice consumes. Carved out as its
// own type because the HTTP handler and the gRPC handler (M1.5) both bind
// to it and JSON / proto field names should match.
type RecordChoiceInput struct {
	PlaythroughID   uuid.UUID  `json:"playthrough_id"`
	VignetteID      string     `json:"vignette_id"`
	ChoiceID        string     `json:"choice_id"`
	ClientTimestamp *time.Time `json:"client_timestamp,omitempty"`
	DeliberationMS  *int       `json:"deliberation_ms,omitempty"`
}

// ScoredChoice is the (vignette_id, choice_id) pair the trait scorer
// consumes. Kept separate from ChoiceEvent so the scoring client doesn't
// have to round-trip the entire DB row.
type ScoredChoice struct {
	VignetteID string
	ChoiceID   string
}

// TraitScoringInput is the payload sent to the ml-py scoring service.
type TraitScoringInput struct {
	PlaythroughID string
	SeasonID      string
	SeasonVersion int
	Events        []ScoredChoice
}

// TraitVector is the 18-dimensional output of the scoring engine. The
// three sub-arrays are stored separately in Postgres
// (playthrough.trait_vectors) so SQL can be written against them
// directly. Order is locked to `content.AllDimensions`.
type TraitVector struct {
	BigFive    []float64 `json:"big_five"`
	Schwartz   []float64 `json:"schwartz"`
	Attachment []float64 `json:"attachment"`
}

// StoredTraitVector is a TraitVector plus the bookkeeping columns
// persisted alongside it. Returned by Repository.GetTraitVector.
type StoredTraitVector struct {
	PlaythroughID  uuid.UUID `json:"playthrough_id"`
	BigFive        []float64 `json:"big_five"`
	Schwartz       []float64 `json:"schwartz"`
	Attachment     []float64 `json:"attachment"`
	ScoringVersion int       `json:"scoring_version"`
	SeasonVersion  int       `json:"season_version"`
	CreatedAt      time.Time `json:"created_at"`
}

// --- Portrait + Reflection (M1 stubs) --------------------------------------

// PortraitInput is the payload sent to ml-py's PortraitGenService. The
// trait vector is passed inline; ml-py never reaches into core-go's
// Postgres (stateless RPC, per docs/05 §"ml-py service boundary").
type PortraitInput struct {
	PlaythroughID string
	Seed          uint64
	BigFive       []float64
	Schwartz      []float64
	Attachment    []float64
}

// PortraitAssets is the Portrait Generator's result. In M1 “PNG“
// carries the inline bytes; in M2 the renderer writes to R2 and
// populates the key fields instead.
type PortraitAssets struct {
	PNG             []byte `json:"png,omitempty"`
	StaticPNGKey    string `json:"static_png_key"`
	AnimatedWebPKey string `json:"animated_webp_key"`
	RendererVersion int    `json:"renderer_version"`
}

// ReflectionInput is the payload sent to ml-py's ReflectionGenService.
type ReflectionInput struct {
	PlaythroughID string
	YouthSafe     bool
	Locale        string
	BigFive       []float64
	Schwartz      []float64
	Attachment    []float64
}

// Reflection is the reflection generator's result. “UsedFallback“ is
// always false for the M1 stub (no LLM to fall back from); the field
// stays in the type so the M2 pipeline can populate it without a
// breaking change.
type Reflection struct {
	Text         string `json:"text"`
	UsedFallback bool   `json:"used_fallback"`
	TemplateID   string `json:"template_id"`
}
