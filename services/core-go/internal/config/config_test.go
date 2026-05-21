package config

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestLoadDefaults(t *testing.T) {
	t.Setenv("CORE_HTTP_ADDR", "")
	t.Setenv("CORE_GRPC_ADDR", "")
	t.Setenv("DATABASE_URL", "")
	t.Setenv("REDIS_URL", "")
	t.Setenv("OTLP_ENDPOINT", "")
	t.Setenv("ECHO_ENV", "")

	cfg, err := Load()
	require.NoError(t, err)
	require.Equal(t, ":8080", cfg.HTTPAddr)
	require.Equal(t, ":9090", cfg.GRPCAddr)
	require.Equal(t, "dev", cfg.Environment)
	require.Empty(t, cfg.DatabaseURL)
	require.Empty(t, cfg.RedisURL)
}

func TestLoadOverrides(t *testing.T) {
	t.Setenv("CORE_HTTP_ADDR", ":9000")
	t.Setenv("DATABASE_URL", "postgres://localhost/echo")
	t.Setenv("REDIS_URL", "redis://localhost:6379")
	t.Setenv("ECHO_ENV", "production")

	cfg, err := Load()
	require.NoError(t, err)
	require.Equal(t, ":9000", cfg.HTTPAddr)
	require.Equal(t, "postgres://localhost/echo", cfg.DatabaseURL)
	require.Equal(t, "redis://localhost:6379", cfg.RedisURL)
	require.Equal(t, "production", cfg.Environment)
}
