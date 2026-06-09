# Ory Kratos configuration (Echo)

This directory contains the configuration Echo uses to run Ory Kratos in **local development** and as the **baseline** for staging / production deployments. Production overrides live alongside the deployment manifests in `infra/flyio/` or `infra/k8s/` (added in M3).

## Files

- **`kratos.yml`** — server config. Declares listener URLs, self-service flow URLs, cookie/cipher secrets (placeholders, replaced in prod), bcrypt hasher settings, session lifespan, and the identity schema path.
- **`identity.schema.json`** — the identity schema. Defines the traits Echo stores on every identity:
  - `email` (the password identifier),
  - `display_name`,
  - `birthdate` (used by `T-CORE-021` age-gating in `services/core-go/auth/`),
  - `consent.{tos,privacy}_{version,accepted_at}` (a tiny consent record that lets the backend determine whether re-consent is required when policies change).

## Local development

`docker compose up -d kratos-migrate kratos` will:

1. run the database migrations against the `kratos` database created by `infra/docker/postgres/init/01_init.sql`,
2. start the public listener on `:4433` and admin listener on `:4434`.

The Flutter client (or any other UI) drives the self-service flows against the public API. The Go backend talks to the admin API to fetch identities and to the public API for `whoami` session validation.

## Why this shape

Per `docs/05_Technical_Architecture.md` §"Auth approach", Kratos owns identity, sessions, recovery, verification, and (in future PRs) OAuth. The Go backend keeps a slim `auth.users` table that joins on `kratos_identity_id` for everything Echo cares about (age band, consent state, last-seen timestamp). This separation is what lets the team move data-residency boundaries without rewriting the auth flow.

## What's intentionally not here yet

- **OIDC (Apple, Google).** `T-CORE-022` (M2). Needs Apple/Google developer account secrets injected via the deployment's secret store; intentionally omitted until those exist.
- **MFA / WebAuthn.** `T-CORE-023` (V1).
- **A real SMTP courier.** Dev points at MailHog (added with the auth UI in `T-CLIENT-020`); production points at a transactional-email provider.

See [`AGENTS.md`](../../AGENTS.md) §"What AI agents should escalate to humans" — anything that changes the schema here is `human-review-required`.
