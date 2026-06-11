// Package config loads runtime configuration from the environment.
//
// Per docs/06_Tech_Stack.md secrets management is HashiCorp Vault in production;
// in local dev we read from environment variables (loaded by docker compose or
// the developer's shell). This package is the only place that touches os.Getenv
// so that config sources can be swapped without spreading env-var names.
package config

import (
	"errors"
	"os"
	"strings"
)

// Config holds the runtime configuration for the core service.
type Config struct {
	// HTTPAddr is the listen address for the HTTP server. Default ":8080".
	HTTPAddr string

	// GRPCAddr is the listen address for the gRPC server. Default ":9090".
	GRPCAddr string

	// DatabaseURL is a libpq-style URL to Postgres. Empty disables Postgres
	// (allowed in dev so the binary can boot without infra; /readyz returns 503).
	DatabaseURL string

	// RedisURL is a redis:// URL. Empty disables Redis.
	RedisURL string

	// OTLPEndpoint is the OpenTelemetry collector endpoint, e.g. "http://localhost:4318".
	// Empty disables telemetry export and falls back to a no-op exporter.
	OTLPEndpoint string

	// KratosPublicURL is the public-API base URL for Ory Kratos.
	// Empty disables the auth middleware and the /whoami endpoint.
	KratosPublicURL string

	// KratosAdminURL is the admin-API base URL for Ory Kratos. Used only by
	// server-side flows (identity lookup, deletion). Empty disables those.
	KratosAdminURL string

	// KratosHookSecret is the shared secret Kratos must include in the
	// `X-Echo-Hook-Secret` header when invoking the registration hooks.
	// Empty in dev (the hook handlers accept all requests when the secret
	// is blank); required in production.
	KratosHookSecret string

	// ContentRoot is the filesystem root that the content service reads
	// Seasons from. In dev this is `./content` relative to the repo root;
	// in production it points at a content image baked into the container.
	// Empty disables the content endpoints.
	ContentRoot string

	// MLgRPCAddr is the host:port of the ml-py gRPC service. Empty
	// disables trait scoring (FinalizeIfComplete returns
	// ErrScorerUnavailable until the dependency is wired).
	MLgRPCAddr string

	// ShareBaseURL is the public origin of the apps/share-web app
	// (e.g. "https://share.echo.app"). Used by the sharing endpoints
	// to build the `share_url` returned to clients. Empty falls back
	// to relative paths.
	ShareBaseURL string

	// APIBaseURL is the public origin of this core-go service (e.g.
	// "https://api.echo.app"). Used to build absolute portrait URLs
	// embedded in share-web payloads (og:image / twitter:image).
	// Empty falls back to relative paths.
	APIBaseURL string

	// Environment is the deployment environment label (dev|staging|production).
	Environment string

	// CORSAllowLocalhost permits browser requests from http://localhost:*
	// and http://127.0.0.1:* origins. Enabled by default in dev for Flutter
	// web; disable in production unless explicitly needed.
	CORSAllowLocalhost bool

	// CORSAllowedOrigins is an explicit allow-list (comma-separated in env).
	// Checked after the localhost rule when CORSAllowLocalhost is true.
	CORSAllowedOrigins []string

	// EnableKratosProxy enables /auth/kratos reverse proxy endpoints that are
	// primarily useful for local Flutter web (single-origin auth calls).
	// Defaults to true in dev and false otherwise.
	EnableKratosProxy bool

	// CompareEnabled gates the Friend Comparison HTTP surface (T-SOCIAL-001)
	// for staged rollout (implementation_plan.md → Rollout step 1). Defaults
	// to true in dev and false in staging/production until explicitly enabled
	// via CORE_COMPARE_ENABLED.
	CompareEnabled bool

	// ─── Billing (T-MONEY-001 / F-MONEY-001) ────────────────────────────────
	//
	// ⚠️  HUMAN REVIEW REQUIRED before enabling in production.
	//     Per AGENTS.md escalation rule #10 (billing logic).

	// StripeSecretKey is the Stripe API secret key (sk_live_… / sk_test_…).
	// Empty disables Stripe checkout and portal session creation.
	StripeSecretKey string

	// StripeWebhookSecret is the Stripe webhook signing secret (whsec_…).
	// Empty skips signature verification (dev only — never empty in production).
	StripeWebhookSecret string

	// StripeMonthlyPriceID is the Stripe Price ID for the monthly Echo+ plan.
	StripeMonthlyPriceID string

	// StripeYearlyPriceID is the Stripe Price ID for the annual Echo+ plan.
	StripeYearlyPriceID string

	// AppleWebhookSecret is the shared secret for Apple App Store Server
	// Notifications. Empty skips JWS signature verification (dev only).
	AppleWebhookSecret string

	// GoogleWebhookSecret is the Google Cloud Pub/Sub push bearer token.
	// Empty skips token verification (dev only).
	GoogleWebhookSecret string
}

