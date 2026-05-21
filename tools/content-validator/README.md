# `@echo/content-validator`

Node CLI that validates every `season.json` under `content/seasons/` against
the JSON Schemas in `packages/content-schema/`.

Per `docs/07_AI_Agent_Implementation_Guide.md` T-CONTENT-001: the validator
must pass on the sample Season. CI runs it as part of `make validate-content`.

## Use

```bash
pnpm install
pnpm --filter @echo/content-validator run validate

# or from the repo root:
make validate-content
```

## Self-check

```bash
node bin/validate.js --self-check
```

Compiles all schemas and exits 0; useful as a precommit smoke test that the
schema package itself hasn't been broken.
