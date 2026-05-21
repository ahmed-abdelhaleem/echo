package playthrough_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sort"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/scoring"
	"github.com/google/uuid"
)

func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// fakeContentLoader serves a fixed Season for tests. Implements
// content.Loader so we can wrap it in a content.Service.
type fakeContentLoader struct {
	seasons map[string]content.Season
}

func (l *fakeContentLoader) LoadSeason(_ context.Context, id string) (content.Season, error) {
	s, ok := l.seasons[id]
	if !ok {
		return content.Season{}, content.ErrSeasonNotFound
	}
	return s, nil
}

func (l *fakeContentLoader) ListSeasonIDs(_ context.Context) ([]string, error) {
	ids := make([]string, 0, len(l.seasons))
	for id := range l.seasons {
		ids = append(ids, id)
	}
	return ids, nil
}

// fakeRepo is an in-memory playthrough repository. Keyed maps mirror the
// (playthrough_id, vignette_id) unique constraint so the idempotency
// branch in Service.RecordChoice can be exercised without Postgres.
type fakeRepo struct {
	playthroughs map[uuid.UUID]playthrough.Playthrough
	// choices keyed by composite (playthrough_id, vignette_id).
	choices      map[choiceKey]playthrough.ChoiceEvent
	traitVectors map[uuid.UUID]playthrough.TraitVector
}

type choiceKey struct {
	PlaythroughID uuid.UUID
	VignetteID    string
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		playthroughs: map[uuid.UUID]playthrough.Playthrough{},
		choices:      map[choiceKey]playthrough.ChoiceEvent{},
		traitVectors: map[uuid.UUID]playthrough.TraitVector{},
	}
}

func (r *fakeRepo) CreatePlaythrough(_ context.Context, userID uuid.UUID, seasonID string, seasonVersion int) (playthrough.Playthrough, error) {
	p := playthrough.Playthrough{
		ID:            uuid.New(),
		UserID:        userID,
		SeasonID:      seasonID,
		SeasonVersion: seasonVersion,
		Status:        playthrough.StatusInProgress,
		StartedAt:     time.Now(),
		CreatedAt:     time.Now(),
		UpdatedAt:     time.Now(),
	}
	r.playthroughs[p.ID] = p
	return p, nil
}

func (r *fakeRepo) GetPlaythrough(_ context.Context, id uuid.UUID) (playthrough.Playthrough, error) {
	p, ok := r.playthroughs[id]
	if !ok {
		return playthrough.Playthrough{}, playthrough.ErrNotFound
	}
	return p, nil
}

func (r *fakeRepo) InsertChoice(_ context.Context, in playthrough.RecordChoiceInput) (playthrough.ChoiceEvent, error) {
	key := choiceKey{PlaythroughID: in.PlaythroughID, VignetteID: in.VignetteID}
	if _, dup := r.choices[key]; dup {
		return playthrough.ChoiceEvent{}, playthrough.ErrChoiceConflict
	}
	ev := playthrough.ChoiceEvent{
		ID:               uuid.New(),
		PlaythroughID:    in.PlaythroughID,
		VignetteID:       in.VignetteID,
		ChoiceID:         in.ChoiceID,
		ClientTimestamp:  in.ClientTimestamp,
		DeliberationMS:   in.DeliberationMS,
		ServerReceivedAt: time.Now(),
		CreatedAt:        time.Now(),
	}
	r.choices[key] = ev
	return ev, nil
}

func (r *fakeRepo) GetChoice(_ context.Context, playthroughID uuid.UUID, vignetteID string) (playthrough.ChoiceEvent, error) {
	ev, ok := r.choices[choiceKey{PlaythroughID: playthroughID, VignetteID: vignetteID}]
	if !ok {
		return playthrough.ChoiceEvent{}, playthrough.ErrNotFound
	}
	return ev, nil
}

func (r *fakeRepo) ListChoices(_ context.Context, playthroughID uuid.UUID) ([]playthrough.ChoiceEvent, error) {
	var out []playthrough.ChoiceEvent
	for k, ev := range r.choices {
		if k.PlaythroughID == playthroughID {
			out = append(out, ev)
		}
	}
	// Deterministic order so test assertions don't flake on map iteration.
	sort.Slice(out, func(i, j int) bool {
		if !out[i].ServerReceivedAt.Equal(out[j].ServerReceivedAt) {
			return out[i].ServerReceivedAt.Before(out[j].ServerReceivedAt)
		}
		return out[i].ID.String() < out[j].ID.String()
	})
	return out, nil
}

