package content_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
)

// countingLoader records how many times LoadSeason is hit. Used to assert
// the Service's cache short-circuits repeated reads.
type countingLoader struct {
	calls atomic.Int32
	out   content.Season
	err   error
}

func (l *countingLoader) LoadSeason(_ context.Context, _ string) (content.Season, error) {
	l.calls.Add(1)
	return l.out, l.err
}

func (l *countingLoader) ListSeasonIDs(_ context.Context) ([]string, error) {
	return nil, nil
}

func TestService_GetSeason_CachesAfterFirstHit(t *testing.T) {
	t.Parallel()
	l := &countingLoader{out: content.Season{ID: "season-001", Title: "x"}}
	svc := content.NewService(l)

	for i := 0; i < 5; i++ {
		got, err := svc.GetSeason(context.Background(), "season-001")
		if err != nil {
			t.Fatalf("GetSeason: %v", err)
		}
		if got.ID != "season-001" {
			t.Fatalf("got %q", got.ID)
		}
	}
	if l.calls.Load() != 1 {
		t.Errorf("expected loader called exactly once, got %d", l.calls.Load())
	}
}

func TestService_GetSeason_DoesNotCacheErrors(t *testing.T) {
	t.Parallel()
	l := &countingLoader{err: content.ErrSeasonNotFound}
	svc := content.NewService(l)

	for i := 0; i < 3; i++ {
		_, err := svc.GetSeason(context.Background(), "season-missing")
		if !errors.Is(err, content.ErrSeasonNotFound) {
			t.Fatalf("expected ErrSeasonNotFound, got %v", err)
		}
	}
	// Errors must NOT poison the cache — every miss should re-hit the
	// loader so that a season added between reads becomes visible.
	if l.calls.Load() != 3 {
		t.Errorf("expected loader called every time on error, got %d", l.calls.Load())
	}
}