// Load reads the configuration from the environment, applying defaults.
// Returns an error only when an explicitly-required value is malformed.
func Load() (Config, error) {
	cfg := Config{
		HTTPAddr:         defaultString(os.Getenv("CORE_HTTP_ADDR"), ":8080"),
		GRPCAddr:         defaultString(os.Getenv("CORE_GRPC_ADDR"), ":9090"),
		DatabaseURL:      strings.TrimSpace(os.Getenv("DATABASE_URL")),
		RedisURL:         strings.TrimSpace(os.Getenv("REDIS_URL")),
		OTLPEndpoint:     strings.TrimSpace(os.Getenv("OTLP_ENDPOINT")),
		KratosPublicURL:  strings.TrimSpace(os.Getenv("KRATOS_PUBLIC_URL")),
		KratosAdminURL:   strings.TrimSpace(os.Getenv("KRATOS_ADMIN_URL")),
		KratosHookSecret: strings.TrimSpace(os.Getenv("KRATOS_HOOK_SECRET")),
		ContentRoot:      strings.TrimSpace(os.Getenv("CONTENT_ROOT")),
		MLgRPCAddr:       strings.TrimSpace(os.Getenv("ML_GRPC_ADDR")),
		ShareBaseURL:     strings.TrimSpace(os.Getenv("SHARE_BASE_URL")),
		APIBaseURL:       strings.TrimSpace(os.Getenv("API_BASE_URL")),
		Environment:      defaultString(os.Getenv("ECHO_ENV"), "dev"),
	}

	cfg.CORSAllowedOrigins = parseCSV(os.Getenv("CORE_CORS_ALLOWED_ORIGINS"))
	cfg.CORSAllowLocalhost = corsAllowLocalhost(cfg.Environment, os.Getenv("CORE_CORS_ALLOW_LOCALHOST"))
	cfg.EnableKratosProxy = boolWithDevDefault(cfg.Environment, os.Getenv("CORE_ENABLE_KRATOS_PROXY"))
	cfg.CompareEnabled = boolWithDevDefault(cfg.Environment, os.Getenv("CORE_COMPARE_ENABLED"))

	// Billing.
	cfg.StripeSecretKey = strings.TrimSpace(os.Getenv("STRIPE_SECRET_KEY"))
	cfg.StripeWebhookSecret = strings.TrimSpace(os.Getenv("STRIPE_WEBHOOK_SECRET"))
	cfg.StripeMonthlyPriceID = strings.TrimSpace(os.Getenv("STRIPE_MONTHLY_PRICE_ID"))
	cfg.StripeYearlyPriceID = strings.TrimSpace(os.Getenv("STRIPE_YEARLY_PRICE_ID"))
	cfg.AppleWebhookSecret = strings.TrimSpace(os.Getenv("APPLE_WEBHOOK_SECRET"))
	cfg.GoogleWebhookSecret = strings.TrimSpace(os.Getenv("GOOGLE_WEBHOOK_SECRET"))

	if cfg.HTTPAddr == "" {
		return cfg, errors.New("CORE_HTTP_ADDR cannot be empty")
	}
	return cfg, nil
}

func defaultString(v, fallback string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return fallback
	}
	return v
}

func parseCSV(v string) []string {
	v = strings.TrimSpace(v)
	if v == "" {
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

// corsAllowLocalhost resolves CORE_CORS_ALLOW_LOCALHOST. When unset, dev
// enables localhost CORS; staging/production default to off.
func corsAllowLocalhost(env, override string) bool {
	override = strings.TrimSpace(strings.ToLower(override))
	switch override {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return strings.EqualFold(env, "dev")
}

// boolWithDevDefault resolves env overrides where the default is true in dev
// and false in non-dev environments.
func boolWithDevDefault(env, override string) bool {
	override = strings.TrimSpace(strings.ToLower(override))
	switch override {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return strings.EqualFold(env, "dev")
}
