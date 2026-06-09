# 07 — AI Agent Implementation Guide

> This document is written for **AI coding agents** (Claude Code, Cursor, Devin, Aider, etc.) and the humans supervising them. It is structured to be machine-friendly: explicit conventions, deterministic task IDs, clear acceptance criteria, and verification commands.

## How to use this document

1. **Read `06_Tech_Stack.md` first.** This guide assumes those tech choices.
2. **Tasks are organized as `EPIC → STORY → TASK`.** Each task has a stable ID like `T-CLIENT-001`. Track tasks against their IDs in your task system.
3. **Tasks have explicit acceptance criteria.** A task is done when its acceptance criteria pass automated verification.
4. **Verification commands are runnable.** If a verification step doesn't pass cleanly from the repo root, the task is not done.
5. **When in doubt, prefer reversible decisions.** Code that's wrong but easy to change is acceptable; architectural decisions baked across many files require human review before changing.

---

## Monorepo layout

The entire project is one git monorepo, with the following top-level structure:

```
echo/
├── apps/
│   ├── client/              # Flutter — iOS, Android, Windows, macOS
│   ├── share-web/           # Public Portrait sharing pages (Next.js or SvelteKit)
│   └── b2b-dashboard/       # Institutional web dashboard (V2; same web stack)
├── services/
│   ├── core-go/             # Modular monolith: auth, users, playthroughs, events, sharing, org
│   └── ml-py/               # Trait scoring, Portrait gen, reflection gen, safety classify, content CMS
├── packages/
│   ├── proto/               # Protobuf definitions for gRPC + GraphQL schemas
│   ├── design-tokens/       # Colors, typography, spacing — shared by client and web
│   └── content-schema/      # JSON Schemas for Vignettes, Seasons, Trait weights
├── infra/
│   ├── docker/              # Dockerfiles and docker-compose.yml for local dev
│   ├── k8s/                 # Kubernetes manifests, Kustomize bases and overlays
│   ├── flyio/               # Fly.io configs for phase-0 hosting
│   ├── terraform/           # Cloud resources (Cloudflare, DNS, R2 buckets, GKE)
│   └── argocd/              # GitOps manifests (phase-1)
├── content/
│   ├── seasons/             # Season YAML/JSON definitions (vignettes, weights)
│   ├── reflection-templates/# Templated reflection prompts and exemplars
│   └── art-tokens/          # Parameters for portrait rendering
├── tools/
│   ├── content-validator/   # CLI: validates Season files against content-schema
│   ├── playthrough-sim/     # CLI: deterministic playthrough simulator for testing
│   └── trait-replay/        # CLI: replays a playthrough and recomputes the trait vector
├── docs/                    # This documentation set lives here
├── .github/workflows/       # CI pipelines
├── .tool-versions           # Pinned toolchain versions (managed by mise)
├── docker-compose.yml       # One-command local stack
├── Makefile                 # Standardized entry points (make dev, make test, make build, etc.)
└── README.md
```

### Why monorepo

- Cross-cutting changes (schema → service → client) land atomically.
- Single source of truth for design tokens and content schemas.
- One CI configuration; one onboarding command.
- Encourages module boundaries to be explicit rather than implicit.

---

## Universal conventions

These apply to **every** AI-agent task across every part of the codebase.

### Naming

- **Files:** `snake_case` for Go, Python, and content YAML; `lower_snake_case.dart` for Dart; `kebab-case.ts` for web TypeScript.
- **Types and classes:** `PascalCase` everywhere.
- **Constants:** `SCREAMING_SNAKE_CASE`.
- **Database tables:** `snake_case`, plural (`users`, `playthroughs`, `vignette_events`).
- **Postgres columns:** `snake_case`.
- **GraphQL fields:** `camelCase`.
- **Protobuf:** `snake_case` field names per protobuf style guide.

### Branching and commits

- Branch naming: `<type>/<task-id>-<short-slug>`, e.g. `feat/T-CLIENT-014-vignette-renderer`.
- Conventional Commits: `feat(client): ...`, `fix(core-go): ...`, `chore(infra): ...`.
- Squash-merge into `main`. `main` is always deployable.

### Testing requirements

- **No PR without tests** for new behavior. Test types and minimum coverage targets:
  - Go: unit + integration tests; target ≥75% line coverage per package.
  - Python: pytest unit + integration; target ≥75% line coverage per module.
  - Dart: widget + golden tests for any visual surface; integration tests for full playthrough.
