// Package http exposes the public HTTP surface of the core service.
//
// Today this is health/readiness and a /whoami endpoint that resolves the
// caller's Kratos session. The GraphQL gateway lands in M1 when client
// traffic begins.
package http

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/sharing"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// Dependencies is the set of process-scoped dependencies the HTTP handlers
// need. Optional fields may be nil in which case the corresponding routes
// degrade gracefully (readiness reports the dependency as unreachable;
// /whoami returns 503 when Auth is nil).
type Dependencies struct {
	Logger      *slog.Logger
	PG          *pgxpool.Pool
	Redis       *redis.Client
	Auth        *auth.Service
	Content     *content.Service
	Playthrough *playthrough.Service
	Sharing     *sharing.Service
	Users       auth.UsersRepository

	// KratosHookSecret is the shared secret that Kratos must include in
	// the [auth.HookSecretHeader] header when invoking the registration
	// hooks (`/auth/hooks/before-registration`,
	// `/auth/hooks/after-registration`). Empty in tests; required in
	// production.
	KratosHookSecret string

	// ShareBaseURL is the origin of the share-web app (e.g.
	// "https://share.echo.app"). Used to build the `share_url` returned
	// to clients. Empty value falls back to a relative path.
	ShareBaseURL string

	// APIBaseURL is the public origin of this core-go service. Used to
	// build the absolute portrait URLs embedded in share-web payloads
	// (og:image / twitter:image). Empty value falls back to relative.
	APIBaseURL string

	// Now is the time source for handlers that need it (user provisioning
	// stamps consent timestamps). Defaults to time.Now when nil.
	Now func() time.Time
}

