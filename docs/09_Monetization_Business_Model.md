# 09 — Monetization & Business Model

## Revenue model at a glance

Echo earns money in three distinct streams that share a single product surface and a single dataset:

1. **Consumer subscription (Echo+)** — recurring monthly/annual.
2. **B2B seat licensing (Echo for Institutions)** — recurring monthly per seat, sold to schools, coaching practices, youth wellbeing programs.
3. **Research and content partnerships** — episodic revenue from licensing the trait engine, anonymized aggregate insights, or Season co-production. Not the wedge; not committed for year 1.

The three streams cross-subsidize each other in important ways: consumer reach validates the trait engine for B2B buyers, B2B revenue funds higher-quality content that improves consumer retention, and research partnerships pay for calibration work that improves both.

---

## Stream 1 — Consumer (Echo+)

### Free tier

- One full Season available at any time. New users can play it immediately, no account required to complete the playthrough.
- Account required to save the Portrait and share.
- Friend comparison: available, with limits (e.g. one comparison per Season for free).

### Echo+ (premium)

Single tier. Single price. No "Echo Pro." Single tiers convert better and are easier to communicate.

**Price targets:** €4.99/month or €39.99/year. Yearly is a 33% discount and the default offered on first paywall view.

**What Echo+ includes:**
- Full Season library (current + back catalog).
- Unlimited friend comparisons.
- Deeper reflection content — extended prose and the optional "show me how my Portrait was made" view.
- Early access to new Seasons (release on Echo+ a week before free).
- Archival of all Portraits in a personal collection ("Constellation").
- Light additional features released over time (no aggressive feature gates — Echo+ is the experience tier, not the unlock-everything tier).

### Why this pricing

- Below the median for self-discovery / wellness apps (Calm, Headspace are €13/mo; 16Personalities Premium is €36 lifetime, which is one-time but lower lifetime value).
- Inside what a 17–24 year old will defensibly add to their app subscriptions list.
- Annual conversion is the actual unit-economics game; targeting €39.99 annual at ≥50% annual mix produces healthy LTV.

### Unit economics (consumer) — illustrative targets

| Metric | Target (Year 2) |
|---|---|
| Player to Echo+ trial conversion | 5–8% |
| Trial to paid conversion | 50% |
| Monthly churn | 4–6% |
| Annual:Monthly subscriber mix | 50:50 |
| Average revenue per paying user (ARPU/month) | ~€4.20 (blended) |
| Cost of goods (LLM + infra + payment fees) per Echo+ user / month | < €0.80 |
| Gross margin per Echo+ user | > 80% |
| LTV (blended) | €60–90 |
| CAC ceiling | €25 (aggressive but achievable with viral coefficient ≥ 0.4) |

These are targets. The closed beta + early launch will reset them with real data.

### Why this is plausible

- Refind Self sold 500,000 copies of a $3.99 one-time game with effectively no marketing. Converting even a small fraction of a similar audience to a recurring sub is well within precedent.
- The Portrait + friend comparison loop is the strongest viral lever in the design. If the viral coefficient lands above 0.4, CAC drops to nearly zero for organic traffic.
- The yearly conversion path materially shifts LTV; this is the single biggest lever in consumer monetization.

---

## Stream 2 — B2B (Echo for Institutions)

The B2B path is where Echo's revenue compounds beyond what consumer alone can support. It also forces product discipline (safety, audit, reporting) that ultimately benefits consumers.

### Customer segments

| Segment | Buyer | Typical seats | Tier pricing target |
|---|---|---|---|
| Schools (secondary and tertiary) | Counselor / wellbeing lead | 50–2,000 per institution | €4–€8 per seat / month |
| University career and coaching | Director of student services | 200–10,000 per institution | €3–€6 per seat / month |
| Coaching practices (private) | Practice owner | 10–100 per practice | €10–€18 per seat / month |
| Youth wellbeing nonprofits | Program lead | 50–500 per program | €3–€5 per seat / month |
| Clinical practices (adolescent therapists) | Practice owner | 10–50 per practice | €15–€25 per seat / month — **deferred to V2.5+**; requires clinical positioning we do not commit to in year 1 |

### What the institutional buyer gets

- All seats include Echo+ for the player.
- Educator/coach dashboard with aggregate cohort views and consented individual Portraits.
- Cohort export (PDF and CSV) for parent-teacher conferences, coaching sessions, internal program reporting.
- Educator-facing content packs: discussion guides tied to Seasons, conversation prompts, debrief structures.
- Admin controls: seat allocation, role management, data residency selection where supported.
- DPA, sub-processor list, security questionnaire response.

### Why an institutional buyer chooses Echo

- **Adolescents will actually engage with it.** Existing tools (Strong Interest Inventory, Holland Code, CliftonStrengths, MBTI for Youth) feel like homework. Echo feels like something teenagers do voluntarily.
- **Discussion-starter, not diagnostic.** Counselors and coaches can use Echo as a low-pressure entry point into self-reflection conversations.
- **Anchored to validated psychology (Big Five) without exposing the player to clinical language.** This is the rare combination that satisfies both the institution's evidentiary needs and the player's experience.
- **Lower cost than incumbent assessment tools.** Hogan, Gallup, SHL are priced for corporate procurement.

### Sales motion

