# 08 — Data, Privacy & Compliance

> Echo handles inferred personality data, and a substantial portion of its users will be minors. Privacy and compliance are not a layer on top of the product — they are constitutive of the product. This document is binding on engineering, content, and business decisions.

## Guiding principles

1. **Collect the minimum necessary.** If a piece of data isn't required to deliver a feature the user explicitly asked for, we don't collect it.
2. **Process where it belongs.** EU user data stays in the EU. Institutional data stays where the contract requires.
3. **Default to private.** Public sharing is opt-in, every time, with friction proportional to the stakes.
4. **Consent must be specific, informed, and reversible.** Not a checkbox at sign-up. Per-feature, in plain language, undoable.
5. **Minors get more protection, not less.** Where the law permits a choice, we choose the more protective option for under-18 users.
6. **The output is descriptive, never diagnostic.** Echo never tells anyone they "are" anything clinical.

These principles override convenience, speed, and revenue when they conflict. They are not waivable to ship faster.

---

## Regulatory frame

Echo's launch geography is EU first, then UK and North America. The compliance posture is built to satisfy the strictest of these from day one, which is the EU + GDPR-K combination.

### Applicable frameworks

- **GDPR** (EU General Data Protection Regulation) — lawful basis, data subject rights, data minimization, data residency, DPO obligations at scale.
- **GDPR-K** (the EU member-state-specific rules for minors, especially the digital-age-of-consent provisions, varying 13–16 by country).
- **UK GDPR + Data Protection Act 2018** — substantially aligned with EU GDPR for our purposes.
- **California CCPA / CPRA** — when we expand to NA.
- **COPPA** (US) — applies to under-13. Echo's age gate hard-blocks under-13 globally, which removes COPPA from the critical path; we maintain alignment regardless.
- **DSA / DMA** (EU Digital Services Act and Digital Markets Act) — when sharing/social features reach relevant thresholds.
- **AI Act** (EU) — Echo's classifiers and reflection generation are not high-risk under the current text but we monitor changes; transparency obligations apply.

### Sectoral frameworks for the B2B path

- **FERPA** (US) — when serving US schools; the institutional path is structured so that schools remain the controller and Echo is the processor.
- **HIPAA** (US) — Echo is *not* a HIPAA-covered product. We will not sell into US clinical contexts that would require HIPAA classification until a deliberate decision to take on that scope.
- **EU member-state education laws** — country-specific rules for school data; managed contract-by-contract.

---

## Data classification

Every piece of data Echo handles falls into one of five tiers. Storage, encryption, access, and retention rules differ by tier.

| Tier | Definition | Examples | Encryption | Access |
|---|---|---|---|---|
| **T1 Anonymous** | No identifier. Cannot be linked to a person. | Aggregate trait distributions across a cohort. | Standard at-rest. | Broad. |
| **T2 Pseudonymous** | Linked to a stable internal ID; not directly identifying. | Event logs keyed by `playthrough_id`. | At-rest + scoped access. | Engineers + ML services. |
| **T3 Personal** | Identifies a person. | Email, OAuth subject, IP at sign-in. | At-rest, field-level for sensitive columns. | Auth service + audited engineer access. |
| **T4 Sensitive Personal** | Inferred trait data, attachment proxies, anything psychologically meaningful linked to a person. | Trait Vector linked to user, reflection text. | At-rest + field-level + audit log on read. | Service-only; human access requires ticket + audit. |
| **T5 Minor Personal** | Any T2–T4 data about a known minor. | Anything about a 13–17 user. | All T4 protections + restricted retention + sharper deletion rules. | Service-only; human access requires DPO approval + audit. |

### Practical implication

- Field-level encryption (Postgres `pgcrypto`) applied to columns containing T3+ data.
- Audit logging on every read of T4 and T5 data, retained 7 years (or until deletion of the underlying record, whichever shorter).
- Backup encryption with keys stored separately from the data they encrypt.

---

## Lawful basis (GDPR Art. 6)

| Processing activity | Lawful basis | Notes |
|---|---|---|
| Account creation and authentication | Contract performance (Art. 6(1)(b)) | Necessary to deliver Echo. |
| Storing and computing Trait Vectors | Contract performance + consent | Consent obtained at sign-up; full disclosure of inference activity. |
| Reflection generation via LLM provider | Contract performance + consent | Provider is a sub-processor; disclosed in privacy policy. |
| Optional public Portrait sharing | Explicit consent (Art. 6(1)(a)) | Opt-in each time, never default on. |
| Product analytics (essential) | Legitimate interest (Art. 6(1)(f)) | Strictly product-improvement use; no third-party advertising joins. |
| Product analytics (extended, e.g. session replay) | Consent | Opt-in, off by default; never on for under-18. |
| Marketing emails | Consent | Granular opt-in; double-opt-in for EU. |
| B2B institutional data | Contract (Art. 6(1)(b)) — institution is the controller | Echo is processor in this context. |

