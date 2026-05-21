package playthrough

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/scoring"
	"github.com/google/uuid"
)

// ErrInvalidSeason is returned when CreatePlaythrough is called with a
// season id the content service doesn't know about.
var ErrInvalidSeason = errors.New("playthrough: unknown season")

// ErrInvalidVignette is returned when RecordChoice references a vignette id
// that does not exist in the playthrough's Season.
var ErrInvalidVignette = errors.New("playthrough: vignette not in season")

// ErrInvalidChoice is returned when RecordChoice references a choice id
// that does not exist on the referenced vignette.
var ErrInvalidChoice = errors.New("playthrough: choice not in vignette")

// Service is the domain entry point for the playthrough flow. It validates
// content references through the in-process content.Service, persists
// through the Repository, and finalises completed playthroughs through
// the trait scoring client.
type Service struct {
	repo    Repository
	content *content.Service
	scoring scoring.Client
	logger  *slog.Logger
}

// NewService wires a Repository and a content.Service into a Service.
// scoringClient may be nil during early-M0 wiring tests — in that case
// the auto-completion path is a no-op (the playthrough stays in_progress).
// Production wires a real scoring.Client; tests inject a deterministic
// fake.
func NewService(repo Repository, contentSvc *content.Service, scoringClient scoring.Client, logger *slog.Logger) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{
		repo:    repo,
		content: contentSvc,
		scoring: scoringClient,
		logger:  logger,
	}
}

// CreatePlaythrough opens a new attempt at the given Season for the user.
// The Season is looked up so the current Version can be locked in.
func (s *Service) CreatePlaythrough(ctx context.Context, userID uuid.UUID, seasonID string) (Playthrough, error) {
	season, err := s.content.GetSeason(ctx, seasonID)
	switch {
	case errors.Is(err, content.ErrSeasonNotFound):
		return Playthrough{}, fmt.Errorf("%w: %s", ErrInvalidSeason, seasonID)
	case err != nil:
		return Playthrough{}, err
	}
	return s.repo.CreatePlaythrough(ctx, userID, season.ID, season.Version)
}

// GetPlaythrough fetches a Playthrough by id.
func (s *Service) GetPlaythrough(ctx context.Context, id uuid.UUID) (Playthrough, error) {
	return s.repo.GetPlaythrough(ctx, id)
}

// RecordChoice persists the player's choice on a vignette. The operation is
// idempotent on (playthrough_id, vignette_id): a second call with the same
// choice id returns the existing row; a second call with a different choice
// id returns ErrChoiceConflict.
//
// Validation order (cheap first):
//  1. playthrough exists (defends against id forgery in URL)
//  2. vignette and choice exist in the Season (defends against stale clients)
//  3. insert (DB enforces idempotency)
func (s *Service) RecordChoice(ctx context.Context, in RecordChoiceInput) (ChoiceEvent, error) {
	p, err := s.repo.GetPlaythrough(ctx, in.PlaythroughID)
	if err != nil {
		return ChoiceEvent{}, err
	}
	if err := s.validateChoiceAgainstSeason(ctx, p, in.VignetteID, in.ChoiceID); err != nil {
		return ChoiceEvent{}, err
	}

	ev, err := s.repo.InsertChoice(ctx, in)
	switch {
	case err == nil:
		// Best-effort finalize. If the season is complete this triggers
		// trait scoring; if not, it's a no-op. Failures here are logged
		// but never propagated — the choice was recorded successfully
		// and a sweeper (T-CORE-012, M2) will retry scoring later.
		s.tryFinalize(ctx, p)
		return ev, nil
	case errors.Is(err, ErrChoiceConflict):
		// Inspect the existing row. Same choice id → idempotent success;
		// different choice id → genuine conflict.
		existing, getErr := s.repo.GetChoice(ctx, in.PlaythroughID, in.VignetteID)
		if getErr != nil {
			return ChoiceEvent{}, getErr
		}
		if existing.ChoiceID == in.ChoiceID {
			// Retry of a previously-successful call. If finalize was
			// skipped before (scoring transport down) this is the
			// natural place to retry it.
			s.tryFinalize(ctx, p)
			return existing, nil
		}
		return ChoiceEvent{}, ErrChoiceConflict
	default:
		return ChoiceEvent{}, err
	}
}

// GetTraitVector returns the persisted trait vector for a playthrough.
// Surfaces ErrNotFound when the playthrough has not yet been scored —
// this lets the HTTP layer return 404 cleanly, and lets the client poll
// (the offline sync worker uses this to know when to render the
// PortraitGen / ReflectionGen artefacts that follow in PR 10).
func (s *Service) GetTraitVector(ctx context.Context, playthroughID uuid.UUID) (TraitVector, error) {
	return s.repo.GetTraitVector(ctx, playthroughID)
}

