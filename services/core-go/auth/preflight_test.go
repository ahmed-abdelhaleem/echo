package auth_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
)

func fixedNow() time.Time {
	// Pinned clock so age math is deterministic across CI runs. Anyone
	// born after 2013-06-15 is under-13 in this universe.
	return time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
}

func doPreflight(t *testing.T, body any) (*httptest.ResponseRecorder, auth.PreflightResponse, map[string]string) {
	t.Helper()
	buf, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/auth/preflight", bytes.NewReader(buf))
	rec := httptest.NewRecorder()
	auth.PreflightHandler(fixedNow)(rec, req)

	if rec.Body.Len() == 0 {
		return rec, auth.PreflightResponse{}, nil
	}
	// First try the success shape, fall back to the error shape.
	var ok auth.PreflightResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &ok)
	var errBody map[string]string
	_ = json.Unmarshal(rec.Body.Bytes(), &errBody)
	return rec, ok, errBody
}

// T-CORE-021 acceptance: integration tests cover all three age branches.
// The three branches exercised here are: under-13 (denied), 13–17 (youth),
// 18+ (adult).

func TestPreflight_AdultAllowed(t *testing.T) {
	t.Parallel()
	rec, ok, _ := doPreflight(t, auth.PreflightRequest{Birthdate: "1990-01-15"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", rec.Code)
	}
	if !ok.Allowed {
		t.Errorf("Allowed: got false, want true")
	}
	if ok.Band != auth.AgeBandAdult {
		t.Errorf("Band: got %q, want %q", ok.Band, auth.AgeBandAdult)
	}
	if ok.Reason != "" {
		t.Errorf("Reason: got %q, want empty for allowed", ok.Reason)
	}
}

func TestPreflight_YouthAllowed(t *testing.T) {
	t.Parallel()
	// 14 years old at the pinned clock.
	rec, ok, _ := doPreflight(t, auth.PreflightRequest{Birthdate: "2012-01-15"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", rec.Code)
	}
	if !ok.Allowed {
		t.Errorf("Allowed: got false, want true")
	}
	if ok.Band != auth.AgeBandYouth {
		t.Errorf("Band: got %q, want %q", ok.Band, auth.AgeBandYouth)
	}
}

func TestPreflight_Under13Denied(t *testing.T) {
	t.Parallel()
	// 8 years old at the pinned clock.
	rec, ok, _ := doPreflight(t, auth.PreflightRequest{Birthdate: "2018-01-15"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200 (200 is the deny shape, body carries allowed=false)", rec.Code)
	}
	if ok.Allowed {
		t.Errorf("Allowed: got true, want false for under-13")
	}
	if ok.Reason == "" {
		t.Error("Reason: expected a non-empty denial reason for under-13")
	}
	// Reason must not echo the applicant's age (privacy-safe).
	if got := ok.Reason; got == "" || (got != "" && containsAge(got)) {
		// containsAge returns false for the canonical reason
		t.Errorf("Reason should not reveal age, got %q", got)
	}
}

// containsAge is a tiny check that the reason does not include digits 0-9.
// The canonical Echo reason ("Echo is not available to users under 13.")
// contains "13" by design, which is the threshold not the applicant's age.
// We accept that single substring but reject anything that looks like a
// dynamic age.
func containsAge(s string) bool {
	// allow "under 13" as the canonical line
	if s == "Echo is not available to users under 13." {
		return false
	}
	for _, r := range s {
		if r >= '0' && r <= '9' {
			return true
		}
	}
	return false
}

func TestPreflight_InvalidBirthdateRejected(t *testing.T) {
	t.Parallel()
	rec, _, errBody := doPreflight(t, auth.PreflightRequest{Birthdate: "not-a-date"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400", rec.Code)
	}
	if errBody["error"] == "" {
		t.Error("error: expected a non-empty error message")
	}
}

func TestPreflight_EmptyBirthdateRejected(t *testing.T) {
	t.Parallel()
	rec, _, errBody := doPreflight(t, auth.PreflightRequest{Birthdate: ""})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400", rec.Code)
	}
	if errBody["error"] == "" {
		t.Error("error: expected a non-empty error message")
	}
}

func TestPreflight_FutureBirthdateRejected(t *testing.T) {
	t.Parallel()
	rec, _, errBody := doPreflight(t, auth.PreflightRequest{Birthdate: "2030-01-15"})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400", rec.Code)
	}
	if errBody["error"] == "" {
		t.Error("error: expected a non-empty error message")
	}
}

func TestPreflight_MalformedJSONRejected(t *testing.T) {
	t.Parallel()
	req := httptest.NewRequest(http.MethodPost, "/auth/preflight", bytes.NewReader([]byte("not json")))
	rec := httptest.NewRecorder()
	auth.PreflightHandler(fixedNow)(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status: got %d, want 400", rec.Code)
	}
}

func TestPreflight_NilNowFallsBackToTimeNow(t *testing.T) {
	t.Parallel()
	// Sanity check that the handler doesn't panic when constructed with
	// a nil now func — the production wiring passes time.Now and we
	// should not require callers to remember.
	h := auth.PreflightHandler(nil)
	req := httptest.NewRequest(http.MethodPost, "/auth/preflight",
		bytes.NewReader([]byte(`{"birthdate":"1990-01-01"}`)))
	rec := httptest.NewRecorder()
	h(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status: got %d, want 200", rec.Code)
	}
}