// NewMux builds the HTTP mux. Kept small in M0; routes accumulate as features land.
func NewMux(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", readyz(deps))

	nowFn := deps.Now
	if nowFn == nil {
		nowFn = time.Now
	}

	// /auth/preflight is unauthenticated by design — a not-yet-signed-up
	// applicant uses it to pre-check their birthdate against the age
	// gate before submitting a full registration form.
	mux.Handle("POST /auth/preflight", auth.PreflightHandler(nowFn))

	// /whoami is the smallest possible authenticated endpoint. It also
	// doubles as a CSRF/cookie-domain sanity check from the client.
	if deps.Auth != nil && deps.Auth.Kratos != nil {
		whoamiHandler := whoamiHandler(deps.Users, nowFn)
		mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
		mux.Handle("GET /whoami", mw(whoamiHandler))
	}

	// Account deletion: DELETE /me. Auth required; the handler reads the
	// session, soft-deletes the auth.users row, then deletes the Kratos
	// identity via the admin API.
	if deps.Auth != nil && deps.Auth.Kratos != nil && deps.Users != nil {
		mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
		mux.Handle("DELETE /me", mw(auth.DeleteMeHandler(auth.DeleteMeConfig{
			Users:  deps.Users,
			Kratos: deps.Auth.Kratos,
			Logger: deps.Logger,
			Now:    nowFn,
		})))
	}

	// Kratos web hooks. These are called by Kratos (server-to-server) so
	// they do NOT go through the session middleware. Authentication is
	// the shared secret in [auth.HookSecretHeader].
	if deps.Auth != nil && deps.Auth.Kratos != nil && deps.Users != nil {
		hookCfg := auth.HookConfig{
			Secret: deps.KratosHookSecret,
			Users:  deps.Users,
			Kratos: deps.Auth.Kratos,
			Logger: deps.Logger,
			Now:    nowFn,
		}
		mux.Handle("POST /auth/hooks/before-registration", auth.BeforeRegistrationHandler(hookCfg))
		mux.Handle("POST /auth/hooks/after-registration", auth.AfterRegistrationHandler(hookCfg))
	}

	// Content endpoints are public: anyone with the client can browse the
	// authored Seasons. Auth is required only for playthrough mutations.
	if deps.Content != nil {
		mux.HandleFunc("GET /content/seasons/{id}", getSeasonHandler(deps.Content))
	}

	// Playthrough endpoints require authentication. Both routes go through
	// auth.Middleware so the handlers can rely on a session being attached.
	if deps.Playthrough != nil && deps.Auth != nil && deps.Auth.Kratos != nil && deps.Users != nil {
		mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
		mux.Handle("POST /playthroughs", mw(createPlaythroughHandler(deps.Playthrough, deps.Users, nowFn)))
		mux.Handle("POST /playthroughs/{id}/choices", mw(recordChoiceHandler(deps.Playthrough)))
		mux.Handle("POST /playthroughs/{id}/finalize", mw(finalizePlaythroughHandler(deps.Playthrough)))
		mux.Handle("GET /playthroughs/{id}/trait-vector", mw(getTraitVectorHandler(deps.Playthrough)))
		mux.Handle("GET /playthroughs/{id}/portrait", mw(getPortraitHandler(deps.Playthrough)))
		mux.Handle("GET /playthroughs/{id}/reflection", mw(getReflectionHandler(deps.Playthrough)))
	}

	// Sharing surface (T-CORE-030). Three routes:
	//   - POST /playthroughs/{id}/share  (auth)   — owner mints a link
	//   - DELETE /share/{token}          (auth)   — owner kills a link
	//   - GET  /share/{token}            (public) — share-web payload
	//   - GET  /share/{token}/portrait   (public) — og:image / preview
	//
	// The public routes are deliberately NOT behind auth.Middleware:
	// share-web is unauthenticated and the entire point of a share link
	// is that any visitor can resolve it.
	if deps.Sharing != nil && deps.Playthrough != nil && deps.Users != nil {
		shareCfg := shareHandlerConfig{
			Share:        deps.Sharing,
			Playthrough:  deps.Playthrough,
			Users:        deps.Users,
			ShareBaseURL: deps.ShareBaseURL,
			APIBaseURL:   deps.APIBaseURL,
			Logger:       deps.Logger,
			Now:          nowFn,
		}
		mux.Handle("GET /share/{token}", publicShareHandler(shareCfg))
		mux.Handle("GET /share/{token}/portrait", publicSharePortraitHandler(shareCfg))
		if deps.Auth != nil && deps.Auth.Kratos != nil {
			mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
			mux.Handle("POST /playthroughs/{id}/share", mw(createShareHandler(shareCfg)))
			mux.Handle("DELETE /share/{token}", mw(revokeShareHandler(shareCfg)))
		}
	}

	// Friend comparison surface (T-SOCIAL-001). Public compare routes are
	// token-based and intentionally unauthenticated; write operations require
	// an authenticated session.
	if deps.Playthrough != nil && deps.Users != nil {
		compareCfg := compareHandlerConfig{
			Playthrough:  deps.Playthrough,
			Users:        deps.Users,
			ShareBaseURL: deps.ShareBaseURL,
			APIBaseURL:   deps.APIBaseURL,
			Logger:       deps.Logger,
			Now:          nowFn,
		}

		mux.Handle("GET /compare/{token}", getCompareHandler(compareCfg))
		mux.Handle("GET /compare/{token}/portrait", publicComparePortraitHandler(compareCfg))

		if deps.Auth != nil && deps.Auth.Kratos != nil {
			mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
			mux.Handle("POST /playthroughs/{id}/compare", mw(createCompareHandler(compareCfg)))
			mux.Handle("POST /compare/accept", mw(acceptCompareHandler(compareCfg)))
			mux.Handle("POST /compare/{token}/share-enable", mw(enableCompareShareHandler(compareCfg)))
			mux.Handle("DELETE /compare/{token}", mw(revokeCompareHandler(compareCfg)))
		}
	}

	return mux
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// whoamiHandler returns the session attached by [auth.Middleware] plus, if
// the auth.users row has been provisioned, the player's age band and
// youth-safe flag. The flag is what the rest of the system gates
// privacy-sensitive features on (sharing, extended analytics).
//
// Reaching this handler without a session is a programming error (the
// middleware should have rejected the request) and surfaces as 500.
//
// If the auth.users row does not exist yet — e.g. registration just
// completed and the after-hook has not run, or the user predates the
// hook flow — the handler attempts a lazy provision via
// [auth.UsersRepository.EnsureFromSession]. That path enforces the same
// age gate as the hook, so the response can never carry a youth_safe=false
// flag for an under-13 identity.
func whoamiHandler(users auth.UsersRepository, now func() time.Time) http.HandlerFunc {
	if now == nil {
		now = time.Now
	}
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := auth.SessionFromContext(r.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "session not attached; middleware misconfigured",
			})
			return
		}

		body := map[string]any{
			"session_id":   sess.ID,
			"identity_id":  sess.IdentityID,
			"email":        sess.Email,
			"display_name": sess.DisplayName,
			"expires_at":   sess.ExpiresAt,
		}

		// Best-effort lookup of the auth.users row to attach
		// (age_band, youth_safe). The middleware path never depended
		// on this lookup so any failure must not change the contract
		// of /whoami; we degrade quietly.
		if users != nil {
			user, err := users.EnsureFromSession(r.Context(), sess, now())
			if err == nil {
				body["age_band"] = string(user.AgeBand)
				body["youth_safe"] = user.AgeBand == auth.AgeBandYouth
			}
		}

		writeJSON(w, http.StatusOK, body)
	}
}

// readyz reports 200 only when all configured dependencies are reachable.
// A nil dependency is treated as "not configured" and contributes a 503.
// Per docs/07 T-CORE-004: returns 200 when DB and Redis reachable; 503 otherwise.
func readyz(deps Dependencies) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		result := map[string]string{}
		ok := true

		if deps.PG == nil {
			result["postgres"] = "not_configured"
			ok = false
		} else if err := deps.PG.Ping(ctx); err != nil {
			result["postgres"] = "unreachable: " + err.Error()
			ok = false
		} else {
			result["postgres"] = "ok"
		}

		if deps.Redis == nil {
			result["redis"] = "not_configured"
			ok = false
		} else if err := deps.Redis.Ping(ctx).Err(); err != nil {
			result["redis"] = "unreachable: " + err.Error()
			ok = false
		} else {
			result["redis"] = "ok"
		}

		status := http.StatusOK
		if !ok {
			status = http.StatusServiceUnavailable
		}
		writeJSON(w, status, result)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
