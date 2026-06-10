# Echo — top-level Makefile.
#
# Standard entry points per docs/07_AI_Agent_Implementation_Guide.md §"Verification".
# Every target must remain exit-0 when nothing relevant has changed (idempotent).

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
# Intentionally NOT using .ONESHELL because we rely on per-line shell isolation
# (each recipe line is its own shell). Recipes that need to chain commands use
# `&&` on the same logical line.

# Default goal — typing `make` with no args prints help.
.DEFAULT_GOAL := help

# Discover whether each toolchain is installed; targets degrade gracefully when
# something is missing so contributors with only one stack present can still
# work on their part of the codebase.
GO_AVAILABLE      := $(shell command -v go      >/dev/null 2>&1 && echo yes)
UV_AVAILABLE      := $(shell command -v uv      >/dev/null 2>&1 && echo yes)
PNPM_AVAILABLE    := $(shell command -v pnpm    >/dev/null 2>&1 && echo yes)
FLUTTER_AVAILABLE := $(shell command -v flutter >/dev/null 2>&1 && echo yes)
DOCKER_COMPOSE    := $(shell docker compose version >/dev/null 2>&1 && echo "docker compose")

# Pinned linter binaries — `go install` respects GOBIN (mise sets it) with a
# fallback to $GOPATH/bin for plain Go installs.
GOPATH := $(shell go env GOPATH 2>/dev/null || echo $$HOME/go)
GOBIN := $(shell go env GOBIN 2>/dev/null)
GO_TOOL_BIN := $(if $(GOBIN),$(GOBIN),$(GOPATH)/bin)
GOLANGCI_LINT := $(GO_TOOL_BIN)/golangci-lint
GOOSE := $(GO_TOOL_BIN)/goose

# Optional repo-root .env for local dev (see .env.example).
ifneq ($(wildcard .env),)
include .env
export
endif

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

.PHONY: help
help:
	@echo "Echo — standard entry points"
	@echo ""
	@echo "Setup:"
	@echo "  make bootstrap        Install per-language dependencies"
	@echo "  make compose-up       docker compose up -d (Postgres, Redis, NATS, Kratos)"
	@echo "  make compose-up-infra docker compose up -d --wait postgres redis (healthcheck-gated)"
	@echo "  make compose-down     docker compose down"
	@echo ""
	@echo "Develop:"
	@echo "  make dev              Print how to run core-go + ml-py locally"
	@echo "  make dev-core         Ensure postgres+redis are up, then run core-go"
	@echo "  make dev-ml           Run ml-py HTTP (uvicorn --reload)"
	@echo "  make dev-ml-grpc      Run ml-py gRPC on :50051"
	@echo "  make dev-asset-worker Run the T-ML-051 JetStream asset worker"
	@echo "  make client           Run Flutter client (auto: chrome without Xcode)"
	@echo "  make client-web-assets Fetch Drift web/sqlite3.wasm + drift_worker.js"
	@echo "  make migrate          Apply database migrations"
	@echo "  make seed             Seed sample content into the database"
	@echo ""
	@echo "Verify:"
	@echo "  make lint             Run all linters (Go, Python, Node)"
	@echo "  make test             Run all unit + integration tests"
	@echo "  make build            Build all services for the current platform"
	@echo "  make validate-content Validate content/ against content-schema"
	@echo "  make validate-assets  Validate 3D asset manifests (content/assets-3d)"
	@echo "  make validate-backdrops Validate vignette-backdrop manifests (content/backdrops)"
	@echo "  make client-content-sync Mirror content/backdrops/ into apps/client/assets/backdrops/"
	@echo "  make simulate         Run tools/playthrough-sim (placeholder until M1)"
	@echo "  make replay           Run tools/trait-replay (placeholder until M1)"
	@echo ""
	@echo "Per-language:"
	@echo "  make go-test          make py-test          make node-test          make flutter-test"
	@echo "  make go-lint          make py-lint          make node-lint          make flutter-analyze"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap: bootstrap-go bootstrap-py bootstrap-node bootstrap-flutter
	@echo "✓ bootstrap complete"

.PHONY: bootstrap-go
bootstrap-go:
ifeq ($(GO_AVAILABLE),yes)
	@echo "→ bootstrapping Go"
	@cd services/core-go && go mod download
	@cd tools/playthrough-sim && [ -f go.mod ] && go mod download || true
	@cd tools/trait-replay && [ -f go.mod ] && go mod download || true
	@echo "→ installing Go tooling (golangci-lint, goose, protoc-gen-go)"
	@go install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2
	@go install github.com/pressly/goose/v3/cmd/goose@v3.22.1
	@go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.0
	@go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
else
	@echo "↷ go not installed; skipping bootstrap-go"
