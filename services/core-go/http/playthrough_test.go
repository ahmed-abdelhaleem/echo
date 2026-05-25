package http

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

// --- Test fakes ---------------------------------------------------------

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

type fakeRepo struct {
	playthroughs map[uuid.UUID]playthrough.Playthrough
	choices      map[string]playthrough.ChoiceEvent
	vectors      map[uuid.UUID]playthrough.StoredTraitVector
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		playthroughs: map[uuid.UUID]playthrough.Playthrough{},
		choices:      map[string]playthrough.ChoiceEvent{},
		vectors:      map[uuid.UUID]playthrough.StoredTraitVector{},
	}
}
func key(p uuid.UUID, v string) string { return p.String() + "|" + v }

func (r *fakeRepo) CreatePlaythrough(_ context.Context, userID uuid.UUID, sid string, sv int) (playthrough.Playthrough, error) {
	p := playthrough.Playthrough{ID: uuid.New(), UserID: userID, SeasonID: sid, SeasonVersion: sv, Status: playthrough.StatusInProgress, StartedAt: time.Now(), CreatedAt: time.Now(), UpdatedAt: time.Now()}
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
	if _, dup := r.choices[key(in.PlaythroughID, in.VignetteID)]; dup {
		return playthrough.ChoiceEvent{}, playthrough.ErrChoiceConflict
	}
	ev := playthrough.ChoiceEvent{ID: uuid.New(), PlaythroughID: in.PlaythroughID, VignetteID: in.VignetteID, ChoiceID: in.ChoiceID, ServerReceivedAt: time.Now(), CreatedAt: time.Now()}
	r.choices[key(in.PlaythroughID, in.VignetteID)] = ev
	return ev, nil
}
func (r *fakeRepo) GetChoice(_ context.Context, pID uuid.UUID, vID string) (playthrough.ChoiceEvent, error) {
	ev, ok := r.choices[key(pID, vID)]
	if !ok {
		return playthrough.ChoiceEvent{}, playthrough.ErrNotFound
	}
	return ev, nil
}
func (r *fakeRepo) ListChoices(_ context.Context, playthroughID uuid.UUID) ([]playthrough.ChoiceEvent, error) {
	var out []playthrough.ChoiceEvent
	prefix := playthroughID.String() + "|"
	for k, ev := range r.choices {
		if strings.HasPrefix(k, prefix) {
			out = append(out, ev)
		}
	}
	return out, nil
}
func (r *fakeRepo) MarkCompleted(_ context.Context, playthroughID uuid.UUID) (playthrough.Playthrough, error) {
	p, ok := r.playthroughs[playthroughID]
	if !ok {
		return playthrough.Playthrough{}, playthrough.ErrNotFound
	}
	now := time.Now()
	p.Status = playthrough.StatusCompleted
	if p.CompletedAt == nil {
		p.CompletedAt = &now
	}
	p.UpdatedAt = now
	r.playthroughs[playthroughID] = p
	return p, nil
}
func (r *fakeRepo) UpsertTraitVector(
	_ context.Context,
	playthroughID uuid.UUID,
	vec playthrough.TraitVector,
	scoringVersion, seasonVersion int,
) (playthrough.StoredTraitVector, error) {
	stored := playthrough.StoredTraitVector{
		PlaythroughID: playthroughID, BigFive: vec.BigFive, Schwartz: vec.Schwartz, Attachment: vec.Attachment,
		ScoringVersion: scoringVersion, SeasonVersion: seasonVersion, CreatedAt: time.Now(),
	}
	r.vectors[playthroughID] = stored
	return stored, nil
}
func (r *fakeRepo) GetTraitVector(_ context.Context, playthroughID uuid.UUID) (playthrough.StoredTraitVector, error) {
	stored, ok := r.vectors[playthroughID]
	if !ok {
		return playthrough.StoredTraitVector{}, playthrough.ErrTraitVectorNotFound
	}
	return stored, nil
}

// fakeScorer is a recording stand-in for the gRPC client. The HTTP
// tests don't care what the vector looks like — the contract under
// test here is the HTTP <-> service — so we return a constant vector.
type fakeScorer struct {
	called bool
	in     playthrough.TraitScoringInput
	out    playthrough.TraitVector
	err    error
}

