package playthrough

import (
	"context"
	"errors"
	"fmt"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
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

// ErrScorerUnavailable is returned by FinalizeIfComplete when the
// Service was constructed without a TraitScorer. Callers should treat
// it as a transient (5xx) condition.
var ErrScorerUnavailable = errors.New("playthrough: trait scorer not configured")

// ErrPlaythroughIncomplete is returned by FinalizeIfComplete when not
// every vignette in the Season has a recorded choice yet.
var ErrPlaythroughIncomplete = errors.New("playthrough: not all vignettes have a recorded choice")

// ScoringVersionM1 is the trait scoring engine version stamped on
// vectors produced today. Bumping this constant must be accompanied by
// a human-review-required PR per AGENTS.md §10.
const ScoringVersionM1 = 1

// TraitScorer is the dependency Service uses to call out to ml-py. The
// interface keeps the gRPC plumbing in services/core-go/grpc out of the
// hot path of unit tests.
type TraitScorer interface {
	Score(ctx context.Context, in TraitScoringInput) (TraitVector, error)
}

// Service is the domain entry point for the playthrough flow. It validates
// content references through the in-process content.Service and persists
// through the Repository.
type Service struct {
	repo    Repository
	content *content.Service
	scorer  TraitScorer
}

// NewService wires a Repository and a content.Service into a Service.
// `scorer` may be nil during early bootstrap; in that case
// FinalizeIfComplete returns ErrScorerUnavailable without persisting a
// completed status, so the player can retry later.
func NewService(repo Repository, contentSvc *content.Service, scorer TraitScorer) *Service {
	return &Service{repo: repo, content: contentSvc, scorer: scorer}
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
		return ev, nil
	case errors.Is(err, ErrChoiceConflict):
		// Inspect the existing row. Same choice id → idempotent success;
		// different choice id → genuine conflict.
		existing, getErr := s.repo.GetChoice(ctx, in.PlaythroughID, in.VignetteID)
		if getErr != nil {
			return ChoiceEvent{}, getErr
		}
		if existing.ChoiceID == in.ChoiceID {
			return existing, nil
		}
		return ChoiceEvent{}, ErrChoiceConflict
	default:
		return ChoiceEvent{}, err
	}
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

// FinalizeIfComplete checks whether every vignette in the playthrough's
// Season has a recorded choice; if so, it asks the trait scorer to
// produce a TraitVector and persists it. Idempotent: a second call after
// success re-scores using the same inputs and overwrites the row (the
// scorer is deterministic, so the row's contents are identical).
//
// Returns:
//   - ErrPlaythroughIncomplete if any vignette still lacks a choice.
//   - ErrScorerUnavailable if Service was constructed without a TraitScorer.
//   - Other errors from the repo / scorer are wrapped and surfaced.
func (s *Service) FinalizeIfComplete(ctx context.Context, playthroughID uuid.UUID) (StoredTraitVector, error) {
	if s.scorer == nil {
		return StoredTraitVector{}, ErrScorerUnavailable
	}
	p, err := s.repo.GetPlaythrough(ctx, playthroughID)
	if err != nil {
		return StoredTraitVector{}, err
	}
	season, err := s.content.GetSeason(ctx, p.SeasonID)
	if err != nil {
		return StoredTraitVector{}, err
	}
	choices, err := s.repo.ListChoices(ctx, playthroughID)
	if err != nil {
		return StoredTraitVector{}, err
	}
	if !allVignettesAnswered(season, choices) {
		return StoredTraitVector{}, ErrPlaythroughIncomplete
	}

	vec, err := s.scorer.Score(ctx, TraitScoringInput{
		PlaythroughID: p.ID.String(),
		SeasonID:      p.SeasonID,
		SeasonVersion: p.SeasonVersion,
		Events:        toScoredChoices(choices),
	})
	if err != nil {
		return StoredTraitVector{}, err
	}

	stored, err := s.repo.UpsertTraitVector(ctx, p.ID, vec, ScoringVersionM1, p.SeasonVersion)
	if err != nil {
		return StoredTraitVector{}, err
	}
	// Best-effort: flip the header to 'completed'. We don't roll back the
	// trait vector if this fails — the next FinalizeIfComplete retry will
	// re-stamp the status. The vector itself is the more important fact.
	if _, err := s.repo.MarkCompleted(ctx, p.ID); err != nil {
		return stored, err
	}
	return stored, nil
}

// GetTraitVector fetches the persisted vector for a playthrough.
func (s *Service) GetTraitVector(ctx context.Context, playthroughID uuid.UUID) (StoredTraitVector, error) {
	return s.repo.GetTraitVector(ctx, playthroughID)
}

// allVignettesAnswered returns true when every vignette in every act has
// at least one matching ChoiceEvent. The check is content-version-agnostic:
// we walk the Season at its current state (which is monotonically growing
// per AGENTS.md and the season schema policy), so an in-progress playthrough
// is not falsely "completed" because the author re-published.
func allVignettesAnswered(season content.Season, choices []ChoiceEvent) bool {
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

// toScoredChoices is a small adapter from the DB row type to the scoring
// payload type.
func toScoredChoices(choices []ChoiceEvent) []ScoredChoice {
	out := make([]ScoredChoice, 0, len(choices))
	for _, c := range choices {
		out = append(out, ScoredChoice{VignetteID: c.VignetteID, ChoiceID: c.ChoiceID})
	}
	return out
}
