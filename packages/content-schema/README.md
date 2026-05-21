# `@echo/content-schema`

JSON Schemas for the content pipeline. Source of truth for the shape of a
`Season`, `Act`, `Vignette`, `Choice`, and `TraitWeight`. Per
`docs/07_AI_Agent_Implementation_Guide.md` T-CONTENT-001.

## Files

| Schema | Description |
|---|---|
| `season.schema.json` | One full Season (4 acts, 15-25 vignettes total). |
| `act.schema.json` | One Act within a Season (Morning / Midday / Afternoon / Evening). |
| `vignette.schema.json` | One decision moment. Setting beat + 2-4 choices + optional resolution beats. |
| `choice.schema.json` | One natural-language option with associated trait weights. |
| `trait_weight.schema.json` | One signed contribution to a single trait dimension. |

Schemas are JSON Schema **Draft 07** for compatibility with the broadest
toolchain (Ajv in Node, jsonschema in Python, json_schema in Dart).

## Validating

The content validator at `tools/content-validator/` uses these schemas via
`Ajv`. Run:

```bash
make validate-content
# or directly:
pnpm --filter @echo/content-validator run validate
```

## Versioning

When the schemas change in a breaking way (renamed field, narrower enum), a new
schema version must be published rather than mutating in place. Until V1 we are
free to evolve the schemas; once Seasons are in production, additive-only.

## See also

- `docs/04_Game_Design.md` — gameplay model that drives these schemas.
- `docs/07_AI_Agent_Implementation_Guide.md` — task IDs and acceptance criteria.
- `content/seasons/season-001/` — the canonical sample Season validated by CI.
