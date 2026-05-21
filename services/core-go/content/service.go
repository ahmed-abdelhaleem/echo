package content

import (
	"context"
	"sync"
)

// Service is the in-process content domain. It wraps a Loader with a small
// read-through cache keyed by season id.
//
// Cache invalidation: Seasons are content-versioned (Season.Version is
// incremented on republish) and the file path is keyed by id, so we never
// need to evict in-process — the next deploy starts with a cold cache.
// If hot-reload becomes a need we can attach an inotify-style watcher.
type Service struct {
	loader Loader

	mu    sync.RWMutex
	cache map[string]Season
}

// NewService returns a Service backed by the given Loader.
func NewService(loader Loader) *Service {
	return &Service{
		loader: loader,
		cache:  make(map[string]Season),
	}
}

// GetSeason returns the Season with the given id, falling through the cache
// if necessary. ErrSeasonNotFound is returned for unknown ids; any other
// error indicates a transient or content-broken condition (caller decides
// whether to retry).
func (s *Service) GetSeason(ctx context.Context, id string) (Season, error) {
	s.mu.RLock()
	if cached, ok := s.cache[id]; ok {
		s.mu.RUnlock()
		return cached, nil
	}
	s.mu.RUnlock()

	season, err := s.loader.LoadSeason(ctx, id)
	if err != nil {
		return Season{}, err
	}

	s.mu.Lock()
	s.cache[id] = season
	s.mu.Unlock()
	return season, nil
}

// ListSeasonIDs returns every season id the loader knows about. The result
// is not cached; the directory listing is cheap.
func (s *Service) ListSeasonIDs(ctx context.Context) ([]string, error) {
	return s.loader.ListSeasonIDs(ctx)
}
