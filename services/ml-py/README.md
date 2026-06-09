# `services/ml-py`

The Echo ML service. Per `docs/05_Technical_Architecture.md` this is a Python
process that owns trait scoring, Portrait generation, reflection generation,
and the safety/tone classifiers.

## Layout

```
services/ml-py/
├── app/
│   ├── main.py                  # FastAPI app: /healthz, /readyz
│   ├── grpc_server.py           # gRPC server (TraitScoringService)
│   ├── grpc_gen/                # protoc-generated stubs (committed; regenerate via `make proto`)
│   └── services/
│       ├── trait_scoring.py     # M1 (T-ML-010) — implemented
│       ├── portrait_gen.py      # M2 (T-ML-030)
│       └── reflection_gen.py    # M2 (T-ML-040)
└── tests/
```

## Run

```bash
uv sync

# HTTP /healthz, /readyz
uv run uvicorn app.main:app --reload

# gRPC TraitScoringService (default :50051)
uv run python -m app.grpc_server
```

The Go core service dials the gRPC server via `ML_GRPC_ADDR` (e.g.
`ML_GRPC_ADDR=127.0.0.1:50051`); when that env var is unset, trait
scoring is disabled and `POST /playthroughs/{id}/finalize` returns 503.

## Verify

```bash
uv run pytest -q
uv run ruff check .
uv run ruff format --check .
uv run mypy app
```
