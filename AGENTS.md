# AGENTS.md

> Conventions binding on **AI coding agents** (Claude Code, Cursor, Devin, Aider, etc.) and the humans supervising them. Excerpted and condensed from [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md), which is authoritative when this file is ambiguous.

## Read these first

Before doing anything in this repo, read the relevant docs in `docs/`:

- Product-level context: `01_Product_Vision`, `03_Product_Requirements`, `04_Game_Design`.
- Technical context: `05_Technical_Architecture`, `06_Tech_Stack`, `07_AI_Agent_Implementation_Guide`.
- Privacy and youth-safe context: `08_Data_Privacy_Compliance`.

## Naming

- **Files:** `snake_case` for Go, Python, and content YAML/JSON; `lower_snake_case.dart` for Dart; `kebab-case.ts` for web TypeScript.
- **Types and classes:** `PascalCase` everywhere.
- **Constants:** `SCREAMING_SNAKE_CASE`.
- **Postgres:** `snake_case`, tables plural (`users`, `playthroughs`, `vignette_events`); columns `snake_case`.
- **GraphQL fields:** `camelCase`.
- **Protobuf field names:** `snake_case` per protobuf style guide.

## Branching and commits

- Branch naming: `<type>/<task-id>-<short-slug>`, e.g. `feat/T-CLIENT-014-vignette-renderer`.
- Conventional Commits: `feat(client): ...`, `fix(core-go): ...`, `chore(infra): ...`.
- Squash-merge into `main`. `main` is always deployable.

## Testing requirements

- **No PR without tests** for new behavior.
- Coverage targets: Go ≥75% line per package, Python ≥75% line per module, Dart widget + golden tests for any visual surface.
- Tests must be deterministic. No flake-tolerated tests in CI.
- Golden tests are required for any Portrait rendering code.

## Safety rails — hard rules

- **Database migrations must be backwards-compatible** (additive, never destructive in a single deploy). Drop columns/tables only after observability confirms no traffic.
- **Never commit secrets.** CI verifies via `gitleaks`.
- **Adding a new top-level dependency requires explicit justification** in the PR description.
- **No `force-push` to `main` or any release branch.**

## What AI agents should escalate to humans

These categories should never be merged by an AI agent without human review:

1. New top-level dependency in any service.
2. Schema migration that drops or renames columns / tables / schemas.
3. Changes to authentication, authorization, or session handling.
4. Changes to the trait scoring engine that could shift trait vectors for existing playthroughs.
5. Changes to safety or tone classifiers.
6. Changes touching anything in `/content/reflection-templates/` beyond formatting.
7. Changes to age-gating, consent flows, or anything in the youth-safe path.
8. Changes to data-residency configuration, region pinning, or backup encryption.
9. Anything that affects the public API contract used by clients in the wild.
10. Changes to billing logic.

When a task touches one of these, open the PR with a `human-review-required` label, a clear summary of the impact, and stop.

## Verification — golden command list

Any agent finishing a task should be able to run, from the repo root:

```bash
make lint                  # All linters
make test                  # All unit + integration tests
make build                 # All build targets for current platform
make validate-content      # tools/content-validator over content/
```

All four must exit zero before claiming a task complete.

For schema or content changes, additionally:

```bash
make replay                # tools/trait-replay over a corpus of test playthroughs
```

If a content change causes `replay` to produce *different* trait vectors for unchanged playthroughs, that is a breaking change and requires human review.

## Working agreement

- Prefer asking targeted questions over making invisible assumptions. Especially on the trait-engine and youth-safe paths.
- When a task is ambiguous, write the most boring, smallest, most reversible solution that satisfies the acceptance criteria.
- When choosing between two valid approaches, leave a clearly-labeled comment with the choice and the alternative considered, and proceed.
- Conformance failures (lint, format, naming) block merge regardless of correctness.
