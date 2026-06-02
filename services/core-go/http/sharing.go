package http

import (
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/sharing"
	"github.com/google/uuid"
)

// shareCreateResponse is the JSON body returned by POST
// /playthroughs/{id}/share. share_url is built from the configured
// share base URL plus the freshly-issued token.
type shareCreateResponse struct {
	Token     string `json:"token"`
	ShareURL  string `json:"share_url"`
	CreatedAt string `json:"created_at"`
}

// sharePayload is the JSON contract apps/share-web consumes. It
// bundles everything the public Portrait page needs so share-web can
// SSR the page in a single core-go round trip.
type sharePayload struct {
	Token         string             `json:"token"`
	PlaythroughID string             `json:"playthrough_id"`
	ShareURL      string             `json:"share_url"`
	PortraitPNG   string             `json:"portrait_png_url"`
	PortraitWebP  string             `json:"portrait_webp_url"`
	Reflection    sharePayloadReflec `json:"reflection"`
	CreatedAt     string             `json:"created_at"`
}

type sharePayloadReflec struct {
	Text       string `json:"text"`
	TemplateID string `json:"template_id"`
}

// shareHandlerConfig groups dependencies for the share handlers so
// NewMux doesn't have to thread half a dozen positional args.
type shareHandlerConfig struct {
	Share        *sharing.Service
	Playthrough  *playthrough.Service
	Users        auth.UsersRepository
	ShareBaseURL string
	APIBaseURL   string
	Logger       *slog.Logger
	Now          func() time.Time
}

