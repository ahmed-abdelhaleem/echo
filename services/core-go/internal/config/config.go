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

	// Environment is the deployment environment label (dev|staging|production).
	Environment string
}

// Load reads the configuration from the environment, applying defaults.
// Returns an error only when an explicitly-required value is malformed.
func Load() (Config, error) {
	cfg := Config{
		HTTPAddr:        defaultString(os.Getenv("CORE_HTTP_ADDR"), ":8080"),
		GRPCAddr:        defaultString(os.Getenv("CORE_GRPC_ADDR"), ":9090"),
		DatabaseURL:     strings.TrimSpace(os.Getenv("DATABASE_URL")),
		RedisURL:        strings.TrimSpace(os.Getenv("REDIS_URL")),
		OTLPEndpoint:    strings.TrimSpace(os.Getenv("OTLP_ENDPOINT")),
		KratosPublicURL: strings.TrimSpace(os.Getenv("KRATOS_PUBLIC_URL")),
		KratosAdminURL:  strings.TrimSpace(os.Getenv("KRATOS_ADMIN_URL")),
		Environment:     defaultString(os.Getenv("ECHO_ENV"), "dev"),
	}

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
