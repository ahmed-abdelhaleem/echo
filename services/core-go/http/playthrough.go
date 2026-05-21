package http

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/google/uuid"
)

// createPlaythroughRequest is the JSON body for POST /playthroughs.
type createPlaythroughRequest struct {
	SeasonID string `json:"season_id"`
}

type playthroughResponse struct {
	Playthrough playthrough.Playthrough `json:"playthrough"`
}

// createPlaythroughHandler returns a handler that opens a new playthrough
// for the authenticated user. The session is taken from the request
// context (set by auth.Middleware); the auth.users row is provisioned
// here so first-time players can immediately start playing.
func createPlaythroughHandler(svc *playthrough.Service, users auth.UsersRepository, now func() time.Time) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}

		var body createPlaythroughRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.SeasonID == "" {
			writeJSONError(w, http.StatusBadRequest, "season_id required")
			return
		}

		user, err := users.EnsureFromSession(r.Context(), sess, now())
		switch {
		case errors.Is(err, auth.ErrUnderageIdentity):
			// Defense-in-depth: under-13 should be rejected at Kratos
			// registration. If we ever see one here it's a bug
			// somewhere upstream; surface it as 403 and refuse to
			// open the playthrough.
			writeJSONError(w, http.StatusForbidden, "ineligible")
			return
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		p, err := svc.CreatePlaythrough(r.Context(), user.ID, body.SeasonID)
		switch {
		case errors.Is(err, playthrough.ErrInvalidSeason):
			writeJSONError(w, http.StatusNotFound, "season not found")
			return
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "create playthrough failed")
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(playthroughResponse{Playthrough: p})
	}
}

// recordChoiceRequest is the JSON body for POST /playthroughs/{id}/choices.
type recordChoiceRequest struct {
	VignetteID      string     `json:"vignette_id"`
	ChoiceID        string     `json:"choice_id"`
	ClientTimestamp *time.Time `json:"client_timestamp,omitempty"`
	DeliberationMS  *int       `json:"deliberation_ms,omitempty"`
}

type choiceEventResponse struct {
	ChoiceEvent playthrough.ChoiceEvent `json:"choice_event"`
}

// recordChoiceHandler returns a handler that records a single choice on
// a playthrough. The (playthrough_id, vignette_id) pair is the natural
// idempotency key: the same call with the same choice id returns the
// existing row (200); a call with a different choice id is rejected (409).
//
// We don't check that the playthrough belongs to the authed user here in
// the M1 slice — that comes with T-CORE-022 (M2 auth tightening), and is
// flagged in code review and the PR description so it isn't forgotten.
func recordChoiceHandler(svc *playthrough.Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if _, ok := auth.SessionFromContext(r.Context()); !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}

		idStr := r.PathValue("id")
		playthroughID, err := uuid.Parse(idStr)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid playthrough id")
			return
		}

		var body recordChoiceRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.VignetteID == "" || body.ChoiceID == "" {
			writeJSONError(w, http.StatusBadRequest, "vignette_id and choice_id required")
			return
		}

		ev, err := svc.RecordChoice(r.Context(), playthrough.RecordChoiceInput{
			PlaythroughID:   playthroughID,
			VignetteID:      body.VignetteID,
			ChoiceID:        body.ChoiceID,
			ClientTimestamp: body.ClientTimestamp,
			DeliberationMS:  body.DeliberationMS,
		})
		switch {
		case errors.Is(err, playthrough.ErrNotFound):
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, playthrough.ErrInvalidVignette):
			writeJSONError(w, http.StatusBadRequest, "vignette not in season")
			return
		case errors.Is(err, playthrough.ErrInvalidChoice):
			writeJSONError(w, http.StatusBadRequest, "choice not in vignette")
			return
		case errors.Is(err, playthrough.ErrChoiceConflict):
			writeJSONError(w, http.StatusConflict, "choice already recorded with a different value")
			return
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "record choice failed")
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(choiceEventResponse{ChoiceEvent: ev})
	}
}
