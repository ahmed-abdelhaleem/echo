package http

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
)

func Test_isLocalhostDevOrigin(t *testing.T) {
	t.Parallel()
	require.True(t, isLocalhostDevOrigin("http://localhost:50087"))
	require.True(t, isLocalhostDevOrigin("http://127.0.0.1:8081"))
	require.False(t, isLocalhostDevOrigin("http://evil.example:50087"))
	require.False(t, isLocalhostDevOrigin("not-a-url"))
}

func TestCORSMiddleware_allowsLocalhostOrigin(t *testing.T) {
	t.Parallel()

	var hit bool
	h := CORSMiddleware(CORSOptions{AllowLocalhost: true, AllowCredentials: true})(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hit = true
			w.WriteHeader(http.StatusOK)
		}),
	)

	req := httptest.NewRequest(http.MethodGet, "/content/seasons/season-001", nil)
	req.Header.Set("Origin", "http://localhost:50087")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	require.True(t, hit)
	require.Equal(t, http.StatusOK, rec.Code)
	require.Equal(t, "http://localhost:50087", rec.Header().Get("Access-Control-Allow-Origin"))
	require.Equal(t, "true", rec.Header().Get("Access-Control-Allow-Credentials"))
}

func TestCORSMiddleware_optionsPreflight(t *testing.T) {
	t.Parallel()

	h := CORSMiddleware(CORSOptions{AllowLocalhost: true})(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			t.Fatal("preflight should not reach handler")
		}),
	)

	req := httptest.NewRequest(http.MethodOptions, "/content/seasons/season-001", nil)
	req.Header.Set("Origin", "http://localhost:50087")
	req.Header.Set("Access-Control-Request-Method", "GET")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	require.Equal(t, http.StatusNoContent, rec.Code)
	require.Equal(t, "http://localhost:50087", rec.Header().Get("Access-Control-Allow-Origin"))
	require.Contains(t, rec.Header().Get("Access-Control-Allow-Headers"), "X-Session-Token")
}

func TestCORSMiddleware_noOriginPassesThrough(t *testing.T) {
	t.Parallel()

	var hit bool
	h := CORSMiddleware(CORSOptions{AllowLocalhost: true})(
		http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			hit = true
		}),
	)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	require.True(t, hit)
	require.Empty(t, rec.Header().Get("Access-Control-Allow-Origin"))
}
