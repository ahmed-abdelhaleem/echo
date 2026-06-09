package http

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
)

// seasonResponse wraps Season for the JSON envelope. We give it a dedicated
// type rather than returning Season directly so future API-only fields
// (cache headers, content-policy hints) don't leak into the domain model.
type seasonResponse struct {
	Season content.Season `json:"season"`
}

// getSeasonHandler returns a handler that reads {id} from the path and
// resolves it through the content service.
func getSeasonHandler(svc *content.Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if id == "" {
			writeJSONError(w, http.StatusBadRequest, "season id required")
			return
		}
		season, err := svc.GetSeason(r.Context(), id)
		switch {
		case errors.Is(err, content.ErrSeasonNotFound):
			writeJSONError(w, http.StatusNotFound, "season not found")
			return
		case err != nil:
			writeJSONError(w, http.StatusInternalServerError, "content error")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		// Content is versioned and the cache invalidates on each
		// deploy; advise downstream caches accordingly.
		w.Header().Set("Cache-Control", "public, max-age=60")
		_ = json.NewEncoder(w).Encode(seasonResponse{Season: season})
	}
}

// writeJSONError centralises the error response shape. Kept here (not in
// auth/) so non-auth handlers don't pull on the auth package.
func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
