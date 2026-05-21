# Echo

> *A game that plays you back.*

Echo is a cross-platform personality-discovery game. Players live one fictional day in a stranger's life and the decisions they make are silently mapped to validated psychological dimensions (Big Five, Schwartz values, attachment proxies). The output is a beautiful, shareable visual Portrait + a short prose reflection.

Founding documentation lives in [`docs/`](./docs/). Start with [`docs/00_README.md`](./docs/00_README.md) and read in order.

---

## Status

- **Stage.** M0 (Foundation) — backend scaffolding, content schema, CI in place.
- **Next milestones.** M1 (vertical-slice playthrough), M2 (MVP closed beta on iOS+Android). See [`docs/10_Roadmap_Milestones.md`](./docs/10_Roadmap_Milestones.md).
- **Repo layout.** Defined in [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md) §"Monorepo layout".

---

## Quick start

You need the versions pinned in [`.tool-versions`](./.tool-versions). The easiest way is `mise` or `asdf`:

```bash
mise install      # installs Go, Python, Node at pinned versions
make bootstrap    # installs per-language deps (Go modules, uv venv, pnpm)
docker compose up -d   # Postgres 16 + Redis 7 + NATS 2.10
make migrate      # runs Postgres migrations
make test         # run all tests
```

Once that is green you can run:

```bash
make dev          # core-go + ml-py in watch mode
```

For full setup details see [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md) §"Setup — first run from clean machine".

---

## Top-level layout

```
echo/
├── apps/
│   ├── client/              # Flutter — iOS, Android, Windows, macOS (PR 2)
│   ├── share-web/           # Public Portrait sharing pages (M2)
│   └── b2b-dashboard/       # Institutional web dashboard (V2)
├── services/
│   ├── core-go/             # Modular monolith: auth, users, playthroughs, events, sharing, org
│   └── ml-py/               # Trait scoring, Portrait gen, reflection gen, safety classify
├── packages/
│   ├── proto/               # Protobuf + GraphQL schemas
│   ├── design-tokens/       # Shared design tokens (M2)
│   └── content-schema/      # JSON Schemas for Seasons/Vignettes/Choices/Weights
├── infra/
│   ├── docker/              # Dockerfiles, local-dev compose
│   ├── k8s/                 # Kubernetes manifests (M3+)
│   ├── flyio/               # Fly.io configs (phase-0 hosting)
│   ├── terraform/           # Cloud resources (M3+)
│   └── argocd/              # GitOps manifests (M3+)
├── content/                 # Season JSON, reflection templates, art tokens
├── tools/                   # CLIs: content-validator, playthrough-sim, trait-replay
├── docs/                    # Founding documentation (read in numerical order)
├── .github/workflows/       # CI
├── .tool-versions           # Pinned toolchain (mise/asdf)
├── docker-compose.yml       # One-command local stack
├── Makefile                 # Standard entry points
└── AGENTS.md                # Conventions binding on AI agents and humans
```

---

## Conventions

See [`AGENTS.md`](./AGENTS.md) and [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md). Highlights:

- **Branch naming:** `<type>/<task-id>-<short-slug>`, e.g. `feat/T-CLIENT-014-vignette-renderer`.
- **Conventional Commits:** `feat(client): ...`, `fix(core-go): ...`, `chore(infra): ...`.
- **Tests required for new behavior.** Targets: ≥75% line coverage for Go and Python packages.
- **Migrations are additive only.** Drops happen in separate deploys after observability confirms.
- **Auth, age-gating, consent, trait engine, safety classifiers, content templates, billing, data residency** — all require human review (see [`AGENTS.md`](./AGENTS.md) §"What AI agents should escalate to humans").

---

## License

To be decided. See the build plan attached to PR #1.