func (f *fakeScorer) Score(_ context.Context, in playthrough.TraitScoringInput) (playthrough.TraitVector, error) {
	f.called = true
	f.in = in
	return f.out, f.err
}

type fakeUsersRepo struct {
	user           auth.User
	ensureErr      error
	ensureCalls    int
	lastEnsuredSes auth.Session
}

func (f *fakeUsersRepo) GetByKratosID(_ context.Context, _ uuid.UUID) (auth.User, error) {
	return f.user, nil
}
func (f *fakeUsersRepo) EnsureFromSession(_ context.Context, sess auth.Session, _ time.Time) (auth.User, error) {
	f.ensureCalls++
	f.lastEnsuredSes = sess
	if f.ensureErr != nil {
		return auth.User{}, f.ensureErr
	}
	return f.user, nil
}

// stubKratos returns an httptest.Server whose /sessions/whoami returns the
// given body. Pulled in here (rather than reusing auth/kratos_client_test.go)
// because helpers in *_test.go aren't exported to other packages.
func stubKratos(t *testing.T, body string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/sessions/whoami", func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Cookie"), auth.KratosCookieName+"=") {
			http.Error(w, "missing cookie", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func fixtureSeason() content.Season {
	return content.Season{
		ID: "season-001", Title: "T", Locale: "en-GB", Version: 3,
		Acts: []content.Act{
			{ID: "act-01", Name: "Morning", Vignettes: []content.Vignette{
				{ID: "vignette-001", SettingBeat: "x", Choices: []content.Choice{
					{ID: "choice-1", Label: "a", Weights: []content.TraitWeight{{Dimension: content.TraitOceanOpenness, Delta: 0.1}}},
					{ID: "choice-2", Label: "b", Weights: []content.TraitWeight{{Dimension: content.TraitOceanOpenness, Delta: -0.1}}},
				}},
			}},
			{ID: "act-02", Name: "Midday", Vignettes: nil},
			{ID: "act-03", Name: "Afternoon", Vignettes: nil},
			{ID: "act-04", Name: "Evening", Vignettes: nil},
		},
	}
}

// fakePortraitGen returns a fixed PNG; satisfies playthrough.PortraitGenerator.
type fakePortraitGen struct {
	called bool
	in     playthrough.PortraitInput
}

func (f *fakePortraitGen) GeneratePortrait(_ context.Context, in playthrough.PortraitInput) (playthrough.PortraitAssets, error) {
	f.called = true
	f.in = in
	return playthrough.PortraitAssets{
		PNG:             []byte("\x89PNG\r\n\x1a\nFAKE"),
		RendererVersion: 1,
	}, nil
}

// fakeReflectionGen returns a fixed reflection; satisfies playthrough.ReflectionGenerator.
type fakeReflectionGen struct {
	called bool
	in     playthrough.ReflectionInput
}

func (f *fakeReflectionGen) GenerateReflection(_ context.Context, in playthrough.ReflectionInput) (playthrough.Reflection, error) {
	f.called = true
	f.in = in
	return playthrough.Reflection{
		Text:       "Today, you reach toward what is unfamiliar.",
		TemplateID: "m1-stub.v1",
	}, nil
}

// newPlaythroughSuite builds a fully-wired mux + a session cookie + the
// fakes the tests want to assert against. The Portrait + Reflection
// generators are wired by default; tests that need the unwired path
// use newPlaythroughSuiteWithoutML.
func newPlaythroughSuite(t *testing.T, usersRepo *fakeUsersRepo) (http.Handler, string, *fakeRepo) {
	t.Helper()
	mux, cookie, repo, _, _ := newPlaythroughSuiteFull(t, usersRepo, true)
	return mux, cookie, repo
}

// newPlaythroughSuiteFull is the underlying constructor exposed to tests
// that need to inspect the Portrait / Reflection fakes or run with the
// generators left unwired.
func newPlaythroughSuiteFull(
	t *testing.T,
	usersRepo *fakeUsersRepo,
	wireML bool,
) (http.Handler, string, *fakeRepo, *fakePortraitGen, *fakeReflectionGen) {
	t.Helper()
	// Kratos identity used by the session below. Any valid UUID works.
	identityID := uuid.New()
	kratosBody := `{
		"id": "session-abc",
		"active": true,
		"issued_at": "2026-05-21T10:00:00Z",
		"expires_at": "2030-01-01T00:00:00Z",
		"identity": {
			"id": "` + identityID.String() + `",
			"schema_id": "default",
			"created_at": "2026-01-01T00:00:00Z",
			"traits": {"email":"a@b.test","display_name":"A","birthdate":"1995-06-10"}
		}
	}`
	kratos := stubKratos(t, kratosBody)

	loader := &fakeContentLoader{seasons: map[string]content.Season{"season-001": fixtureSeason()}}
	contentSvc := content.NewService(loader)
	repo := newFakeRepo()
	scorer := &fakeScorer{
		out: playthrough.TraitVector{
			BigFive:    []float64{0.1, 0, 0, 0, 0},
			Schwartz:   make([]float64, 10),
			Attachment: []float64{0.2, 0, 0},
		},
	}
	ptSvc := playthrough.NewService(repo, contentSvc, scorer)
	var (
		portrait   *fakePortraitGen
		reflection *fakeReflectionGen
	)
	if wireML {
		portrait = &fakePortraitGen{}
		reflection = &fakeReflectionGen{}
		ptSvc.WithPortraitGenerator(portrait).WithReflectionGenerator(reflection)
	}

	kc := auth.NewKratosClient(kratos.URL, kratos.URL, nil)
	authSvc := auth.New(kc)

	if usersRepo.user.ID == uuid.Nil {
		usersRepo.user = auth.User{ID: uuid.New(), KratosIdentityID: identityID, AgeBand: auth.AgeBandAdult}
	}

	mux := NewMux(Dependencies{
		Logger:      slog.Default(),
		Auth:        authSvc,
		Content:     contentSvc,
		Playthrough: ptSvc,
		Users:       usersRepo,
	})

	return mux, "session-token", repo, portrait, reflection
}

func doJSON(t *testing.T, mux http.Handler, method, path, cookie string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		require.NoError(t, err)
		rdr = bytes.NewReader(b)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, rdr)
	req.Header.Set("Content-Type", "application/json")
	if cookie != "" {
		req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: cookie})
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

// --- Tests --------------------------------------------------------------

func TestCreatePlaythrough_HappyPath(t *testing.T) {
	users := &fakeUsersRepo{}
	mux, cookie, _ := newPlaythroughSuite(t, users)
	rec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})

	require.Equal(t, http.StatusCreated, rec.Code, rec.Body.String())
	var resp playthroughResponse
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &resp))
	require.Equal(t, "season-001", resp.Playthrough.SeasonID)
	require.Equal(t, 3, resp.Playthrough.SeasonVersion)
	require.Equal(t, 1, users.ensureCalls, "user provisioning should run exactly once")
	require.Equal(t, users.user.ID, resp.Playthrough.UserID)
}