func (c shareHandlerConfig) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// createShareHandler implements POST /playthroughs/{id}/share. Auth
// required (session middleware). Returns 403 when the caller's age
// band is youth (privacy invariant: opt-in only, never for under-18s),
// 404 when the playthrough is not owned by the caller, and 409 when
// the playthrough has not been finalized.
func createShareHandler(cfg shareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, cfg.now())
		switch {
		case errors.Is(err, auth.ErrUnderageIdentity):
			writeJSONError(w, http.StatusForbidden, "ineligible")
			return
		case err != nil:
			cfg.Logger.Error("share: ensure user", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		ptID, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid playthrough id")
			return
		}

		link, err := cfg.Share.Create(r.Context(), sharing.CreateInput{
			UserID:        user.ID,
			PlaythroughID: ptID,
		})
		switch {
		case errors.Is(err, sharing.ErrYouthSafeDenied):
			writeJSONError(w, http.StatusForbidden, "sharing disabled for youth-safe accounts")
			return
		case errors.Is(err, sharing.ErrNotOwner):
			// Deliberately 404 — we don't confirm playthrough
			// existence to non-owners.
			writeJSONError(w, http.StatusNotFound, "playthrough not found")
			return
		case errors.Is(err, sharing.ErrPlaythroughNotComplete):
			writeJSONError(w, http.StatusConflict, "playthrough not complete")
			return
		case err != nil:
			cfg.Logger.Error("share: create", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "share creation failed")
			return
		}

		writeJSON(w, http.StatusCreated, shareCreateResponse{
			Token:     link.Token,
			ShareURL:  shareURL(cfg.ShareBaseURL, link.Token),
			CreatedAt: link.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
}

// revokeShareHandler implements DELETE /share/{token}. Auth required.
// Returns 204 on success (idempotent — double-revoke is fine).
func revokeShareHandler(cfg shareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSONError(w, http.StatusUnauthorized, "authentication required")
			return
		}
		user, err := cfg.Users.EnsureFromSession(r.Context(), sess, cfg.now())
		if err != nil {
			cfg.Logger.Error("share: revoke: ensure user", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "user provisioning failed")
			return
		}

		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			writeJSONError(w, http.StatusBadRequest, "token required")
			return
		}

		err = cfg.Share.Revoke(r.Context(), token, user.ID)
		switch {
		case errors.Is(err, sharing.ErrLinkNotFound), errors.Is(err, sharing.ErrNotOwner):
			// Both map to 404 — we don't tell the caller whether the
			// link existed and was unowned, or never existed.
			writeJSONError(w, http.StatusNotFound, "share not found")
			return
		case err != nil:
			cfg.Logger.Error("share: revoke", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "revoke failed")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// publicShareHandler implements GET /share/{token}. Public — no auth.
// Returns the JSON contract share-web consumes. 404 on missing token,
// 410 Gone on revoked link.
func publicShareHandler(cfg shareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			writeJSONError(w, http.StatusNotFound, "share not found")
			return
		}
		link, err := cfg.Share.GetByToken(r.Context(), token)
		switch {
		case errors.Is(err, sharing.ErrLinkNotFound):
			writeJSONError(w, http.StatusNotFound, "share not found")
			return
		case errors.Is(err, sharing.ErrLinkRevoked):
			// 410 Gone — deliberate kill, not a transient miss.
			writeJSONError(w, http.StatusGone, "share has been revoked")
			return
		case err != nil:
			cfg.Logger.Error("share: public get", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "share fetch failed")
			return
		}

		// youth_safe=false on the public surface always. (Youth
		// accounts can't create shares; this is defense in depth.)
		refl, err := cfg.Playthrough.GetReflection(r.Context(), link.PlaythroughID, false)
		if err != nil {
			cfg.Logger.Error("share: public reflection", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "reflection unavailable")
			return
		}

		writeJSON(w, http.StatusOK, sharePayload{
			Token:         link.Token,
			PlaythroughID: link.PlaythroughID.String(),
			ShareURL:      shareURL(cfg.ShareBaseURL, link.Token),
			PortraitPNG:   portraitURLForToken(cfg.APIBaseURL, link.Token, false),
			PortraitWebP:  portraitURLForToken(cfg.APIBaseURL, link.Token, true),
			Reflection: sharePayloadReflec{
				Text:       refl.Text,
				TemplateID: refl.TemplateID,
			},
			CreatedAt: link.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
}

// publicSharePortraitHandler implements GET /share/{token}/portrait.
// Public — no auth. Streams the PNG bytes (or WebP if ?format=webp).
//
// This sits behind the share token rather than the authenticated
// portrait endpoint so share-web (and downstream embeds like
// og:image / twitter:image) can deep-link the image without a
// session.
func publicSharePortraitHandler(cfg shareHandlerConfig) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimSpace(r.PathValue("token"))
		if token == "" {
			writeJSONError(w, http.StatusNotFound, "share not found")
			return
		}
		link, err := cfg.Share.GetByToken(r.Context(), token)
		switch {
		case errors.Is(err, sharing.ErrLinkNotFound):
			writeJSONError(w, http.StatusNotFound, "share not found")
			return
		case errors.Is(err, sharing.ErrLinkRevoked):
			writeJSONError(w, http.StatusGone, "share has been revoked")
			return
		case err != nil:
			cfg.Logger.Error("share: public portrait", "err", err)
			writeJSONError(w, http.StatusInternalServerError, "share fetch failed")
			return
		}

		animate := r.URL.Query().Get("format") == "webp"
		assets, err := cfg.Playthrough.GetPortrait(r.Context(), link.PlaythroughID, animate)
		if err != nil {
			cfg.Logger.Error("share: public portrait gen", "err", err)
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

// shareURL composes the canonical public share URL. baseURL is the
// share-web origin (e.g. "https://share.echo.app"); "/share/{token}"
// is appended. Empty baseURL returns a relative path — useful in tests.
func shareURL(baseURL, token string) string {
	if baseURL == "" {
		return "/share/" + token
	}
	return strings.TrimRight(baseURL, "/") + "/share/" + token
}

// portraitURLForToken composes the public portrait URL for a token.
// Points at the API origin (where the public portrait handler lives)
// rather than the share-web origin.
func portraitURLForToken(apiBaseURL, token string, animate bool) string {
	suffix := "/share/" + token + "/portrait"
	if animate {
		suffix += "?format=webp"
	}
	if apiBaseURL == "" {
		return suffix
	}
	return strings.TrimRight(apiBaseURL, "/") + suffix
}
