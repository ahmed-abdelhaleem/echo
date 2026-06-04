package playthrough

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/google/uuid"
)

var (
	ErrYouthSafeDenied        = errors.New("playthrough: youth-safe accounts cannot participate in comparisons")
	ErrNotOwner               = errors.New("playthrough: caller does not own the playthrough")
	ErrPlaythroughNotComplete = errors.New("playthrough: playthrough is not complete")
	ErrComparisonNotPending   = errors.New("playthrough: comparison is not pending")
	ErrSeasonMismatch         = errors.New("playthrough: playthroughs must belong to the same season")
	ErrNoDivergence           = errors.New("playthrough: playthroughs have no divergence moments")
)

// WithUsersRepository attaches a UsersRepository to the service.
func (s *Service) WithUsersRepository(repo auth.UsersRepository) *Service {
	s.users = repo
	return s
}

// CreateComparisonInvite generates a comparison token mapping User A's playthrough.
func (s *Service) CreateComparisonInvite(ctx context.Context, userID uuid.UUID, playthroughID uuid.UUID) (Comparison, error) {
	// 1. Youth safe gate (if users repo is wired)
	if s.users != nil {
		u, err := s.users.GetByID(ctx, userID)
		if err != nil {
			return Comparison{}, fmt.Errorf("playthrough: lookup user: %w", err)
		}
		if u.AgeBand == auth.AgeBandYouth {
			return Comparison{}, ErrYouthSafeDenied
		}
	}

	pt, err := s.repo.GetPlaythrough(ctx, playthroughID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return Comparison{}, ErrNotOwner
		}
		return Comparison{}, err
	}

	if pt.UserID != userID {
		return Comparison{}, ErrNotOwner
	}

	if pt.Status != StatusCompleted {
		return Comparison{}, ErrPlaythroughNotComplete
	}

	// Generate 22-char base64-urlsafe token
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return Comparison{}, fmt.Errorf("playthrough: generate comparison token: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(buf)

	return s.repo.CreateComparison(ctx, token, playthroughID, pt.SeasonID)
}

// AcceptComparisonInvite accepts a comparison token and binds User B's playthrough.
func (s *Service) AcceptComparisonInvite(ctx context.Context, userID uuid.UUID, token string, playthroughID uuid.UUID) (Comparison, error) {
	// 1. Youth safe gate (if users repo is wired)
	if s.users != nil {
		u, err := s.users.GetByID(ctx, userID)
		if err != nil {
			return Comparison{}, fmt.Errorf("playthrough: lookup user: %w", err)
		}
		if u.AgeBand == auth.AgeBandYouth {
			return Comparison{}, ErrYouthSafeDenied
		}
	}

	comp, err := s.repo.GetComparison(ctx, token)
	if err != nil {
		return Comparison{}, err
	}

	if comp.Status != ComparisonStatusPending {
		return Comparison{}, ErrComparisonNotPending
	}

	pt, err := s.repo.GetPlaythrough(ctx, playthroughID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return Comparison{}, ErrNotOwner
		}
		return Comparison{}, err
	}

	if pt.UserID != userID {
		return Comparison{}, ErrNotOwner
	}

	if pt.Status != StatusCompleted {
		return Comparison{}, ErrPlaythroughNotComplete
	}

	if pt.SeasonID != comp.SeasonID {
		return Comparison{}, ErrSeasonMismatch
	}

	// Restrict to different players (don't compare with self)
	inviterPt, err := s.repo.GetPlaythrough(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return Comparison{}, err
	}
	if inviterPt.UserID == userID {
		return Comparison{}, errors.New("playthrough: cannot compare with your own playthrough")
	}

	return s.repo.AcceptComparison(ctx, token, playthroughID)
}

// ComparisonDivergence represents the divergence vignette.
type ComparisonDivergence struct {
	VignetteID    string `json:"vignette_id"`
	InviterChoice string `json:"inviter_choice"`
	InviteeChoice string `json:"invitee_choice"`
}

// ComparisonResult wraps the comparison results for the API.
type ComparisonResult struct {
	Comparison   Comparison           `json:"comparison"`
	InviterModel StoredTraitVector    `json:"inviter_traits"`
	InviteeModel StoredTraitVector    `json:"invitee_traits"`
	Divergence   ComparisonDivergence `json:"divergence"`
}

// GetComparisonResult aggregates portraits and computes divergence.
func (s *Service) GetComparisonResult(ctx context.Context, token string) (ComparisonResult, error) {
	comp, err := s.repo.GetComparison(ctx, token)
	if err != nil {
		return ComparisonResult{}, err
	}

	if comp.Status != ComparisonStatusAccepted || comp.InviteePlaythroughID == nil {
		return ComparisonResult{Comparison: comp}, nil
	}

	inviterTraits, err := s.repo.GetTraitVector(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return ComparisonResult{}, err
	}

	inviteeTraits, err := s.repo.GetTraitVector(ctx, *comp.InviteePlaythroughID)
	if err != nil {
		return ComparisonResult{}, err
	}

	inviterChoices, err := s.repo.ListChoices(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return ComparisonResult{}, err
	}

	inviteeChoices, err := s.repo.ListChoices(ctx, *comp.InviteePlaythroughID)
	if err != nil {
		return ComparisonResult{}, err
	}

	divergence, err := findDivergenceMoment(inviterChoices, inviteeChoices)
	if err != nil {
		return ComparisonResult{}, err
	}

	return ComparisonResult{
		Comparison:   comp,
		InviterModel: inviterTraits,
		InviteeModel: inviteeTraits,
		Divergence:   divergence,
	}, nil
}

// RevokeComparison revokes the comparison. Only owner (inviter or invitee) may revoke.
func (s *Service) RevokeComparison(ctx context.Context, userID uuid.UUID, token string) error {
	comp, err := s.repo.GetComparison(ctx, token)
	if err != nil {
		return err
	}

	// Load inviter playthrough
	inviterPt, err := s.repo.GetPlaythrough(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return err
	}

	isOwner := inviterPt.UserID == userID
	if !isOwner && comp.InviteePlaythroughID != nil {
		inviteePt, err := s.repo.GetPlaythrough(ctx, *comp.InviteePlaythroughID)
		if err == nil && inviteePt.UserID == userID {
			isOwner = true
		}
	}

	if !isOwner {
		return ErrNotOwner
	}

	return s.repo.RevokeComparison(ctx, token)
}

func findDivergenceMoment(choicesA, choicesB []ChoiceEvent) (ComparisonDivergence, error) {
	mapB := make(map[string]string)
	for _, c := range choicesB {
		mapB[c.VignetteID] = c.ChoiceID
	}

	for _, cA := range choicesA {
		if cBVal, ok := mapB[cA.VignetteID]; ok {
			if cA.ChoiceID != cBVal {
				return ComparisonDivergence{
					VignetteID:    cA.VignetteID,
					InviterChoice: cA.ChoiceID,
					InviteeChoice: cBVal,
				}, nil
			}
		}
	}

	return ComparisonDivergence{}, ErrNoDivergence
}
