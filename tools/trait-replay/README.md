# `tools/trait-replay`

Replays a corpus of recorded playthroughs through the **same** rule-based
trait-scoring engine the server uses (`services/ml-py` →
`app.services.trait_scoring`) and asserts each one still produces its recorded
`TraitVector`. A drift means a content edit (or an engine change) shifted trait
vectors for *existing* playthroughs — a breaking change requiring human review
(AGENTS.md §4 / §10).

Reusing the production engine is deliberate: a second implementation could
silently drift and make the gate lie.

## Layout

- `corpus/*.json` — recorded playthroughs. Each fixture:
  ```json
  {
    "playthrough_id": "season-001-morning-aware",
    "season_id": "season-001",
    "events": [{ "vignette_id": "vignette-001", "choice_id": "choice-1" }],
    "expected": { "big_five": [...5], "schwartz": [...10], "attachment": [...3] }
  }
  ```
- The runner lives at `services/ml-py/app/tools/trait_replay.py` so it can
  import the engine and is covered by ml-py's ruff/mypy/pytest.

## Run

```bash
make replay          # compare every corpus fixture against its baseline
make replay-update   # re-record baselines after a human-reviewed content change
```

`make replay` exits non-zero on any drift or missing baseline. After an
**intentional** season-content change that shifts vectors, run
`make replay-update`, review the diff, and note it in the PR with a
`human-review-required` label.