endif

.PHONY: bootstrap-py
bootstrap-py:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ bootstrapping Python (uv)"
	@cd services/ml-py && uv sync
else
	@echo "↷ uv not installed; skipping bootstrap-py"
endif

.PHONY: bootstrap-node
bootstrap-node:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ bootstrapping Node (pnpm)"
	@pnpm install --silent
else
	@echo "↷ pnpm not installed; skipping bootstrap-node"
endif

.PHONY: bootstrap-flutter
bootstrap-flutter:
ifeq ($(FLUTTER_AVAILABLE),yes)
	@echo "→ bootstrapping Flutter (apps/client)"
	@cd apps/client && flutter pub get
else
	@echo "↷ flutter not installed; skipping bootstrap-flutter"
endif

# ---------------------------------------------------------------------------
# Local infrastructure
# ---------------------------------------------------------------------------

.PHONY: compose-up
compose-up:
	@$(DOCKER_COMPOSE) up -d

# Bring up only the two services core-go needs (postgres + redis).
# Uses `--wait` so the target blocks until both healthchecks pass.
.PHONY: compose-up-infra
compose-up-infra:
	@echo "→ starting postgres and redis (waiting for healthy)…"
	@$(DOCKER_COMPOSE) up -d --wait postgres redis

.PHONY: compose-down
compose-down:
	@$(DOCKER_COMPOSE) down

.PHONY: compose-logs
compose-logs:
	@$(DOCKER_COMPOSE) logs -f

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

DATABASE_URL ?= postgres://echo:echo_dev@localhost:5432/echo?sslmode=disable
MIGRATIONS_DIR := services/core-go/db/migrations

.PHONY: migrate
migrate:
	@DATABASE_URL='$(DATABASE_URL)' $(GOOSE) -dir $(MIGRATIONS_DIR) postgres '$(DATABASE_URL)' up

.PHONY: migrate-status
migrate-status:
	@DATABASE_URL='$(DATABASE_URL)' $(GOOSE) -dir $(MIGRATIONS_DIR) postgres '$(DATABASE_URL)' status

.PHONY: migrate-down
migrate-down:
	@DATABASE_URL='$(DATABASE_URL)' $(GOOSE) -dir $(MIGRATIONS_DIR) postgres '$(DATABASE_URL)' down

.PHONY: seed
seed:
	@echo "→ seed: placeholder; real seeding lands with T-CONTENT-002 in M1"

# ---------------------------------------------------------------------------
# Lint
# ---------------------------------------------------------------------------

.PHONY: lint
lint: go-lint py-lint node-lint flutter-analyze
	@echo "✓ lint clean"

.PHONY: go-lint
go-lint:
ifeq ($(GO_AVAILABLE),yes)
	@echo "→ go-lint"
	@cd services/core-go && go vet ./...
	@cd services/core-go && $(GOLANGCI_LINT) run --timeout=5m ./...
else
	@echo "↷ go not installed; skipping go-lint"
endif

.PHONY: py-lint
py-lint:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ py-lint (ruff + mypy)"
	@cd services/ml-py && uv run ruff check .
	@cd services/ml-py && uv run ruff format --check .
	@cd services/ml-py && uv run mypy app
else
	@echo "↷ uv not installed; skipping py-lint"
endif

.PHONY: node-lint
node-lint:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ node-lint"
	@pnpm -r --if-present lint
	@pnpm -r --if-present format:check
else
	@echo "↷ pnpm not installed; skipping node-lint"
endif

.PHONY: flutter-analyze
flutter-analyze:
ifeq ($(FLUTTER_AVAILABLE),yes)
	@echo "→ flutter-analyze (apps/client)"
	@cd apps/client && flutter analyze
else
	@echo "↷ flutter not installed; skipping flutter-analyze"
endif

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

.PHONY: test
test: go-test py-test node-test flutter-test
	@echo "✓ test green"

.PHONY: go-test
go-test:
ifeq ($(GO_AVAILABLE),yes)
	@echo "→ go-test"
	@cd services/core-go && go test ./... -race -count=1
else
	@echo "↷ go not installed; skipping go-test"
endif

.PHONY: py-test
py-test:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ py-test"
	@cd services/ml-py && uv run pytest -q
else
	@echo "↷ uv not installed; skipping py-test"
endif

.PHONY: node-test
node-test:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ node-test"
	@pnpm -r --if-present test
else
	@echo "↷ pnpm not installed; skipping node-test"
endif

.PHONY: flutter-test
flutter-test:
ifeq ($(FLUTTER_AVAILABLE),yes)
	@echo "→ flutter-test (apps/client)"
	@cd apps/client && flutter test
else
	@echo "↷ flutter not installed; skipping flutter-test"
endif

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