- **Tests must be deterministic.** No flake-tolerated tests in CI.
- **Golden tests** are required for any Portrait rendering code; brand-critical visual regressions fail CI hard.

### Code review (for human supervisor of AI agent)

- Every PR includes a "what I changed and why" summary in the description.
- Architectural changes (new service, new dependency, schema migration) require explicit human approval before merge.
- AI agents do not approve their own PRs.

### Safety rails for AI agents

- **Database migrations** must be backwards-compatible (additive, never destructive in a single deploy). Drop columns/tables only after observability confirms no traffic. This is a hard rule.
- **Secrets:** Never commit secrets. CI verifies via `gitleaks`.
- **Dependencies:** Adding a new top-level dependency requires explicit justification in the PR description. Transitive dependencies via existing libraries do not.
- **No `force-push` to `main` or any release branch.** Ever.

---

## Setup — first run from clean machine

Every AI agent or developer should be able to bring the whole stack up with these commands and nothing else:

```bash
# 1. Install toolchain (mise reads .tool-versions)
mise install

# 2. Install dependencies for each language
make bootstrap

# 3. Bring up local stack (Postgres, Redis, NATS, services)
docker compose up -d

# 4. Run database migrations
make migrate

# 5. Seed sample content
make seed

# 6. Run tests to confirm everything works
make test
```

`make dev` then runs all services in watch mode. Client is launched separately with `make client` (selects target platform interactively or via `PLATFORM=ios|android|windows|macos`).

If any of these commands fails on a clean checkout, **fixing that is higher priority than any other task**.

---

## Task IDs and milestones

Tasks are grouped by milestone, then epic. Within an epic, tasks are ordered by execution dependency.

```
T-<AREA>-<NNN>
   ├─ AREA: CLIENT | CORE | ML | INFRA | CONTENT | WEB | B2B | TEST | DOCS
   └─ NNN: zero-padded sequence number
```

The list below is **not exhaustive**; it's the spine. Each task on this list will have a fuller specification in the task tracker.

---

## MILESTONE M0 — Foundation (Weeks 1–4)

### Epic: Monorepo and tooling

- **T-INFRA-001** — Initialize monorepo structure as documented above.
  - Accept: `tree -L 2` matches the layout.
- **T-INFRA-002** — Configure `.tool-versions` (Go 1.23, Python 3.12, Dart 3.6, Node 22).
  - Accept: `mise install && mise current` lists all four at correct versions.
- **T-INFRA-003** — Author `docker-compose.yml` with Postgres 16, Redis 7, NATS 2.10.
  - Accept: `docker compose up -d` brings all three up healthy.
- **T-INFRA-004** — `Makefile` with `bootstrap`, `dev`, `test`, `migrate`, `seed`, `lint`, `build` targets.
  - Accept: each target exits 0 after one full setup.
- **T-INFRA-005** — GitHub Actions CI: per-language linters, tests, build verification.
  - Accept: a PR with no changes fails no checks; a PR introducing a lint error fails.

### Epic: Core service scaffolding

- **T-CORE-001** — Initialize `services/core-go/` with module structure: `auth/`, `playthrough/`, `events/`, `sharing/`, `org/`, `http/`, `grpc/`, `db/`.
  - Accept: `go build ./...` succeeds; module boundaries enforced via import linting.
- **T-CORE-002** — Postgres connection pool (pgx) + sqlc for typed queries.
  - Accept: example query roundtrips against local Postgres in a unit test.
- **T-CORE-003** — Database migration tool: `goose` or `golang-migrate`. Migrations stored in `services/core-go/db/migrations/`.
  - Accept: `make migrate` creates schemas `auth`, `playthrough`, `events`, `sharing`, `org`.
- **T-CORE-004** — Health/readiness endpoints `/healthz`, `/readyz`.
  - Accept: returns 200 when DB and Redis reachable; 503 otherwise.
- **T-CORE-005** — Structured logging (zerolog or slog), OpenTelemetry tracing scaffold.
  - Accept: a single inbound request produces a trace with at least three spans (handler → service → db).

### Epic: ML service scaffolding

- **T-ML-001** — Initialize `services/ml-py/` with FastAPI + uvicorn, `uv` for deps.
  - Accept: `uvicorn app:app` serves `/healthz`.
- **T-ML-002** — Protobuf-generated gRPC server for `TraitScoringService`, `ReflectionGenService`, `PortraitGenService`. Service stubs return `Unimplemented`.
  - Accept: gRPC client in Go reaches each stub.

### Epic: Client scaffolding

