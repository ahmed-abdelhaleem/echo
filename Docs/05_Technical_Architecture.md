# 05 — Technical Architecture

## Architectural principles

Every architectural decision in this document is constrained by these five principles, in order. When two principles conflict, the higher one wins.

1. **Privacy by design and EU-data-residency first.** Echo handles personality data about minors; this is not negotiable.
2. **Single codebase across all four client platforms.** No iOS team and Android team in parallel.
3. **API-first.** Every player-facing feature is a thin client over a public API. The same API serves consumer apps, the B2B dashboard, and (later) third-party integrations.
4. **Start as a modular monolith on the backend; split into services only when service boundaries are forced by scale or team structure.** Avoid premature microservices.
5. **No vendor lock-in for the critical path.** Authentication, storage, observability, and orchestration all use open standards or open-source primitives with multiple compatible providers.

---

## High-level system diagram (text form)

```
┌────────────────────────────────────────────────────────────────────┐
│                          CLIENT (Flutter)                            │
│   iOS │ Android │ Windows │ macOS — one codebase, native packages    │
└──────────────┬─────────────────────────────────────────────────────┘
               │  HTTPS / GraphQL / WebSocket
               ▼
┌────────────────────────────────────────────────────────────────────┐
│                        EDGE (Cloudflare)                             │
│           CDN │ DDoS │ WAF │ Workers (edge) │ R2 (object store)      │
└──────────────┬─────────────────────────────────────────────────────┘
               │
               ▼
┌────────────────────────────────────────────────────────────────────┐
│                        API GATEWAY (Go)                              │
│         Auth │ Rate-limit │ Tenant routing │ GraphQL schema           │
└──┬──────────────────────────┬───────────────────┬────────────────────┘
   │                          │                   │
   ▼                          ▼                   ▼
┌─────────────┐      ┌──────────────────┐  ┌────────────────────────┐
│  Core App   │      │   ML / Content   │  │   B2B / Institutions   │
│   (Go)      │      │     (Python)     │  │        (Go)            │
│             │      │                  │  │                        │
│ - Users     │      │ - Trait scoring  │  │ - Org admin            │
│ - Sessions  │      │ - Portrait gen   │  │ - Seats / billing      │
│ - Playthrus │      │ - Reflection gen │  │ - Cohort dashboards    │
│ - Events    │      │ - Safety filter  │  │ - Reports / exports    │
│ - Sharing   │      │ - Content CMS    │  │                        │
└──────┬──────┘      └────────┬─────────┘  └──────────┬─────────────┘
       │                      │                       │
       ▼                      ▼                       ▼
┌────────────────────────────────────────────────────────────────────┐
│                       SHARED DATA LAYER                              │
│  PostgreSQL (primary)  │  Redis (cache + queue)  │  NATS (event bus) │
│  Cloudflare R2 (assets)│  S3-compat backups       │  Read replicas    │
└────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│              OBSERVABILITY (OpenTelemetry standard)                  │
│   Grafana │ Prometheus │ Loki │ Tempo │ Sentry (errors)              │
└────────────────────────────────────────────────────────────────────┘
```

---

## Client architecture

### One codebase, four platforms

The client is built in **Flutter** (Dart). A single repository produces native packages for iOS, Android, Windows, and macOS. Flutter is chosen over the alternatives for these reasons:

- **Rendering parity across platforms.** Flutter renders its own widgets via Skia/Impeller, so a Portrait looks identical on every device. With React Native or native development, ensuring visual parity for the parametric art would require platform-specific work.
- **Animation and atmospheric work is first-class.** Flutter's animation framework + the **Rive** runtime cover the kind of motion design Echo needs.
- **Game-engine option without leaving the stack.** The **Flame** engine is a 2D game framework built on Flutter; if any vignette ever needs more game-like behavior, Flame integrates without a re-platform.
- **Desktop maturity.** Flutter's Windows and macOS targets are now stable and shipping in mainstream production apps.
- **Strong testing story.** Widget tests, integration tests, and golden tests cover the surface area.

### Client module structure