.PHONY: build
build: go-build py-build node-build flutter-build
	@echo "✓ build complete"

.PHONY: go-build
go-build:
ifeq ($(GO_AVAILABLE),yes)
	@echo "→ go-build"
	@cd services/core-go && go build -o bin/core ./cmd/core
else
	@echo "↷ go not installed; skipping go-build"
endif

.PHONY: py-build
py-build:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ py-build"
	@cd services/ml-py && uv build
else
	@echo "↷ uv not installed; skipping py-build"
endif

.PHONY: node-build
node-build:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ node-build"
	@pnpm -r --if-present build
else
	@echo "↷ pnpm not installed; skipping node-build"
endif

# flutter-build defaults to the web target because that's the only platform we
# can build on a Linux CI runner without paid macOS / Windows runners. Mobile
# binaries are produced by separate release workflows (T-CLIENT-030, M2).
.PHONY: flutter-build
flutter-build:
ifeq ($(FLUTTER_AVAILABLE),yes)
	@echo "→ flutter-build (web)"
	@cd apps/client && flutter build web --release
else
	@echo "↷ flutter not installed; skipping flutter-build"
endif

# ---------------------------------------------------------------------------
# Content
# ---------------------------------------------------------------------------

.PHONY: validate-content
validate-content:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ validate-content"
	@pnpm --filter @echo/content-validator run validate
else
	@echo "↷ pnpm not installed; skipping validate-content"
endif

.PHONY: validate-assets
validate-assets:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ validate-assets"
	@pnpm --filter @echo/content-validator run validate -- --only assets
else
	@echo "↷ pnpm not installed; skipping validate-assets"
endif

.PHONY: validate-backdrops
validate-backdrops:
ifeq ($(PNPM_AVAILABLE),yes)
	@echo "→ validate-backdrops"
	@pnpm --filter @echo/content-validator run validate -- --only backdrops
else
	@echo "↷ pnpm not installed; skipping validate-backdrops"
endif

# Mirror content/backdrops/ into the Flutter client's asset bundle. The
# client reads the manifest from rootBundle (T-CLIENT-041) so the file has
# to live under apps/client/assets/. Run whenever a backdrop manifest in
# content/ changes; CI runs this and verifies the bundle is up to date.
.PHONY: client-content-sync
client-content-sync:
	@echo "→ client-content-sync"
	@rm -rf apps/client/assets/backdrops
	@mkdir -p apps/client/assets/backdrops
	@cp -R content/backdrops/. apps/client/assets/backdrops/
	@echo "✓ apps/client/assets/backdrops mirrors content/backdrops"

# ---------------------------------------------------------------------------
# Tools (placeholders until M1)
# ---------------------------------------------------------------------------

.PHONY: simulate
simulate:
	@echo "→ simulate: tools/playthrough-sim is a placeholder until M1 (T-CLIENT-011 / T-CORE-010)."
	@echo "  Adding a no-op exit-0 to keep the convention from docs/07."

.PHONY: replay
replay:
	@echo "→ replay: tools/trait-replay is a placeholder until M2 (post T-ML-010)."
	@echo "  Adding a no-op exit-0 to keep the convention from docs/07."

# ---------------------------------------------------------------------------
# Proto codegen (committed to the tree so CI doesn't need protoc)
# ---------------------------------------------------------------------------

PROTO_DIR := packages/proto
GO_PB_OUT := services/core-go/grpc/echopb
PY_PB_OUT := services/ml-py/app/grpc_gen

.PHONY: proto
proto:
	@command -v protoc >/dev/null 2>&1 || (echo "protoc not installed; run make bootstrap-proto" && exit 1)
	@command -v protoc-gen-go >/dev/null 2>&1 || (echo "protoc-gen-go not installed; run make bootstrap-proto" && exit 1)
	@command -v protoc-gen-go-grpc >/dev/null 2>&1 || (echo "protoc-gen-go-grpc not installed; run make bootstrap-proto" && exit 1)
	@mkdir -p $(GO_PB_OUT) $(PY_PB_OUT)
	@touch $(PY_PB_OUT)/__init__.py
	@protoc -I=$(PROTO_DIR) \
		--go_out=$(GO_PB_OUT) --go_opt=paths=source_relative \
		--go-grpc_out=$(GO_PB_OUT) --go-grpc_opt=paths=source_relative \
		$(PROTO_DIR)/trait_scoring.proto \
		$(PROTO_DIR)/portrait_gen.proto \
		$(PROTO_DIR)/reflection_gen.proto \
		$(PROTO_DIR)/asset_gen.proto
	@cd services/ml-py && uv run python -m grpc_tools.protoc \
		-I=../../$(PROTO_DIR) \
		--python_out=app/grpc_gen \
		--grpc_python_out=app/grpc_gen \
		../../$(PROTO_DIR)/trait_scoring.proto \
		../../$(PROTO_DIR)/portrait_gen.proto \
		../../$(PROTO_DIR)/reflection_gen.proto \
		../../$(PROTO_DIR)/asset_gen.proto
	@# grpc_tools emits absolute imports (`import trait_scoring_pb2`) which
	@# break when the package is imported as `app.grpc_gen`. Patch them to
	@# explicit relative imports so the generated module is portable.
	@for p in trait_scoring portrait_gen reflection_gen asset_gen; do \
		perl -pi -e "s/^import \$${p}_pb2 as /from . import \$${p}_pb2 as /" \
			$(PY_PB_OUT)/\$${p}_pb2_grpc.py; \
	done
	@echo "✓ proto stubs regenerated under $(GO_PB_OUT) and $(PY_PB_OUT)"

