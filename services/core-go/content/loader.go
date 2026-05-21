package content

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// ErrSeasonNotFound is returned when GetSeason is called with an id that
// does not exist in the configured content root.
var ErrSeasonNotFound = errors.New("content: season not found")

// Loader reads a Season by id. Implementations are expected to be safe for
// concurrent use; the in-process Service caches loaded Seasons so a Loader
// only sees a request per (id, cold cache) combination.
type Loader interface {
	LoadSeason(ctx context.Context, id string) (Season, error)
	ListSeasonIDs(ctx context.Context) ([]string, error)
}

// FilesystemLoader reads Seasons from a directory laid out as
//
//	<root>/seasons/<season-id>/season.json
//
// matching the layout under /content/ in this repo. The root is passed in
// so tests can point at a temp directory.
type FilesystemLoader struct {
	root string
}

// NewFilesystemLoader returns a FilesystemLoader rooted at the given path.
// The path is not validated here; the first LoadSeason / ListSeasonIDs
// call surfaces any IO errors.
func NewFilesystemLoader(root string) *FilesystemLoader {
	return &FilesystemLoader{root: root}
}

// LoadSeason reads <root>/seasons/<id>/season.json and decodes it into a
// Season. The id is validated as a path component (no slashes) to prevent
// directory traversal.
func (l *FilesystemLoader) LoadSeason(_ context.Context, id string) (Season, error) {
	if err := validateSeasonID(id); err != nil {
		return Season{}, err
	}
	path := filepath.Join(l.root, "seasons", id, "season.json")
	data, err := os.ReadFile(path) //nolint:gosec // id is validated above
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Season{}, fmt.Errorf("%w: %s", ErrSeasonNotFound, id)
		}
		return Season{}, fmt.Errorf("content: read %s: %w", path, err)
	}
	var s Season
	if err := json.Unmarshal(data, &s); err != nil {
		return Season{}, fmt.Errorf("content: decode %s: %w", path, err)
	}
	if s.ID != id {
		return Season{}, fmt.Errorf("content: season id mismatch in %s: file declares %q, requested %q", path, s.ID, id)
	}
	return s, nil
}

// ListSeasonIDs returns every season id present under <root>/seasons/.
// Hidden entries (dotfiles) are skipped. Returns an empty slice (not nil)
// when the directory exists but is empty.
func (l *FilesystemLoader) ListSeasonIDs(_ context.Context) ([]string, error) {
	dir := filepath.Join(l.root, "seasons")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("content: read seasons dir %s: %w", dir, err)
	}
	ids := make([]string, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() || name == "" || name[0] == '.' {
			continue
		}
		ids = append(ids, name)
	}
	return ids, nil
}

// validateSeasonID rejects ids that are empty, absolute, or contain path
// separators. This is the only sanitisation needed because the id is
// joined into a path; everything else (pattern, charset) is enforced by
// the content-validator at author time.
func validateSeasonID(id string) error {
	if id == "" {
		return fmt.Errorf("%w: empty id", ErrSeasonNotFound)
	}
	if filepath.IsAbs(id) {
		return fmt.Errorf("%w: id %q must be relative", ErrSeasonNotFound, id)
	}
	if filepath.Base(id) != id {
		return fmt.Errorf("%w: id %q must be a bare path component", ErrSeasonNotFound, id)
	}
	return nil
}
