# Reflection templates

> **Human-review required.** Changes to anything in this directory beyond formatting must be reviewed by a human per [`AGENTS.md` §10.6](../../AGENTS.md). The M2 reflection pipeline relies on these templates to deliver Echo's voice (docs/04 §"The prose reflection") with a controllable, auditable surface; silent edits would shift the reflection a million players receive.

## What is a template?

Each `*.template.json` file is one voice-tested reflection profile. The runtime selector (`services/ml-py/app/services/reflection_templates.py::select_candidates`) matches a player's trait vector against every template's `applies_when` block and ranks the candidates by priority + signal strength. The reflection pipeline (T-ML-042, lands in PR D) picks the top candidate (or blends the top two) and passes the chosen template's voice notes + exemplars into the LLM prompt.

The contract for each template is the JSON Schema at [`packages/content-schema/reflection_template.schema.json`](../../packages/content-schema/reflection_template.schema.json), validated by the content-validator (`make validate-content`).

## What the M2 library covers

The library opens with **52 templates** chosen to span the trait space without being exhaustive:

| Group                  | Count | Priority | Notes |
|------------------------|-------|----------|-------|
| Big Five, single dim   |  10   |    50    | high + low for each of the five OCEAN dimensions |
| Schwartz, single dim   |  20   |    50    | high + low for each of the ten Schwartz dimensions |
| Attachment, prominent  |   3   |    55    | secure / anxious / avoidant — only the prominent pole reads |
| Two-dim contrasts      |  10   |    65    | curious-impulsive, steady-builder, warm-uncertain, etc. |
| Three-dim clusters     |   5   |    75    | open-experience, conservative-achiever, tending-circle, etc. |
| Meta + universal       |   4   | 20–70    | muted-day, contradictory-day, balanced-day, fallback-generic |

A few intentional gaps the M2.x cycles will fill:
- We do **not** ship low-attachment templates (e.g. "low secure"). docs/04 frames attachment as a single-pole signal: prominence reads as the style being present today; absence is silent.
- We do not yet ship cluster templates for the *low* poles of clusters (e.g. "low achievement + low conformity + low tradition"). The selector falls back to single-dim templates for those vectors, then to the universal fallback.

## Voice rules (binding on every template)

Mirrored verbatim from docs/04 §"Voice rules":

- **Always second person.** `You...` never `the user`.
- **Always specific.** A reflection that could describe anyone is a failed reflection.
- **Never flattering, never roasting.** Describe; do not evaluate.
- **No clinical terms.** No `neurotic`, `narcissistic`, `avoidant`, `depressed`.
- **No archetypes.** No `the helper`, `the rebel`, `the explorer`, `the curious one`.
- **Acknowledge contradiction** where the data supports it.

Each template's `voice_notes.emphasize` block weights up the subset of these rules that matter most for its profile (e.g. `acknowledge_contradiction` is critical for the two-dim contrasts; `no_clinical_term` is critical for the neuroticism + attachment templates). The `voice_notes.avoid` block lists profile-specific phrases that the LLM and the tone classifier must reject (e.g. the high-extraversion template forbids `you are an extrovert`).

## How to add or change a template

1. Add a `<id>.template.json` file in this directory (or edit an existing one).
2. Run `make validate-content` — the validator runs the JSON Schema, checks `id` matches the filename, and re-runs the Python loader test suite.
3. Run `pytest services/ml-py/tests/test_reflection_templates.py` to verify that every exemplar still passes the voice-rule checks (second-person, sentence count, no forbidden terms).
4. Open the PR with the `human-review-required` label per AGENTS.md §10.6.

## What lands in PR D (T-ML-042)

PR D wires this library into the actual reflection pipeline:

1. The pipeline takes a trait vector and a few "signal moments" from the playthrough.
2. It calls `select_candidates(...)` and picks the top candidate (or, when two candidates score within ~10% of each other, blends both).
3. It builds an LLM prompt from the chosen template's exemplars + voice notes + the player's signal moments.
4. It runs the LLM output through the safety classifier (no clinical / no self-harm) and the tone classifier (recognisably Echo's voice).
5. On classifier failure, it falls back to a curated string per docs/04 §"Generation pipeline".
