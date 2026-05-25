// Package main is the entrypoint for the Echo core monolith.
//
// The service exposes:
//   - HTTP on $CORE_HTTP_ADDR (default ":8080") with /healthz and /readyz
//   - gRPC on $CORE_GRPC_ADDR (default ":9090") (wired in M1; not bound yet)
//
// The HTTP server is the surface the orchestrator (Fly.io / GKE) reads to
// determine liveness and readiness. Per docs/07_AI_Agent_Implementation_Guide.md
// T-CORE-004:
//
//	/healthz  - returns 200 if the process is up.
//	/readyz   - returns 200 only when Postgres and Redis are reachable.
//
// The service is the spine of the modular monolith. Domain modules live in
// auth/, playthrough/, events/, sharing/, and org/ siblings and are wired
// into HTTP / gRPC handlers as the M1 vertical slice lands.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ahmed-abdelhaleem/echo/services/core-go/auth"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/content"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/db"
	coregrpc "github.com/ahmed-abdelhaleem/echo/services/core-go/grpc"
	corehttp "github.com/ahmed-abdelhaleem/echo/services/core-go/http"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/internal/config"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/internal/telemetry"
	"github.com/ahmed-abdelhaleem/echo/services/core-go/playthrough"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	cfg, err := config.Load()
	if err != nil {
		logger.Error("config load failed", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Telemetry — currently configured to use a no-op exporter when no OTLP
	// endpoint is set. This keeps local dev silent while the Grafana stack
	// from docs/06_Tech_Stack.md is still being set up.
	shutdownTelemetry, err := telemetry.Setup(ctx, telemetry.Options{
		ServiceName:  "core-go",
		OTLPEndpoint: cfg.OTLPEndpoint,
	})
	if err != nil {
		logger.Error("telemetry setup failed", "err", err)
		os.Exit(1)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = shutdownTelemetry(shutdownCtx)
	}()

	// Connect to data plane. In dev we tolerate Postgres/Redis being absent so
	// `go run ./cmd/core` works in a barebones environment; readiness will
	// reflect actual connectivity.
	deps := corehttp.Dependencies{
		Logger: logger,
	}
	if cfg.DatabaseURL != "" {
		pool, err := db.Connect(ctx, cfg.DatabaseURL)
		if err != nil {
			logger.Warn("postgres not reachable at startup; /readyz will return 503", "err", err)
		} else {
			deps.PG = pool
			defer pool.Close()
		}
	}
	if cfg.RedisURL != "" {
		rc, err := db.ConnectRedis(ctx, cfg.RedisURL)
		if err != nil {
			logger.Warn("redis not reachable at startup; /readyz will return 503", "err", err)
		} else {
			deps.Redis = rc
			defer func() { _ = rc.Close() }()
		}
	}

	// Auth — disabled if the Kratos URL isn't set, so `go run ./cmd/core`
	// still boots in a barebones environment for unrelated work. The
	// /whoami route is only registered when Auth is wired.
	if cfg.KratosPublicURL != "" {
		kc := auth.NewKratosClient(cfg.KratosPublicURL, cfg.KratosAdminURL, nil)
		deps.Auth = auth.New(kc)
		logger.Info("auth enabled", "kratos_public_url", cfg.KratosPublicURL)
	} else {
		logger.Info("auth disabled; KRATOS_PUBLIC_URL not set")
	}

	// Content — disabled if CONTENT_ROOT isn't set. In docker-compose this
	// is `/srv/content` (bind-mounted from the repo's `content/` folder);
	// for `go run ./cmd/core` from the repo root it can be `./content`.
	if cfg.ContentRoot != "" {
		deps.Content = content.NewService(content.NewFilesystemLoader(cfg.ContentRoot))
		logger.Info("content enabled", "content_root", cfg.ContentRoot)
	} else {
		logger.Info("content disabled; CONTENT_ROOT not set")
	}

	// Trait scoring + Portrait + Reflection share a single gRPC
	// connection to ml-py. When ML_GRPC_ADDR isn't set, all three
	// dependencies stay nil and the relevant endpoints surface 503 so
	// the player can retry once the ml-py wiring is up.
	var (
		scorer        playthrough.TraitScorer
		portraitGen   playthrough.PortraitGenerator
		reflectionGen playthrough.ReflectionGenerator
	)
	if cfg.MLgRPCAddr != "" {
		mlClient, err := coregrpc.DialML(ctx, cfg.MLgRPCAddr)
		if err != nil {
			logger.Warn("ml gRPC not reachable at startup; trait scoring + portrait + reflection disabled", "err", err)
		} else {
			scorer = mlClient
			portraitGen = mlClient
			reflectionGen = mlClient
			defer func() { _ = mlClient.Close() }()
			logger.Info("ml dependencies enabled", "ml_grpc_addr", cfg.MLgRPCAddr)
		}
	} else {
		logger.Info("ml dependencies disabled; ML_GRPC_ADDR not set")
	}

	// Playthrough — requires Postgres + Content. Auth is checked at route
	// registration time so the routes only appear when the full chain is
	// wired.
	if deps.PG != nil && deps.Content != nil {
		deps.Users = auth.NewPgUsersRepository(deps.PG)
		deps.Playthrough = playthrough.
			NewService(playthrough.NewPgRepository(deps.PG), deps.Content, scorer).
			WithPortraitGenerator(portraitGen).
			WithReflectionGenerator(reflectionGen)
		logger.Info("playthrough enabled")
	} else {
		logger.Info("playthrough disabled; postgres or content not available")
	}

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           corehttp.NewMux(deps),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Info("core-go starting", "http_addr", cfg.HTTPAddr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http server crashed", "err", err)
			stop()
		}
	}()

	<-ctx.Done()
	logger.Info("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("http shutdown failed", "err", err)
	}
	logger.Info("core-go stopped")
}