.PHONY: bootstrap-proto
bootstrap-proto:
	@echo "→ installing Go proto plugins"
	@go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.0
	@go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
	@echo "→ Python protoc tooling is a uv dev-dep on grpcio-tools; already in pyproject.toml"

# ---------------------------------------------------------------------------
# Dev (long-running)
# ---------------------------------------------------------------------------

.PHONY: dev
dev:
	@echo "→ dev: postgres+redis start automatically with dev-core."
	@echo "  For the full stack (NATS, Kratos, MailHog) run: make compose-up"
	@echo "    cp -n .env.example .env   # once per machine"
	@echo "    make migrate              # first time or after schema changes"
	@echo "    make dev-core             # terminal 1 — core-go on :8081 (starts postgres+redis)"
	@echo "    make dev-ml-grpc          # terminal 2 — ml-py gRPC on :50051 (optional)"
	@echo "    make client               # terminal 3 — Flutter client"

.PHONY: dev-core
dev-core: compose-up-infra
ifeq ($(GO_AVAILABLE),yes)
	@test -f .env || (echo "→ copy .env.example to .env and adjust paths if needed" && exit 1)
	@echo "→ dev-core (HTTP $${CORE_HTTP_ADDR:-:8081})"
	@cd services/core-go && go run ./cmd/core
else
	@echo "↷ go not installed; cannot run dev-core"
	@exit 1
endif

.PHONY: dev-ml
dev-ml:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ dev-ml (HTTP uvicorn --reload)"
	@cd services/ml-py && uv run uvicorn app.main:app --reload
else
	@echo "↷ uv not installed; cannot run dev-ml"
	@exit 1
endif

.PHONY: dev-ml-grpc
dev-ml-grpc:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ dev-ml-grpc (gRPC :50051)"
	@cd services/ml-py && uv run python -m app.grpc_server
else
	@echo "↷ uv not installed; cannot run dev-ml-grpc"
	@exit 1
endif

.PHONY: dev-asset-worker
dev-asset-worker:
ifeq ($(UV_AVAILABLE),yes)
	@echo "→ dev-asset-worker (JetStream)"
	@cd services/ml-py && uv sync --extra asset-worker
	@cd services/ml-py && uv run python -m app.services.asset_gen.worker_main
else
	@echo "↷ uv not installed; cannot run dev-asset-worker"
	@exit 1
endif

# PLATFORM selects the Flutter device (macos, ios, android, chrome, ...).
# Default to chrome when full Xcode.app is not active — macOS desktop builds
# need `xcodebuild` from Xcode, not Command Line Tools alone.
FLUTTER_WEB_PORT ?= 8082
XCODE_BUILD_AVAILABLE := $(shell xcodebuild -version >/dev/null 2>&1 && echo yes)
ifeq ($(PLATFORM),)
  ifeq ($(XCODE_BUILD_AVAILABLE),yes)
    PLATFORM := macos
  else
    PLATFORM := chrome
  endif
endif

.PHONY: client-web-assets
client-web-assets:
	@chmod +x apps/client/tool/fetch_drift_web_assets.sh
	@apps/client/tool/fetch_drift_web_assets.sh

.PHONY: client
client:
ifeq ($(FLUTTER_AVAILABLE),yes)
ifeq ($(PLATFORM),chrome)
	@test -f apps/client/web/sqlite3.wasm || $(MAKE) client-web-assets
	@echo "→ flutter web port $(FLUTTER_WEB_PORT)"
	@cd apps/client && flutter pub get && flutter run -d chrome --web-port=$(FLUTTER_WEB_PORT)
else
	@echo "→ flutter run -d $(PLATFORM)"
	@cd apps/client && flutter pub get && flutter run -d $(PLATFORM)
endif
else
	@echo "↷ flutter not installed; cannot run client"
	@exit 1
endif
