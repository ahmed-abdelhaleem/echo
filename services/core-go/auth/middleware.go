package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
)

// contextKey is unexported so external packages cannot stuff arbitrary
// values into the request context using our key by accident.
type contextKey struct{}

var sessionCtxKey = contextKey{}

// Middleware returns an HTTP middleware that validates the Kratos session
// cookie and attaches the resolved [Session] to the request context.
//
// Behaviour:
//   - missing or invalid cookie -> 401 with a tiny JSON body. The cookie is
//     never echoed back.
//   - active session            -> next handler called with the Session in
//     context; downstream code reads it with [SessionFromContext].
//   - Kratos unreachable        -> 502 (we deliberately do not pretend the
//     user is authenticated when we don't know).
//
// The middleware is stateless. Tests construct it with a *KratosClient that
// targets an httptest server.
func Middleware(client *KratosClient, logger *slog.Logger) func(http.Handler) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cookie, err := r.Cookie(KratosCookieName)
			if err != nil {
				writeAuthError(w, http.StatusUnauthorized, "no session cookie")
				return
			}

			sess, err := client.Whoami(r.Context(), cookie.Value)
			switch {
			case errors.Is(err, ErrSessionUnauthorized), errors.Is(err, ErrSessionNotActive):
				writeAuthError(w, http.StatusUnauthorized, "invalid or expired session")
				return
			case err != nil:
				logger.WarnContext(r.Context(), "kratos whoami failed", slog.String("err", err.Error()))
				writeAuthError(w, http.StatusBadGateway, "auth backend unavailable")
				return
			}

			ctx := contextWithSession(r.Context(), sess)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// SessionFromContext returns the session attached by [Middleware]. The bool
// is false (and the Session is zero) when the middleware has not run for
// this request — handlers should treat that as a programming error and
// return 500, not 401.
func SessionFromContext(ctx context.Context) (Session, bool) {
	if ctx == nil {
		return Session{}, false
	}
	v, ok := ctx.Value(sessionCtxKey).(Session)
	return v, ok
}

func contextWithSession(ctx context.Context, s Session) context.Context {
	return context.WithValue(ctx, sessionCtxKey, s)
}

// writeAuthError responds with a tiny JSON body so the Flutter client can
// surface a friendly message without parsing prose. The HTTP status is
// the canonical signal.
func writeAuthError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// Hand-roll the JSON to avoid pulling in a json encoder on the hot path
	// and to keep the response body predictable for clients.
	_, _ = w.Write([]byte(`{"error":"` + msg + `"}`))
}
