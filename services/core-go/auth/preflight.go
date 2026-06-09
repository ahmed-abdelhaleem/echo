package auth

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"
)

// PreflightRequest is the body the client POSTs to `/auth/preflight` to
// validate a birthdate against the age gate before submitting the
// registration form to Kratos. The endpoint is a UX nicety: it gives the
// client instant feedback so the user does not type a full registration
// form only to be rejected at submit time.
//
// The hard rule still lives in the Kratos before-registration hook
// (handled by [BeforeRegistrationHandler]); preflight is advisory.
type PreflightRequest struct {
	Birthdate string `json:"birthdate"`
}

// PreflightResponse is the JSON body returned by `/auth/preflight`.
type PreflightResponse struct {
	Allowed bool    `json:"allowed"`
	Band    AgeBand `json:"band,omitempty"`
	Reason  string  `json:"reason,omitempty"`
}

// PreflightHandler returns an HTTP handler that runs [EvaluateAgeGate]
// against the supplied birthdate.
//
// Response shapes:
//   - 200 + {allowed: true, band: "youth"|"adult"}   - applicant may proceed
//   - 200 + {allowed: false, reason: "..."}          - under-13, hard-denied
//   - 400 + {error: "invalid request"}               - body malformed
//   - 400 + {error: "invalid birthdate ..."}         - birthdate unparseable
//
// The endpoint is intentionally unauthenticated: registration users do not
// have a session yet. The handler reveals no data about existing
// identities; it only echoes the supplied birthdate's classification.
func PreflightHandler(now func() time.Time) http.HandlerFunc {
	if now == nil {
		now = time.Now
	}
	return func(w http.ResponseWriter, r *http.Request) {
		var req PreflightRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writePreflightError(w, http.StatusBadRequest, "invalid request")
			return
		}

		decision, err := EvaluateAgeGate(req.Birthdate, now())
		if err != nil {
			if errors.Is(err, ErrInvalidBirthdate) {
				writePreflightError(w, http.StatusBadRequest, "invalid birthdate; expected yyyy-mm-dd")
				return
			}
			writePreflightError(w, http.StatusInternalServerError, "preflight failed")
			return
		}

		resp := PreflightResponse{Allowed: decision.Allowed}
		if decision.Allowed {
			resp.Band = decision.Band
		} else {
			resp.Reason = decision.Reason
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

func writePreflightError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// writeJSON is a tiny helper local to this package so the auth handlers do
// not depend on `net/http` siblings. Mirrors the helper in
// `services/core-go/http/mux.go` but staying out of that package avoids an
// import cycle.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
