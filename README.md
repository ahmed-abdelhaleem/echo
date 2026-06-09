# Echo

> *A game that plays you back.*

Echo is a cross-platform personality-discovery game for adolescents and young adults, with a layered SaaS / B2B revenue model. Players live one fictional day in a stranger's life; their micro-decisions are silently mapped to validated psychological dimensions (Big Five, Schwartz values, attachment style), and at the end the game generates a unique visual Portrait and short prose reflection of who the player actually is.

This repository is a monorepo containing the Flutter client (iOS / Android / Windows / macOS), the Go and Python backend services, infrastructure, and the curated content that drives the experience.

## Documentation

All founding documents live in [`docs/`](./docs). Start with [`docs/00_README.md`](./docs/00_README.md) for the index and reading order.

If you only have time for three:

1. [`docs/01_Product_Vision.md`](./docs/01_Product_Vision.md) — what Echo is and why
2. [`docs/06_Tech_Stack.md`](./docs/06_Tech_Stack.md) — exact technologies and rationale
3. [`docs/10_Roadmap_Milestones.md`](./docs/10_Roadmap_Milestones.md) — phased plan from day 0 to Series A

AI coding agents should additionally read [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md) before starting any task.

## Repository layout

```
apps/         Flutter client and web surfaces
services/    Go core service and Python ML service
packages/    Shared schemas, protobufs, design tokens
infra/        Docker, Kubernetes, Fly.io, Terraform, ArgoCD
content/     Seasons, reflection templates, art tokens
tools/        Content validator, playthrough simulator, trait replay
docs/         Founding documentation
```

The full layout and conventions are documented in [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md).

## Getting started

The toolchain is pinned via [`.tool-versions`](./.tool-versions) (managed by [`mise`](https://mise.jdx.dev) or `asdf`):

```bash
mise install
```

Service-level setup, build, and test instructions will be added per service as they land in milestone M0.

## Status

Pre-build, founding documentation phase. The repository is being initialized against milestone **M0 — Foundation** (see [`docs/10_Roadmap_Milestones.md`](./docs/10_Roadmap_Milestones.md)).
