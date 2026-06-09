# 11 — Risk Assessment

> Every risk an investor or co-founder will surface, written down honestly with mitigations. The point of this document is to make the risks legible *before* they bite, not to comfort anyone reading it.

## Risk framework

Each risk is rated on two axes:

- **Likelihood** — how probable, given the plan in `10_Roadmap_Milestones`.
- **Impact** — how bad if it materializes, ranging from "we slip a quarter" to "the company ends."

Ratings are L (Low), M (Medium), H (High). The combined score signals where to focus mitigation effort.

---

## Category 1 — Product risk

### R-PROD-001 — The Portrait and reflection don't feel true to most players
**Likelihood:** M · **Impact:** H · **Combined:** High priority.

If the output doesn't strike most players as accurate, the viral loop and the B2B credibility both collapse. This is the *core product risk*.

**Mitigations.**
- Extensive playtesting from M1 onward with iterative refinement of vignettes, weights, and reflection templates.
- External validation: calibration against BFI-2 (open-license Big Five inventory) with willing testers in M2 and ongoing.
- Tone classifier rejects generic reflections; failure metrics are tracked weekly.
- An external panel rating playthroughs as "feels accurate" at ≥60% is a published M2 exit criterion.
- The founder's stated strength — sustained iteration on content quality — is explicitly the lever for this risk.

**Tripwire.** If by M2 exit the external panel doesn't hit 60%, the public launch is delayed and the Season undergoes a second iteration cycle before going wider.

### R-PROD-002 — The brand voice is hard to maintain at scale
**Likelihood:** M · **Impact:** M

As content volume and team size grow, the reflection and vignette voice drifts. Echo's distinctness softens. Reviewers start describing it as "another personality app."

**Mitigations.**
- Brand voice rules codified in `04_Game_Design` and referenced by every reflection template.
- Tone classifier in the generation pipeline enforces voice at production time.
- All content goes through a single editorial reviewer until at least V2.
- The classifier itself gets retrained on rejected outputs as the team grows.

### R-PROD-003 — Players try to game the trait engine and the result loses meaning
**Likelihood:** M · **Impact:** L

Some players will replay deliberately as a different character. As noted in `04_Game_Design`, the design treats this as a feature, not a bug.

**Mitigations.**
- The product UI acknowledges replays as part of self-discovery rather than treating them as cheating.
- Multiple playthroughs surface as a "constellation" instead of being averaged into a single result.
- The trait engine records that a playthrough was a replay; this is signal, not noise.

---

## Category 2 — Technical risk

### R-TECH-001 — LLM costs or terms shift unfavorably
**Likelihood:** M · **Impact:** M

Provider pricing, rate limits, or terms of service for the LLM API change in ways that hurt unit economics or compliance.

**Mitigations.**
- Multi-provider abstraction (Anthropic primary, OpenAI secondary, self-hosted open model fallback) keeps switching cost low.
- Self-hosted open model already covers the cheap-tier and free-tier path by V1.
- All provider-specific code is behind the `reflection-gen` service interface.

**Tripwire.** If LLM cost-per-Echo+ user exceeds €1.00/month, route more traffic to the self-hosted path.

### R-TECH-002 — A safety classifier failure produces harmful content
**Likelihood:** L · **Impact:** H

A reflection generated for a minor contains content that is unsafe, even after both safety and tone classifiers.

**Mitigations.**
- Two-stage classification with a fallback library of pre-approved reflections.
- Every generation logged with prompt + output for retrospective review.
- A weekly sample of production reflections is human-reviewed.
- An incident response runbook exists specifically for "harmful generated content" with both technical and communications components.
- The classifier failure rate is a Sev2 alertable metric.

**Tripwire.** Any single Sev2-grade reflection-content incident triggers an immediate full review of the pipeline, with human approval gating before further generations resume.

### R-TECH-003 — A data breach exposes inferred personality data
**Likelihood:** L · **Impact:** H (existential)

Echo's brand is built on trust. A breach affecting personality inference data, especially of minors, could be fatal for the company.

**Mitigations.**
- Field-level encryption on T3+ columns; access audit logging on T4/T5.
- No standing production database access; ticketed + 2FA + audit.
- Annual third-party penetration testing.
- SOC 2 Type I by V2; Type II within a year of Type I.
- Incident response plan rehearsed.

**Honest note.** No mitigation reduces this risk to zero. The mitigation is layered defenses plus minimizing the data we hold in the first place (see `08_Data_Privacy_Compliance` retention policy).

### R-TECH-004 — Cross-platform parity costs are higher than projected
**Likelihood:** M · **Impact:** L

Flutter is mature on iOS, Android, and macOS, but Windows in particular still has rough edges for certain UI patterns. Some platform-specific work will be necessary.