// tryFinalize is the "is the playthrough complete? if so, score + mark
// completed" pass. Best-effort: any error is logged and swallowed so
// the caller's RecordChoice success is not retracted.
//
// Skip conditions (each a no-op):
//   - p.Status is already completed (nothing to do)
//   - the season still has unanswered vignettes
//   - no scoring client configured (early bootstrap / tests that opt out)
//
// Failure modes that leave the playthrough in_progress (sweeper will
// retry):
//   - listing choices fails
//   - reading the season fails
//   - scoring transport error (5xx / network)
func (s *Service) tryFinalize(ctx context.Context, p Playthrough) {
	if p.Status == StatusCompleted {
		return
	}
	if s.scoring == nil {
		return
	}

	season, err := s.content.GetSeason(ctx, p.SeasonID)
	if err != nil {
		s.logger.Warn("playthrough: finalize get season failed",
			"playthrough_id", p.ID, "season_id", p.SeasonID, "err", err.Error())
		return
	}

	choices, err := s.repo.ListChoices(ctx, p.ID)
	if err != nil {
		s.logger.Warn("playthrough: finalize list choices failed",
			"playthrough_id", p.ID, "err", err.Error())
		return
	}

	if !seasonComplete(season, choices) {
		return
	}

	weights, err := collectWeights(season, choices)
	if err != nil {
		// Choice in DB referenced unknown content — this should not
		// happen because RecordChoice validated against the Season,
		// but if it does we want a load-bearing log entry rather than
		// a silent miscalibration.
		s.logger.Error("playthrough: finalize weight resolution failed",
			"playthrough_id", p.ID, "err", err.Error())
		return
	}

	resp, err := s.scoring.Score(ctx, scoring.ScoreRequest{
		PlaythroughID: p.ID.String(),
		Weights:       weights,
	})
	if err != nil {
		// Transport/5xx error — leave playthrough in_progress.
		// Configuration/4xx error — same; a sweeper retry is harmless
		// because UpsertTraitVector is idempotent.
		s.logger.Warn("playthrough: scoring call failed",
			"playthrough_id", p.ID, "err", err.Error())
		return
	}

	tv := TraitVector{
		PlaythroughID:  p.ID,
		Values:         resp.Vector,
		ScoringVersion: resp.ScoringVersion,
		ComputedAt:     time.Now().UTC(),
	}
	if err := s.repo.UpsertTraitVector(ctx, tv); err != nil {
		s.logger.Error("playthrough: trait vector upsert failed",
			"playthrough_id", p.ID, "err", err.Error())
		return
	}
	if err := s.repo.MarkCompleted(ctx, p.ID); err != nil {
		s.logger.Error("playthrough: mark completed failed",
			"playthrough_id", p.ID, "err", err.Error())
		return
	}
	s.logger.Info("playthrough: finalised",
		"playthrough_id", p.ID,
		"scoring_version", resp.ScoringVersion,
		"unknown_dimensions", resp.UnknownDimensions)
}

// seasonComplete reports whether every vignette in every act of the
// Season has a corresponding choice in choices. The check is by
// vignette id (the unique constraint on choice_events already enforces
// at most one choice per (playthrough, vignette)).
func seasonComplete(season content.Season, choices []ChoiceEvent) bool {
	answered := make(map[string]struct{}, len(choices))
	for _, c := range choices {
		answered[c.VignetteID] = struct{}{}
	}
	for _, act := range season.Acts {
		for _, v := range act.Vignettes {
			if _, ok := answered[v.ID]; !ok {
				return false
			}
		}
	}
	return true
}

// collectWeights flattens "every choice the player made" into the wire
// format the scoring engine consumes. Order is preserved (deterministic
// for trait-replay diffs).
//
// Returns an error if a recorded choice references content that doesn't
// exist in the Season. This is a "should never happen" branch (RecordChoice
// validates first), kept defensive so a silent data drift surfaces in
// the logs rather than the trait vector.
func collectWeights(season content.Season, choices []ChoiceEvent) ([]scoring.TraitWeight, error) {
	// Index Season for O(1) lookup.
	choiceIndex := map[string]map[string][]content.TraitWeight{}
	for _, act := range season.Acts {
		for _, v := range act.Vignettes {
			byChoice := map[string][]content.TraitWeight{}
			for _, c := range v.Choices {
				byChoice[c.ID] = c.Weights
			}
			choiceIndex[v.ID] = byChoice
		}
	}
	var out []scoring.TraitWeight
	for _, ce := range choices {
		byChoice, ok := choiceIndex[ce.VignetteID]
		if !ok {
			return nil, fmt.Errorf("unknown vignette in recorded choice: %s", ce.VignetteID)
		}
		weights, ok := byChoice[ce.ChoiceID]
		if !ok {
			return nil, fmt.Errorf("unknown choice in recorded choice: vignette=%s choice=%s",
				ce.VignetteID, ce.ChoiceID)
		}
		for _, w := range weights {
			out = append(out, scoring.TraitWeight{
				Dimension: string(w.Dimension),
				Delta:     w.Delta,
			})
		}
	}
	return out, nil
}

// validateChoiceAgainstSeason confirms the (vignette_id, choice_id) pair is
// actually authored content for this playthrough's Season at the version
// the playthrough was started against.
//
// We load the Season at its current version (the content service is
// in-process; this is cheap). The locked season_version on the playthrough
// is informational here — content authors are not allowed to remove
// vignettes or choices once published, only add new ones, so a vignette
// that existed at start time still exists today.
func (s *Service) validateChoiceAgainstSeason(ctx context.Context, p Playthrough, vignetteID, choiceID string) error {
	season, err := s.content.GetSeason(ctx, p.SeasonID)
	if err != nil {
		return err
	}
	for _, act := range season.Acts {
		for _, v := range act.Vignettes {
			if v.ID != vignetteID {
				continue
			}
			for _, c := range v.Choices {
				if c.ID == choiceID {
					return nil
				}
			}
			return fmt.Errorf("%w: vignette=%s choice=%s", ErrInvalidChoice, vignetteID, choiceID)
		}
	}
	return fmt.Errorf("%w: vignette=%s season=%s", ErrInvalidVignette, vignetteID, p.SeasonID)
}
