# `services/ml-py`

The Echo ML service. Per `docs/05_Technical_Architecture.md` this is a Python
process that owns trait scoring, Portrait generation, reflection generation,
and the safety/tone classifiers.

## Layout

```
services/ml-py/
├── app/
│   ├── main.py              # FastAPI app: /healthz, /readyz
│   └── services/
│       ├── trait_scoring.py     # M1 (T-ML-010)
│       ├── portrait_gen.py      # M2 (T-ML-030)
│       └── reflection_gen.py    # M2 (T-ML-040)
└── tests/
```

## Run

```bash
uv sync
uv run uvicorn app.main:app --reload
```

## Verify

```bash
uv run pytest -q
uv run ruff check .
uv run ruff format --check .
uv run mypy app
```
