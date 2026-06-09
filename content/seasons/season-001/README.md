# Season 001 — *The Stranger's Tuesday*

> **Status:** placeholder for M0 foundation. Real Season 1 writing is M2 scope per `docs/10_Roadmap_Milestones.md`. Voice and weights here are illustrative; the editorial pass that produces the shipped Season 1 has not happened yet.

This directory holds the canonical machine-readable definition of Season 1:

- `season.json` — the validated content file. Loaded by `core-go`, scored by `ml-py`, validated in CI by `tools/content-validator`.

## Editing conventions

- All vignettes must validate against `packages/content-schema/season.schema.json`.
- `setting_beat` text follows the voice rules in `docs/04_Game_Design.md` §"Shape of a Vignette": specific, present-tense, no generic flavor.
- Choice labels are natural language, never archetypes.
- Trait weights are recorded with a `rationale` field for the audit trail.

Any change here that alters trait weights for a vignette the engine has already scored counts as a content-breaking change under `docs/07_AI_Agent_Implementation_Guide.md` and requires re-running `make replay` against the test corpus.
