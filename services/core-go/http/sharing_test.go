package http

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/sharing"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

// --- Sharing test fakes ----------------------------------------------------

// memShareRepo is an in-memory sharing.Repository for HTTP-layer tests.
// Distinct from the sharing package's memRepo (which lives in
// sharing_test.go and is package-private).
type memShareRepo struct {
	mu    sync.Mutex
	links map[string]sharing.Link
}

func newMemShareRepo() *memShareRepo {
	return &memShareRepo{links: map[string]sharing.Link{}}
}

func (r *memShareRepo) Insert(_ context.Context, l sharing.Link) (sharing.Link, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, dup := r.links[l.Token]; dup {
		return sharing.Link{}, errors.New("duplicate token")
	}
	if l.CreatedAt.IsZero() {
		l.CreatedAt = time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC)
	}
	r.links[l.Token] = l
	return l, nil
}

func (r *memShareRepo) GetByToken(_ context.Context, token string) (sharing.Link, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	l, ok := r.links[token]
	if !ok {
		return sharing.Link{}, sharing.ErrLinkNotFound
	}
	return l, nil
}

func (r *memShareRepo) Revoke(_ context.Context, token string, userID uuid.UUID, now time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	l, ok := r.links[token]
	if !ok {
		return sharing.ErrLinkNotFound
	}
	if l.UserID != userID {
		return sharing.ErrNotOwner
	}
	if l.RevokedAt != nil {
		return nil
	}
	t := now
	l.RevokedAt = &t
	r.links[token] = l
	return nil
}

func (r *memShareRepo) IncrementViewCount(_ context.Context, token string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	l, ok := r.links[token]
	if !ok {
		return sharing.ErrLinkNotFound
	}
	l.ViewCount++
	r.links[token] = l
	return nil
}

func (r *memShareRepo) ListByPlaythrough(_ context.Context, _ uuid.UUID) ([]sharing.Link, error) {
	return nil, nil
}

// fixedTokens hands out tokens from a slice. Hard-fails the test if
// drained — the suite is sized to never exhaust normally.
type fixedTokens struct {
	mu     sync.Mutex
	values []string
}

func (s *fixedTokens) NewToken() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.values) == 0 {
		return "", errors.New("fixed token source exhausted")
	}
	v := s.values[0]
	s.values = s.values[1:]
	return v, nil
}

// --- Suite scaffolding -----------------------------------------------------

// shareSuite wraps the wired mux + everything a test wants to poke.
type shareSuite struct {
	mux       http.Handler
	cookie    string
	repo      *fakeRepo
	shareRepo *memShareRepo
	users     *fakeUsersRepo
	pid       uuid.UUID
	userID    uuid.UUID
}

