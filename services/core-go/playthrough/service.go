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

// Service is the domain entry point for the playthrough flow. It validates
// content references through the in-process content.Service and persists
// through the Repository.
type Service struct {
	repo    Repository
	content *content.Service
}

// NewService wires a Repository and a content.Service into a Service.
func NewService(repo Repository, contentSvc *content.Service) *Service {
	return &Service{repo: repo, content: contentSvc}
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
