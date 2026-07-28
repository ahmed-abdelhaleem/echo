# 06 — Tech Stack Specification

> This document is the authoritative source for **what** is used. The architecture document explains **why** at the system level; this one drills into specific technologies, versions, and the alternatives considered for each.

## Format conventions

Every choice in this document follows the same structure:

```
TECHNOLOGY · CATEGORY
- Version: <minimum acceptable>
- Role: <what it does in Echo>
- Why this: <key reasons it wins>
- Alternatives considered: <runner-ups and why they lost>
- Lock-in risk: <Low / Medium / High>
- Replace path: <how we'd swap it out if needed>
```

The **Replace path** field exists so that future-us, future-team, or an AI agent maintaining this codebase always knows the migration route.

---

## Client

### Unity 6 Personal · Authoritative cross-platform game client
- **Version:** Unity `6000.5.4f1` or a compatible Unity 6 LTS editor
- **Role:** Authoritative client for Echo's explorable 3D game on iOS, Android, Windows, macOS, and WebGL. Source lives in `apps/unity-client`.
- **Why this:** Mature 3D rendering, animation, lighting, profiling, accessibility hooks, automated play-mode tests, and one C# project for all game targets.
- **Gameplay/rendering profile:** URP, Input System, CharacterController,
  componentized vignette director/interactables/objective UI, collision-aware
  third-person camera, authored PBR art, and deterministic play-mode coverage.
- **Free author-time asset stack:** Blender validation/optimization, vetted CC0
  Poly Haven environment models, and optional local Mixamo humanoids and
  animation. See `14_Graphics_Gameplay_Production_Plan`.
- **Alternatives considered:** Godot 4 (viable and open source, but would add a second migration while the current Unity prototype already proves the target); Flutter/Thermion (retained as migration reference/fallback but did not deliver a production-quality game world).
- **Lock-in risk:** Medium. Scenes and gameplay code use Unity APIs, while source meshes, textures, animation, content schemas, and backend contracts remain portable.
- **Replace path:** Export source assets in standard FBX/GLB formats and rebuild the thin scene/gameplay layer in another engine.

### Flutter · Legacy 2D client and migration reference
- **Version:** Flutter 3.44+ (Dart 3.12+ runtime; app language remains 3.6)
- **Role:** Preserves the earlier 2D implementation, content/data integration, and an atmospheric fallback during Unity migration. It is not the final 3D game foundation.
- **Why this:** Existing code remains useful as a behavioral reference while equivalent playthrough, Portrait, persistence, and accessibility behavior moves into Unity.
- **Lock-in risk:** Low because no new Phase-G 3D feature should depend on it.
- **Replace path:** Retire after Unity reaches the Game-Complete gate and all required fallback behavior is covered.

### Drift · Local persistence (SQLite wrapper for Flutter)
- **Version:** Drift 2.x
- **Role:** Offline-first storage of playthrough state, choice events, cached Portraits.
- **Why this:** Typed Dart API over SQLite, generated migrations, async-first.
- **Alternatives considered:** Isar (faster but younger ecosystem), Hive (key-value, not relational enough for our needs).
- **Lock-in risk:** Low. SQLite data is portable; Drift is a wrapper.
- **Replace path:** Migrate to direct `sqflite` or another SQLite wrapper; data files are standard.

### Rive · Interactive animation runtime
- **Version:** Rive 0.13+ Flutter runtime
- **Role:** Atmospheric animations in vignettes; animated portrait playback.
- **Why this:** State-machine driven animations, runs identically on all four platforms, very small runtime, animations authored in Rive's editor by a designer without engineering involvement.
- **Alternatives considered:** Lottie (JSON-based, less expressive for state-driven motion), Flutter's built-in animations only (sufficient for UI motion but underpowered for atmosphere).
- **Lock-in risk:** Low. Rive files are exportable to Lottie if needed.
- **Replace path:** Lottie + custom Flutter animations.

