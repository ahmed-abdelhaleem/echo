package auth_test

import (
	"errors"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
)

func TestEvaluateAgeGate_Under13Denied(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.May, 21, 0, 0, 0, 0, time.UTC)

	tests := []struct {
		name      string
		birthdate string
	}{
		{"twelve_yo", "2013-06-01"},                // turns 13 in two weeks
		{"twelve_yo_one_day_short", "2013-05-22"},  // turns 13 tomorrow
		{"day_before_13th_birthday", "2013-05-22"}, // explicit boundary
		{"newborn", "2026-05-20"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			d, err := auth.EvaluateAgeGate(tc.birthdate, now)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if d.Allowed {
				t.Errorf("expected denial for birthdate %q, got Allowed=true", tc.birthdate)
			}
			if d.Reason == "" {
				t.Error("expected a non-empty Reason")
			}
		})
	}
}

func TestEvaluateAgeGate_Youth(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.May, 21, 0, 0, 0, 0, time.UTC)

	tests := []struct{ name, birthdate string }{
		{"thirteen_today", "2013-05-21"},
		{"sixteen", "2010-05-21"},
		{"seventeen_yo_day_before_18", "2008-05-22"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			d, err := auth.EvaluateAgeGate(tc.birthdate, now)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !d.Allowed || d.Band != auth.AgeBandYouth {
				t.Errorf("birthdate %q: got %+v, want youth allowed", tc.birthdate, d)
			}
		})
	}
}

func TestEvaluateAgeGate_Adult(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.May, 21, 0, 0, 0, 0, time.UTC)

	tests := []struct{ name, birthdate string }{
		{"eighteen_today", "2008-05-21"},
		{"thirty", "1996-05-21"},
		{"old", "1940-01-01"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			d, err := auth.EvaluateAgeGate(tc.birthdate, now)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !d.Allowed || d.Band != auth.AgeBandAdult {
				t.Errorf("birthdate %q: got %+v, want adult allowed", tc.birthdate, d)
			}
		})
	}
}

func TestEvaluateAgeGate_InvalidBirthdate(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, time.May, 21, 0, 0, 0, 0, time.UTC)

	tests := []struct{ name, birthdate string }{
		{"empty", ""},
		{"garbage", "not-a-date"},
		{"wrong_format", "21/05/2010"},
		{"future", "2030-01-01"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := auth.EvaluateAgeGate(tc.birthdate, now)
			if !errors.Is(err, auth.ErrInvalidBirthdate) {
				t.Errorf("birthdate %q: expected ErrInvalidBirthdate, got %v", tc.birthdate, err)
			}
		})
	}
}
