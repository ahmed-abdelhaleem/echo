# 10 — Roadmap & Milestones

> This is the single shared timeline. All other documents reference these milestone labels (M0–M5). Dates are calendar-anchored from project kickoff (`T0`).

## At a glance

```
T0          M0          M1          M2          M3          M4          M5
Kickoff    Foundation  Vert.slice  MVP beta    Public V1   Institut.   Series-A
            ────────    ────────    ────────    ────────    ────────    ────────
Weeks       0–4         5–9         10–22       23–38       39–60       61–80
            (~1 mo)     (~1 mo)     (~3 mo)     (~3.5 mo)   (~5 mo)     (~4 mo)
```

A few honest notes about the timeline:

- These are **target durations under expected conditions**. They will slip; the plan accommodates 20–30% slip.
- The bottleneck is content production and design polish, not engineering. Engineering can move faster than the brand can.
- The team grows as funding lands. The plan does not assume more headcount than the funding milestones support.

---

## M0 — Foundation (Weeks 0–4)

**Goal:** Build the foundation. Nothing user-visible yet.

**Team:** Founder + advisor circle (part-time).

### Deliverables

- Monorepo bootstrapped with the structure in `07_AI_Agent_Implementation_Guide`.
- Local dev environment one-command-up (`docker compose up && make dev`).
- CI/CD pipeline producing green builds for all services and the client across all four platforms.
- `core-go` and `ml-py` service skeletons with health endpoints, gRPC stubs, OpenTelemetry tracing.
- Postgres schema baseline for `auth`, `playthrough`, `events`.
- Cloud accounts opened: Google Cloud (EU project), Cloudflare, Apple Developer, Google Play, Stripe (test), Anthropic.
- DPO appointed (internal designate or external contract).
- `content-schema` package: JSON Schema for Seasons, Acts, Vignettes, Choices, Trait Weights.

### Exit criteria

- A new developer or AI agent can clone the repo and have a working dev environment in under 30 minutes.
- All CI jobs are green and stay green for one full week.
- DPO and basic compliance setup in place.

---

## M1 — Vertical slice (Weeks 5–9)

**Goal:** One vignette, end-to-end on the client, scored on the server, with a deterministic placeholder Portrait. No real content yet, just the rails.

**Team:** Founder + 1–2 advisors active (mobile, backend) part-time.

### Deliverables

- A single test vignette renders on iOS and Android.
- Player makes a choice; choice persists locally and syncs to the server.
- On playthrough completion (1 vignette in this slice), trait scoring produces a deterministic Trait Vector.
- Placeholder Portrait generation (parametric but minimal) returns an image keyed by the trait vector.
- Authentication via Ory Kratos working end-to-end (email + Apple OAuth).
- Telemetry pipeline operational: a single playthrough produces traces and metrics visible in Grafana.

### Exit criteria

- A non-technical playtest participant can complete the vignette on their own device and see a Portrait.
- The system's behavior is fully deterministic and reproducible from event logs (the `trait-replay` tool produces identical output on repeated runs).

---

## M2 — MVP, closed beta (Weeks 10–22)

**Goal:** Full Season 1, real Portrait, real reflection, on iOS and Android, with a closed beta of ~200 testers.

**Team:** Founder full-time. First external hire targeted around Week 14 (recommended: a Flutter engineer to accelerate client polish). Friends/advisors active on a defined cadence (mobile, ML, DevOps, backend reviewers).

### Deliverables

- **Content:** Season 1 fully written, weighted, playtested, and integrated. 15–25 vignettes across 4 acts.
- **Portrait:** Real parametric renderer, deterministic from trait vector, animated and static outputs, brand-signed-off.
- **Reflection:** Real LLM-based reflection pipeline with safety + tone classifiers, 50+ templates, fallback flow.
- **Auth and accounts:** Sign-up, login, account management, age gating (under-13 hard block, 13–17 youth-safe routing), GDPR rights flows.
- **Sharing:** Portrait sharing via system share sheet; public `share-web` pages live.
- **Closed beta:** 200 testers (mix of demographics — primary audience 16–25, plus a small adolescent cohort with appropriate consent).
- **Telemetry, error monitoring, customer support inbox** operational.
- **Privacy policy and terms of service** drafted and reviewed by external counsel.

### Exit criteria

- ≥150 closed-beta playthroughs completed end-to-end.
- ≥70% completion rate among beta starters.
- NPS-style "would you recommend Echo to a friend?" ≥50.
- Zero unhandled safety classifier violations in the production set.
- The reflection of a willing-to-share subset of testers is independently rated "feels accurate" by an external panel at ≥60%.

---

## M3 — Public V1 launch (Weeks 23–38)

**Goal:** Public launch on all four platforms in the EU. Echo+ subscription live. Second Season released. Friend comparison shipped. The product becomes findable and shareable.

**Team:** Founder + 2 full-time engineers (Flutter + Python/ML) by this stage, funded by pre-seed.

### Deliverables