For Art. 9 special-category data (which would include health and certain biometric data), Echo's design deliberately keeps trait inference *outside* the Art. 9 scope by not making diagnostic or health claims. The reflection-generation pipeline's safety classifier enforces this.

---

## Age gating and minor protections

### Hard rule: under-13 are not Echo users

- Self-declared age at sign-up. Date-of-birth input, not "I am 18+" checkbox.
- Under-13 → friendly block screen, no account created, no data stored beyond an ephemeral session flag.
- Attempts to circumvent (e.g. lying about age) are caught at best-effort; we do not perform invasive age verification, which would itself be a privacy harm.

### 13–17: youth-safe path

By default, an account aged 13–17 has these properties:

- Public sharing is **disabled**.
- Friend comparison is **disabled** until a verified parent/guardian email consent flow is completed.
- Reflection prose generation runs through a **stricter prompt profile** with additional safety classifier rules.
- Extended analytics (session replay, heatmaps) are **off** and cannot be enabled.
- Marketing email is **off** and cannot be enabled until 18.
- Data retention is set to the more aggressive end of the policy (see retention table below).

### Consent capture for minors

- Echo respects the digital age of consent per EU member state. For users below their country's threshold, parental consent is required for any processing beyond contract-performance basics.
- Parental consent is captured via a verified email round-trip with a clear disclosure. We do not require government ID or any heavyweight identity verification, which would be a worse privacy outcome.

### Institutional minors

When minors come in via a school, the school is the controller and bears legal responsibility for consent (under FERPA in US, equivalent under national education laws in EU). Echo provides the tooling and audit trail. Our DPA with the school documents this responsibility split clearly.

---

## Data subject rights — operational implementation

Every right below is exposed in the player's account settings *and* available via a public DSR endpoint that an authorized representative can use on behalf of a person. Targets are **stricter than the legal minima** by design.

| Right | Article | Operational target |
|---|---|---|
| Access | GDPR Art. 15 | DSR responded within 14 days (legal max 30). |
| Portability | Art. 20 | JSON export within 72 hours of request. |
| Rectification | Art. 16 | In-app correction surfaces for everything correctable; non-correctable items (e.g. inferred traits — these are deletable but not "correctable" by user assertion). |
| Erasure | Art. 17 | Hard-delete within 30 days; surviving aggregates fully anonymized. |
| Restriction | Art. 18 | Account-level pause flag, suspends all non-essential processing. |
| Objection | Art. 21 | Available per processing activity in settings. |
| Automated decision-making | Art. 22 | Trait inference disclosed; reflection generation disclosed; no decisions with legal effect made automatically. |

### What "delete" really means in Echo

When a user deletes their account:

- **Within 24 hours:** account is deactivated; all sessions are invalidated; the user can no longer log in.
- **Within 30 days:** all T3, T4, T5 data linked to the user is hard-deleted from primary storage. Portraits are deleted from R2. Reflections are deleted.
- **Backups are not exhumed.** Encrypted backups containing the data continue to exist on their existing rotation but are inaccessible without operational reason. When backups expire on their normal schedule, the data is gone. This is documented in the privacy policy.
- **Aggregate research data** derived from the user's events is retained in anonymized form (counts, distributions) — this is permissible under GDPR Recital 26 since the data is no longer linkable to the individual. The privacy policy is explicit about this.

### Self-service vs. submitted requests

Self-service exists for: data export, account deletion, granular consent toggles, communication preferences. Submitted (via DSR endpoint + identity confirmation) exists for: access requests on behalf of others, edge cases involving deceased users, formal Art. 18 restrictions.

---

## Retention policy

| Data type | Adult retention | Minor retention |
|---|---|---|
| Account record | Until deletion | Until deletion or 6 months after last login, whichever sooner |
| Playthrough events (T2) | 18 months from playthrough | 12 months from playthrough |
| Trait Vectors linked to user (T4/T5) | Until deletion | Until deletion |
| Portraits (in R2) | Until deletion | Until deletion |
| Reflections (text) | Until deletion | Until deletion |
| Reflection generation prompt/response audit | 90 days | 90 days |
| Auth logs | 12 months | 12 months |
| Sentry / error logs containing user IDs | 30 days | 30 days |
| Backups (full encrypted) | 90 days rolling | 90 days rolling |
| Anonymized aggregate research data | Indefinite | Indefinite (only fully anonymized) |

