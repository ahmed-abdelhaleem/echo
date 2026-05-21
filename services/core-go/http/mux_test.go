package http

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
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
