# Contributing to Echo

> Read [`AGENTS.md`](./AGENTS.md) first. It's the binding rule set; this file gives you the day-one walk-through.

## Getting set up

You need the versions pinned in [`.tool-versions`](./.tool-versions). With `mise`:

```bash
mise install
mise current   # should list go, python, node at the pinned versions
make bootstrap
docker compose up -d
make migrate
make test
```

If any of those fail on a clean machine, that itself is a bug — open an issue or PR.

## Workflow

1. **Pick a task.** Tasks live in [`docs/07_AI_Agent_Implementation_Guide.md`](./docs/07_AI_Agent_Implementation_Guide.md) with stable IDs.
2. **Branch** as `<type>/<task-id>-<short-slug>`. Example: `feat/T-CLIENT-014-vignette-renderer`.
3. **Write tests first** for any new behavior — no PR without tests. Coverage targets in [`AGENTS.md`](./AGENTS.md).
4. **Run the golden commands** before pushing:
   ```bash
   make lint
   make test
   make build
   make validate-content
   ```
5. **Conventional Commits.** `feat(client): ...`, `fix(core-go): ...`, `chore(infra): ...`.
6. **PR description** should reference the task ID(s) the PR closes and any acceptance criteria touched.

## What needs human review

Anything in the list under [`AGENTS.md` §"What AI agents should escalate to humans"](./AGENTS.md) must be opened with the `human-review-required` label and a reviewer assigned. AI agents must not auto-merge in those areas.

## Reporting safety issues

If you find a content-safety or privacy issue, do **not** open a public issue. Email the maintainer directly. See `SECURITY.md` (added at M2 when the responsible-disclosure process is formalized).