- **T-CLIENT-001** — `flutter create` with the four target platforms enabled.
  - Accept: `flutter build apk`, `flutter build ipa`, `flutter build windows`, `flutter build macos` all succeed on CI.
- **T-CLIENT-002** — Riverpod + go_router + ferry GraphQL client wired.
  - Accept: a sample screen reads a value from a Riverpod provider and renders.
- **T-CLIENT-003** — Drift database scaffolded with a `playthrough_state` table.
  - Accept: round-trip a record locally; encrypted at rest.

---

## MILESTONE M1 — One playable vignette end-to-end (Weeks 5–9)

The vertical slice: a single vignette renders on the client, the player makes a choice, the choice persists locally, syncs to the server, and a trivial trait increment is recorded.

### Epic: Content pipeline

- **T-CONTENT-001** — JSON Schema for `Season`, `Act`, `Vignette`, `Choice`, `TraitWeight`.
  - Accept: schema published in `packages/content-schema/`; `tools/content-validator/` validates a sample Season.
- **T-CONTENT-002** — `content/seasons/season-001/` populated with a single test vignette and full trait weights.
  - Accept: validator passes; loading the file produces a typed Go/Python/Dart struct.
- **T-CONTENT-003** — Content loading endpoint in `core-go`: `GetSeason(id) -> Season`.
  - Accept: client can fetch the seeded Season.

### Epic: Playthrough flow

- **T-CLIENT-010** — Vignette renderer widget: setting beat, choice list, resolution beat.
  - Accept: golden test passes against reference design.
- **T-CLIENT-011** — Choice handler: records `Choice` event locally (Drift) and queues a sync.
  - Accept: integration test simulates a choice and verifies local persistence.
- **T-CORE-010** — `RecordChoice(playthrough_id, vignette_id, choice_id, timing_meta)` API.
  - Accept: persisted to `playthrough.choice_events`; idempotent on retry.
- **T-CLIENT-012** — Background sync: pending events drain to server when connectivity available.
  - Accept: integration test takes the client offline, makes choices, comes back online, sync completes.

### Epic: Trait scoring (rule-based v1)

- **T-ML-010** — Implement rule-based trait scoring: given a list of `Choice` events with associated weights, produce a `TraitVector` (5 Big Five + 10 Schwartz).
  - Accept: deterministic output for a given input; unit tests cover the weight aggregation logic.
- **T-CORE-011** — On playthrough completion, `core-go` calls `ml-py` `TraitScoringService.Score(playthrough_id)` via gRPC and persists the result.
  - Accept: integration test runs a full playthrough and verifies a `TraitVector` row exists.

### Epic: Portrait + reflection (stubs in M1)

- **T-ML-020** — Portrait generation stub: returns a placeholder PNG keyed by trait vector.
  - Accept: same trait vector → same PNG; different vector → different PNG.
- **T-ML-021** — Reflection generation stub: returns a templated string with no LLM call.
  - Accept: response includes recognizable trait-derived language.

---

## MILESTONE M2 — Full Season MVP (Weeks 10–22)

Everything from M1 plus: full Season content, real parametric Portrait, real LLM reflection, auth, account flow, youth-safe routing, basic sharing.

### Epic: Real parametric Portrait

- **T-ML-030** — Portrait renderer using Pillow/Cairo, deterministic from `(TraitVector, seed)`.
  - Accept: golden tests for 10 representative trait vectors.
- **T-ML-031** — Animated WebP output for in-app/Story display.
  - Accept: animation loops smoothly; file size < 800 KB at 1080×1080.

### Epic: Real reflection pipeline

- **T-ML-040** — Reflection template library in `content/reflection-templates/`.
  - Accept: ≥50 templates; each has exemplar outputs and brand-voice notes.
- **T-ML-041** — LLM client abstraction with multi-provider routing (Anthropic primary, OpenAI fallback, configurable per environment).
  - Accept: a forced failure on primary routes to fallback with no caller change.
- **T-ML-042** — Reflection pipeline: trait vector + signal moments → template → LLM → safety classify → tone classify → output.
  - Accept: end-to-end test produces a reflection that passes both classifiers for a happy-path input; fails closed for a contrived problematic input.

### Epic: Auth and accounts

- **T-INFRA-020** — Deploy Ory Kratos to local stack and dev environment.
  - Accept: Kratos identities, sessions, and recovery flows functional.
- **T-CORE-020** — Integrate Kratos: session middleware, user provisioning, OAuth provider configuration.
  - Accept: sign-up, login, password reset, account deletion all work end-to-end.