### Blender + verified free assets · 3D content production
- **Version:** Blender 5.2 LTS locally; authoring scripts must declare compatibility
- **Role:** Render explorable 3D diorama environments, props, and animated NPCs for Echo vignettes. Replaces the former automated AI generation (Meshy/TRELLIS) and Thermion/Filament Flutter experiment, which are not the foundation of the final game.
- **Backend & Core Retained:** The Go core backend services, Python ML & trait scoring engine, writing, and season content schemas are fully salvageable and retained.
- **Why this:** Human-curated stylized assets and lighting provide coherent places without a paid generation dependency. Kenney and Poly Haven are preferred for redistributable CC0 environment assets. Mixamo may supply local humanoid models/animations under Adobe's game-use terms.
- **Alternatives considered:**
  - Automated AI 3D Generation (Meshy / TRELLIS + Thermion/Filament) — rejected as primary strategy for final game; unproven visual coherence and mesh quality.
- **Lock-in risk:** Low. Blender scenes and FBX/GLB exports are portable.
- **Replace path:** Substitute other verified source assets without changing gameplay or backend contracts.

### graphql_flutter + ferry · GraphQL client
- **Version:** ferry 0.16+ (preferred for stricter typing and offline cache)
- **Role:** Type-safe GraphQL client with codegen.
- **Why this:** Code-generated Dart types from the schema; offline cache integrates with Drift.
- **Alternatives considered:** `graphql_flutter` directly (less typing rigor), REST + dio (loses the GraphQL benefits).
- **Lock-in risk:** Low.
- **Replace path:** Swap to a different GraphQL client; the schema is the contract.

### Riverpod · State management
- **Version:** Riverpod 2.5+
- **Role:** App state, dependency injection, scoped lifecycles.
- **Why this:** Compile-time safe, testable, widely adopted in modern Flutter.
- **Alternatives considered:** Bloc (more boilerplate), Provider (less expressive).
- **Lock-in risk:** Low.
- **Replace path:** Refactor to Bloc or another state library; not trivial but bounded.

---

## Backend — services

### Go · Primary backend language
- **Version:** Go 1.23+
- **Role:** Auth, sessions, users, playthroughs, event ingestion, sharing, B2B services, API gateway.
- **Why this:** Excellent concurrency story for high-throughput event ingestion, small binary footprint, fast startup, mature standard library, simple deployment story (single binary, no runtime).
- **Alternatives considered:**
  - **Rust** — faster and safer but slower to develop in; not justified for the workload.
  - **Node.js / TypeScript** — good ecosystem but weaker for high-throughput stateful services and operational simplicity.
  - **Elixir** — excellent fit for some Echo workloads (live "Same Vignette") but smaller talent pool and overall ecosystem.
- **Lock-in risk:** Low. Go services are standard HTTP/gRPC servers.
- **Replace path:** Rewrite a service in another language module-by-module; APIs unchanged.

### Python · ML / content / generation services
- **Version:** Python 3.12+
- **Role:** Trait scoring, Portrait generation, reflection-generation orchestration, classifiers, content management backend.
- **Why this:** The ML ecosystem (PyTorch, Hugging Face, ML tooling) is in Python; no other language is realistic for this work.
- **Lock-in risk:** Low.
- **Replace path:** Not applicable; Python is correct for this layer.

### FastAPI · Python service framework
- **Version:** FastAPI 0.115+
- **Role:** HTTP API surface of all Python services.
- **Why this:** Async-first, automatic OpenAPI schema, Pydantic models, strong typing.
- **Alternatives considered:** Flask (less async-friendly), Django (too heavy for this layer).
- **Lock-in risk:** Low.
- **Replace path:** Migrate to Litestar or similar; ASGI compatibility means the swap is incremental.

### gRPC · Inter-service communication
- **Version:** standard gRPC + protobuf
- **Role:** Communication between the Go core service and Python ML service.
- **Why this:** Strongly typed contracts, efficient binary protocol, supported in both languages.
- **Alternatives considered:** REST/JSON (slower, looser contracts), GraphQL between services (overkill for internal RPC).
- **Lock-in risk:** Low.
- **Replace path:** Swap to REST/JSON or another binary protocol.

