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
	Users       auth.UsersRepository

	// Now is the time source for handlers that need it (user provisioning
	// stamps consent timestamps). Defaults to time.Now when nil.
	Now func() time.Time
}

// NewMux builds the HTTP mux. Kept small in M0; routes accumulate as features land.
func NewMux(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", readyz(deps))

	// /whoami is the smallest possible authenticated endpoint. It also
	// doubles as a CSRF/cookie-domain sanity check from the client.
	if deps.Auth != nil && deps.Auth.Kratos != nil {
		whoamiHandler := http.HandlerFunc(whoami)
		mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
		mux.Handle("GET /whoami", mw(whoamiHandler))
	}

	// Content endpoints are public: anyone with the client can browse the
	// authored Seasons. Auth is required only for playthrough mutations.
	if deps.Content != nil {
		mux.HandleFunc("GET /content/seasons/{id}", getSeasonHandler(deps.Content))
	}

	// Playthrough endpoints require authentication. Both routes go through
	// auth.Middleware so the handlers can rely on a session being attached.
	if deps.Playthrough != nil && deps.Auth != nil && deps.Auth.Kratos != nil && deps.Users != nil {
		nowFn := deps.Now
		if nowFn == nil {
			nowFn = time.Now
		}
		mw := auth.Middleware(deps.Auth.Kratos, deps.Logger)
		mux.Handle("POST /playthroughs", mw(createPlaythroughHandler(deps.Playthrough, deps.Users, nowFn)))
		mux.Handle("POST /playthroughs/{id}/choices", mw(recordChoiceHandler(deps.Playthrough)))
		mux.Handle("GET /playthroughs/{id}/trait-vector", mw(getTraitVectorHandler(deps.Playthrough)))
	}

	return mux
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// whoami returns the session attached by [auth.Middleware]. Reaching this
// handler without a session is a programming error (the middleware should
// have rejected the request) and surfaces as 500.
func whoami(w http.ResponseWriter, r *http.Request) {
	sess, ok := auth.SessionFromContext(r.Context())
	if !ok {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "session not attached; middleware misconfigured",
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session_id":   sess.ID,
		"identity_id":  sess.IdentityID,
		"email":        sess.Email,
		"display_name": sess.DisplayName,
		"expires_at":   sess.ExpiresAt,
	})
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
