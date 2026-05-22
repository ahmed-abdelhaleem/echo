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

// traitVectorResponse wraps the stored Trait Vector for HTTP egress.
type traitVectorResponse struct {
	TraitVector playthrough.StoredTraitVector `json:"trait_vector"`
}

// finalizePlaythroughHandler triggers trait scoring for the playthrough
// when every vignette has been answered. The body is empty; the
// playthrough id comes from the URL.
//
// Status surface:
//   - 200 OK              -> finalized; body has the trait vector.
//   - 401 Unauthorized    -> no session.
//   - 404 Not Found       -> playthrough id doesn't exist OR the season
//     it references is unknown to ml-py (a content packaging bug).
//   - 409 Conflict        -> ErrPlaythroughIncomplete; some vignettes
//     still lack a choice. The client should keep playing.
//   - 503 Service Unavailable -> trait scorer not configured at boot;
//     a transient infra state, retry later.
//   - 502 Bad Gateway     -> upstream (ml-py) returned INVALID_ARGUMENT
//     for an event we sent it; bug at the boundary, log + return.
//   - 500                 -> anything else.
//
// As with recordChoiceHandler, we don't yet check that the playthrough
// belongs to the authed user; cross-user authz lands in T-CORE-022.
func finalizePlaythroughHandler(svc *playthrough.Service) http.HandlerFunc {
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

		stored, err := svc.FinalizeIfComplete(r.Context(), playthroughID)
		switch {
		case errors.Is(err, playthrough.ErrNotFound):
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, playthrough.ErrPlaythroughIncomplete):
			writeJSONError(w, http.StatusConflict, "playthrough is not yet complete")
			return
		case errors.Is(err, playthrough.ErrScorerUnavailable):
			writeJSONError(w, http.StatusServiceUnavailable, "trait scoring is not configured")
			return
		case err != nil:
			writeJSONError(w, http.StatusBadGateway, "trait scoring failed")
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(traitVectorResponse{TraitVector: stored})
	}
}

// getTraitVectorHandler returns the persisted trait vector for a
// playthrough. 404 if scoring hasn't completed yet.
func getTraitVectorHandler(svc *playthrough.Service) http.HandlerFunc {
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

		stored, err := svc.GetTraitVector(r.Context(), playthroughID)
		switch {
		case errors.Is(err, playthrough.ErrTraitVectorNotFound):
			writeJSONError(w, http.StatusNotFound, "trait vector not found")
			return
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "get trait vector failed")
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(traitVectorResponse{TraitVector: stored})
	}
}