### GraphQL (schema layer for clients) — `gqlgen` (Go) + `Strawberry` (Python)
- **Role:** Single GraphQL endpoint that the clients call. Schema lives in the Go gateway; resolvers either run in-process (Go) or proxy to Python services via gRPC.
- **Why this:** Clients get a single typed surface; backend retains language flexibility.
- **Lock-in risk:** Low.
- **Replace path:** GraphQL schemas are portable; we can rewrite the gateway in another language.

---

## Data stores

### PostgreSQL · Primary database
- **Version:** PostgreSQL 16+
- **Role:** All transactional data — users, playthroughs, vignette content, events, organizations, billing, consent records.
- **Why this:** Most reliable, most capable open-source database. Supports JSON, full-text search, vector search (`pgvector`), row-level security, partitioning, logical replication.
- **Alternatives considered:**
  - **MySQL** — strong but Postgres's feature set (RLS, JSON, vectors) is broader.
  - **MongoDB** — document model fits poorly with strongly-relational entities like billing.
  - **CockroachDB** — globally distributed Postgres-compatible, considered for V2 when multi-region matters; not justified at MVP.
- **Lock-in risk:** Low. Standard SQL with SQL-compatible alternatives.
- **Replace path:** Migrate to CockroachDB (Postgres-wire-compatible) if multi-region active-active is ever needed.

### `pgvector` · Vector index inside Postgres
- **Role:** Embeddings for any future semantic-search needs (e.g. similar Portraits, content tag retrieval).
- **Why this:** Avoids adding a separate vector database for our scale.
- **Replace path:** Migrate to Qdrant or Weaviate if vector workloads outgrow Postgres.

### Redis · Cache, sessions, rate-limiting, queue
- **Version:** Redis 7.4+ (or compatible — Valkey, KeyDB)
- **Role:** Sessions, rate-limiting counters, hot Portraits, simple delayed jobs.
- **Why this:** Industry-standard, extremely fast, simple to operate.
- **Lock-in risk:** Low — Valkey is a true drop-in replacement maintained by AWS, Google, and others.

### NATS JetStream · Event bus
- **Version:** NATS 2.10+ with JetStream enabled
- **Role:** Durable event streaming for player choice events, cross-service notifications.
- **Why this:** Lighter than Kafka, simpler to operate, scales to millions of messages per second when needed. Excellent Go client.
- **Alternatives considered:**
  - **Kafka** — overkill for our scale; operational cost is high.
  - **RabbitMQ** — fine for queues, weaker for durable streams.
  - **Redis Streams** — workable but less robust for long-retention event data.
- **Lock-in risk:** Low.
- **Replace path:** Migrate to Kafka if scale forces it.

### Cloudflare R2 · Object storage
- **Role:** Portraits, ambient audio, vignette art, sharing-page assets.
- **Why this:** S3-compatible API, **zero egress fees** (huge cost saver for viral share-page traffic), Cloudflare CDN integration.
- **Alternatives considered:** AWS S3 (more mature ecosystem but egress costs hurt our usage pattern), Backblaze B2 (cheaper still, less integrated with edge).
- **Lock-in risk:** Low (S3-compatible).
- **Replace path:** Migrate to any S3-compatible store.

---

## Auth and identity

### Ory Kratos · Identity service
- **Version:** Ory Kratos 1.x
- **Role:** User identity, sessions, multi-factor, password recovery, OIDC.
- **Why this:** Open source, self-hostable, OIDC-compliant, written in Go (good integration story), strong session model.
- **Alternatives considered:**
  - **Firebase Auth** — fast to start but Google lock-in and not ideal for institutional data residency.
  - **Auth0** — excellent product but expensive at scale and creates vendor lock-in.
  - **Build from scratch** — risky for a critical-path system.