- **Self-serve up to ~50 seats.** Stripe-backed. Institution signs up online with self-serve DPA acceptance.
- **Sales-assisted above ~50 seats.** Founder-led initially. Hire one head of B2B in late V1 / early V2 if the founder is the constraint.
- **Pilot offer:** 90-day pilot at 50% off for the first 25 institutional customers, in exchange for a co-marketing case study commitment. Strong initial reference customers are worth more than maximum revenue from those deals.

### Why institutional pricing works mathematically

If a typical school customer is 500 seats at €6/seat/month, that's €36,000 ARR per school. 30 schools = ~€1M ARR from B2B alone. This is achievable in V2 (months 14–22) with one founder-led sales motion and a small SDR/SE hire late in V2.

---

## Stream 3 — Research and content partnerships

Episodic revenue, not the wedge. Listed here for completeness because the founder's question explicitly asked about investor profitability and these are real future revenue lines investors will ask about.

- **Academic research partnerships.** Universities studying adolescent personality development license access to (consented, anonymized, aggregate) Echo data. Modest revenue, high credibility, and forces ongoing research-grade rigor on the trait engine. Targeted: 1–2 partnerships in V2.
- **Brand-aligned Seasons.** A book publisher, a film studio, or a museum co-funds a Season tied to their content (e.g. a Season inspired by a literary work, with the author's involvement). Only undertaken when the brand fit is real and the editorial integrity of the Season is uncompromised. Not committed until V2.5+; reserved as an explicit "do not do this cheaply" line.

---

## Investor-facing economics

The pitch numbers an investor will care about, with reasonable Year 3 targets if execution lands:

| Metric | Year 3 target |
|---|---|
| Monthly active players (consumer) | 2–4M |
| Paying Echo+ subscribers | 80,000–160,000 |
| Consumer ARR | €4–8M |
| Institutional customers | 80–150 |
| Institutional ARR | €3–6M |
| **Total ARR** | **€7–14M** |
| Gross margin | 75–85% |
| Net revenue retention (institutional) | > 115% |

Notes for an investor conversation:

- These are targets, not commitments. The plan funds the path; the company iterates against reality.
- The two streams together produce a model where consumer drives top-of-funnel and brand awareness, B2B drives revenue density and durability, and the dataset that compounds across both becomes the long-term moat.
- The Refind Self benchmark — 500k units sold by one developer with no marketing — is a useful sanity check that the demand-side floor is high enough.

---

## Funding strategy

### Founder capital (now)

- Up to €100k of founder personal capital allocated, drawn against MVP build (months 0–6) — primarily covers initial infrastructure, two part-time technical hires beyond the founder/advisor circle if needed, content production for Season 1, and legal/DPO setup.

### Pre-seed / friends-and-family (months 4–8)

- Target raise: €250k–€500k.
- Use of proceeds: Season 2 production, V1 public launch on all four platforms, two full-time hires (one mobile/Flutter, one ML/Python), DPO retainer, EU+UK marketing test budget.
- Valuation target: €3–5M post-money. Convertible note or SAFE preferred over priced round at this stage.

### Seed (months 10–14, around V1 traction)

- Target raise: €2–4M.
- Use of proceeds: B2B engineering and sales motion build-out, SOC 2 Type I, NA expansion, content cadence to one Season per quarter sustained.
- Valuation target: depends on V1 metrics; €8–15M pre-money plausible with healthy KPIs.

### Series A (months 22–30, post-V2 traction)

- Target raise: €8–15M.
- Use of proceeds: NA scale, second-tier institutional segments (universities, larger districts), localization, clinical scoping decision.
- Valuation target: dependent on metrics — €40–80M pre-money plausible with ≥€2M ARR and clear unit economics.

---

## Cost shape — what we actually spend

Approximate annual operating cost at each stage (excluding founder time and equity dilution):

| Stage | Months | Annualized cost |
|---|---|---|
| MVP build | 0–6 | €120–180k |
| V1 build + launch | 7–12 | €350–550k |
| V2 build + launch | 13–22 | €1.2–2.0M |
| Year 3 steady state | 23–36 | €3–5M |

The biggest cost lines:

- Engineering payroll (60–70% of total in Years 1–2).
- LLM inference (4–8% of total; mitigated by self-hosted open model on lower-margin paths).
- Cloud infrastructure (3–6% of total).
- Compliance and DPO (3–5% of total, more in B2B build years).
- Content production (writers, designers, audio, playtest panels) — under-budgeted at most consumer-software startups; for Echo this is a moat-building investment.

---

## What can break the model

Honestly noted, because investors will ask:

1. **Consumer subscription floor doesn't hold.** If we can't get to 5%+ trial conversion, the consumer model breaks and we lean harder on B2B. This is survivable but slower.
2. **Institutional sales cycles are longer than projected.** Schools in particular are slow. We mitigate with coaching practices and youth nonprofits as faster-moving early customers.
3. **LLM costs spike or providers change terms.** Mitigated by the multi-provider abstraction and the self-hosted open-model fallback that already covers the cheap-tier path.
4. **A Big Tech entrant ships a similar concept.** Mitigated by brand, content moat, and B2B distribution; the consumer game becomes harder, B2B harder for them to match quickly.
5. **A privacy incident.** Catastrophic for a brand built on trust. Mitigated by the privacy posture documented in `08_Data_Privacy_Compliance` — and by accepting that no mitigation eliminates this risk entirely.