- **T-CLIENT-020** — Sign-up / login / settings flows in the client.
  - Accept: full account lifecycle achievable from the client UI.
- **T-CORE-021** — Age gating: under-13 blocked at sign-up; 13–17 routed into youth-safe flow with a flag on the user record.
  - Accept: integration tests cover all three age branches.

### Epic: Sharing

- **T-CORE-030** — Sharing endpoint that returns a public Portrait URL.
  - Accept: shareable URL renders the Portrait page via `share-web` (Next.js/SvelteKit).
- **T-WEB-001** — `share-web` Portrait page: SEO-friendly, animated Portrait, reflection, CTA to download Echo.
  - Accept: Lighthouse score ≥90 on all four categories.
- **T-CLIENT-030** — System share sheet integration on each platform.
  - Accept: sharing produces a high-res image plus the public URL.

---

## MILESTONE M3 — Public launch on all four platforms (Weeks 23–38)

### Highlights

- **T-CLIENT-100** — Windows and macOS builds production-ready, code-signed and notarized.
- **T-CORE-050** — Second Season content fully integrated; trait re-calibration verified against beta data.
- **T-MONEY-001** — Subscription billing (Apple IAP + Google Play Billing + Stripe).
- **T-SOCIAL-001** — Friend comparison feature end-to-end.
- **T-INFRA-050** — Migrate from Fly.io to GKE (EU region).
- **T-INFRA-051** — Linkerd service mesh installed; mTLS between all internal services.
- **T-INFRA-052** — Backup/restore drills documented and rehearsed.

---

## MILESTONE M4 — Institutional (V2) (Weeks 39–60)

### Highlights

- **T-B2B-001** — `org` module evolves into a candidate split-out service.
- **T-B2B-010** — Institution onboarding, seat assignment, billing.
- **T-B2B-020** — Educator dashboard: aggregate cohort views, individual Portraits with explicit consent.
- **T-COMPLIANCE-001** — SOC 2 Type I audit initiated.
- **T-COMPLIANCE-002** — DPA template, sub-processor list, security questionnaire response prepared.

---

## Verification — golden command list

Any AI agent finishing a task should be able to run:

```bash
make lint        # All linters: golangci-lint, ruff, mypy, dart analyze, prettier
make test        # All unit + integration tests across services and client
make build       # All build targets for current platform
make simulate    # tools/playthrough-sim runs a deterministic playthrough end-to-end
```

All four must exit zero before claiming a task complete.

For client work:

```bash
PLATFORM=ios     make client-test    # widget + integration + golden tests
PLATFORM=android make client-test
PLATFORM=windows make client-test
PLATFORM=macos   make client-test
```

For schema or content changes:

```bash
make validate-content   # tools/content-validator over all of content/
make replay             # tools/trait-replay over a corpus of test playthroughs
```

If a content change causes `replay` to produce *different* trait vectors for unchanged playthroughs, that is a breaking change and requires human review.

---

## What AI agents should escalate to humans

These categories should never be merged by an AI agent without human review and approval:

1. **New top-level dependency** in any service.
2. **Schema migration that drops or renames** columns, tables, or schemas.
3. **Changes to authentication, authorization, or session handling.**
4. **Changes to the trait scoring engine** that could shift trait vectors for existing playthroughs.
5. **Changes to safety or tone classifiers.**
6. **Changes touching anything in `/content/reflection-templates/`** beyond formatting.
7. **Changes to age-gating, consent flows, or anything in the youth-safe path.**
8. **Changes to data-residency configuration, region pinning, or backup encryption.**
9. **Anything that affects the public API contract used by clients in the wild.**
10. **Changes to billing logic.**

When an AI agent identifies that a task touches one of these areas, it should produce the change in a branch, open the PR with a `human-review-required` label and a clear summary, and stop.

---

## Working agreement with AI agents

If you are an AI agent reading this:

- Read the relevant docs in `/docs/` before starting any task. The product-level context lives in `01_Product_Vision`, `03_Product_Requirements`, and `04_Game_Design`. The technical-level context lives in `05_Technical_Architecture` and `06_Tech_Stack`.
- Prefer asking targeted questions over making invisible assumptions. Especially on the trait-engine and youth-safe paths.
- When a task is ambiguous, write the most boring, smallest, most reversible solution that satisfies the acceptance criteria.
- When in doubt about which of two valid approaches to take, leave a clearly-labeled comment with the choice and the alternative considered, and proceed.
- Treat the conventions in this document as binding. Conformance failures block merge regardless of correctness.