- **Lock-in risk:** Low — open source, data is exportable.
- **Replace path:** Migrate user records to another OIDC provider.

### Sign in with Apple, Sign in with Google · OAuth providers
- **Role:** OAuth federation. Apple is required by App Store rules when other social logins are offered; Google is required for Android user experience.

---

## ML / content generation

### Anthropic Claude API · Primary LLM provider
- **Role:** Reflection generation, safety and tone classification (initially), content authoring assistance.
- **Why this:** Strongest instruction-following and safety record for the tone-sensitive work Echo does; explicit safety properties matter for a product used by adolescents.
- **Alternatives considered:** OpenAI GPT (used as redundant provider), Google Gemini (in evaluation).
- **Lock-in risk:** Medium — mitigated by the multi-provider abstraction layer.
- **Replace path:** Multi-provider router (`reflection-gen` service) makes provider swap a config change.

### vLLM + open-weight model (Llama derivative) · Fallback / cost-arbitrage LLM
- **Role:** Self-hosted alternative path for non-premium tier and cost optimization at scale.
- **Why this:** Owning inference for the cheap-tier path materially reduces cost-of-revenue; vLLM is the production-grade open-source serving framework.
- **Lock-in risk:** Low.

### Sentence-Transformers / Hugging Face models · Embedding and small classifiers
- **Role:** Tone and safety classifiers once we move off pure LLM-based classification; embeddings for any semantic lookups.
- **Lock-in risk:** Low.

### Pillow + Cairo · Server-side Portrait rendering
- **Role:** Parametric Portrait generation in Python.
- **Why this:** Pure server-side rendering, deterministic output, fully under our control. No external API dependency for the highest-stakes asset.
- **Lock-in risk:** None.

### Meshy / TRELLIS experiment · Retired Phase-G path
- **Role:** Historical prototype code only; not an active dependency of the game client or content plan.
- **Why retired:** Generated objects did not solve scene coherence, art direction, rigging, lighting, or game integration, and paid generation conflicts with the selected reproducible free approach.
- **Reconsideration gate:** A later, explicitly budgeted experiment requires human approval and must outperform the authored Blender/CC0 pipeline at the scene level.

---

## Infrastructure and platform

### Docker · Containerization
- **Role:** All services packaged as OCI containers.

### Kubernetes (GKE) · Orchestration, target state
- **Version:** Kubernetes 1.31+ via Google Kubernetes Engine (managed)
- **Role:** Container orchestration at production scale.
- **Why GKE specifically:** Best managed-K8s operational maturity for small teams; strong default security posture; integrated logging/monitoring; EU regions available.
- **Alternatives considered:** EKS (more configuration work for small teams), AKS (regional fit is fine, ops experience is mixed), self-managed (operational cost not justified).
- **Lock-in risk:** Low. Standard Kubernetes manifests run on any provider.
- **Replace path:** Migrate to EKS or AKS; manifests largely unchanged.

### Fly.io · Phase-0 hosting (months 0–9)
- **Role:** Hosting through MVP and early V1 before migration to K8s.
- **Why this:** Lower operational overhead than running K8s when traffic is small; same Docker images; trivial cutover.
- **Replace path:** Cut over to GKE when scale, B2B compliance, or service-mesh needs justify it. Both run the same containers.

### Cloudflare · Edge, CDN, DDoS, WAF
- **Role:** CDN for Portrait sharing pages, DDoS protection for all public endpoints, R2 object storage, Workers for edge logic (e.g. share-page rendering, lightweight redirects).
- **Why this:** Best-in-class price/performance for our access patterns, and the no-egress-fee R2 alignment.
- **Lock-in risk:** Medium for the edge-workers layer if used heavily; minimized by keeping Workers stateless and minimal.

### Linkerd · Service mesh (when on K8s)
- **Role:** mTLS between services, observability, traffic policy.
- **Why this:** Lighter and operationally simpler than Istio; sufficient feature set for our needs.