// newShareSuite stands up the full mux with a sharing.Service wired in.
// The playthrough is pre-finalized with a known trait vector so the
// public payload returns a real reflection.
func newShareSuite(t *testing.T, ageBand auth.AgeBand, tokens []string) shareSuite {
	t.Helper()

	identityID := uuid.New()
	userID := uuid.New()
	pid := uuid.New()
	completedAt := time.Date(2026, 5, 21, 9, 0, 0, 0, time.UTC)

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
	repo.playthroughs[pid] = playthrough.Playthrough{
		ID:            pid,
		UserID:        userID,
		SeasonID:      "season-001",
		SeasonVersion: 3,
		Status:        playthrough.StatusCompleted,
		StartedAt:     time.Date(2026, 5, 21, 8, 0, 0, 0, time.UTC),
		CompletedAt:   &completedAt,
		UpdatedAt:     completedAt,
	}
	repo.vectors[pid] = playthrough.StoredTraitVector{
		PlaythroughID:  pid,
		BigFive:        []float64{0.1, 0, 0, 0, 0},
		Schwartz:       make([]float64, 10),
		Attachment:     []float64{0.2, 0, 0},
		ScoringVersion: 1,
		SeasonVersion:  3,
		CreatedAt:      completedAt,
	}

	scorer := &fakeScorer{
		out: playthrough.TraitVector{
			BigFive:    []float64{0.1, 0, 0, 0, 0},
			Schwartz:   make([]float64, 10),
			Attachment: []float64{0.2, 0, 0},
		},
	}
	ptSvc := playthrough.NewService(repo, contentSvc, scorer).
		WithPortraitGenerator(&fakePortraitGen{}).
		WithReflectionGenerator(&fakeReflectionGen{})

	kc := auth.NewKratosClient(kratos.URL, kratos.URL, nil)
	authSvc := auth.New(kc)

	users := &fakeUsersRepo{user: auth.User{
		ID:               userID,
		KratosIdentityID: identityID,
		AgeBand:          ageBand,
	}}

	shareRepo := newMemShareRepo()
	shareSvc := sharing.New(sharing.Config{
		Repository:   shareRepo,
		Playthroughs: ptSvc,
		Users:        users,
		Tokens:       &fixedTokens{values: tokens},
		Now:          func() time.Time { return time.Date(2026, 5, 21, 12, 0, 0, 0, time.UTC) },
	})

	mux := NewMux(Dependencies{
		Logger:       slog.Default(),
		Auth:         authSvc,
		Content:      contentSvc,
		Playthrough:  ptSvc,
		Sharing:      shareSvc,
		Users:        users,
		ShareBaseURL: "https://share.echo.test",
		APIBaseURL:   "https://api.echo.test",
	})

	return shareSuite{
		mux:       mux,
		cookie:    "session-token",
		repo:      repo,
		shareRepo: shareRepo,
		users:     users,
		pid:       pid,
		userID:    userID,
	}
}

// --- POST /playthroughs/{id}/share ----------------------------------------

func TestCreateShare_AdultHappyPath(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-happy"})

	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	require.Equal(t, http.StatusCreated, rec.Code, rec.Body.String())

	var body shareCreateResponse
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "tok-happy", body.Token)
	require.Equal(t, s.pid.String(), body.PlaythroughID)
	require.Equal(t, "https://share.echo.test/share/tok-happy", body.ShareURL)
	require.Equal(t, "https://api.echo.test/share/tok-happy/portrait", body.PortraitPNGURL)
	require.Equal(t, "https://api.echo.test/share/tok-happy/portrait?format=webp", body.PortraitWebPURL)
	require.NotEmpty(t, body.CreatedAt)
	require.Contains(t, s.shareRepo.links, "tok-happy")
}

func TestCreateShare_YouthSafeForbidden(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandYouth, []string{"tok-x"})

	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	require.Equal(t, http.StatusForbidden, rec.Code, rec.Body.String())
	require.Empty(t, s.shareRepo.links, "youth share must not persist")
}

