package http

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

func TestHealthzAlwaysOK(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	var body map[string]string
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "ok", body["status"])
}

func TestReadyzReturnsUnavailableWithoutDeps(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusServiceUnavailable, rec.Code)
	var body map[string]string
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "not_configured", body["postgres"])
	require.Equal(t, "not_configured", body["redis"])
}

// TestWhoamiReturns404WhenAuthDisabled documents the contract that the
// /whoami route is only registered when an auth.Service is wired. This
// matters because `go run ./cmd/core` boots without Kratos for unrelated
// work — a 401 from /whoami would be misleading in that mode.
func TestWhoamiReturns404WhenAuthDisabled(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusNotFound, rec.Code)
}

func TestWhoamiReturns401WithoutCookie(t *testing.T) {
	deps := Dependencies{
		Logger: slog.Default(),
		Auth:   auth.New(auth.NewKratosClient("http://127.0.0.1:1", "http://127.0.0.1:1", nil)),
	}
	mux := NewMux(deps)
	req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusUnauthorized, rec.Code)
}

// muxFakeUsers is a tiny in-memory UsersRepository for mux tests.
type muxFakeUsers struct {
	user      auth.User
	ensureErr error
}

func (f *muxFakeUsers) GetByKratosID(_ context.Context, _ uuid.UUID) (auth.User, error) {
	return f.user, nil
}
func (f *muxFakeUsers) GetByID(_ context.Context, _ uuid.UUID) (auth.User, error) {
	return f.user, nil
}
func (f *muxFakeUsers) EnsureFromSession(_ context.Context, _ auth.Session, _ time.Time) (auth.User, error) {
	if f.ensureErr != nil {
		return auth.User{}, f.ensureErr
	}
	return f.user, nil
}
func (f *muxFakeUsers) EnsureForKratosIdentity(_ context.Context, _ uuid.UUID, _ auth.AgeBand, _ time.Time) (auth.User, error) {
	return f.user, nil
}
func (f *muxFakeUsers) SoftDeleteByKratosID(_ context.Context, _ uuid.UUID, _ time.Time) error {
	return nil
}

// stubKratosWhoami returns an httptest server that responds to
// /sessions/whoami with the given identity id and birthdate.
func stubKratosWhoami(t *testing.T, identityID, birthdate string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/sessions/whoami", func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Cookie"), auth.KratosCookieName+"=") {
			http.Error(w, "missing cookie", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"id":"sess",
			"active":true,
			"issued_at":"2026-05-21T10:00:00Z",
			"expires_at":"2030-01-01T00:00:00Z",
			"identity":{"id":"` + identityID + `","traits":{"email":"a@x","display_name":"A","birthdate":"` + birthdate + `"}}
		}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestWhoami_IncludesAdultAgeBandAndYouthSafeFalse(t *testing.T) {
	id := uuid.New()
	srv := stubKratosWhoami(t, id.String(), "1990-01-15")
	users := &muxFakeUsers{user: auth.User{KratosIdentityID: id, AgeBand: auth.AgeBandAdult}}

	deps := Dependencies{
		Logger: slog.Default(),
		Auth:   auth.New(auth.NewKratosClient(srv.URL, srv.URL, nil)),
		Users:  users,
	}
	mux := NewMux(deps)
	req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "v"})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	var body map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "adult", body["age_band"])
	require.Equal(t, false, body["youth_safe"])
}

func TestWhoami_IncludesYouthAgeBandAndYouthSafeTrue(t *testing.T) {
	id := uuid.New()
	srv := stubKratosWhoami(t, id.String(), "2012-01-15")
	users := &muxFakeUsers{user: auth.User{KratosIdentityID: id, AgeBand: auth.AgeBandYouth}}

	deps := Dependencies{
		Logger: slog.Default(),
		Auth:   auth.New(auth.NewKratosClient(srv.URL, srv.URL, nil)),
		Users:  users,
	}
	mux := NewMux(deps)
	req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "v"})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	var body map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "youth", body["age_band"])
	require.Equal(t, true, body["youth_safe"])
}

func TestWhoami_DegradesGracefullyWhenUsersLookupFails(t *testing.T) {
	id := uuid.New()
	srv := stubKratosWhoami(t, id.String(), "1990-01-15")
	users := &muxFakeUsers{ensureErr: auth.ErrUserNotFound}

	deps := Dependencies{
		Logger: slog.Default(),
		Auth:   auth.New(auth.NewKratosClient(srv.URL, srv.URL, nil)),
		Users:  users,
	}
	mux := NewMux(deps)
	req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
	req.AddCookie(&http.Cookie{Name: auth.KratosCookieName, Value: "v"})
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
	var body map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	// age_band / youth_safe must be absent rather than nullish so the
	// client can tell apart "not provisioned yet" from "guaranteed adult".
	_, hasBand := body["age_band"]
	_, hasYouthSafe := body["youth_safe"]
	require.False(t, hasBand)
	require.False(t, hasYouthSafe)
}

func TestPreflight_RegisteredAtRouteLevel(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	req := httptest.NewRequest(http.MethodPost, "/auth/preflight",
		bytes.NewReader([]byte(`{"birthdate":"1990-01-15"}`)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)
}

func TestPreflight_NoAuthRequired(t *testing.T) {
	// /auth/preflight must work without any auth wiring — its whole
	// purpose is to support the registration UX before the user has any
	// session.
	mux := NewMux(Dependencies{Logger: slog.Default()})
	req := httptest.NewRequest(http.MethodPost, "/auth/preflight",
		bytes.NewReader([]byte(`{"birthdate":"2018-01-15"}`)))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	require.Equal(t, http.StatusOK, rec.Code)
	var body map[string]any
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, false, body["allowed"])
}

func TestHooks_NotMountedWithoutFullChain(t *testing.T) {
	// Hooks require Auth + Users; with neither wired they 404 instead of
	// 401 / 500, so a misconfigured Kratos can't accidentally hit a
	// half-built endpoint.
	mux := NewMux(Dependencies{Logger: slog.Default()})
	for _, path := range []string{"/auth/hooks/before-registration", "/auth/hooks/after-registration"} {
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader([]byte(`{}`)))
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		require.Equal(t, http.StatusNotFound, rec.Code, "path=%s", path)
	}
}

func TestDeleteMe_Returns401WithoutSession(t *testing.T) {
	deps := Dependencies{
		Logger: slog.Default(),
		Auth:   auth.New(auth.NewKratosClient("http://127.0.0.1:1", "http://127.0.0.1:1", nil)),
		Users:  &muxFakeUsers{},
	}
	mux := NewMux(deps)
	req := httptest.NewRequest(http.MethodDelete, "/me", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	require.Equal(t, http.StatusUnauthorized, rec.Code)
}