### HashiCorp Vault (or managed equivalent) · Secrets management
- **Role:** All secrets and credentials.

### GitHub · Source control
- **Role:** Code hosting, code review, issue tracking initially.
- **Companion:** GitHub Actions for CI.

### ArgoCD · GitOps continuous deployment (post-K8s)
- **Role:** Declarative deployment of services from git.

---

## Observability

### OpenTelemetry · Instrumentation standard
- **Role:** Traces, metrics, logs across all services. Vendor-neutral instrumentation; vendor swaps don't require code changes.

### Grafana Cloud (managed) OR self-hosted Grafana + Prometheus + Loki + Tempo
- **Role:** Visualization, metrics, logs, traces.
- **Why this:** Open standards, no lock-in. Start managed (Grafana Cloud free tier or low-tier paid) and self-host when scale justifies.

### Sentry · Error monitoring
- **Role:** Application error capture across client and server.
- **Why this:** Best-in-class DX. Lock-in is shallow — Sentry's open-source SDKs are usable with self-hosted Sentry as a fallback.

### PostHog · Product analytics
- **Version:** PostHog Cloud initially, self-hosted later
- **Role:** Behavioral analytics, funnels, feature flags, session replay.
- **Why this:** Open source, self-hostable, comprehensive, GDPR-friendly. Replaces three or four separate SaaS tools.
- **Alternatives considered:** Mixpanel (closed, more expensive), Amplitude (closed, more expensive).
- **Lock-in risk:** Low (open source).

---

## Compliance and security tooling

### Snyk + Dependabot · Dependency scanning
### Trivy · Container image scanning
### `gitleaks` · Secrets scanning in CI
### Static analysis: `golangci-lint`, `ruff` + `mypy` (Python), `dart analyze`

---

## Local development

### `mise` (formerly `rtx`) or `asdf` · Toolchain version management
- **Role:** Ensures every developer (and AI agent) uses the exact specified versions of Go, Python, Dart, Node, etc.
- **Config file:** `.tool-versions` at repo root.

### `docker compose` · Local environment
- **Role:** One-command local stack: Postgres, Redis, NATS, all services. Mirrors the production composition.

### `pnpm` (if any JS tooling) and `uv` (Python package manager)
- **Role:** Fast, reproducible package management.

---

## Summary — the canonical stack

| Layer | Choice |
|---|---|
| Client | Unity 6 Personal (C#) + URP + Input System |
| Legacy/fallback client | Flutter (Dart) + Drift + Rive + Riverpod + Ferry GraphQL |
| API surface | GraphQL (gqlgen) + REST for public surfaces + WebSocket for live |
| Backend services | Go (core) + Python (ML/content) |
| Inter-service | gRPC |
| Database | PostgreSQL 16 + pgvector |
| Cache / queue | Redis 7 |
| Event bus | NATS JetStream |
| Object storage | Cloudflare R2 |
| Auth | Ory Kratos + Apple/Google OAuth |
| LLM | Anthropic Claude (primary) + self-hosted open model (fallback) |
| 3D assets | Blender-authored/optimized + verified CC0 libraries + optional local Mixamo animation |
| Hosting phase 0 | Fly.io |
| Hosting phase 1 | GKE (Kubernetes on Google Cloud, EU) |
| Edge | Cloudflare (CDN, R2, Workers) |
| Mesh | Linkerd |
| Observability | OpenTelemetry → Grafana + Prometheus + Loki + Tempo + Sentry |
| Analytics | PostHog |
| Secrets | Vault |
| CI/CD | GitHub Actions → ArgoCD |
| Toolchain | mise + docker compose + uv + pnpm |

This stack is intentionally **boring where it can be boring** (Postgres, Redis, Go, Python, Flutter) and **opinionated only where the product demands it** (Ory Kratos for auth sovereignty, Cloudflare R2 for egress economics, NATS for event simplicity, Anthropic Claude for the safety-critical generation path).
