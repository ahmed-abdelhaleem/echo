// Package scoring is core-go's bridge to the ml-py trait scoring engine
// (T-ML-010). It owns the call surface, the in-process types, and the
// retry/transport policy.
//
// We choose HTTP+JSON over gRPC for M1 deliberately:
//   - the call site is once per playthrough completion (cold path)
//   - gRPC adds a proto build step we don't need to unblock M1
//   - the request/response shapes here are intentionally laid out so a
//     future TraitScoringService.Score RPC binds 1:1 against them
//
// Trait vector storage lives in playthrough.trait_vectors (see migration
// 20260521000004_create_trait_vectors.sql). This package does not own
// persistence — the playthrough service does.
package scoring

import "errors"

// TraitWeight is one signed contribution from one Choice. Identical wire
// shape to content.TraitWeight (string dimension + float delta); kept as
// a separate type so the scoring package doesn't import content (which
// would create a cycle once content depends on this package for replay).
type TraitWeight struct {
	Dimension string  `json:"dimension"`
	Delta     float64 `json:"delta"`
}

// ScoreRequest is the body of a POST /score call to ml-py.
type ScoreRequest struct {
	PlaythroughID string        `json:"playthrough_id"`
	Weights       []TraitWeight `json:"weights"`
}

// ScoreResponse is the body of a successful POST /score call to ml-py.
//
// Vector is the post-clamp, dimension-complete mapping
// (18 entries — see services/ml-py/app/services/trait_scoring.py).
// UnknownDimensions is informational; ml-py logs unknowns rather than
// failing so content authors can preview a new dimension before the
// engine is updated for it.
type ScoreResponse struct {
	PlaythroughID     string             `json:"playthrough_id"`
	ScoringVersion    string             `json:"scoring_version"`
	Vector            map[string]float64 `json:"vector"`
	UnknownDimensions []string           `json:"unknown_dimensions"`
}

// ErrTransport signals the scoring call could not be reached or returned
// a 5xx. The playthrough service treats this as deferrable — the
// playthrough is left in_progress, and a sweeper (M2 task) will retry.
// We deliberately do NOT promote a transport failure into "playthrough
// completed without a vector"; an empty trait vector would corrupt
// downstream reflection generation.
var ErrTransport = errors.New("scoring: transport failure")

// ErrInvalidResponse signals ml-py replied with 2xx but a malformed body.
// Treated as a logged hard failure so the on-call operator can investigate
// the shape mismatch rather than silently degrading.
var ErrInvalidResponse = errors.New("scoring: invalid response body")