**Mitigations.**
- Windows and macOS slip behind iOS/Android in M3 ordering; this is anticipated.
- Platform-specific code is isolated in `lib/platform/` to keep the shared codebase clean.
- The closest reference comparable (Refind Self) ships on all four platforms with a single codebase; the feasibility is established.

### R-TECH-005 — Postgres becomes the bottleneck before we plan to migrate
**Likelihood:** L · **Impact:** M

The "single Postgres until it doesn't work" decision in `05_Technical_Architecture` is correct but eventually has a ceiling.

**Mitigations.**
- Architecture supports adding read replicas, partitioning, and eventually moving to Citus or CockroachDB without application rewrites.
- Telemetry on Postgres performance is dashboarded from M0.
- The first signs of bottleneck (sustained replication lag, query latency degradation) trigger a re-architecture work track, not a panic.

---

## Category 3 — Market and competitive risk

### R-MKT-001 — A Big Tech entrant ships a competing concept
**Likelihood:** L–M · **Impact:** H

Apple, Google, Meta, or a major game studio launches a similar product with massive distribution.

**Mitigations.**
- Brand and aesthetic specificity is hard to replicate; Echo's quiet, generous tone is unlike how Big Tech defaults to building.
- B2B distribution is structurally difficult for Big Tech to enter quickly — schools and coaching practices buy on relationships and compliance fit, not on platform power.
- The content moat (Seasons, vignettes, reflection templates) compounds with time; a fast follower starts cold.
- Speed of execution and content quality are the consumer-side defenses.

**Honest note.** This risk is non-zero. The mitigation is to be unmistakably ourselves rather than try to out-resource the bigger entrant.

### R-MKT-002 — Refind Self ships a v2 with social and recurring monetization
**Likelihood:** L · **Impact:** M

The most direct comparable explicitly addresses its gaps.

**Mitigations.**
- Refind Self's team (one developer, one publisher) is unlikely to build a SaaS B2B layer; that's a different business.
- Cross-platform breadth, friend comparison, and B2B credibility are Echo's leads.
- Watch the space, but don't react to it — execute the plan.

### R-MKT-003 — Consumer subscription fatigue cuts trial conversion
**Likelihood:** M · **Impact:** M

Gen Z is increasingly subscription-fatigued. The 5% trial conversion assumption may not hold.

**Mitigations.**
- One-time purchase option as a fallback monetization path (Echo+ Lifetime at a higher price) tested in M3.
- Heavy investment in the free tier's value (one full Season free) keeps the top of funnel wide even if conversion is lower than target.
- B2B revenue grows independently of consumer conversion; the model isn't single-stream-dependent.

### R-MKT-004 — Institutional sales cycles are slower than projected
**Likelihood:** M · **Impact:** M

Schools especially are slow to procure. The V2 B2B revenue target may slip.

**Mitigations.**
- Sequence: coaching practices and youth nonprofits first (faster sales), schools and universities second (slower sales).
- Pilot program at 50% pricing for first 25 customers accelerates initial adoption by lowering decision friction.
- Founder-led sales until clear product-market fit signals in the institutional segment justify scaling sales hires.

---

## Category 4 — Team and execution risk

### R-TEAM-001 — Founder burnout
**Likelihood:** M · **Impact:** H

Solo founder + advisors model has a ceiling. The founder being the constraint on too many fronts is a real risk.

**Mitigations.**
- First full-time hire (Flutter engineer) is in M2, well before the founder is the only one shipping.
- Pre-seed raise is explicitly scoped to fund two engineering hires.
- The founder's stated strength (sustained content iteration) is the moat-building work; that's where founder time should go, not on infrastructure.
- Honest periodic "what am I doing that someone else should be doing?" reviews.

### R-TEAM-002 — Advisor circle deprioritizes Echo
**Likelihood:** M · **Impact:** M

The four advisors are friends, not employees. Their contribution will fluctuate.

**Mitigations.**
- Don't put advisors on the critical path for any deliverable. Their role is reviewer, sounding board, and pinch-hitter — not owner.
- The first external hires replace specific advisor functions (Flutter, ML) with full-time owners.
- Equity grants to advisors recognize their contribution but do not create dependency.

### R-TEAM-003 — Distribution, marketing, and investor relations are the founder's weakest area
**Likelihood:** H (acknowledged) · **Impact:** M

This was identified as the honest gap in the original pitch.

**Mitigations.**
- An advisor or angel investor with go-to-market and fundraising experience is added in M1 or M2 as a deliberate hire.
- Early-stage marketing is organic, brand-led, and TikTok/Instagram-native — work the founder can hire one specialist for rather than build a marketing team.
- Investor introductions in M2 and M3 are made via the angel/advisor network rather than cold outreach.

### R-TEAM-004 — Content writing and editorial talent is harder to hire than engineering
**Likelihood:** M · **Impact:** M

