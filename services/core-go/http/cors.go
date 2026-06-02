package http

import (
	"net/http"
	"net/url"
	"strings"
)

// CORSOptions configures [CORSMiddleware]. When AllowLocalhost is true,
// any Origin whose host is localhost or 127.0.0.1 is permitted — this
// covers Flutter web's random dev-server ports without listing each one.
type CORSOptions struct {
	AllowLocalhost  bool
	AllowedOrigins  []string
	AllowCredentials bool
}

func (o CORSOptions) originAllowed(origin string) bool {
	if origin == "" {
		return false
	}
	if o.AllowLocalhost && isLocalhostDevOrigin(origin) {
		return true
	}
	for _, allowed := range o.AllowedOrigins {
		if origin == allowed {
			return true
		}
	}
	return false
}

// isLocalhostDevOrigin reports whether origin is an http(s) URL on
// localhost or 127.0.0.1 (any port). Used for local Flutter web only.
func isLocalhostDevOrigin(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	switch u.Scheme {
	case "http", "https":
	default:
		return false
	}
	host := u.Hostname()
	return host == "localhost" || host == "127.0.0.1"
}

// CORSMiddleware adds Access-Control-* headers for browser clients (eg
// Flutter web). Non-browser clients omit Origin and pass through unchanged.
func CORSMiddleware(opts CORSOptions) func(http.Handler) http.Handler {
	allowCreds := opts.AllowCredentials
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			origin := r.Header.Get("Origin")
			if origin == "" || !opts.originAllowed(origin) {
				next.ServeHTTP(w, r)
				return
			}

			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Add("Vary", "Origin")
			if allowCreds {
				w.Header().Set("Access-Control-Allow-Credentials", "true")
			}
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Cookie, X-Requested-With")
			w.Header().Set("Access-Control-Max-Age", "86400")

			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

// ParseAllowedOrigins splits a comma-separated CORE_CORS_ALLOWED_ORIGINS value.
func ParseAllowedOrigins(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	parts := strings.Split(v, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
