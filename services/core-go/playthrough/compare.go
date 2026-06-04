package playthrough

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

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
	ErrComparisonNotAccepted  = errors.New("playthrough: comparison is not accepted")
	ErrComparisonTokenExpired = errors.New("playthrough: comparison token expired")
)

const (
	inviteTokenTTL = 7 * 24 * time.Hour
	shareTokenTTL  = 30 * 24 * time.Hour
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

	token, tokenHash, err := generateComparisonToken()
	if err != nil {
		return Comparison{}, err
	}

	comp, err := s.repo.CreateComparison(ctx, tokenHash, playthroughID, pt.SeasonID)
	if err != nil {
		return Comparison{}, err
	}
	if err := s.repo.CreateComparisonToken(ctx, comp.ID, ComparisonTokenTypeInvite, tokenHash, userID, time.Now().UTC().Add(inviteTokenTTL)); err != nil {
		return Comparison{}, err
	}
	comp.Token = token
	return comp, nil
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

	tokenHash := hashComparisonToken(token)
	comp, err := s.getComparisonByToken(ctx, tokenHash, ComparisonTokenTypeInvite)
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

	canonicalOrder, err := s.canonicalVignetteOrder(ctx, comp.SeasonID)
	if err != nil {
		return Comparison{}, err
	}

	inviterChoices, err := s.repo.ListChoices(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return Comparison{}, err
	}
	inviteeChoices, err := s.repo.ListChoices(ctx, playthroughID)
	if err != nil {
		return Comparison{}, err
	}
	divergence, err := findDivergenceMoment(canonicalOrder, inviterChoices, inviteeChoices)
	if err != nil {
		return Comparison{}, err
	}

	return s.repo.AcceptComparison(ctx, comp.ID, playthroughID, divergence.VignetteID)
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
	tokenHash := hashComparisonToken(token)
	comp, err := s.getComparisonByToken(ctx, tokenHash, ComparisonTokenTypeShare)
	if err != nil {
		return ComparisonResult{}, err
	}

	if comp.Status != ComparisonStatusAccepted || comp.InviteePlaythroughID == nil {
		return ComparisonResult{Comparison: comp}, nil
	}
	if !comp.ShareEnabled {
		return ComparisonResult{}, ErrNotFound
	}

	inviterTraits, err := s.repo.GetTraitVector(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return ComparisonResult{}, err
	}

	inviteeTraits, err := s.repo.GetTraitVector(ctx, *comp.InviteePlaythroughID)
	if err != nil {
		return ComparisonResult{}, err
	}

	canonicalOrder, err := s.canonicalVignetteOrder(ctx, comp.SeasonID)
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

	divergence, err := findDivergenceMoment(canonicalOrder, inviterChoices, inviteeChoices)
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

// EnableComparisonShare flips share_enabled and mints a share token.
func (s *Service) EnableComparisonShare(ctx context.Context, userID uuid.UUID, token string) (string, error) {
	tokenHash := hashComparisonToken(token)
	comp, err := s.repo.GetComparisonByAnyToken(ctx, tokenHash)
	if err != nil {
		return "", err
	}

	inviterPt, err := s.repo.GetPlaythrough(ctx, comp.InviterPlaythroughID)
	if err != nil {
		return "", err
	}
	isOwner := inviterPt.UserID == userID
	if !isOwner && comp.InviteePlaythroughID != nil {
		inviteePt, err := s.repo.GetPlaythrough(ctx, *comp.InviteePlaythroughID)
		if err == nil && inviteePt.UserID == userID {
			isOwner = true
		}
	}
	if !isOwner {
		return "", ErrNotOwner
	}
	if comp.Status != ComparisonStatusAccepted {
		return "", ErrComparisonNotAccepted
	}

	now := time.Now().UTC()
	if err := s.repo.EnableComparisonShare(ctx, comp.ID, now); err != nil {
		return "", err
	}

	shareToken, shareTokenHash, err := generateComparisonToken()
	if err != nil {
		return "", err
	}
	if err := s.repo.CreateComparisonToken(ctx, comp.ID, ComparisonTokenTypeShare, shareTokenHash, userID, now.Add(shareTokenTTL)); err != nil {
		return "", err
	}
	return shareToken, nil
}

// RevokeComparison revokes the comparison. Only owner (inviter or invitee) may revoke.
func (s *Service) RevokeComparison(ctx context.Context, userID uuid.UUID, token string) error {
	tokenHash := hashComparisonToken(token)
	comp, err := s.repo.GetComparisonByAnyToken(ctx, tokenHash)
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

	now := time.Now().UTC()
	if err := s.repo.RevokeComparison(ctx, comp.ID, now); err != nil {
		return err
	}
	return s.repo.RevokeComparisonTokens(ctx, comp.ID, now)
}

func generateComparisonToken() (string, string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", "", fmt.Errorf("playthrough: generate comparison token: %w", err)
	}
	token := base64.RawURLEncoding.EncodeToString(buf)
	return token, hashComparisonToken(token), nil
}

func hashComparisonToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func findDivergenceMoment(canonicalOrder []string, choicesA, choicesB []ChoiceEvent) (ComparisonDivergence, error) {
	mapA := make(map[string]string)
	for _, c := range choicesA {
		mapA[c.VignetteID] = c.ChoiceID
	}

	mapB := make(map[string]string)
	for _, c := range choicesB {
		mapB[c.VignetteID] = c.ChoiceID
	}

	for _, vignetteID := range canonicalOrder {
		choiceA, okA := mapA[vignetteID]
		choiceB, okB := mapB[vignetteID]
		if okA && okB && choiceA != choiceB {
				return ComparisonDivergence{
					VignetteID:    vignetteID,
					InviterChoice: choiceA,
					InviteeChoice: choiceB,
				}, nil
		}
	}

	return ComparisonDivergence{}, ErrNoDivergence
}

func (s *Service) canonicalVignetteOrder(ctx context.Context, seasonID string) ([]string, error) {
	season, err := s.content.GetSeason(ctx, seasonID)
	if err != nil {
		return nil, err
	}
	ordered := make([]string, 0)
	for _, act := range season.Acts {
		for _, vignette := range act.Vignettes {
			ordered = append(ordered, vignette.ID)
		}
	}
	return ordered, nil
}

func (s *Service) getComparisonByToken(ctx context.Context, tokenHash string, tokenType ComparisonTokenType) (Comparison, error) {
	now := time.Now().UTC()
	comp, err := s.repo.GetComparisonByToken(ctx, tokenHash, tokenType, now)
	if err == nil {
		return comp, nil
	}
	if !errors.Is(err, ErrComparisonNotFound) {
		return Comparison{}, err
	}

	compAnyState, errAnyState := s.repo.GetComparisonByTokenAnyState(ctx, tokenHash, tokenType)
	if errAnyState != nil {
		return Comparison{}, err
	}
	if compAnyState.ExpiresAt != nil && !compAnyState.ExpiresAt.After(now) {
		return Comparison{}, ErrComparisonTokenExpired
	}
	return Comparison{}, err
}