---

## Data residency

- **EU users:** all primary processing in Frankfurt (or Amsterdam) GKE region. Postgres primary in EU. R2 storage with EU jurisdiction. LLM provider calls go to the provider's EU endpoint where available (Anthropic offers EU regional endpoints; Echo will require this configuration in production).
- **NA users (year 2+):** primary processing in NA region. Cross-border transfers only via SCCs and where strictly necessary for system operation (e.g. global error monitoring with Sentry; this is disclosed).
- **Institutional contracts:** may specify tenant-region pinning. Architecture supports this from day one.

---

## Sub-processors

A public sub-processor list is maintained at `echo.app/legal/sub-processors` and updated at least 30 days before any new sub-processor is engaged for production data. The minimum list at MVP:

- **Google Cloud (GKE, EU)** — infrastructure hosting.
- **Cloudflare** — edge, CDN, R2 storage.
- **Anthropic** — LLM inference for reflection generation. EU regional endpoint.
- **Sentry** — error monitoring; PII scrubbing applied at the SDK layer.
- **PostHog Cloud (EU instance)** — product analytics. Self-hosted option deferred to V2.
- **Apple, Google** — payment processing for mobile IAP.
- **Stripe (EU entity)** — payment processing for desktop subscriptions and B2B.

Each sub-processor has an executed DPA on file.

---

## Security posture

### Encryption

- TLS 1.3 for all client-server and inter-service traffic. mTLS once Linkerd is in place.
- AES-256 at rest for all persistent storage.
- Field-level encryption for sensitive T3+ columns using Postgres `pgcrypto` with keys managed in Vault.
- R2 server-side encryption enabled; client-side encryption of Portraits considered but not adopted at MVP (cost/complexity tradeoff documented).

### Access control

- Production database access requires SSO + 2FA + audit ticket. No standing access.
- Service accounts authenticate via short-lived credentials (Workload Identity in GCP).
- All admin actions logged to a separate audit stream; immutable WORM-style retention for 7 years.

### Vulnerability management

- Dependency scanning (Snyk + Dependabot) on every PR.
- Container image scanning (Trivy) at build time.
- Secrets scanning (gitleaks) in CI.
- Annual third-party penetration test from V1; rotating scope across the codebase.

### Incident response

- Documented incident response plan with severity tiers.
- Notification SLAs:
  - Personal data breach affecting users: notify supervisory authority within 72 hours per GDPR Art. 33.
  - High-risk to users: notify affected individuals "without undue delay" per Art. 34.
- Post-incident review for every Sev1 and Sev2 incident; learnings folded back into engineering practice.

### Backup integrity

- Daily encrypted backups to a separate cloud (cross-provider for disaster diversity).
- Restore drills quarterly; results documented.
- Backups never restored to production except in genuine disaster recovery, with audit.

---

## DPO and governance

- **Data Protection Officer**: appointed at the threshold required by GDPR Art. 37 (large-scale processing or processing involving children). Echo, by design, meets the children-processing threshold from launch, so a DPO is appointed at MVP — either an internal designate (with adequate independence) or a contracted external DPO firm.
- **Privacy review board**: any change to the data model, the trait engine, the reflection pipeline, the safety classifiers, or the consent flows requires sign-off from the DPO plus founder.
- **Annual privacy audit**: by an external firm, results acted on with public commitments.

---

## Communicating privacy to users

The privacy policy is a legal document and is necessary. It is not the primary way Echo communicates with users about privacy. The primary surfaces are:

1. **Plain-language summaries** alongside every consent decision in-app — written at roughly an 11-year-old's reading level (since 13–17 will see them).
2. **The "what does Echo know about me" surface** in account settings — an actually readable view of what data the system holds about the user, with one-tap deletion of each kind.
3. **An optional "show me how my Portrait was made" surface** for the curious — discloses the trait engine inputs and which choices influenced which trait.

These surfaces are content-design problems, not legal-text problems, and they are owned by product and design, with legal review.

---

## What we will not do

For founder and team clarity, the practices below are explicit non-options at Echo, regardless of revenue pressure:

- Selling personal data to advertisers, brokers, or any third party.
- Training models on user data without explicit, granular, revocable consent.
- "Personality-based targeted advertising," directly or via partners.
- Sharing inferred personality data with employers without the player's explicit choice in each instance.
- Operating in jurisdictions whose laws would require us to disclose user inference data to authorities without judicial process.
- Using dark patterns in any consent or settings surface.

These are committed in writing in this document so that future decisions cannot quietly relitigate them.