func (r *fakeRepo) MarkCompleted(_ context.Context, playthroughID uuid.UUID) error {
	p, ok := r.playthroughs[playthroughID]
	if !ok {
		return playthrough.ErrNotFound
	}
	if p.Status == playthrough.StatusCompleted {
		return nil
	}
	now := time.Now()
	p.Status = playthrough.StatusCompleted
	p.CompletedAt = &now
	p.UpdatedAt = now
	r.playthroughs[playthroughID] = p
	return nil
}

func (r *fakeRepo) UpsertTraitVector(_ context.Context, v playthrough.TraitVector) error {
	r.traitVectors[v.PlaythroughID] = v
	return nil
}

func (r *fakeRepo) GetTraitVector(_ context.Context, playthroughID uuid.UUID) (playthrough.TraitVector, error) {
	v, ok := r.traitVectors[playthroughID]
	if !ok {
		return playthrough.TraitVector{}, playthrough.ErrNotFound
	}
	return v, nil
}

// fakeScoringClient is a deterministic in-process scoring.Client. It
// records every Score call so tests can assert on the wire payload and
// returns a configurable response (or error) without touching the
// network. Used by the playthrough service tests.
type fakeScoringClient struct {
	calls     []scoring.ScoreRequest
	response  scoring.ScoreResponse
	returnErr error
}

func (c *fakeScoringClient) Score(_ context.Context, req scoring.ScoreRequest) (scoring.ScoreResponse, error) {
	c.calls = append(c.calls, req)
	if c.returnErr != nil {
		return scoring.ScoreResponse{}, c.returnErr
	}
	// If the test didn't customise the response, synthesise one keyed on
	// the request playthrough id so assertions can pin the value.
	if c.response.Vector == nil {
		return scoring.ScoreResponse{
			PlaythroughID:  req.PlaythroughID,
			ScoringVersion: "rule-v1",
			Vector: map[string]float64{
				"OCEAN-O": 0.0, "OCEAN-C": 0.0, "OCEAN-E": 0.0,
				"OCEAN-A": 0.0, "OCEAN-N": 0.0,
			},
			UnknownDimensions: []string{},
		}, nil
	}
	return c.response, nil
}

// fixtureSeason returns a Season with one vignette and three choices.
func fixtureSeason() content.Season {
	return content.Season{
		ID: "season-001", Title: "Test", Locale: "en-GB", Version: 7,
		Acts: []content.Act{
			{ID: "act-01", Name: "Morning", Vignettes: []content.Vignette{
				{
					ID:          "vignette-001",
					SettingBeat: "x",
					Choices: []content.Choice{
						{ID: "choice-1", Label: "a", Weights: []content.TraitWeight{{Dimension: content.TraitOceanOpenness, Delta: 0.1}}},
						{ID: "choice-2", Label: "b", Weights: []content.TraitWeight{{Dimension: content.TraitOceanOpenness, Delta: -0.1}}},
						{ID: "choice-3", Label: "c", Weights: []content.TraitWeight{{Dimension: content.TraitOceanConscientiousness, Delta: 0.1}}},
					},
				},
			}},
			{ID: "act-02", Name: "Midday", Vignettes: []content.Vignette{}},
			{ID: "act-03", Name: "Afternoon", Vignettes: []content.Vignette{}},
			{ID: "act-04", Name: "Evening", Vignettes: []content.Vignette{}},
		},
	}
}

func newServiceFixture(t *testing.T) (*playthrough.Service, *fakeRepo, *fakeScoringClient) {
	t.Helper()
	loader := &fakeContentLoader{seasons: map[string]content.Season{
		"season-001": fixtureSeason(),
	}}
	contentSvc := content.NewService(loader)
	repo := newFakeRepo()
	scoringClient := &fakeScoringClient{}
	svc := playthrough.NewService(repo, contentSvc, scoringClient, silentLogger())
	return svc, repo, scoringClient
}

func TestService_CreatePlaythrough_LocksSeasonVersion(t *testing.T) {
	t.Parallel()
	svc, repo, _ := newServiceFixture(t)
	got, err := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	if err != nil {
		t.Fatalf("CreatePlaythrough: %v", err)
	}
	if got.SeasonVersion != 7 {
		t.Errorf("season_version: want 7, got %d", got.SeasonVersion)
	}
	if got.Status != playthrough.StatusInProgress {
		t.Errorf("status: want in_progress, got %q", got.Status)
	}
	if _, ok := repo.playthroughs[got.ID]; !ok {
		t.Error("playthrough not persisted in repo")
	}
}

func TestService_CreatePlaythrough_UnknownSeason(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	_, err := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-missing")
	if !errors.Is(err, playthrough.ErrInvalidSeason) {
		t.Errorf("want ErrInvalidSeason, got %v", err)
	}
}

