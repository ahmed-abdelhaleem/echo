package playthrough_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/google/uuid"
)

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
	choices map[choiceKey]playthrough.ChoiceEvent
}

type choiceKey struct {
	PlaythroughID uuid.UUID
	VignetteID    string
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		playthroughs: map[uuid.UUID]playthrough.Playthrough{},
		choices:      map[choiceKey]playthrough.ChoiceEvent{},
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

func newServiceFixture(t *testing.T) (*playthrough.Service, *fakeRepo) {
	t.Helper()
	loader := &fakeContentLoader{seasons: map[string]content.Season{
		"season-001": fixtureSeason(),
	}}
	contentSvc := content.NewService(loader)
	repo := newFakeRepo()
	return playthrough.NewService(repo, contentSvc), repo
}

func TestService_CreatePlaythrough_LocksSeasonVersion(t *testing.T) {
	t.Parallel()
	svc, repo := newServiceFixture(t)
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
	svc, _ := newServiceFixture(t)
	_, err := svc.CreatePlaythrough(context.Background(), uuid.New(), "season-missing")
	if !errors.Is(err, playthrough.ErrInvalidSeason) {
		t.Errorf("want ErrInvalidSeason, got %v", err)
	}
}

func TestService_RecordChoice_HappyPath(t *testing.T) {
	t.Parallel()
	svc, _ := newServiceFixture(t)
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
	svc, _ := newServiceFixture(t)
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
	svc, _ := newServiceFixture(t)
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
	svc, _ := newServiceFixture(t)
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
	svc, _ := newServiceFixture(t)
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
	svc, _ := newServiceFixture(t)
	_, err := svc.RecordChoice(context.Background(), playthrough.RecordChoiceInput{
		PlaythroughID: uuid.New(), VignetteID: "vignette-001", ChoiceID: "choice-1",
	})
	if !errors.Is(err, playthrough.ErrNotFound) {
		t.Errorf("want ErrNotFound, got %v", err)
	}
}
