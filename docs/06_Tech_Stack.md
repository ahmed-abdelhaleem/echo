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

### Flutter · Cross-platform application framework
- **Version:** Flutter 3.44+ (Dart 3.12+ runtime; app language remains 3.6)
- **Role:** Single codebase producing native iOS, Android, Windows, and macOS applications.
- **Why this:** Single codebase with identical rendering across platforms, mature animation framework, strong testing tooling, first-class desktop support, large community.
- **Alternatives considered:**
  - **React Native** — JavaScript ecosystem reach, but rendering parity for parametric art is weaker, and desktop story is immature.
  - **Unity / Godot** — game engines with strong cross-platform, but heavyweight for an experience that is mostly narrative; harder to integrate with web sharing pages and B2B dashboards built in standard web tooling.
  - **Native iOS + Android + Electron** — best per-platform fidelity, but triples the engineering surface and is incompatible with the team size.
- **Lock-in risk:** Medium. Dart is the only consumer of this codebase. Migration would be substantial.
- **Replace path:** If Flutter is ever abandoned (low probability — Google ships it in production, third-party adoption is broad), the client could be rebuilt in React Native or platform-native; the backend API contract is unchanged.

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

### Flame · 2D game engine (optional, on-demand)
- **Version:** Flame 1.20+
- **Role:** Available for any vignette that needs more game-engine behavior (e.g. a vignette that simulates a space the player can wander). Not required for the typical vignette.
- **Why this:** Built directly on Flutter, no platform-bridge concerns.
- **Alternatives considered:** Embedding Unity (overkill, large binary), pure-Flutter custom canvas (works for simple cases, harder for non-trivial scenes).
- **Lock-in risk:** Low.
- **Replace path:** Custom Flutter `CustomPainter`-based renderers for the affected vignettes.

### Thermion (Filament) + glTF/GLB · 3D scene and model rendering
- **Version:** Thermion 0.x (Flutter runtime), glTF 2.0 / GLB asset format
- **Role:** Render AI-generated 3D vignette environments, props, and ambient scene elements inside the client — from parallaxed atmospheric depth up to fully composed, gently **explorable 3D scenes** (`F-CORE-007`, milestone M5) with an author-defined camera rig and bounded free-look. Target is parity across all four platforms **and web** (Filament-on-WASM, or a baked per-vignette scene GLB). (The player **Portrait** is *not* 3D; it stays a deterministic parametric render — see Pillow + Cairo below.)
- **Why this:** Thermion wraps Google's **Filament** PBR engine behind a Flutter API, giving high-fidelity, identical rendering across all four platforms — the same parity argument that selected Flutter itself. **glTF/GLB** is the universal, royalty-free 3D interchange format that every generation provider can export, which keeps us provider-neutral end to end.
- **Alternatives considered:**
  - **flutter_scene** (Impeller-native 3D from the Flutter team) — lighter and promising, but still experimental; revisit as it matures.
  - **model_viewer_plus** (`<model-viewer>` in a platform webview) — trivial to adopt and a fine low-fidelity fallback, but webview overhead, single-model only (cannot compose a multi-asset scene), and weak control over lighting/perf. Kept only as the web/low-end fallback.
  - **Embedding Unity / Godot** — full engines, but heavyweight and reintroduce exactly the cross-platform-bridge problems Flutter exists to avoid. **Re-confirmed when scoping explorable scenes (M5):** an atmospheric, bounded diorama needs a *renderer*, not a game engine, and Unity's binary size + WebGL-iframe story on web would regress the Flutter parity the whole stack is built on. We stay on Thermion; Unity would only be revisited if Echo became "3D-game-first," which is a product-vision change, not a rendering choice.
- **Lock-in risk:** Low. Assets are standard glTF/GLB; the renderer is swappable without touching content.
- **Replace path:** Swap to flutter_scene or model_viewer_plus; assets are unchanged because they are standard glTF.

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

### Meshy AI (+ open-model fallback) · AI 3D model generation
- **Role:** Generate 3D models and scene elements (props, environments, ambient objects) for vignettes from text and reference-image prompts. This is **content tooling for the atmospheric world**, distinct from the player Portrait — the Portrait remains a deterministic parametric render with no external dependency (see Pillow + Cairo above).
- **Why this:** Meshy AI offers strong text-to-3D and image-to-3D with direct **glTF/GLB + PBR-texture** export, an API suited to automated pipelines, and good quality-for-cost. It lets a tiny team produce a large, cohesive set of 3D assets without a 3D-artist headcount.
- **Alternatives considered:**
  - **Luma AI (Genie), Tripo AI, Rodin / Hyper3D, Stability AI (Stable Fast 3D)** — viable hosted providers; kept behind the same abstraction as redundant / cost-arbitrage routes.
  - **Self-hosted Microsoft TRELLIS** (called through the `ml-py` provider abstraction) — owned inference for cost control at scale and for assets we prefer not to send to a third party; the same role the self-hosted LLM plays for reflection. The model runtime stays behind an HTTP boundary and can use the original CUDA implementation or an Apple Silicon MPS/MLX port.
- **Lock-in risk:** Medium — mitigated by (a) a multi-provider abstraction identical in spirit to the LLM router and (b) standardized glTF/GLB output that any provider and any renderer accept.
- **Replace path:** The provider router in the `asset-gen` service makes a provider swap a config change; self-hosted TRELLIS is the floor if every hosted provider becomes unviable. See the **continuous background asset generation** pipeline in `05_Technical_Architecture`.

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
| Client | Flutter (Dart) + Drift + Rive + Riverpod + Ferry GraphQL |
| Client 3D | Thermion (Filament) + glTF/GLB |
| API surface | GraphQL (gqlgen) + REST for public surfaces + WebSocket for live |
| Backend services | Go (core) + Python (ML/content) |
| Inter-service | gRPC |
| Database | PostgreSQL 16 + pgvector |
| Cache / queue | Redis 7 |
| Event bus | NATS JetStream |
| Object storage | Cloudflare R2 |
| Auth | Ory Kratos + Apple/Google OAuth |
| LLM | Anthropic Claude (primary) + self-hosted open model (fallback) |
| 3D assets | AI-generated — Meshy (primary) + self-hosted TRELLIS (fallback), glTF/GLB |
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