func TestService_RecordChoice_HappyPath(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")

	ev, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-2",
	})
	if err != nil {
		t.Fatalf("RecordChoice: %v", err)
	}
	if ev.ChoiceID != "choice-2" || ev.VignetteID != "vignette-001" {
		t.Errorf("unexpected event: %+v", ev)
	}
}

// TestService_RecordChoice_IdempotentSameChoice is the M1 sync story's
// safety net: the client may retry a RecordChoice (offline → online,
// flaky network), and the server must return the existing row, not 409.
func TestService_RecordChoice_IdempotentSameChoice(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	in := playthrough.RecordChoiceInput{PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1"}

	first, err := svc.RecordChoice(context.Background(), in)
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	second, err := svc.RecordChoice(context.Background(), in)
	if err != nil {
		t.Fatalf("retry: %v", err)
	}
	if first.ID != second.ID {
		t.Errorf("retry returned a different row: first=%s second=%s", first.ID, second.ID)
	}
}

// TestService_RecordChoice_ConflictDifferentChoice is the other half of
// the idempotency story: the player cannot change their mind once a choice
// is committed. The application layer must surface this as a hard error,
// not silently overwrite.
func TestService_RecordChoice_ConflictDifferentChoice(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")

	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	_, err = svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-2",
	})
	if !errors.Is(err, playthrough.ErrChoiceConflict) {
		t.Errorf("want ErrChoiceConflict, got %v", err)
	}
}

func TestService_RecordChoice_UnknownVignette(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-999", ChoiceID: "choice-1",
	})
	if !errors.Is(err, playthrough.ErrInvalidVignette) {
		t.Errorf("want ErrInvalidVignette, got %v", err)
	}
}

func TestService_RecordChoice_UnknownChoice(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-bogus",
	})
	if !errors.Is(err, playthrough.ErrInvalidChoice) {
		t.Errorf("want ErrInvalidChoice, got %v", err)
	}
}

func TestService_RecordChoice_UnknownPlaythrough(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: uuid.New(), VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if !errors.Is(err, playthrough.ErrNotFound) {
		t.Errorf("want ErrNotFound, got %v", err)
	}
}

// --- Auto-finalize behaviour (T-CORE-011) -------------------------------
//
// The fixture Season has exactly one vignette, so any RecordChoice on it
// is by definition the last choice and should trigger trait scoring.

// TestService_RecordChoice_TriggersScoring_OnComplete is the headline
// behaviour: when the player commits the final choice, the playthrough
// flips to completed, the scoring client is called with every weight
// from every chosen Choice, and the resulting vector is persisted.
func TestService_RecordChoice_TriggersScoring_OnComplete(t *testing.T) {
	t.Parallel()
	svc, repo, sc := newServiceFixture(t)
	sc.response = scoring.ScoreResponse{
		PlaythroughID:  "ignored",
		ScoringVersion: "rule-v1",
		Vector: map[string]float64{
			"OCEAN-O": 0.42, "OCEAN-C": 0.0, "OCEAN-E": 0.0,
			"OCEAN-A": 0.0, "OCEAN-N": 0.0,
		},
		UnknownDimensions: nil,
	}

	p, err := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	if err != nil {
		t.Fatalf("CreatePlaythrough: %v", err)
	}

	_, err = svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if err != nil {
		t.Fatalf("RecordChoice: %v", err)
	}

	// Scoring was called exactly once, with the choice's authored weights.
	if got := len(sc.calls); got != 1 {
		t.Fatalf("scoring calls: want 1, got %d", got)
	}
	call := sc.calls[0]
	if call.PlaythroughID != p.ID.String() {
		t.Errorf("scoring playthrough_id: want %s, got %s", p.ID, call.PlaythroughID)
	}
	wantWeight := scoring.TraitWeight{Dimension: "OCEAN-O", Delta: 0.1}
	if len(call.Weights) != 1 || call.Weights[0] != wantWeight {
		t.Errorf("scoring weights: want [%+v], got %+v", wantWeight, call.Weights)
	}

	// Trait vector persisted.
	tv, ok := repo.traitVectors[p.ID]
	if !ok {
		t.Fatalf("trait vector not persisted")
	}
	if tv.ScoringVersion != "rule-v1" {
		t.Errorf("scoring_version: want rule-v1, got %q", tv.ScoringVersion)
	}
	if tv.Values["OCEAN-O"] != 0.42 {
		t.Errorf("vector OCEAN-O: want 0.42, got %v", tv.Values["OCEAN-O"])
	}
	if tv.ComputedAt.IsZero() {
		t.Error("computed_at should be set")
	}

	// Playthrough flipped to completed with completed_at populated.
	updated := repo.playthroughs[p.ID]
	if updated.Status != playthrough.StatusCompleted {
		t.Errorf("status: want completed, got %q", updated.Status)
	}
	if updated.CompletedAt == nil {
		t.Error("completed_at should be non-nil")
	}
}