```
echo_client/
├── lib/
│   ├── app/                  // App shell, routing, theming
│   ├── core/                 // Cross-cutting: networking, auth, storage
│   ├── features/
│   │   ├── playthrough/      // Vignette renderer, choice handling
│   │   ├── portrait/         // Portrait render + share
│   │   ├── account/          // Sign-up, settings, account mgmt
│   │   ├── compare/          // Friend comparison
│   │   └── institution/      // B2B client surfaces (V2)
│   ├── shared/               // Widgets, design system, animations
│   └── generated/            // Codegen output (GraphQL, l10n)
├── assets/                   // Art, audio, fonts
├── test/                     // Unit + widget tests
├── integration_test/         // End-to-end on-device tests
└── platform/
    ├── ios/
    ├── android/
    ├── windows/
    └── macos/
```

### Offline-first state

The client uses **Drift** (a typed SQLite wrapper for Flutter) as the local persistence layer. Every player choice is written locally immediately, then synced opportunistically to the backend. A playthrough started online can be completed offline; sync resumes when connectivity returns. The local DB is encrypted at rest using platform secure storage for the key.

### Networking

- **GraphQL** is the primary client-server protocol. Single endpoint, typed schema, codegen for Dart clients. Echo's client surface is read-heavy and view-shaped — GraphQL fits well.
- **WebSocket** subscriptions for the few real-time surfaces (friend comparison invites, live "Same Vignette" sessions in V2.5).
- **HTTP/REST fallback** for sharing pages and webhook receivers.

---

## Backend architecture

### Phase 1 — Modular monolith (months 0–9)

For MVP and V1 the backend ships as a **modular monolith** in two languages:

- **Go core service.** Auth, sessions, users, playthroughs, event ingestion, sharing, B2B (when introduced). Organized internally as separate domain modules (`auth/`, `playthrough/`, `events/`, `sharing/`, `org/`) with explicit module boundaries. The monolith pattern keeps deployment, observability, and ops simple while we're small.
- **Python ML service.** Trait scoring, Portrait generation orchestration, reflection generation (LLM calls), safety/tone classification, content management. Separated from the Go core because the Python ecosystem is irreplaceable for ML.

This is two services, not many. Inter-service communication is gRPC.

### Phase 2 — Service decomposition (post V1, only as needed)

The module boundaries inside the Go monolith are deliberately drawn along future service-split lines. When scale, team growth, or compliance forces a split, modules become services without restructure.

Predictable split candidates:
- **Event ingestion** — will be the highest-throughput surface; first to split.
- **Sharing / Portrait serving** — public-facing, may want independent scaling.
- **B2B / Institution service** — has compliance constraints (SOC 2 scope, separate logging) that benefit from isolation.

### Why a modular monolith and not microservices on day one?

- **Founder + 4 advisors is not a microservices-scale team.** Microservices multiply operational surface area before there is enough traffic to justify it.
- **Boundaries inside a monolith are cheap to redraw; service boundaries are not.** The product is still discovering itself; locking in service boundaries early is expensive.
- **Observability, deployment, and debugging are dramatically simpler.** A single process with clean modules is what one DevOps-leaning person can run while focusing on product.

---

## Data layer

### Primary database — PostgreSQL

- Managed Postgres (recommended provider: **Crunchy Data**, **Neon**, or **AWS RDS** depending on cost at scale; managed by default, self-hosted only when costs justify it).
- Single primary, one or more read replicas.
- Connection pooling via **PgBouncer**.
- **Logical schema separation by domain** (`auth`, `playthrough`, `content`, `org`, `events`) — every domain has its own schema in the same DB. Easy to split out later.
- **Point-in-time recovery** enabled from day one. Tested quarterly.

### Why a single Postgres and not a polyglot persistence?

Postgres in 2026 can do JSON well, full-text search well, vector search well (via `pgvector`), time-series adequately, and small-scale geospatial. Avoiding additional data stores at this stage trades a small performance ceiling for an enormous reduction in operational complexity. We add specialized stores only when Postgres provably fails for that workload.

### Cache, queue, pub/sub

- **Redis** — session store, rate limiting, ephemeral compute caches (e.g. recently generated Portraits), simple delayed jobs.
- **NATS JetStream** — durable event bus for high-volume per-vignette telemetry, and pub/sub for cross-service notifications. Lighter than Kafka, easier to operate at our scale, and scales to millions of msg/sec when needed.

### Object storage

- **Cloudflare R2** for Portraits, ambient audio, vignette art. S3-compatible API, no egress fees (significant cost saver for share-page traffic).
- **AWS S3** (or equivalent) for encrypted database backups stored in a separate provider for disaster recovery diversity.