func TestCreatePlaythrough_RequiresAuth(t *testing.T) {
	mux, _, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	rec := doJSON(t, mux, http.MethodPost, "/playthroughs", "", map[string]string{"season_id": "season-001"})
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

func TestCreatePlaythrough_UnknownSeason(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	rec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-bogus"})
	require.Equal(t, http.StatusNotFound, rec.Code)
}

// TestCreatePlaythrough_RejectsUnderage locks down the youth-safe path: if
// EnsureFromSession ever returns ErrUnderageIdentity (which it shouldn't,
// because Kratos rejects at registration), the handler must refuse to open
// a playthrough at all.
func TestCreatePlaythrough_RejectsUnderage(t *testing.T) {
	users := &fakeUsersRepo{ensureErr: auth.ErrUnderageIdentity}
	mux, cookie, _ := newPlaythroughSuite(t, users)
	rec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})
	require.Equal(t, http.StatusForbidden, rec.Code)
}

func TestRecordChoice_HappyPath(t *testing.T) {
	users := &fakeUsersRepo{}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})
	require.Equal(t, http.StatusCreated, createRec.Code)
	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))

	rec := doJSON(t, mux, http.MethodPost,
		"/playthroughs/"+created.Playthrough.ID.String()+"/choices",
		cookie,
		map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"},
	)
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	var resp choiceEventResponse
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &resp))
	require.Equal(t, "vignette-001", resp.ChoiceEvent.VignetteID)
	require.Equal(t, "choice-1", resp.ChoiceEvent.ChoiceID)
}

