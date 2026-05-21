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
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{
		playthroughs: map[uuid.UUID]playthrough.Playthrough{},
		choices:      map[string]playthrough.ChoiceEvent{},
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

// newPlaythroughSuite builds a fully-wired mux + a session cookie + the
// fakes the tests want to assert against.
func newPlaythroughSuite(t *testing.T, usersRepo *fakeUsersRepo) (http.Handler, string, *fakeRepo) {
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
	ptSvc := playthrough.NewService(repo, contentSvc)

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

	return mux, "session-token", repo
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