### Search

- Postgres full-text search until proven inadequate. If we ever need fuzzier semantic search across vignettes or research corpora, **Typesense** or **Meilisearch** added as a dedicated service.

---

## Trait, Portrait, and Reflection pipeline

This is the ML/content-critical path. End-to-end target latency at p95: **under 6 seconds from playthrough completion to result display.**

```
   Playthrough complete (client)
              │
              ▼
   ┌──────────────────────────┐
   │  Event log finalization   │  ← all events confirmed server-side
   └────────────┬─────────────┘
                │
                ▼
   ┌──────────────────────────┐
   │   Trait scoring (Python) │  ← rule-based v1, ML v2+
   │   produces Trait Vector  │
   └────────────┬─────────────┘
                │
                ├───────────────┐
                ▼               ▼
   ┌────────────────┐   ┌──────────────────────┐
   │ Portrait gen   │   │ Reflection pipeline   │
   │ (deterministic │   │  1. Template select   │
   │  parametric    │   │  2. LLM completion    │
   │  renderer)     │   │  3. Safety classify   │
   │                │   │  4. Tone classify     │
   │ outputs PNG    │   │  5. Fallback if fail  │
   │ + animated     │   └──────────┬───────────┘
   └────────┬───────┘              │
            │                      │
            ▼                      ▼
   ┌──────────────────────────────────────┐
   │   Stored in R2 + Postgres, returned  │
   └──────────────────────────────────────┘
```

### Trait scoring service

- **v1 (MVP–V1):** Rule-based. Every choice in every vignette has a YAML-defined weight contribution to one or more trait dimensions. Scoring is a deterministic aggregation. Fully auditable, fully reproducible.
- **v2 (post V1):** ML-augmented. Inputs include not just choices but hesitation, revisit patterns, and pacing. Model trained against (consenting) users who also completed validated inventories (BFI-2 etc.). Model served via **BentoML** or **KServe**.

### Portrait generation

- **MVP:** Server-side parametric renderer in Python using **Pillow + custom drawing**, or **Cairo** for SVG output rasterized server-side. The renderer is a pure function from `(Trait Vector, seed)` to `(animated WebP, static PNG)`. Brand-controlled output, deterministic, no external API dependency.
- **V2 enhancement (optional):** AI image generation as an *enrichment layer on top* of the parametric base — e.g. a generated background that responds to a small set of trait coordinates. Decision deferred until brand and cost analysis support it.

### Reflection generation

- LLM provider: **multi-provider with abstraction layer.** Primary: Anthropic Claude API (strong instruction-following and safety). Fallback / cost-arbitrage: an open model (Llama-derived) self-hosted via vLLM. The application code never directly calls a provider — it calls our internal `reflection-gen` service which routes.
- All prompts version-controlled. All outputs persisted with prompt + model version for audit and improvement.

### Safety and tone classifiers

- Initial implementation: prompted Claude / GPT call returning structured `{safety_pass: bool, tone_pass: bool, reasons: []}`.
- Once we have enough labeled examples (manual review queue feeds this), replace with a small fine-tuned classifier — cheaper and faster.

---

## Authentication and authorization

### Auth approach

- **Custom-built auth service backed by `Ory Kratos`** (open source, self-hostable, OIDC-compliant) — chosen because:
  - We do not want to be locked into Firebase Auth or Auth0 if we want to operate in tightly-regulated institutional contexts where data residency is non-negotiable.
  - Kratos handles email/password, OAuth (Apple, Google), passwordless, and recovery flows out of the box.
- **OAuth providers from day one:** Sign in with Apple (required for iOS App Store), Google, plus email/password.
- **JWT** access tokens, short-lived (15 min) + refresh tokens (long-lived, rotated).
- **Age verification at sign-up.** Self-declared but reinforced with friction (date of birth, not just "I am 18+ checkbox"). Under-13 hard-blocked. 13–17 routed into youth-safe flow.

### Authorization

- **Role-based** for B2B (institution admin, educator, player).
- **Attribute-based** for content access (which Seasons does this player have access to?).
- **Strict tenant isolation** for B2B data. Postgres row-level security (RLS) policies enforce that an educator at School A cannot ever see data from School B, even in the case of a bug in the application layer.

---

## B2B / Institution layer

