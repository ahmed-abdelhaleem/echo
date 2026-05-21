# `services/core-go`

The Echo core monolith. Per `docs/05_Technical_Architecture.md` this is a
single Go binary with modular boundaries that map to future service splits.

## Module layout

```
services/core-go/
├── cmd/core/            # main entrypoint
├── internal/
│   ├── config/          # env-var config loader
│   └── telemetry/       # OpenTelemetry setup
├── db/
│   ├── db.go            # pgxpool + redis client constructors
│   └── migrations/      # goose .sql migrations
├── http/                # HTTP surface (/healthz, /readyz, future GraphQL gateway)
├── grpc/                # gRPC clients to ml-py and (future) other services
├── auth/                # M2: Ory Kratos integration, sessions
├── playthrough/         # M1: start/pause/resume/complete a playthrough
├── events/              # M1: ingest per-vignette events
├── sharing/             # M2: public Portrait URLs, share-web payloads
└── org/                 # M4: institutions, cohorts, seats, consent
```

Domain modules under `auth/`, `playthrough/`, `events/`, `sharing/`, `org/`
intentionally start as placeholder packages so the boundary is enforced by
the package layout from day one and future PRs accumulate inside their
package without restructuring the tree.

## Build / run

```bash
go test ./...
go build -o bin/core ./cmd/core
go run ./cmd/core
```

Env vars consumed:

| Var | Default | Purpose |
|---|---|---|
| `CORE_HTTP_ADDR` | `:8080` | HTTP listen address |
| `CORE_GRPC_ADDR` | `:9090` | gRPC listen address (M1) |
| `DATABASE_URL` | unset | Postgres libpq URL; absent → `/readyz` returns 503 |
| `REDIS_URL` | unset | Redis URL; absent → `/readyz` returns 503 |
| `OTLP_ENDPOINT` | unset | OpenTelemetry collector |
| `ECHO_ENV` | `dev` | Environment label |
