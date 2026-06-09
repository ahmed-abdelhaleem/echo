package content_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
)

// writeSeason writes a minimal valid season.json under tmpRoot/seasons/<id>/.
func writeSeason(t *testing.T, tmpRoot, id, body string) {
	t.Helper()
	dir := filepath.Join(tmpRoot, "seasons", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "season.json"), []byte(body), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestFilesystemLoader_LoadSeason_HappyPath(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	writeSeason(t, tmp, "season-001", `{
		"id": "season-001",
		"title": "Test",
		"locale": "en-GB",
		"version": 1,
		"acts": [
			{"id":"act-01","name":"Morning","vignettes":[]},
			{"id":"act-02","name":"Midday","vignettes":[]},
			{"id":"act-03","name":"Afternoon","vignettes":[]},
			{"id":"act-04","name":"Evening","vignettes":[]}
		]
	}`)

	l := content.NewFilesystemLoader(tmp)
	got, err := l.LoadSeason(context.Background(), "season-001")
	if err != nil {
		t.Fatalf("LoadSeason: %v", err)
	}
	if got.ID != "season-001" || got.Title != "Test" || got.Version != 1 {
		t.Errorf("decoded season mismatch: %+v", got)
	}
	if len(got.Acts) != 4 || got.Acts[0].Name != "Morning" {
		t.Errorf("acts mismatch: %+v", got.Acts)
	}
}

func TestFilesystemLoader_LoadSeason_NotFound(t *testing.T) {
	t.Parallel()
	l := content.NewFilesystemLoader(t.TempDir())
	_, err := l.LoadSeason(context.Background(), "season-999")
	if !errors.Is(err, content.ErrSeasonNotFound) {
		t.Errorf("expected ErrSeasonNotFound, got %v", err)
	}
}

func TestFilesystemLoader_LoadSeason_IDMismatch(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	writeSeason(t, tmp, "season-001", `{
		"id": "season-002",
		"title": "Wrong",
		"locale": "en-GB",
		"version": 1,
		"acts": []
	}`)
	l := content.NewFilesystemLoader(tmp)
	_, err := l.LoadSeason(context.Background(), "season-001")
	if err == nil {
		t.Fatal("expected id-mismatch error, got nil")
	}
}

// TestFilesystemLoader_LoadSeason_PathTraversal locks down the small but
// real exposure that loader.go consciously prevents: an id is used to build
// a filesystem path, so anything that's not a bare path component must be
// rejected to keep `../../etc/passwd`-style ids out of os.ReadFile.
func TestFilesystemLoader_LoadSeason_PathTraversal(t *testing.T) {
	t.Parallel()
	l := content.NewFilesystemLoader(t.TempDir())
	for _, bad := range []string{"", "/abs", "../escape", "season-001/extra"} {
		bad := bad
		t.Run(bad, func(t *testing.T) {
			t.Parallel()
			_, err := l.LoadSeason(context.Background(), bad)
			if !errors.Is(err, content.ErrSeasonNotFound) {
				t.Errorf("id %q: expected ErrSeasonNotFound, got %v", bad, err)
			}
		})
	}
}

func TestFilesystemLoader_ListSeasonIDs(t *testing.T) {
	t.Parallel()
	tmp := t.TempDir()
	writeSeason(t, tmp, "season-001", `{"id":"season-001","title":"a","locale":"en","version":1,"acts":[]}`)
	writeSeason(t, tmp, "season-002", `{"id":"season-002","title":"b","locale":"en","version":1,"acts":[]}`)
	// hidden + file should both be skipped
	if err := os.Mkdir(filepath.Join(tmp, "seasons", ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "seasons", "README.md"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	l := content.NewFilesystemLoader(tmp)
	ids, err := l.ListSeasonIDs(context.Background())
	if err != nil {
		t.Fatalf("ListSeasonIDs: %v", err)
	}
	if len(ids) != 2 {
		t.Errorf("expected 2 ids, got %v", ids)
	}
}
