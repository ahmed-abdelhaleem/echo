package http

import (
	"context"
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
	TokenAllow   compareTokenAllowFunc
	Audit        compareAuditFunc
	Logger       *slog.Logger
	Now          func() time.Time
}

type compareTokenAllowFunc func(ctx context.Context, action, token string) bool

type compareAuditFunc func(action, outcome string)

func (c compareHandlerConfig) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c compareHandlerConfig) allow(ctx context.Context, action, token string) bool {
	if c.TokenAllow == nil {
		return true
	}
	return c.TokenAllow(ctx, action, token)
}

func (c compareHandlerConfig) audit(action, outcome string) {
	// Record the lifecycle metric off the same taxonomy as the audit hook
	// (implementation plan → Observability). Safe no-op until a MeterProvider
	// exporter is wired.
	getCompareMetrics().record(action, outcome)
	if c.Audit != nil {
		c.Audit(action, outcome)
	}
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
		case errors.Is(err, playthrough.ErrGuardianConsentRequired):
			cfg.audit("compare_invite_create", "guardian_consent_required")
			writeJSONError(w, http.StatusForbidden, "guardian consent required for youth comparison")
			return
		case errors.Is(err, playthrough.ErrYouthSafeDenied):
			cfg.audit("compare_invite_create", "youth_safe_denied")
			writeJSONError(w, http.StatusForbidden, "comparisons disabled for youth-safe accounts")
			return
		case errors.Is(err, playthrough.ErrNotOwner):
			cfg.audit("compare_invite_create", "not_found")
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, playthrough.ErrPlaythroughNotComplete):
			cfg.audit("compare_invite_create", "playthrough_incomplete")
			writeJSONError(w, http.StatusConflict, "playthrough not complete")
			return
		case err != nil:
			cfg.audit("compare_invite_create", "error")
			cfg.Logger.Error("compare: create invite", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "comparison invite creation failed")
			return
		}
		cfg.audit("compare_invite_create", "success")

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
			cfg.audit("compare_accept", "bad_request")
			writeJSONError(w, http.StatusBadRequest, "token and playthrough_id required")
			return
		}
		if !cfg.allow(r.Context(), "compare_accept", body.Token) {
			cfg.audit("compare_accept", "rate_limited")
			writeJSONError(w, http.StatusTooManyRequests, "too many requests")
			return
		}

		comp, err := cfg.Playthrough.AcceptComparisonInvite(r.Context(), user.ID, body.Token, body.PlaythroughID)
		switch {
		case errors.Is(err, playthrough.ErrGuardianConsentRequired):
			cfg.audit("compare_accept", "guardian_consent_required")
			writeJSONError(w, http.StatusForbidden, "guardian consent required for youth comparison")
			return
		case errors.Is(err, playthrough.ErrComparisonNotFound):
			cfg.audit("compare_accept", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case errors.Is(err, playthrough.ErrComparisonTokenExpired):
			cfg.audit("compare_accept", "expired")
			writeJSONError(w, http.StatusGone, "comparison invite expired")
			return
		case errors.Is(err, playthrough.ErrYouthSafeDenied):
			cfg.audit("compare_accept", "youth_safe_denied")
			writeJSONError(w, http.StatusForbidden, "comparisons disabled for youth-safe accounts")
			return
		case errors.Is(err, playthrough.ErrNotOwner):
			cfg.audit("compare_accept", "not_owner")
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, playthrough.ErrPlaythroughNotComplete):
			cfg.audit("compare_accept", "playthrough_incomplete")
			writeJSONError(w, http.StatusConflict, "playthrough not complete")
			return
		case errors.Is(err, playthrough.ErrSeasonMismatch):
			cfg.audit("compare_accept", "season_mismatch")
			writeJSONError(w, http.StatusBadRequest, "playthroughs must belong to the same season")
			return
		case errors.Is(err, playthrough.ErrComparisonNotPending):
			cfg.audit("compare_accept", "not_pending")
			writeJSONError(w, http.StatusGone, "comparison is not pending")
			return
		case err != nil:
			cfg.audit("compare_accept", "error")
			cfg.Logger.Error("compare: accept invite", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "accepting comparison failed")
			return
		}
		cfg.audit("compare_accept", "success")

		writeJSON(w, http.StatusOK, comp)
	}
}

type comparePublicResponse struct {
	SeasonID   string                           `json:"season_id"`
	Status     playthrough.ComparisonStatus     `json:"status"`
	Divergence playthrough.ComparisonDivergence `json:"divergence"`
	InviterPNG string                           `json:"inviter_png_url"`
	InviteePNG string                           `json:"invitee_png_url"`
}

func getCompareHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			cfg.audit("compare_get", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		}
		if !cfg.allow(r.Context(), "compare_get", token) {
			cfg.audit("compare_get", "rate_limited")
			writeJSONError(w, http.StatusTooManyRequests, "too many requests")
			return
		}

		res, err := cfg.Playthrough.GetComparisonResult(r.Context(), token)
		switch {
		case errors.Is(err, playthrough.ErrComparisonNotFound):
			cfg.audit("compare_get", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case errors.Is(err, playthrough.ErrComparisonTokenExpired):
			cfg.audit("compare_get", "expired")
			writeJSONError(w, http.StatusGone, "comparison link expired")
			return
		case errors.Is(err, playthrough.ErrNotFound):
			cfg.audit("compare_get", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case errors.Is(err, playthrough.ErrNoDivergence):
			cfg.audit("compare_get", "no_divergence")
			// If there's no divergence but it's accepted, we still return the model structure
			// but we handle no divergence. But service returns ErrNoDivergence.
			// Let's write standard error response.
			writeJSONError(w, http.StatusConflict, "no divergence moment found between playthroughs")
			return
		case err != nil:
			cfg.audit("compare_get", "error")
			cfg.Logger.Error("compare: get result", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "get comparison failed")
			return
		}

		var inviterPNG, inviteePNG string
		if res.Comparison.Status == playthrough.ComparisonStatusAccepted {
			inviterPNG = portraitURLForToken(cfg.APIBaseURL, token, false) + "?side=inviter"
			inviteePNG = portraitURLForToken(cfg.APIBaseURL, token, false) + "?side=invitee"
		}

		writeJSON(w, http.StatusOK, comparePublicResponse{
			SeasonID:   res.Comparison.SeasonID,
			Status:     res.Comparison.Status,
			Divergence: res.Divergence,
			InviterPNG: inviterPNG,
			InviteePNG: inviteePNG,
		})
		cfg.audit("compare_get", "success")
	}
}

// publicComparePortraitHandler serves the portrait of either the inviter or invitee for a comparison token.
// E.g., /compare/{token}/portrait?side=inviter or ?side=invitee
func publicComparePortraitHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			cfg.audit("compare_portrait_get", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		}
		if !cfg.allow(r.Context(), "compare_portrait_get", token) {
			cfg.audit("compare_portrait_get", "rate_limited")
			writeJSONError(w, http.StatusTooManyRequests, "too many requests")
			return
		}

		comp, err := cfg.Playthrough.GetComparisonResult(r.Context(), token)
		if err != nil {
			if errors.Is(err, playthrough.ErrComparisonNotFound) {
				cfg.audit("compare_portrait_get", "not_found")
				writeJSONError(w, http.StatusNotFound, "comparison not found")
				return
			}
			if errors.Is(err, playthrough.ErrComparisonTokenExpired) {
				cfg.audit("compare_portrait_get", "expired")
				writeJSONError(w, http.StatusGone, "comparison link expired")
				return
			}
			if errors.Is(err, playthrough.ErrNotFound) {
				cfg.audit("compare_portrait_get", "not_found")
				writeJSONError(w, http.StatusNotFound, "comparison not found")
				return
			}
			cfg.audit("compare_portrait_get", "error")
			cfg.Logger.Error("compare: public portrait check", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "fetch failed")
			return
		}

		side := r.URL.Query().Get("side")
		var targetPtID uuid.UUID
		if side == "invitee" {
			if comp.Comparison.InviteePlaythroughID == nil {
				cfg.audit("compare_portrait_get", "bad_request")
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
			cfg.audit("compare_portrait_get", "error")
			cfg.Logger.Error("compare: public portrait gen", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "portrait unavailable")
			return
		}

		if animate && len(assets.AnimatedWebP) > 0 {
			cfg.audit("compare_portrait_get", "success")
			w.Header().Set("Content-Type", "image/webp")
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			_, _ = w.Write(assets.AnimatedWebP)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		_, _ = w.Write(assets.PNG)
		cfg.audit("compare_portrait_get", "success")
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
			cfg.audit("compare_revoke", "bad_request")
			writeJSONError(w, http.StatusBadRequest, "token required")
			return
		}

		err = cfg.Playthrough.RevokeComparison(r.Context(), user.ID, token)
		switch {
		case errors.Is(err, playthrough.ErrNotFound), errors.Is(err, playthrough.ErrNotOwner):
			cfg.audit("compare_revoke", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case err != nil:
			cfg.audit("compare_revoke", "error")
			cfg.Logger.Error("compare: revoke", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "revoke failed")
			return
		}
		cfg.audit("compare_revoke", "success")
		w.WriteHeader(http.StatusNoContent)
	}
}

type shareEnableResponse struct {
	ShareToken string `json:"share_token"`
	ShareURL   string `json:"share_url"`
}

func enableCompareShareHandler(cfg compareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, cfg.now())
		if err != nil {
			cfg.Logger.Error("compare: share-enable: ensure user", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			cfg.audit("compare_share_enable", "bad_request")
			writeJSONError(w, http.StatusBadRequest, "token required")
			return
		}

		shareToken, err := cfg.Playthrough.EnableComparisonShare(r.Context(), user.ID, token)
		switch {
		case errors.Is(err, playthrough.ErrNotFound), errors.Is(err, playthrough.ErrNotOwner):
			cfg.audit("compare_share_enable", "not_found")
			writeJSONError(w, http.StatusNotFound, "comparison not found")
			return
		case errors.Is(err, playthrough.ErrComparisonNotAccepted):
			cfg.audit("compare_share_enable", "not_accepted")
			writeJSONError(w, http.StatusConflict, "comparison is not accepted")
			return
		case err != nil:
			cfg.audit("compare_share_enable", "error")
			cfg.Logger.Error("compare: share-enable", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "share-enable failed")
			return
		}
		cfg.audit("compare_share_enable", "success")

		writeJSON(w, http.StatusOK, shareEnableResponse{
			ShareToken: shareToken,
			ShareURL:   compareURL(cfg.ShareBaseURL, shareToken),
		})
	}
}

func compareURL(baseURL, token string) string {
	if baseURL == "" {
		return "/compare/" + token
	}
	return strings.TrimRight(baseURL, "/") + "/compare/" + token
}
