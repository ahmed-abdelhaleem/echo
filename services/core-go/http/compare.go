package http

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/google/uuid"
)

type compareHandlerConfig struct {
	Playthrough  *playthrough.Service
	Users        auth.UsersRepository
	ShareBaseURL string
	APIBaseURL   string
	Logger       *slog.Logger
	Now          func() time.Time
}

func (c compareHandlerConfig) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

type createCompareRequest struct {
	PlaythroughID uuid.UUID `json:"playthrough_id"`
}

type compareInviteResponse struct {
	Token      string `json:"token"`
	CompareURL string `json:"compare_url"`
	CreatedAt  string `json:"created_at"`
}

func createCompareHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, cfg.now())
		if err != nil {
			cfg.Logger.Error("compare: ensure user", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		// Playthrough ID is read from the URL path: /playthroughs/{id}/compare
		ptIDStr := r.PathValue("id")
		ptID, err := uuid.Parse(ptIDStr)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid playthrough id")
			return
		}

		comp, err := cfg.Playthrough.CreateComparisonInvite(r.Context(), user.ID, ptID)
		switch {
		case errors.Is(err, playthrough.ErrYouthSafeDenied):
			writeJSONError(w, http.StatusForbidden, "comparisons disabled for youth-safe accounts")
			return
		case errors.Is(err, playthrough.ErrNotOwner):
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, playthrough.ErrPlaythroughNotComplete):
			writeJSONError(w, http.StatusConflict, "playthrough not complete")
			return
		case err != nil:
			cfg.Logger.Error("compare: create invite", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "comparison invite creation failed")
			return
		}

		writeJSON(w, http.StatusCreated, compareInviteResponse{
			Token:      comp.Token,
			CompareURL: compareURL(cfg.ShareBaseURL, comp.Token),
			CreatedAt:  comp.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
}

type acceptCompareRequest struct {
	Token         string    `json:"token"`
	PlaythroughID uuid.UUID `json:"playthrough_id"`
}

func acceptCompareHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, cfg.now())
		if err != nil {
			cfg.Logger.Error("compare: ensure user", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		var body acceptCompareRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Token == "" || body.PlaythroughID == uuid.Nil {
			writeJSONError(w, http.StatusBadRequest, "token and playthrough_id required")
			return
		}

		comp, err := cfg.Playthrough.AcceptComparisonInvite(r.Context(), user.ID, body.Token, body.PlaythroughID)
		switch {
		case errors.Is(err, playthrough.ErrYouthSafeDenied):
			writeJSONError(w, http.StatusForbidden, "comparisons disabled for youth-safe accounts")
			return
		case errors.Is(err, playthrough.ErrNotOwner):
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, playthrough.ErrPlaythroughNotComplete):
			writeJSONError(w, http.StatusConflict, "playthrough not complete")
			return
		case errors.Is(err, playthrough.ErrSeasonMismatch):
			writeJSONError(w, http.StatusBadRequest, "playthroughs must belong to the same season")
			return
		case errors.Is(err, playthrough.ErrComparisonNotPending):
			writeJSONError(w, http.StatusGone, "comparison is not pending")
			return
		case err != nil:
			cfg.Logger.Error("compare: accept invite", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "accepting comparison failed")
			return
		}

		writeJSON(w, http.StatusOK, comp)
	}
}

type comparePublicResponse struct {
	Comparison   playthrough.Comparison           `json:"comparison"`
	InviterModel playthrough.StoredTraitVector    `json:"inviter_traits"`
	InviteeModel playthrough.StoredTraitVector    `json:"invitee_traits"`
	Divergence   playthrough.ComparisonDivergence `json:"divergence"`
	InviterPNG   string                           `json:"inviter_png_url"`
	InviteePNG   string                           `json:"invitee_png_url"`
}

func getCompareHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		}

		res, err := cfg.Playthrough.GetComparisonResult(r.Context(), token)
		switch {
		case errors.Is(err, playthrough.ErrNotFound):
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case errors.Is(err, playthrough.ErrNoDivergence):
			// If there's no divergence but it's accepted, we still return the model structure
			// but we handle no divergence. But service returns ErrNoDivergence.
			// Let's write standard error response.
			writeJSONError(w, http.StatusConflict, "no divergence moment found between playthroughs")
			return
		case err != nil:
			cfg.Logger.Error("compare: get result", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "get comparison failed")
			return
		}

		var inviterPNG, inviteePNG string
		if res.Comparison.Status == playthrough.ComparisonStatusAccepted {
			inviterPNG = portraitURLForToken(cfg.APIBaseURL, res.Comparison.Token, false) + "?side=inviter"
			inviteePNG = portraitURLForToken(cfg.APIBaseURL, res.Comparison.Token, false) + "?side=invitee"
		}

		writeJSON(w, http.StatusOK, comparePublicResponse{
			Comparison:   res.Comparison,
			InviterModel: res.InviterModel,
			InviteeModel: res.InviteeModel,
			Divergence:   res.Divergence,
			InviterPNG:   inviterPNG,
			InviteePNG:   inviteePNG,
		})
	}
}

// publicComparePortraitHandler serves the portrait of either the inviter or invitee for a comparison token.
// E.g., /compare/{token}/portrait?side=inviter or ?side=invitee
func publicComparePortraitHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		}

		comp, err := cfg.Playthrough.GetComparisonResult(r.Context(), token)
		if err != nil {
			if errors.Is(err, playthrough.ErrNotFound) {
				writeJSONError(w, http.StatusNotFound, "comparison not found")
				return
			}
			cfg.Logger.Error("compare: public portrait check", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "fetch failed")
			return
		}

		side := r.URL.Query().Get("side")
		var targetPtID uuid.UUID
		if side == "invitee" {
			if comp.Comparison.InviteePlaythroughID == nil {
				writeJSONError(w, http.StatusBadRequest, "invitee playthrough not accepted yet")
				return
			}
			targetPtID = *comp.Comparison.InviteePlaythroughID
		} else {
			targetPtID = comp.Comparison.InviterPlaythroughID
		}

		animate := r.URL.Query().Get("format") == "webp"
		assets, err := cfg.Playthrough.GetPortrait(r.Context(), targetPtID, animate)
		if err != nil {
			cfg.Logger.Error("compare: public portrait gen", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "portrait unavailable")
			return
		}

		if animate && len(assets.AnimatedWebP) > 0 {
			w.Header().Set("Content-Type", "image/webp")
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			_, _ = w.Write(assets.AnimatedWebP)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		_, _ = w.Write(assets.PNG)
	}
}

func revokeCompareHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, cfg.now())
		if err != nil {
			cfg.Logger.Error("compare: revoke: ensure user", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			writeJSONError(w, http.StatusBadRequest, "token required")
			return
		}

		err = cfg.Playthrough.RevokeComparison(r.Context(), user.ID, token)
		switch {
		case errors.Is(err, playthrough.ErrNotFound), errors.Is(err, playthrough.ErrNotOwner):
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case err != nil:
			cfg.Logger.Error("compare: revoke", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "revoke failed")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

func compareURL(baseURL, token string) string {
	if baseURL == "" {
		return "/compare/" + token
	}
	return strings.TrimRight(baseURL, "/") + "/compare/" + token
}
