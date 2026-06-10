# `@echo/content-validator`

Node CLI that validates content against the JSON Schemas in
`packages/content-schema/`: every `season.json` under `content/seasons/`, every
`*.template.json` under `content/reflection-templates/`, every
`*.manifest.json` under `content/assets-3d/` (3D asset manifests), and every
`*.manifest.json` under `content/backdrops/` (vignette atmospheric backdrops).

Per `docs/07_AI_Agent_Implementation_Guide.md` T-CONTENT-001 / T-CONTENT-004 /
T-CONTENT-005: the validator must pass on the sample content. CI runs it as
part of `make validate-content`.

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

## 3D asset manifests

Asset manifests (T-CONTENT-004) are validated against `asset_manifest.schema.json`
plus rules JSON Schema can't express: unique asset ids, `image-to-3d` requires a
reference, and each asset's `content_address` must equal the hash of its
generation inputs (see `lib/content_address.js`). Validate just these with:

```bash
node bin/validate.js --only assets
# or from the repo root:
make validate-assets
```

## Vignette backdrop manifests

Backdrop manifests (T-CONTENT-005) under `content/backdrops/` are validated
against `vignette_backdrop.schema.json` plus rules JSON Schema can't express:
at most one backdrop per `vignette_id`, and unique layer ids within a
backdrop. Validate just these with:

```bash
node bin/validate.js --only backdrops
# or from the repo root:
make validate-backdrops
```