The Season-per-quarter cadence depends on excellent writers. Excellent writers are not interchangeable, not commodity, and harder to evaluate than engineers.

**Mitigations.**
- The first Season is largely founder-authored (in collaboration with one trusted writer) to set the voice.
- Writer hires are vetted on actual sample vignettes against the codified voice rules.
- A small rotating roster (3–4 writers) instead of one staff writer reduces dependency risk.

---

## Category 5 — Regulatory and reputational risk

### R-REG-001 — A regulatory change in EU re: AI and minors increases compliance burden
**Likelihood:** M · **Impact:** M

The AI Act is in force; Member State implementations are evolving; UK and EU regimes diverge. Echo's product touches both AI generation and minors — high-attention surface.

**Mitigations.**
- DPO from MVP; privacy review board with sign-off on relevant changes.
- Transparency obligations (AI Act) are already designed-in: users are informed about inference, generation, and what the reflection pipeline does.
- The architecture supports tightening (e.g. region pinning, additional consent flows) without rewriting.

### R-REG-002 — Misclassification by app stores
**Likelihood:** L · **Impact:** M

Apple or Google misclassifies Echo (e.g. "mental health app" with the resulting restrictions, or refuses approval over LLM-generated content involving minors).

**Mitigations.**
- App store submission positioning carefully crafted: Echo is a narrative game with a personality result, not a mental health tool.
- Pre-submission conversations with both stores prior to first release.
- Safety classifier enforcement is documentable.

### R-REG-003 — A high-profile media story misrepresents Echo
**Likelihood:** L · **Impact:** M

"App profiles your teenager's personality without parental consent" — a story Echo could survive but only by being prepared for it.

**Mitigations.**
- Communication-ready compliance documents (public privacy summary, sub-processor list, age-gating explanation).
- DPA and consent flows are demonstrably stricter than the regulatory minimum; this is defensible publicly.
- A media response runbook exists for the brand-critical scenarios.

---

## Category 6 — Financial risk

### R-FIN-001 — Pre-seed raise takes longer than projected
**Likelihood:** M · **Impact:** M

The €250k–€500k pre-seed slips by 3–6 months.

**Mitigations.**
- The €100k founder capital is sized to cover the MVP path without external funding.
- Pre-seed timing is at the V1 launch decision point, not before MVP completion — the product is more legible to investors at that stage.
- The plan does not include any external hires before pre-seed lands.

### R-FIN-002 — Currency or macro shock
**Likelihood:** L · **Impact:** M

EU economic conditions deteriorate; consumer subscription becomes harder to grow; institutional budgets tighten.

**Mitigations.**
- The model has two independent revenue streams (consumer + B2B); both contracting simultaneously is the bad scenario but each is somewhat decoupled.
- Cost structure is variable enough (LLM use, marketing spend) that we can cut quickly without core engineering layoffs.

### R-FIN-003 — Underestimating customer acquisition cost
**Likelihood:** M · **Impact:** M

Organic + viral growth is the plan; if the viral coefficient lands below 0.3, paid CAC pressure rises.

**Mitigations.**
- Friend comparison is the single biggest viral lever — design and engineering investment in this is prioritized.
- The free tier is generous enough to sustain top-of-funnel without paid spend.
- B2B revenue density compensates for lower-than-expected consumer LTV.

---

## Risk-priority summary

The top five risks to actively manage from day one:

1. **R-PROD-001** — Product feels true. Mitigated by content investment, classifier discipline, and external validation. This is *the* product risk.
2. **R-TECH-003** — Data breach. Mitigated by layered security and minimal data retention.
3. **R-TEAM-001** — Founder burnout. Mitigated by hiring early and protecting founder time for moat-building work.
4. **R-MKT-001** — Big Tech entrant. Mitigated by brand specificity and B2B distribution; partially un-mitigatable.
5. **R-PROD-002 / R-TECH-002** — Brand voice drift and safety failures, treated together because both are about quality of generated content.

Every other risk is real but secondary to these five.

---

## What we explicitly accept

Some risks cannot be fully mitigated and we accept them in exchange for the strategy:

- **Schools sell slowly.** We accept that and time the B2B revenue accordingly.
- **A solo founder model has a ceiling.** We accept that and plan the hiring sequence around it.
- **Self-hosting a tier of LLM inference adds operational complexity.** We accept that as the cost of margin sovereignty.
- **EU-first means we leave US-fastest-growth on the table for year 1.** We accept that because the regulatory complexity of starting US-first with adolescents is greater than the revenue we lose by waiting.
- **A single-tier consumer subscription doesn't extract maximum revenue from power users.** We accept that because tier complexity erodes brand and conversion.

These are not failures of analysis; they are deliberate trade-offs aligned with the brand and strategy.