// TestRecordChoice_IdempotentRetry verifies the M1 sync story: a retry of
// the same call must succeed with the same body. This is what makes
// T-CLIENT-012 (offline → sync) safe.
func TestRecordChoice_IdempotentRetry(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})
	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))

	body := map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"}
	first := doJSON(t, mux, http.MethodPost, "/playthroughs/"+created.Playthrough.ID.String()+"/choices", cookie, body)
	second := doJSON(t, mux, http.MethodPost, "/playthroughs/"+created.Playthrough.ID.String()+"/choices", cookie, body)
	require.Equal(t, http.StatusOK, first.Code)
	require.Equal(t, http.StatusOK, second.Code)

	var firstResp, secondResp choiceEventResponse
	require.NoError(t, json.Unmarshal(first.Body.Bytes(), &firstResp))
	require.NoError(t, json.Unmarshal(second.Body.Bytes(), &secondResp))
	require.Equal(t, firstResp.ChoiceEvent.ID, secondResp.ChoiceEvent.ID, "retry returned a different row id")
}

// TestRecordChoice_ConflictOnDifferentChoice is the converse: a player
// cannot change their mind once a choice is committed.
func TestRecordChoice_ConflictOnDifferentChoice(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})
	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))
	id := created.Playthrough.ID.String()

	first := doJSON(t, mux, http.MethodPost, "/playthroughs/"+id+"/choices", cookie,
		map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"})
	require.Equal(t, http.StatusOK, first.Code)

	second := doJSON(t, mux, http.MethodPost, "/playthroughs/"+id+"/choices", cookie,
		map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-2"})
	require.Equal(t, http.StatusConflict, second.Code)
}

func TestRecordChoice_BadInputs(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})

	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie, map[string]string{"season_id": "season-001"})
	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))
	pid := created.Playthrough.ID.String()

	t.Run("invalid playthrough uuid", func(t *testing.T) {
		rec := doJSON(t, mux, http.MethodPost, "/playthroughs/not-a-uuid/choices", cookie,
			map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"})
		require.Equal(t, http.StatusBadRequest, rec.Code)
	})

	t.Run("missing fields", func(t *testing.T) {
		rec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+pid+"/choices", cookie, map[string]string{})
		require.Equal(t, http.StatusBadRequest, rec.Code)
	})

	t.Run("unknown vignette", func(t *testing.T) {
		rec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+pid+"/choices", cookie,
			map[string]string{"vignette_id": "vignette-999", "choice_id": "choice-1"})
		require.Equal(t, http.StatusBadRequest, rec.Code)
	})

	t.Run("unknown choice", func(t *testing.T) {
		rec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+pid+"/choices", cookie,
			map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-bogus"})
		require.Equal(t, http.StatusBadRequest, rec.Code)
	})

	t.Run("missing playthrough", func(t *testing.T) {
		rec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+uuid.New().String()+"/choices", cookie,
			map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"})
		require.Equal(t, http.StatusNotFound, rec.Code)
	})
}

