package http

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/stretchr/testify/require"
)

func seedSeason(t *testing.T, tmpRoot string) {
	t.Helper()
	dir := filepath.Join(tmpRoot, "seasons", "season-001")
	require.NoError(t, os.MkdirAll(dir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "season.json"), []byte(`{
		"id": "season-001",
		"title": "Test Season",
		"locale": "en-GB",
		"version": 1,
		"acts": [
			{"id":"act-01","name":"Morning","vignettes":[]},
			{"id":"act-02","name":"Midday","vignettes":[]},
			{"id":"act-03","name":"Afternoon","vignettes":[]},
			{"id":"act-04","name":"Evening","vignettes":[]}
		]
	}`), 0o600))
}

func newContentMux(t *testing.T) http.Handler {
	t.Helper()
	tmp := t.TempDir()
	seedSeason(t, tmp)
	svc := content.NewService(content.NewFilesystemLoader(tmp))
	return NewMux(Dependencies{Logger: slog.Default(), Content: svc})
}

func TestGetSeason_HappyPath(t *testing.T) {
	mux := newContentMux(t)
	req := httptest.NewRequest(http.MethodGet, "/content/seasons/season-001", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	require.Equal(t, http.StatusOK, rec.Code)
	require.Equal(t, "application/json", rec.Header().Get("Content-Type"))
	require.NotEmpty(t, rec.Header().Get("Cache-Control"))

	var body struct {
		Season content.Season `json:"season"`
	}
	require.NoError(t, json.Unmarshal(rec.Body.Bytes(), &body))
	require.Equal(t, "season-001", body.Season.ID)
	require.Len(t, body.Season.Acts, 4)
}

func TestGetSeason_NotFound(t *testing.T) {
	mux := newContentMux(t)
	req := httptest.NewRequest(http.MethodGet, "/content/seasons/season-missing", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	require.Equal(t, http.StatusNotFound, rec.Code)
}

// TestGetSeason_Disabled documents the contract that the content route is
// only registered when a Service is wired. Boot the mux without Content
// and confirm the route is absent.
func TestGetSeason_Disabled(t *testing.T) {
	mux := NewMux(Dependencies{Logger: slog.Default()})
	req := httptest.NewRequest(http.MethodGet, "/content/seasons/season-001", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	require.Equal(t, http.StatusNotFound, rec.Code)
}
