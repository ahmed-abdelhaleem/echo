# Echo

> *A game that plays you back.*

Echo is a cross-platform personality-discovery game. Players live one fictional day in a stranger's life and the decisions they make are silently mapped to validated psychological dimensions (Big Five, Schwartz values, attachment proxies). The output is a beautiful, shareable visual Portrait + a short prose reflection.

Founding documentation lives in [`docs/`](./docs/). Start with [`docs/00_README.md`](./docs/00_README.md) and read in order.

---

## Status

- **Stage.** Phase G — the Unity 6 Personal build now has a connected,
  playable three-vignette loop across Bedroom, Harbor Street, and Café. All
  three have third-person movement, objectives, interactions, choices,
  resolutions, Mixamo animation/fallbacks, and scene-specific CC0 PBR assets.
  External art-direction, accessibility, performance, asset/brand, and
  youth-safe review still block scaling to the rest of Season 1.
- **Build order.** Finish the anonymous/offline game and pass the Game-Complete gate before accounts, monetization, sharing, or B2B. See [`docs/10_Roadmap_Milestones.md`](./docs/10_Roadmap_Milestones.md).
- **Repo layout.** Defined in [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md) §"Monorepo layout".

---

## Quick start

You need the versions pinned in [`.tool-versions`](./.tool-versions). The easiest way is `mise` or `asdf`:

```bash
mise install      # installs Go, Python, Node at pinned versions
make bootstrap    # installs per-language deps (Go modules, uv venv, pnpm)
cp -n .env.example .env   # local env for core-go (gitignored)
docker compose up -d   # Postgres 16 + Redis 7 + NATS 2.10 + Kratos
make migrate      # runs Postgres migrations
make test         # run all tests
```

Once that is green you can run:

```bash
make unity-test          # Unity play-mode test
make unity-build-macos   # standalone apps/unity-client/Builds/macOS/Echo.app
make dev          # prints the three-terminal local workflow
make dev-core     # terminal 1 — core-go on :8081 (see .env.example)
make client       # legacy/fallback Flutter client
```

For full setup details see [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md) §"Setup — first run from clean machine".

---

## Top-level layout

```
echo/
├── apps/
│   ├── client/              # Flutter — iOS, Android, Windows, macOS, web, Linux
│   ├── unity-client/        # Unity 6 Personal — authoritative explorable 3D game
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