// TestRecordChoice_Unauthenticated confirms the route is locked behind
// auth.Middleware: no cookie → 401.
func TestRecordChoice_Unauthenticated(t *testing.T) {
	mux, _, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	rec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+uuid.New().String()+"/choices", "",
		map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"})
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

// TestCreatePlaythrough_NoFakesNeeded_NilDeps documents that the
// playthrough routes are absent when the dependencies aren't wired —
// useful for environments that haven't been provisioned yet.
func TestPlaythroughRoutes_Disabled(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	rec := doJSON(t, mux, http.MethodPost, "/playthroughs", "", map[string]string{"season_id": "season-001"})
	require.Equal(t, http.StatusNotFound, rec.Code)
}

// Sanity: ensure the test for ErrChoiceConflict surface is wired through
// to the right HTTP status (catch regressions where someone returns 500).
func TestRecordChoice_ErrChoiceConflict_Symbol(t *testing.T) {
	require.True(t, errors.Is(playthrough.ErrChoiceConflict, playthrough.ErrChoiceConflict))
}

// --- Finalize + trait vector ----------------------------------------------

func TestFinalize_HappyPath(t *testing.T) {
	users := &fakeUsersRepo{}
	mux, cookie, _ := newPlaythroughSuite(t, users)

	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie,
		map[string]string{"season_id": "season-001"})
	require.Equal(t, http.StatusCreated, createRec.Code, createRec.Body.String())
	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))
	pid := created.Playthrough.ID.String()

	rec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+pid+"/choices", cookie,
		map[string]string{"vignette_id": "vignette-001", "choice_id": "choice-1"})
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())

	finRec := doJSON(t, mux, http.MethodPost, "/playthroughs/"+pid+"/finalize", cookie, nil)
	require.Equal(t, http.StatusOK, finRec.Code, finRec.Body.String())
	var fin traitVectorResponse
	require.NoError(t, json.Unmarshal(finRec.Body.Bytes(), &fin))
	require.Equal(t, created.Playthrough.ID, fin.TraitVector.PlaythroughID)
	require.Len(t, fin.TraitVector.BigFive, 5)
	require.Len(t, fin.TraitVector.Schwartz, 10)
	require.Len(t, fin.TraitVector.Attachment, 3)
	require.Equal(t, playthrough.ScoringVersionM1, fin.TraitVector.ScoringVersion)

	getRec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+pid+"/trait-vector", cookie, nil)
	require.Equal(t, http.StatusOK, getRec.Code, getRec.Body.String())
}

func TestFinalize_Incomplete(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	createRec := doJSON(t, mux, http.MethodPost, "/playthroughs", cookie,
		map[string]string{"season_id": "season-001"})
	var created playthroughResponse
	require.NoError(t, json.Unmarshal(createRec.Body.Bytes(), &created))

	finRec := doJSON(t, mux, http.MethodPost,
		"/playthroughs/"+created.Playthrough.ID.String()+"/finalize", cookie, nil)
	require.Equal(t, http.StatusConflict, finRec.Code)
}

func TestFinalize_NotFound(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	finRec := doJSON(t, mux, http.MethodPost,
		"/playthroughs/"+uuid.New().String()+"/finalize", cookie, nil)
	require.Equal(t, http.StatusNotFound, finRec.Code)
}

func TestFinalize_Unauthenticated(t *testing.T) {
	mux, _, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	finRec := doJSON(t, mux, http.MethodPost,
		"/playthroughs/"+uuid.New().String()+"/finalize", "", nil)
	require.Equal(t, http.StatusUnauthorized, finRec.Code)
}