- **Cross-platform parity:** Windows and macOS builds shipped, signed, notarized, distributed via Microsoft Store / Mac App Store / direct download.
- **Echo+ subscription:** Apple IAP, Google Play Billing, Stripe (desktop) all live, with proper paywall design, trial flow, restore-purchase flows.
- **Season 2** released, with trait re-calibration verified.
- **Friend comparison** feature shipped end-to-end.
- **Migration from Fly.io to GKE** completed; Linkerd mesh, region pinning, backup drills documented and rehearsed.
- **Marketing launch:** soft-launch on Product Hunt, TikTok/Instagram organic, targeted press in product and design publications.

### Exit criteria

- 50,000 public players in the first 90 days post-launch.
- ≥5% trial conversion.
- ≥50% trial-to-paid conversion.
- Crash-free sessions ≥99.5%.
- Refund rate ≤2% of subscription purchases.

---

## M4 — Institutional V2 (Weeks 39–60)

**Goal:** Echo for Institutions live, with the first paying schools and coaching practices onboarded. SOC 2 Type I audit underway. NA expansion begins.

**Team:** Engineering grows to 5–7. First B2B hire (founder-led initially, formal hire by mid-V2).

### Deliverables

- **B2B dashboard:** institution onboarding, seat management, cohort views, individual Portrait views with consent, exports, billing.
- **Compliance pack:** DPA template, sub-processor list, security questionnaire response (SIG/CAIQ), SOC 2 Type I report initiated.
- **Pilot program:** 25 pilot institutions at 50% pilot pricing in exchange for case studies.
- **NA expansion:** US west and east region pinning option for NA institutional customers. CCPA compliance verified.
- **Season 3 and Season 4** released. Sustained one-Season-per-quarter cadence.
- **Localization started:** French, German, Spanish (player-facing strings; reflection generation per locale).

### Exit criteria

- 25 paying institutional customers; €500K+ ARR from B2B alone.
- Consumer ARR €1M+.
- SOC 2 Type I report issued.
- Series-A-ready KPI dashboard with at least 6 months of clean data.

---

## M5 — Series A and scale (Weeks 61–80)

**Goal:** Close Series A. Scale consumer and institutional both. Reach the year-3 targets stated in `09_Monetization_Business_Model`.

### Deliverables

- Series A closed.
- Two more languages localized (PT, IT).
- Sustained Season-per-quarter cadence with three writers in rotation.
- ML-augmented trait scoring engine (v2) deployed, validated against external Big Five inventories at scale.
- B2B sales team in place: SDR, SE, customer success.
- Research partnership #1 announced.

---

## Operating cadence

Independent of the milestone calendar, these are the rhythms that should hold:

| Cadence | Activity |
|---|---|
| **Daily** | Async standup in chat. CI is always green or being fixed. |
| **Weekly** | Founder + one advisor: progress, blockers, decisions log. Brief design review of in-flight work. |
| **Bi-weekly** | Full team retro and planning. |
| **Monthly** | Privacy review of any changes touching T4/T5 data (per `08_Data_Privacy_Compliance`). Metrics review (consumer + B2B). |
| **Per Season** | Content readiness review: writing, weights, playtests, calibration. Brand voice review of reflection templates. |
| **Quarterly** | Restore drill (backups). Security review. Roadmap re-baseline. |
| **Annually** | External privacy audit. External penetration test. |

---

## Decisions that must be made by specific dates

These are decisions where deferring past the listed point compounds risk. They are not all "do this thing"; some are explicit decisions including "do not do this thing yet."

| By date | Decision |
|---|---|
| End of M0 | Confirm Fly.io vs. GKE for phase-0 hosting (recommended: Fly.io). |
| End of M0 | Confirm LLM primary provider (recommended: Anthropic) and contract for EU regional endpoint. |
| Mid-M2 | Decide go/no-go on closed beta launch based on internal playtests of Season 1. |
| End of M2 | Decide pricing of Echo+ (recommended: €4.99/mo, €39.99/yr) and confirm. |
| Mid-M3 | Decide migration timing to GKE based on traffic and B2B pipeline. |
| End of M3 | Decide whether to begin SOC 2 Type I now or defer to early M4. |
| Mid-M4 | Decide on NA expansion sequencing (US first vs. CA first; East vs. West region). |
| Mid-M4 | Decide on first hire for B2B sales (founder-led until at least this point). |
| End of M4 | Confirm Series A fundraise timing based on Q4-of-M4 metrics. |

---

## What we will *not* do, on this roadmap

These are explicit anti-deliverables to keep the roadmap honest:

- No real-time multiplayer in year 1.
- No user-generated content.
- No advertising-supported tier.
- No clinical positioning in year 1 (no claims of diagnostic utility; HIPAA scope deferred).
- No expansion into APAC in year 1 (different regulatory and localization scope).
- No Android TV / iPad-specific premium tier; the four target platforms are the four target platforms.

Anything added to this list mid-flight requires a deliberate roadmap re-plan, not an in-flight scope expansion.