// TestService_RecordChoice_ScoringTransportError_LeavesInProgress
// captures the resilience story: ml-py being down must not corrupt the
// playthrough state. The choice is still recorded; the playthrough
// stays in_progress so the M2 sweeper can finalise it later.
func TestService_RecordChoice_ScoringTransportError_LeavesInProgress(t *testing.T) {
	t.Parallel()
	svc, repo, sc := newServiceFixture(t)
	sc.returnErr = scoring.ErrTransport

	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if err != nil {
		t.Fatalf("RecordChoice should not surface scoring errors: %v", err)
	}

	if _, ok := repo.traitVectors[p.ID]; ok {
		t.Error("trait vector should NOT be persisted on scoring failure")
	}
	if repo.playthroughs[p.ID].Status == playthrough.StatusCompleted {
		t.Error("playthrough should remain in_progress on scoring failure")
	}
	if _, ok := repo.choices[choiceKey{p.ID, "vignette-001"}]; !ok {
		t.Error("choice should still be recorded even when scoring fails")
	}
}

// TestService_RecordChoice_IdempotentRetry_RetriesFinalize covers the
// recovery story: a retry of an already-recorded choice (same choice_id)
// should re-attempt finalize so a scoring outage that prevented
// finalise on the original call gets caught up by the natural sync retry.
func TestService_RecordChoice_IdempotentRetry_RetriesFinalize(t *testing.T) {
	t.Parallel()
	svc, _, sc := newServiceFixture(t)
	sc.returnErr = scoring.ErrTransport

	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	in := playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1",
	}
	if _, err := svc.RecordChoice(context.Background(), in); err != nil {
		t.Fatalf("first call: %v", err)
	}
	if len(sc.calls) != 1 {
		t.Fatalf("scoring calls after first: want 1, got %d", len(sc.calls))
	}

	// Scoring service is back. The client retries the same choice.
	sc.returnErr = nil
	if _, err := svc.RecordChoice(context.Background(), in); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if len(sc.calls) != 2 {
		t.Errorf("scoring should be retried on idempotent retry: got %d calls", len(sc.calls))
	}
}

// TestService_GetTraitVector_ReturnsNotFoundBeforeScoring guards the
// pre-finalise window: clients polling for the vector get a clean
// ErrNotFound rather than a zero-vector that they'd misinterpret as
// a real result.
func TestService_GetTraitVector_ReturnsNotFoundBeforeScoring(t *testing.T) {
	t.Parallel()
	svc, _, _ := newServiceFixture(t)
	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")

	_, err := svc.GetTraitVector(context.Background(), p.ID)
	if !errors.Is(err, playthrough.ErrNotFound) {
		t.Errorf("want ErrNotFound, got %v", err)
	}
}

// TestService_GetTraitVector_AfterScoring returns the persisted vector.
func TestService_GetTraitVector_AfterScoring(t *testing.T) {
	t.Parallel()
	svc, _, sc := newServiceFixture(t)
	sc.response = scoring.ScoreResponse{
		PlaythroughID:  "ignored",
		ScoringVersion: "rule-v1",
		Vector: map[string]float64{
			"OCEAN-O": 0.7,
		},
	}

	p, _ := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if err != nil {
		t.Fatalf("RecordChoice: %v", err)
	}

	tv, err := svc.GetTraitVector(context.Background(), p.ID)
	if err != nil {
		t.Fatalf("GetTraitVector: %v", err)
	}
	if tv.Values["OCEAN-O"] != 0.7 {
		t.Errorf("OCEAN-O: want 0.7, got %v", tv.Values["OCEAN-O"])
	}
}

// TestService_RecordChoice_NoScoringClient_NoCrash is the bootstrap
// safety net: a Service constructed without a scoring.Client (early
// dev environments) must record choices cleanly. Auto-finalise just
// quietly no-ops.
func TestService_RecordChoice_NoScoringClient_NoCrash(t *testing.T) {
	t.Parallel()
	loader := &fakeContentLoader{seasons: map[string]content.Season{
		"season-001": fixtureSeason(),
	}}
	contentSvc := content.NewService(loader)
	repo := newFakeRepo()
	svc := playthrough.NewService(repo, contentSvc, nil, silentLogger())

	p, err := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-001")
	if err != nil {
		t.Fatalf("CreatePlaythrough: %v", err)
	}
	_, err = svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: p.ID, VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if err != nil {
		t.Fatalf("RecordChoice: %v", err)
	}
	if repo.playthroughs[p.ID].Status == playthrough.StatusCompleted {
		t.Error("playthrough should NOT be marked completed without scoring client")
	}
}