func TestGetTraitVector_NotFound(t *testing.T) {
	mux, cookie, _ := newPlaythroughSuite(t, &fakeUsersRepo{})
	rec := doJSON(t, mux, http.MethodGet,
		"/playthroughs/"+uuid.New().String()+"/trait-vector", cookie, nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

// --- Portrait + Reflection endpoints (T-ML-020 / T-ML-021) ------------------

func TestGetPortrait_HappyPath(t *testing.T) {
	users := &fakeUsersRepo{}
	mux, cookie, repo, portrait, _ := newPlaythroughSuiteFull(t, users, true)

	pid := uuid.New()
	repo.vectors[pid] = playthrough.StoredTraitVector{
		PlaythroughID:  pid,
		BigFive:        []float64{0.1, 0, 0, 0, 0},
		Schwartz:       make([]float64, 10),
		Attachment:     []float64{0.2, 0, 0},
		ScoringVersion: playthrough.ScoringVersionM1,
		SeasonVersion:  7,
		CreatedAt:      time.Now(),
	}

	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+pid.String()+"/portrait", cookie, nil)
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	require.Equal(t, "image/png", rec.Header().Get("Content-Type"))
	require.Equal(t, "1", rec.Header().Get("X-Renderer-Version"))
	require.True(t, bytes.HasPrefix(rec.Body.Bytes(), []byte("\x89PNG")), "body should be PNG")
	require.True(t, portrait.called, "portrait generator must be invoked")
	require.Equal(t, pid.String(), portrait.in.PlaythroughID)
}

func TestGetPortrait_TraitVectorNotFound(t *testing.T) {
	mux, cookie, _, _, _ := newPlaythroughSuiteFull(t, &fakeUsersRepo{}, true)
	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+uuid.New().String()+"/portrait", cookie, nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

func TestGetPortrait_Unauthenticated(t *testing.T) {
	mux, _, _, _, _ := newPlaythroughSuiteFull(t, &fakeUsersRepo{}, true)
	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+uuid.New().String()+"/portrait", "", nil)
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

func TestGetPortrait_Unwired_Returns503(t *testing.T) {
	mux, cookie, repo, _, _ := newPlaythroughSuiteFull(t, &fakeUsersRepo{}, false)
	pid := uuid.New()
	repo.vectors[pid] = playthrough.StoredTraitVector{
		PlaythroughID: pid, BigFive: []float64{0, 0, 0, 0, 0},
		Schwartz: make([]float64, 10), Attachment: []float64{0, 0, 0},
		ScoringVersion: 1, SeasonVersion: 7, CreatedAt: time.Now(),
	}
	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+pid.String()+"/portrait", cookie, nil)
	require.Equal(t, http.StatusServiceUnavailable, rec.Code)
}

func TestGetReflection_HappyPath(t *testing.T) {
	users := &fakeUsersRepo{}
	mux, cookie, repo, _, reflection := newPlaythroughSuiteFull(t, users, true)

	pid := uuid.New()
	repo.vectors[pid] = playthrough.StoredTraitVector{
		PlaythroughID:  pid,
		BigFive:        []float64{0.9, 0, 0, 0, 0},
		Schwartz:       make([]float64, 10),
		Attachment:     []float64{0, 0, 0},
		ScoringVersion: playthrough.ScoringVersionM1,
		SeasonVersion:  7,
		CreatedAt:      time.Now(),
	}

	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+pid.String()+"/reflection", cookie, nil)
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())

	var resp reflectionResponse
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &resp))
	require.Contains(t, resp.Reflection.Text, "reach toward what is unfamiliar")
	require.Equal(t, "m1-stub.v1", resp.Reflection.TemplateID)
	require.False(t, resp.Reflection.UsedFallback)
	require.True(t, reflection.called)
	// HTTP handler currently sends youth_safe=true unconditionally
	// (M2 T-CORE-022 plumbs the real age band).
	require.True(t, reflection.in.YouthSafe)
}

func TestGetReflection_TraitVectorNotFound(t *testing.T) {
	mux, cookie, _, _, _ := newPlaythroughSuiteFull(t, &fakeUsersRepo{}, true)
	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+uuid.New().String()+"/reflection", cookie, nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

func TestGetReflection_Unauthenticated(t *testing.T) {
	mux, _, _, _, _ := newPlaythroughSuiteFull(t, &fakeUsersRepo{}, true)
	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+uuid.New().String()+"/reflection", "", nil)
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

func TestGetReflection_Unwired_Returns503(t *testing.T) {
	mux, cookie, repo, _, _ := newPlaythroughSuiteFull(t, &fakeUsersRepo{}, false)
	pid := uuid.New()
	repo.vectors[pid] = playthrough.StoredTraitVector{
		PlaythroughID: pid, BigFive: []float64{0, 0, 0, 0, 0},
		Schwartz: make([]float64, 10), Attachment: []float64{0, 0, 0},
		ScoringVersion: 1, SeasonVersion: 7, CreatedAt: time.Now(),
	}
	rec := doJSON(t, mux, http.MethodGet, "/playthroughs/"+pid.String()+"/reflection", cookie, nil)
	require.Equal(t, http.StatusServiceUnavailable, rec.Code)
}
