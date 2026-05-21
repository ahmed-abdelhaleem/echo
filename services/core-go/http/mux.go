// Package http exposes the public HTTP surface of the core service.
//
// Today this is only the health/readiness endpoints (T-CORE-004). The GraphQL
// gateway lands in M1 when client traffic begins.
package http

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// Dependencies is the set of process-scoped dependencies the HTTP handlers
// need. Optional fields may be nil in which case the readiness check reports
// the corresponding dependency as unreachable.
type Dependencies struct {
	Logger *slog.Logger
	PG     *pgxpool.Pool
	Redis  *redis.Client
}

// NewMux builds the HTTP mux. Kept tiny in M0; routes accumulate as features land.
func NewMux(deps Dependencies) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /readyz", readyz(deps))
	return mux
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
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