### Architecture

The institution functionality lives initially as a module inside the Go monolith. It is structured so that splitting it out becomes a contained piece of work when scale or compliance demand it.

### Data model (key entities)

- `Institution` — the contracting organization.
- `Cohort` — a group of players within an institution (e.g. a class, a coaching cohort).
- `Educator` — an institutional user with permissions over cohorts.
- `Seat` — a billable association between a player and an institution.
- `Consent` — explicit consent record per player per disclosure (what the institution can see, etc.).

### Reporting

- All institutional reports are computed against aggregate data, never directly from the raw event log.
- Individual Portraits visible to educators only when the player has explicitly opted into that visibility.

---

## Observability and ops

### Standard

OpenTelemetry traces, metrics, and logs across all services. No proprietary SDKs in app code; the OTel collector handles forwarding.

### Stack

- **Metrics:** Prometheus, visualized in Grafana.
- **Logs:** Loki.
- **Traces:** Tempo.
- **Errors:** Sentry (the only proprietary tool — by far the best DX for this purpose, and the lock-in is shallow).
- **Synthetic monitoring:** simple periodic playthrough simulators run in CI and from external regions to catch end-to-end regressions.

### Alerting

- Pager rotation: founder + one advisor initially.
- Alerts only for actually-actionable events. Aggressive tuning against alert fatigue.
- Customer-impacting alerts (latency above SLO, error rate spike) route to phone. Everything else to chat.

---

## Hosting and infrastructure

### Phase 0 — single-region EU (months 0–12)

- **Primary region:** Frankfurt or Amsterdam (EU GDPR-native).
- **Hosting:** managed Kubernetes (**GKE** preferred for ops quality at our scale) OR **Fly.io / Railway** for the first 6 months if simpler PaaS is enough.
- **Recommendation: start on Fly.io for the monolith.** Move to GKE around V1 when scale and B2B compliance demand it. Both run the same Docker images; the migration is a deployment-pipeline change, not an application change.

### Phase 1 — multi-region (year 2+)

- Add a North America region when NA users exceed ~20% of traffic.
- Data residency: EU user data stays in EU region; NA user data stays in NA region; institutional contracts may demand specific data location guarantees, supported via tenant-region pinning.

### CI/CD

- **GitHub Actions** for CI.
- Docker images pushed to **GitHub Container Registry** or a managed registry.
- **ArgoCD** (or Flux) for GitOps once on Kubernetes.
- Every PR runs full test suite + a small smoke playthrough simulation against an ephemeral env.

---

## Cost shape at scale (rough)

Approximate steady-state monthly cost estimates (illustrative, not committed):

| Stage | Active monthly players | Monthly infra cost |
|---|---|---|
| MVP / closed beta | < 5,000 | < €1,500 |
| Public launch | 50,000 | ~€5,000 |
| V1 mature | 250,000 | ~€20,000 |
| V2 institutional | 1,000,000 | ~€60,000–80,000 |

LLM inference dominates per-user cost. Single biggest optimization lever is moving reflection generation to a self-hosted open model for non-premium users.

---

## Security posture

- All inter-service traffic mTLS via service mesh (Linkerd preferred — lighter than Istio).
- Field-level encryption for sensitive PII columns (Postgres `pgcrypto`).
- Secrets management via **HashiCorp Vault** or a managed equivalent (AWS Secrets Manager / GCP Secret Manager).
- Regular dependency scanning (Dependabot + Snyk).
- Annual third-party penetration test from V1 onward.
- SOC 2 Type I targeted at V2 institutional launch; Type II within 12 months thereafter.

---

## Why this architecture scales

- **Stateless application services** — every service is horizontally scalable by adding instances.
- **Postgres scales vertically far further than people remember.** Read replicas + connection pooling support hundreds of thousands of concurrent users on a single primary. Sharding becomes necessary only at very large scale, and Postgres has multiple modern sharding solutions (Citus, partitioning) when it does.
- **Event ingestion is the first part that needs to scale horizontally.** NATS JetStream handles this naturally and is operationally simple.
- **The boundary between modular monolith and microservices is a deployment topology choice, not an architectural choice.** When scaling forces it, we change *how the modules deploy*, not the modules themselves.
- **CDN-fronted public Portraits** means the highest-traffic surface (viral sharing) hits Cloudflare's edge, not our origin.