func TestCreateShare_RequiresAuth(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", "", nil)
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

func TestCreateShare_InvalidPlaythroughID(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/not-a-uuid/share", s.cookie, nil)
	require.Equal(t, http.StatusBadRequest, rec.Code)
}

func TestCreateShare_UnknownPlaythroughLooks404(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+uuid.New().String()+"/share", s.cookie, nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

func TestCreateShare_NotOwnerLooks404(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	// Repoint the playthrough to a different owner without telling the
	// users repo — this is exactly the non-owner case.
	p := s.repo.playthroughs[s.pid]
	p.UserID = uuid.New()
	s.repo.playthroughs[s.pid] = p

	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

func TestCreateShare_PlaythroughIncomplete(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	p := s.repo.playthroughs[s.pid]
	p.Status = playthrough.StatusInProgress
	p.CompletedAt = nil
	s.repo.playthroughs[s.pid] = p

	rec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	require.Equal(t, http.StatusConflict, rec.Code)
}

// --- GET /share/{token} (public) ------------------------------------------

func TestGetShare_PublicHappyPath(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-pub"})
	// First create the link.
	createRec := doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	require.Equal(t, http.StatusCreated, createRec.Code)

	// Then read it back as a fully unauthenticated client.
	pubRec := doJSON(t, s.mux, http.MethodGet, "/share/tok-pub", "", nil)
	require.Equal(t, http.StatusOK, pubRec.Code, pubRec.Body.String())

	var body sharePayload
	require.NoError(t, json.Unmarshal(pubRec.Body.Bytes(), &body))
	require.Equal(t, "tok-pub", body.Token)
	require.Equal(t, "https://share.echo.test/share/tok-pub", body.ShareURL)
	require.Equal(t, "https://api.echo.test/share/tok-pub/portrait", body.PortraitPNG)
	require.Equal(t, "https://api.echo.test/share/tok-pub/portrait?format=webp", body.PortraitWebP)
	require.NotEmpty(t, body.Reflection.Text)
	require.True(t, strings.HasPrefix(body.PortraitPNG, "https://"))
}

func TestGetShare_PublicNoAuthNeeded(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-anon"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)

	// No cookie at all.
	rec := doJSON(t, s.mux, http.MethodGet, "/share/tok-anon", "", nil)
	require.Equal(t, http.StatusOK, rec.Code)
}

func TestGetShare_NotFound(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	rec := doJSON(t, s.mux, http.MethodGet, "/share/does-not-exist", "", nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

func TestGetShare_RevokedReturns410(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-rev"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	delRec := doJSON(t, s.mux, http.MethodDelete, "/share/tok-rev", s.cookie, nil)
	require.Equal(t, http.StatusNoContent, delRec.Code)

	pubRec := doJSON(t, s.mux, http.MethodGet, "/share/tok-rev", "", nil)
	require.Equal(t, http.StatusGone, pubRec.Code, "revoked link must return 410 Gone")
}

// --- GET /share/{token}/portrait (public) ---------------------------------

func TestGetSharePortrait_PNG(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-img"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)

	rec := doJSON(t, s.mux, http.MethodGet, "/share/tok-img/portrait", "", nil)
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	require.Equal(t, "image/png", rec.Header().Get("Content-Type"))
	require.NotEmpty(t, rec.Body.Bytes())
}

func TestGetSharePortrait_WebP(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-anim"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)

	rec := doJSON(t, s.mux, http.MethodGet, "/share/tok-anim/portrait?format=webp", "", nil)
	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	// Animated WebP is best-effort: the fake portrait gen may not emit
	// AnimatedWebP, so we accept either webp or png content-type but
	// must always have a successful body.
	ct := rec.Header().Get("Content-Type")
	require.Contains(t, []string{"image/webp", "image/png"}, ct)
}

func TestGetSharePortrait_RevokedReturns410(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-img-r"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)
	_ = doJSON(t, s.mux, http.MethodDelete, "/share/tok-img-r", s.cookie, nil)

	rec := doJSON(t, s.mux, http.MethodGet, "/share/tok-img-r/portrait", "", nil)
	require.Equal(t, http.StatusGone, rec.Code)
}

// --- DELETE /share/{token} ------------------------------------------------

func TestRevokeShare_HappyPath(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-del"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)

	rec := doJSON(t, s.mux, http.MethodDelete, "/share/tok-del", s.cookie, nil)
	require.Equal(t, http.StatusNoContent, rec.Code)
	require.NotNil(t, s.shareRepo.links["tok-del"].RevokedAt)
}

func TestRevokeShare_Idempotent(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-del2"})
	_ = doJSON(t, s.mux, http.MethodPost,
		"/playthroughs/"+s.pid.String()+"/share", s.cookie, nil)

	rec1 := doJSON(t, s.mux, http.MethodDelete, "/share/tok-del2", s.cookie, nil)
	require.Equal(t, http.StatusNoContent, rec1.Code)
	rec2 := doJSON(t, s.mux, http.MethodDelete, "/share/tok-del2", s.cookie, nil)
	require.Equal(t, http.StatusNoContent, rec2.Code, "second delete must be no-op")
}

func TestRevokeShare_RequiresAuth(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	rec := doJSON(t, s.mux, http.MethodDelete, "/share/tok-x", "", nil)
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

func TestRevokeShare_NotFound(t *testing.T) {
	s := newShareSuite(t, auth.AgeBandAdult, []string{"tok-x"})
	rec := doJSON(t, s.mux, http.MethodDelete, "/share/never-existed", s.cookie, nil)
	require.Equal(t, http.StatusNotFound, rec.Code)
}
